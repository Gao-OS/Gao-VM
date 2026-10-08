import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OwnedImageDirectory bundles;
  late OwnedImageDirectory images;
  late VmSpec spec;
  late PublicApiServer server;
  late HttpClient client;

  setUp(() async {
    temporary =
        await (Platform.isMacOS
                ? Directory('/private/tmp')
                : Directory.systemTemp)
            .createTemp('gvm-log-api-');
    imageFileMode(temporary.path, 0x1c0);
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    final bundleDirectory = await Directory('${temporary.path}/vms').create();
    imageFileMode(bundleDirectory.path, 0x1c0);
    bundles = await OwnedImageDirectory.open(bundleDirectory);
    final source = await File(
      '${temporary.path}/kernel',
    ).writeAsString('kernel');
    final imageDirectory = Directory('${temporary.path}/images');
    final kernel = await ImageStore(
      database,
      imageDirectory,
    ).importFile(source, type: ImageType.linuxKernel);
    imageFileMode(imageDirectory.path, 0x1c0);
    images = await OwnedImageDirectory.open(imageDirectory);
    spec = VmSpec(
      cpu: 2,
      memoryBytes: 268435456,
      boot: LinuxKernelBoot(kernelImageId: kernel.id),
      disks: [
        VmDisk(
          id: 'root',
          source: ExternalDiskSource(source.path),
          writable: true,
        ),
      ],
      networks: [DisconnectedNetwork(id: 'net0')],
      graphics: GraphicsConfig(enabled: false),
      serial: const SerialConfig(enabled: true, capture: true),
      guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
      restartPolicy: RestartPolicy.never,
    );
    final router = PublicApiRouter();
    VmLogApiHandlers(
      logs: VmLogApplicationService(database: database, bundles: bundles),
    ).register(router);
    server = PublicApiServer(
      socketPath: '${temporary.path}/api.sock',
      openApiDocument: const {},
      systemHealth: _Health(),
      router: router,
    );
    client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (_, _, _) => Socket.startConnect(
        InternetAddress(server.socketPath, type: InternetAddressType.unix),
        0,
      );
    await server.start();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
    images.close();
    bundles.close();
    database.close();
    await temporary.delete(recursive: true);
  });

  Future<VmId> createVm(String name, {bool publish = true}) async {
    final accepted =
        await SqliteVmCreateAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 30),
        ).accept(
          VmCreateCommand(
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
            name: name,
            spec: spec,
          ),
        );
    final id = accepted.resourceId as VmId;
    if (publish) {
      final job = (await SqliteVmProvisioningRepository(database).get(id))!;
      await VmBundleStore(
        database: database,
        bundles: bundles,
        images: images,
      ).withBundle(job.plan, (bundle) => bundle.publish());
    }
    return id;
  }

  String bundlePath(VmId id) => '${bundles.path}/${id.value}.gaovm';

  Future<void> completeProvisioning() async {
    final outcomes = await VmProvisioningWorker(
      work: SqliteVmProvisioningWorkRepository(database),
      bundles: VmBundleStore(
        database: database,
        bundles: bundles,
        images: images,
      ),
      owner: 'vm-log-api-test',
    ).dispatchOnce();
    expect(outcomes, hasLength(1));
    expect(outcomes.single.kind, VmProvisioningOutcomeKind.completed);
    expect(outcomes.single.completion, VmProvisioningCompletionKind.succeeded);
  }

  Future<({int status, Map<String, dynamic> body, HttpHeaders headers})>
  getJson(String path, {String? body}) async {
    final request = await client.getUrl(Uri.parse('http://localhost$path'));
    if (body != null) {
      request.headers.contentType = ContentType.json;
      final bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 5));
    return (
      status: response.statusCode,
      body:
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
      headers: response.headers,
    );
  }

  test(
    'lists current per-VM log metadata without bytes or host paths',
    () async {
      final first = await createVm('first');
      final second = await createVm('second');
      final expected = <Map<String, Object?>>[];
      for (final kind in ['driver', 'serial', 'guest']) {
        final file = await File(
          '${bundlePath(first)}/logs/$kind.log',
        ).writeAsString('private $kind log contents');
        await file.setLastModified(DateTime.utc(2021, 2, 3, 4, 5, 6));
        final stat = await file.stat();
        expected.add({
          'kind': kind,
          'vm_id': first.value,
          'size_bytes': stat.size,
          'updated_at': stat.modified.toUtc().toIso8601String(),
          'artifact_id': null,
        });
      }
      await File(
        '${bundlePath(second)}/logs/driver.log',
      ).writeAsString('other VM');
      await File(
        '${bundlePath(first)}/logs/driver.log.1',
      ).writeAsString('rotation');
      await File(
        '${bundlePath(first)}/logs/unrelated',
      ).writeAsString('not a log');

      final response = await getJson('/v1/vms/${first.value}/logs');
      expect(response.status, 200);
      expect(response.body, {'items': expected});
      expect(response.headers.contentType?.mimeType, 'application/json');
      expect(
        () => RequestId(response.headers.value('x-request-id')!),
        returnsNormally,
      );
      expect(jsonEncode(response.body), isNot(contains(temporary.path)));
      expect(jsonEncode(response.body), isNot(contains('private')));
      expect(jsonEncode(response.body), isNot(contains(second.value)));
    },
  );

  test(
    'kind filters return only existing current files and fresh metadata',
    () async {
      final id = await createVm('filtered');
      final path = '/v1/vms/${id.value}/logs';
      final empty = await getJson(path);
      expect(empty.status, 200);
      expect(empty.body, {'items': []});
      final driver = await File(
        '${bundlePath(id)}/logs/driver.log',
      ).writeAsString('a');
      await File('${bundlePath(id)}/logs/serial.log').writeAsString('serial');
      for (final (kind, count) in [
        ('driver', 1),
        ('serial', 1),
        ('guest', 0),
      ]) {
        final response = await getJson('$path?kind=$kind');
        expect(response.status, 200);
        final items = (response.body['items'] as List)
            .map(LogReference.fromJson)
            .toList();
        expect(items, hasLength(count));
        for (final item in items) {
          expect(item.kind.name, kind);
          expect(item.vmId, id);
          expect(item.artifactId, isNull);
        }
      }
      await driver.writeAsString('additional', mode: FileMode.append);
      await driver.setLastModified(DateTime.utc(2022, 3, 4, 5, 6, 7));
      final refreshed = await getJson('$path?kind=driver');
      final item = LogReference.fromJson(
        (refreshed.body['items'] as List).single,
      );
      expect(item.sizeBytes, 11);
      expect(item.updatedAt, DateTime.utc(2022, 3, 4, 5, 6, 7));
      await driver.rename('${driver.path}.1');
      final rotating = await getJson('$path?kind=driver');
      expect(rotating.status, 200);
      expect(rotating.body, {'items': []});
      await File(driver.path).writeAsString('next');
      final rotated = await getJson('$path?kind=driver');
      expect(
        LogReference.fromJson((rotated.body['items'] as List).single).sizeBytes,
        4,
      );
    },
  );

  test(
    'invalid log requests and unknown VMs return correlated Problems',
    () async {
      final id = await createVm('requests');
      final path = '/v1/vms/${id.value}/logs';
      for (final (url, body) in [
        ('$path?kind=', null),
        ('$path?kind=stdout', null),
        ('$path?kind=Driver', null),
        ('$path?kind=driver&kind=serial', null),
        ('$path?path=/outside', null),
        ('$path?limit=1', null),
        ('$path?kind=driver&cursor=abc', null),
        ('/v1/vms/default/logs', null),
        ('/v1/vms/${ImageId.generate().value}/logs', null),
        (path, '{}'),
        (path, '[]'),
        (path, 'null'),
      ]) {
        final response = await getJson(url, body: body);
        expect(response.status, 400, reason: '$url $body');
        final problem = Problem.fromJson(response.body);
        expect(problem.code, ErrorCode.invalidRequest);
        expect(problem.requestId.value, response.headers.value('x-request-id'));
        expect(problem.retryable, isFalse);
        expect(
          response.headers.contentType?.mimeType,
          'application/problem+json',
        );
        expect(jsonEncode(response.body), isNot(contains(temporary.path)));
      }
      final unknown = await getJson('/v1/vms/${VmId.generate().value}/logs');
      expect(unknown.status, 404);
      expect(Problem.fromJson(unknown.body).code, ErrorCode.vmNotFound);
      expect(unknown.body['request_id'], unknown.headers.value('x-request-id'));
    },
  );

  test('log discovery never snapshots bytes or mutates durable work', () async {
    final id = await createVm('read-only');
    final file = await File(
      '${bundlePath(id)}/logs/driver.log',
    ).writeAsString('preserve bytes');
    await file.setLastAccessed(DateTime.utc(2001, 1, 1));
    final fileBefore = await file.stat();
    final vms = SqliteVmRepository(database);
    final operations = SqliteOperationRepository(database);
    final events = SqliteEventRepository(database);
    final artifacts = ArtifactRepository(database);
    final vmBefore = await vms.get(id);
    final operationsBefore = await operations.list();
    final eventsBefore = await events.list();
    final outboxBefore = (await events.readUnpublishedOutbox())
        .map(_outboxState)
        .toList();
    final pathsBefore = await Directory(bundlePath(id))
        .list(recursive: true, followLinks: false)
        .map((entry) => entry.path)
        .toList();
    for (var attempt = 0; attempt < 3; attempt++) {
      final response = await getJson('/v1/vms/${id.value}/logs');
      expect(response.status, 200);
      expect((response.body['items'] as List).single['artifact_id'], isNull);
    }
    expect(await vms.get(id), vmBefore);
    expect(await operations.list(), operationsBefore);
    expect(await events.list(), eventsBefore);
    expect(
      (await events.readUnpublishedOutbox()).map(_outboxState).toList(),
      outboxBefore,
    );
    expect((await artifacts.list(ArtifactListQuery(owner: id))).items, isEmpty);
    expect(
      await Directory(bundlePath(id))
          .list(recursive: true, followLinks: false)
          .map((entry) => entry.path)
          .toList(),
      unorderedEquals(pathsBefore),
    );
    final fileAfter = await file.stat();
    expect(fileAfter.size, fileBefore.size);
    expect(fileAfter.modified, fileBefore.modified);
    expect(fileAfter.accessed, fileBefore.accessed);
    expect(fileAfter.mode, fileBefore.mode);
    expect(await file.readAsString(), 'preserve bytes');
  });

  test(
    'missing, corrupt, oversized and wrong-VM manifests fail as server Problems',
    () async {
      final id = await createVm('manifest');
      final other = await createVm('other-manifest');
      final manifest = File('${bundlePath(id)}/manifest.json');
      final original = await manifest.readAsString();
      final foreign = await File(
        '${bundlePath(other)}/manifest.json',
      ).readAsString();
      final log = await File(
        '${bundlePath(id)}/logs/driver.log',
      ).writeAsString('keep');
      for (final bytes in [
        '{',
        '{}',
        foreign,
        original.replaceFirst('sha256:', 'sha255:'),
      ]) {
        await manifest.writeAsString(bytes);
        final response = await getJson('/v1/vms/${id.value}/logs');
        expect(response.status, 500);
        expect(Problem.fromJson(response.body).code, ErrorCode.internalError);
        expect(
          response.body['request_id'],
          response.headers.value('x-request-id'),
        );
        expect(jsonEncode(response.body), isNot(contains(temporary.path)));
        expect(await manifest.readAsString(), bytes);
        expect(await log.readAsString(), 'keep');
      }
      final writer = await manifest.open(mode: FileMode.write);
      try {
        await writer.truncate(1024 * 1024 + 1);
      } finally {
        await writer.close();
      }
      expect((await getJson('/v1/vms/${id.value}/logs')).status, 500);
      expect(await manifest.length(), 1024 * 1024 + 1);
      await manifest.delete();
      final missing = await getJson('/v1/vms/${id.value}/logs');
      expect(missing.status, 500);
      expect(missing.body['code'], 'INTERNAL_ERROR');
      expect(await manifest.exists(), isFalse);
      expect(await log.readAsString(), 'keep');
    },
  );

  for (final component in ['bundle', 'logs', 'manifest', 'driver']) {
    test(
      'rejects a linked $component without following or replacing it',
      () async {
        final id = await createVm('linked-$component');
        final root = bundlePath(id);
        final log = await File(
          '$root/logs/driver.log',
        ).writeAsString('keep linked bytes');
        final String linkedPath;
        final String movedPath;
        if (component == 'bundle' || component == 'logs') {
          linkedPath = component == 'bundle' ? root : '$root/logs';
          movedPath = '${temporary.path}/original-$component';
          await Directory(linkedPath).rename(movedPath);
        } else {
          linkedPath = component == 'manifest'
              ? '$root/manifest.json'
              : log.path;
          movedPath = '${temporary.path}/original-$component';
          await File(linkedPath).rename(movedPath);
        }
        await Link(linkedPath).create(movedPath);
        final response = await getJson('/v1/vms/${id.value}/logs');
        expect(response.status, 500);
        expect(Problem.fromJson(response.body).code, ErrorCode.internalError);
        expect(
          response.body['request_id'],
          response.headers.value('x-request-id'),
        );
        expect(jsonEncode(response.body), isNot(contains(temporary.path)));
        expect(await Link(linkedPath).target(), movedPath);
        expect(await log.readAsString(), 'keep linked bytes');
      },
    );
  }

  for (final component in ['manifest', 'driver']) {
    test(
      'rejects a hard-linked $component without changing either name',
      () async {
        final id = await createVm('hard-linked-$component');
        final root = bundlePath(id);
        final source = component == 'manifest'
            ? File('$root/manifest.json')
            : await File(
                '$root/logs/driver.log',
              ).writeAsString('keep hard-linked bytes');
        final bytes = await source.readAsBytes();
        final alias = '${temporary.path}/alias-$component';
        final linked = await Process.run('ln', [source.path, alias]);
        expect(linked.exitCode, 0, reason: '${linked.stderr}');
        final response = await getJson('/v1/vms/${id.value}/logs');
        expect(response.status, 500);
        expect(response.body['code'], 'INTERNAL_ERROR');
        expect(jsonEncode(response.body), isNot(contains(temporary.path)));
        expect(await source.readAsBytes(), bytes);
        expect(await File(alias).readAsBytes(), bytes);
      },
    );
  }

  for (final component in ['bundles', 'bundle', 'logs', 'manifest', 'driver']) {
    test(
      'rejects unsafe $component permissions without repairing them',
      () async {
        final id = await createVm('unsafe-$component');
        final root = bundlePath(id);
        final log = await File(
          '$root/logs/driver.log',
        ).writeAsString('keep permissions');
        final target = switch (component) {
          'bundles' => bundles.path,
          'bundle' => root,
          'logs' => '$root/logs',
          'manifest' => '$root/manifest.json',
          _ => log.path,
        };
        final unsafeMode = component == 'manifest' || component == 'driver'
            ? 0x1b6
            : 0x1ff;
        imageFileMode(target, unsafeMode);
        final response = await getJson('/v1/vms/${id.value}/logs');
        expect(response.status, 500);
        expect(response.body['code'], 'INTERNAL_ERROR');
        expect(jsonEncode(response.body), isNot(contains(temporary.path)));
        expect((await FileStat.stat(target)).mode & 0x1ff, unsafeMode);
        expect(await log.readAsString(), 'keep permissions');
      },
    );
  }

  test(
    'rejects a replaced bundle root instead of consulting its replacement',
    () async {
      final id = await createVm('replaced-root');
      await File(
        '${bundlePath(id)}/logs/driver.log',
      ).writeAsString('original log');
      final moved = await Directory(
        bundles.path,
      ).rename('${temporary.path}/original-vms');
      final replacement = await Directory(bundles.path).create();
      imageFileMode(replacement.path, 0x1c0);
      final response = await getJson('/v1/vms/${id.value}/logs');
      expect(response.status, 500);
      expect(response.body['code'], 'INTERNAL_ERROR');
      expect(jsonEncode(response.body), isNot(contains(temporary.path)));
      expect(await replacement.list().isEmpty, isTrue);
      expect(
        await File(
          '${moved.path}/${id.value}.gaovm/logs/driver.log',
        ).readAsString(),
        'original log',
      );
    },
  );

  for (final type in ['directory', 'fifo', 'dangling-link']) {
    test('rejects a $type log without blocking or removing it', () async {
      final id = await createVm('special-$type');
      final path = '${bundlePath(id)}/logs/driver.log';
      if (type == 'directory') {
        await Directory(path).create();
      } else if (type == 'fifo') {
        final result = await Process.run('mkfifo', [path]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      } else {
        await Link(path).create('${temporary.path}/missing-log');
      }
      final before = await FileSystemEntity.type(path, followLinks: false);
      final response = await getJson('/v1/vms/${id.value}/logs');
      expect(response.status, 500);
      expect(response.body['code'], 'INTERNAL_ERROR');
      expect(jsonEncode(response.body), isNot(contains(temporary.path)));
      expect(await FileSystemEntity.type(path, followLinks: false), before);
    });
  }

  test(
    'unproduced logs are empty and tombstoned VMs are not rediscovered',
    () async {
      final pending = await createVm('not-published', publish: false);
      final pendingPath = bundlePath(pending);
      final response = await getJson('/v1/vms/${pending.value}/logs');
      expect(response.status, 200);
      expect(response.body, {'items': []});
      expect(await Directory(pendingPath).exists(), isFalse);

      final id = await createVm('no-logs-yet');
      final logs = Directory('${bundlePath(id)}/logs');
      await logs.delete();
      final missingLogs = await getJson('/v1/vms/${id.value}/logs');
      expect(missingLogs.status, 200);
      expect(missingLogs.body, {'items': []});
      expect(await logs.exists(), isFalse);
      final vms = SqliteVmRepository(database);
      final vm = (await vms.get(id))!;
      final deleting = await vms.markDeleting(
        id,
        expectedRevision: vm.metadata.revision,
      );
      await vms.tombstone(id, expectedRevision: deleting.metadata.revision);
      final deleted = await getJson('/v1/vms/${id.value}/logs');
      expect(deleted.status, 404);
      expect(deleted.body['code'], 'VM_NOT_FOUND');
      expect(await Directory(bundlePath(id)).exists(), isTrue);
    },
  );

  test(
    'a newer catalog spec does not invalidate the pinned bundle origin',
    () async {
      final id = await createVm('staged-spec');
      await completeProvisioning();
      await File(
        '${bundlePath(id)}/logs/driver.log',
      ).writeAsString('old generation');
      final repository = SqliteVmRepository(database);
      final vm = (await repository.get(id))!;
      final updated = await repository.updateSpec(
        id,
        expectedRevision: vm.metadata.revision,
        spec: VmSpec.fromJson({...vm.spec.toJson(), 'cpu': vm.spec.cpu + 1}),
      );
      expect(updated.status.specGeneration, vm.status.specGeneration + 1);
      final response = await getJson('/v1/vms/${id.value}/logs');
      expect(response.status, 200);
      expect(
        LogReference.fromJson(
          (response.body['items'] as List).single,
        ).sizeBytes,
        14,
      );
      expect(await repository.get(id), updated);
    },
  );

  test(
    'a missing committed bundle is not silently reported as unproduced logs',
    () async {
      final id = await createVm('lost-bundle');
      await completeProvisioning();
      final job = (await SqliteVmProvisioningRepository(database).get(id))!;
      expect(job.completion?.kind, VmProvisioningCompletionKind.succeeded);
      await Directory(bundlePath(id)).delete(recursive: true);
      final before = await SqliteOperationRepository(
        database,
      ).get(job.plan.operationId);
      final response = await getJson('/v1/vms/${id.value}/logs');
      expect(response.status, 500);
      expect(response.body['code'], 'INTERNAL_ERROR');
      expect(jsonEncode(response.body), isNot(contains(temporary.path)));
      expect(await Directory(bundlePath(id)).exists(), isFalse);
      expect(
        await SqliteOperationRepository(database).get(job.plan.operationId),
        before,
      );
      expect(await File('${temporary.path}/kernel').readAsString(), 'kernel');
    },
  );
}

List<Object?> _outboxState(OutboxRecord item) => [
  item.id,
  item.topic,
  item.key,
  item.payload,
  item.createdAt,
  item.publishedAt,
  item.attempts,
  item.claimedBy,
  item.claimExpiresAt,
];

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
