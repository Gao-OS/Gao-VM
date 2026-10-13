import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/test_run_cleanup_worker.dart';
import 'package:gaovmd/src/test_run_collection_worker.dart';
import 'package:gaovmd/src/test_run_provisioning_worker.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  late Directory temporary;
  late _ColdState fixture;
  final children = <OwnedTestProcess>[];

  setUp(() async {
    children.clear();
    final created = await Directory.systemTemp.createTemp('gaovm-cold-backup-');
    temporary = Directory(await created.resolveSymbolicLinks());
    imageFileMode(temporary.path, 0x1c0);
    fixture = await _ColdState.create(temporary);
  });

  tearDown(() async {
    fixture.close();
    for (final child in children) {
      if (!await child.terminate()) {
        throw StateError('Live backup fixture retained at ${temporary.path}');
      }
    }
    await temporary.delete(recursive: true);
  });

  Future<ProcessResult> runFixtureCommand(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final child = OwnedTestProcess(
      await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      ),
    );
    children.add(child);
    final result = await child.result();
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stderr, isEmpty);
    return result;
  }

  test(
    'cold archive restores catalog, disk and public artifact bytes at the original path',
    () async {
      final schemaVersion = fixture.database.schemaVersion;
      final catalog = await SqliteVmRepository(
        fixture.database,
      ).get(fixture.vmId);
      final images = await ImageRepository(fixture.database).list();
      final operations = await SqliteOperationRepository(
        fixture.database,
      ).list();
      final events = await SqliteEventRepository(fixture.database).list();
      final outbox = await SqliteEventRepository(
        fixture.database,
      ).readUnpublishedOutbox();
      final run = await SqliteTestRunRepository(
        fixture.database,
      ).get(fixture.testRunId);
      final runArtifacts = (await fixture.artifacts.listForTestRun(
        fixture.testRunId,
      )).items;
      final archive = File('${temporary.path}/state.tar');
      final saved = Directory('${temporary.path}/state-before-restore');
      final externalDigest = await _digest(fixture.externalDisk);
      fixture.close();
      final catalogDigest = await _digest(
        File('${fixture.directory.path}/gaovm.db'),
      );

      await runFixtureCommand('tar', [
        '-cpf',
        archive.path,
        '--exclude=./run',
        '-C',
        fixture.directory.path,
        '.',
      ]);
      imageFileMode(archive.path, 0x180);
      final archiveDigest = await _digest(archive);
      final listing = await runFixtureCommand('tar', ['-tf', archive.path]);
      expect(listing.stdout, contains('./gaovm.db'));
      expect(listing.stdout, isNot(contains('./run/')));
      if (Platform.isMacOS) {
        final checksum = await runFixtureCommand('/usr/bin/shasum', [
          '-a',
          '256',
          'state.tar',
        ], workingDirectory: temporary.path);
        expect(checksum.stdout, startsWith(archiveDigest));
        await File(
          '${temporary.path}/state.tar.sha256',
        ).writeAsString(checksum.stdout as String);
        final verification = await runFixtureCommand('/usr/bin/shasum', [
          '-a',
          '256',
          '-c',
          'state.tar.sha256',
        ], workingDirectory: temporary.path);
        expect(verification.stdout, 'state.tar: OK\n');
      }
      await fixture.directory.rename(saved.path);
      await _privateDirectory(fixture.directory.path);
      await runFixtureCommand('tar', [
        '-xpf',
        archive.path,
        '-C',
        fixture.directory.path,
      ]);
      expect(await _digest(archive), archiveDigest);
      expect((await archive.stat()).mode & 0x3f, 0);
      expect((await fixture.directory.stat()).mode & 0x3f, 0);
      expect(
        await Directory('${fixture.directory.path}/run').exists(),
        isFalse,
      );
      expect(await File('${saved.path}/gaovm.db').exists(), isTrue);
      expect(await _digest(File('${saved.path}/gaovm.db')), catalogDigest);
      expect(
        await _digest(File('${fixture.directory.path}/gaovm.db')),
        catalogDigest,
      );
      expect(await _digest(fixture.externalDisk), externalDigest);
      if (Platform.isMacOS) {
        final inspection = await runFixtureCommand('/usr/bin/sqlite3', [
          '-readonly',
          '${fixture.directory.path}/gaovm.db',
          'PRAGMA integrity_check; PRAGMA foreign_key_check; PRAGMA user_version;',
        ]);
        expect(inspection.stdout, 'ok\n$schemaVersion\n');
      }
      await fixture.open();

      expect(
        await SqliteVmRepository(fixture.database).get(fixture.vmId),
        catalog,
      );
      expect(await ImageRepository(fixture.database).list(), images);
      expect(
        await SqliteOperationRepository(fixture.database).list(),
        operations,
      );
      expect(await SqliteEventRepository(fixture.database).list(), events);
      expect(
        await SqliteTestRunRepository(fixture.database).get(fixture.testRunId),
        run,
      );
      expect(
        (await fixture.artifacts.listForTestRun(fixture.testRunId)).items,
        runArtifacts,
      );
      final restoredOutbox = await SqliteEventRepository(
        fixture.database,
      ).readUnpublishedOutbox();
      expect(
        restoredOutbox.map((record) => record.id),
        outbox.map((record) => record.id),
      );
      expect(
        restoredOutbox.map((record) => record.payload),
        outbox.map((record) => record.payload),
      );
      final integrity = await fixture.database.read(
        (db) => db.select('PRAGMA integrity_check').single.values.single,
      );
      expect(integrity, 'ok');
      expect(
        await fixture.database.read(
          (db) => db.select('PRAGMA foreign_key_check'),
        ),
        isEmpty,
      );
      for (final image in images) {
        expect(
          (await ImageStore(
            fixture.database,
            Directory('${fixture.directory.path}/images'),
          ).verifyImage(image.id, contentByteBudget: 1024)).digestsVerified,
          isTrue,
        );
      }
      await fixture.assets.withAssets(
        VmControllerState.initial(
          vmId: fixture.vmId,
          specGeneration: 1,
          restartPolicy: RestartPolicy.never,
        ),
        (assets) async {
          expect(
            await File(assets.disks.first.path).readAsString(),
            'changed writable guest disk',
          );
          expect(assets.disks.last.path, fixture.externalDisk.path);
          expect(
            await File(assets.disks.last.path).readAsString(),
            'separately owned external disk',
          );
        },
      );
      await _publicDownload(fixture.artifacts, fixture.artifact, temporary);
      for (final artifact in runArtifacts) {
        final download = await fixture.artifacts.download(artifact.id);
        final bytes = await download.bytes.expand((chunk) => chunk).toList();
        expect(download.artifact, artifact);
        expect(bytes.length, artifact.sizeBytes);
        expect('sha256:${sha256.convert(bytes)}', artifact.digest);
      }
      final resumed = await SqliteEventRepository(fixture.database).append(
        type: 'backup.fixture_verified',
        resourceType: ResourceType.virtualMachine,
        resourceId: fixture.vmId,
        vmId: fixture.vmId,
        payload: JsonObjectValue.empty,
      );
      expect(resumed.sequence, greaterThan(events.last.sequence));
      expect(
        await File('${fixture.directory.path}/external.raw').exists(),
        isFalse,
      );
    },
    skip: Platform.isWindows ? 'Cold tar recipe requires a POSIX host.' : false,
  );

  test('a live main-file copy omits a committed WAL event', () async {
    final checkpoint = await fixture.database.read(
      (db) => db.select('PRAGMA wal_checkpoint(TRUNCATE)').single,
    );
    expect(checkpoint['busy'], 0);
    await fixture.database.read(
      (db) => db.execute('PRAGMA wal_autocheckpoint = 0'),
    );
    final event = await SqliteEventRepository(fixture.database).append(
      type: 'backup.live_wal_fixture',
      resourceType: ResourceType.virtualMachine,
      resourceId: fixture.vmId,
      vmId: fixture.vmId,
      payload: JsonObjectValue.empty,
    );
    expect(
      await File('${fixture.directory.path}/gaovm.db-wal').length(),
      greaterThan(0),
    );
    final copy = await File(
      '${fixture.directory.path}/gaovm.db',
    ).copy('${temporary.path}/main-file-only.db');
    // Open only this disposable, incomplete copy; the source stays live.
    final incomplete = sqlite3.open(copy.path);
    try {
      expect(
        incomplete.select('SELECT id FROM events WHERE id = ?', [
          event.eventId.value,
        ]),
        isEmpty,
      );
    } finally {
      incomplete.dispose();
    }
    expect(
      await SqliteEventRepository(fixture.database).get(event.eventId),
      event,
    );
  });

  test(
    'a cold database-only copy cannot serve its missing payload or runtime disk',
    () async {
      fixture.close();
      final copy = await _privateDirectory('${temporary.path}/database-only');
      await File(
        '${fixture.directory.path}/gaovm.db',
      ).copy('${copy.path}/gaovm.db');
      final roots = <OwnedImageDirectory>[];
      final database = await GaoVmDatabase.open('${copy.path}/gaovm.db');
      try {
        for (final name in ['vms', 'images', 'artifacts']) {
          roots.add(
            await OwnedImageDirectory.open(
              await _privateDirectory('${copy.path}/$name'),
            ),
          );
        }
        final artifacts = ArtifactApplicationService(
          database: database,
          directory: roots[2],
        );
        expect(await SqliteVmRepository(database).get(fixture.vmId), isNotNull);
        expect(
          (await artifacts.listForVm(fixture.vmId)).items,
          contains(fixture.artifact),
        );
        await _publicDownload(
          artifacts,
          fixture.artifact,
          temporary,
          expectedStatus: HttpStatus.internalServerError,
        );
        var accepted = false;
        await expectLater(
          SqliteVmRuntimeAssets(
            database: database,
            bundles: roots[0],
            images: roots[1],
          ).withAssets(
            VmControllerState.initial(
              vmId: fixture.vmId,
              specGeneration: 1,
              restartPolicy: RestartPolicy.never,
            ),
            (_) async {
              accepted = true;
            },
          ),
          throwsA(
            isA<RuntimeDriverError>().having(
              (error) => error.code,
              'code',
              RuntimeDriverErrorCode.invalidRuntimeConfig,
            ),
          ),
        );
        expect(accepted, isFalse);
      } finally {
        for (final root in roots.reversed) {
          root.close();
        }
        database.close();
      }
      expect(
        await File(
          '${fixture.directory.path}/artifacts/${fixture.artifact.id.value}/payload',
        ).readAsBytes(),
        [0, 255, 10, 128],
      );
    },
  );

  test(
    'a catalog from a newer version is rejected without rewriting the backup',
    () async {
      final version = fixture.database.schemaVersion;
      fixture.close();
      final copy = await File(
        '${fixture.directory.path}/gaovm.db',
      ).copy('${temporary.path}/newer-version.db');
      final future = sqlite3.open(copy.path);
      try {
        future.userVersion = version + 1;
      } finally {
        future.dispose();
      }
      final digest = await _digest(copy);
      await expectLater(
        GaoVmDatabase.open(copy.path),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('newer than supported'),
          ),
        ),
      );
      expect(await _digest(copy), digest);
      final inspection = sqlite3.open(copy.path, mode: OpenMode.readOnly);
      try {
        expect(inspection.userVersion, version + 1);
        expect(
          inspection.select('SELECT id FROM vms WHERE id = ?', [
            fixture.vmId.value,
          ]),
          hasLength(1),
        );
      } finally {
        inspection.dispose();
      }
      await fixture.open();
      expect(fixture.database.schemaVersion, version);
      expect(
        await SqliteVmRepository(fixture.database).get(fixture.vmId),
        isNotNull,
      );
    },
  );
}

class _ColdState {
  _ColdState(this.directory, this.externalDisk);
  final Directory directory;
  final File externalDisk;
  late GaoVmDatabase database;
  late OwnedImageDirectory bundles;
  late OwnedImageDirectory images;
  late OwnedImageDirectory artifactRoot;
  late VmId vmId;
  late TestRunId testRunId;
  late Artifact artifact;
  bool _open = false;

  ArtifactApplicationService get artifacts =>
      ArtifactApplicationService(database: database, directory: artifactRoot);
  SqliteVmRuntimeAssets get assets => SqliteVmRuntimeAssets(
    database: database,
    bundles: bundles,
    images: images,
  );

  static Future<_ColdState> create(Directory temporary) async {
    final state = await _privateDirectory('${temporary.path}/state');
    final external = await File(
      '${temporary.path}/external.raw',
    ).writeAsString('separately owned external disk');
    imageFileMode(external.path, 0x180);
    for (final name in ['images', 'vms', 'artifacts', 'run']) {
      await _privateDirectory('${state.path}/$name');
    }
    final fixture = _ColdState(state, external);
    await fixture.open();
    try {
      final store = ImageStore(
        fixture.database,
        Directory('${state.path}/images'),
      );
      final kernel = await store.importFile(
        await File(
          '${temporary.path}/kernel-source',
        ).writeAsString('test kernel, not a boot image'),
        type: ImageType.linuxKernel,
      );
      final disk = await store.importFile(
        await File(
          '${temporary.path}/disk-source',
        ).writeAsString('immutable base disk'),
        type: ImageType.rawDisk,
      );
      final spec = VmSpec(
        cpu: 2,
        memoryBytes: 536870912,
        boot: LinuxKernelBoot(kernelImageId: kernel.id),
        disks: [
          VmDisk(
            id: 'root',
            source: ManagedImageDiskSource(disk.id),
            writable: true,
          ),
          VmDisk(
            id: 'external',
            source: ExternalDiskSource(external.path),
            writable: true,
          ),
        ],
        networks: [DisconnectedNetwork(id: 'net0')],
        graphics: GraphicsConfig(enabled: false),
        serial: const SerialConfig(enabled: true, capture: true),
        guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
        restartPolicy: RestartPolicy.never,
      );
      final acceptance =
          await SqliteVmCreateAcceptance(
            database: fixture.database,
            idempotencyRetention: const Duration(days: 1),
          ).create(
            VmCreateCommand(
              requestId: RequestId.generate(),
              idempotencyKey: 'backup-vm',
              requestBody: utf8.encode(jsonEncode(spec.toJson())),
              name: 'backup-fixture',
              labels: {'backup.fixture': 'true'},
              spec: spec,
            ),
          );
      fixture.vmId = acceptance.resourceId as VmId;
      final outcomes = await VmProvisioningWorker(
        work: SqliteVmProvisioningWorkRepository(fixture.database),
        bundles: VmBundleStore(
          database: fixture.database,
          bundles: fixture.bundles,
          images: fixture.images,
        ),
        owner: 'cold-backup-fixture',
      ).dispatchOnce();
      expect(
        outcomes.single.completion,
        VmProvisioningCompletionKind.succeeded,
      );
      await File(
        '${fixture.bundles.path}/${fixture.vmId.value}.gaovm/disks/root.raw',
      ).writeAsString('changed writable guest disk');
      fixture.artifact = await fixture.artifacts.publish(
        bytes: Stream.value([0, 255, 10, 128]),
        kind: ArtifactKind.serial,
        contentType: 'application/octet-stream',
        maxBytes: 16,
        vmId: fixture.vmId,
        operationId: acceptance.operationId,
      );

      final runs = TestRunApplicationService(database: fixture.database);
      final runSpec = TestRunSpec(
        source: ImageTestRunSource(kernel.id),
        wait: VmWaitSpec(
          condition: WaitCondition.runtimeRunning,
          timeoutSeconds: 10,
        ),
        steps: [
          TestStepRequest(argv: ['true'], timeoutSeconds: 10),
        ],
        cleanup: CleanupPolicy.deleteOnSuccess,
        retainOnFailure: true,
      );
      final created = await runs.create(
        TestRunCreateCommand(
          spec: runSpec,
          requestId: RequestId.generate(),
          idempotencyKey: 'backup-test-run',
          requestBody: utf8.encode(jsonEncode(runSpec.toJson())),
        ),
      );
      fixture.testRunId = created.resourceId as TestRunId;
      await runs.cancelRun(
        TestRunCancelCommand(
          testRunId: fixture.testRunId,
          requestId: RequestId.generate(),
          idempotencyKey: 'backup-cancel',
          requestBody: const [],
        ),
      );
      await TestRunProvisioningWorker(
        database: fixture.database,
      ).dispatchOnce();
      final collector = TestRunCollectionWorker(
        database: fixture.database,
        bundles: fixture.bundles,
        artifacts: fixture.artifacts,
      );
      try {
        expect((await collector.dispatchOnce()).single.collected, isTrue);
      } finally {
        await collector.close();
      }
      expect(
        (await TestRunCleanupWorker(
          database: fixture.database,
        ).dispatchOnce()).single.completed,
        isTrue,
      );
      final socket = await ServerSocket.bind(
        InternetAddress(
          '${state.path}/run/api.sock',
          type: InternetAddressType.unix,
        ),
        0,
      );
      await socket.close();
      return fixture;
    } catch (_) {
      fixture.close();
      rethrow;
    }
  }

  Future<void> open() async {
    final roots = <OwnedImageDirectory>[];
    database = await GaoVmDatabase.open('${directory.path}/gaovm.db');
    try {
      bundles = await OwnedImageDirectory.open(
        Directory('${directory.path}/vms'),
      );
      roots.add(bundles);
      images = await OwnedImageDirectory.open(
        Directory('${directory.path}/images'),
      );
      roots.add(images);
      artifactRoot = await OwnedImageDirectory.open(
        Directory('${directory.path}/artifacts'),
      );
      roots.add(artifactRoot);
      _open = true;
    } catch (_) {
      for (final root in roots.reversed) {
        root.close();
      }
      database.close();
      rethrow;
    }
  }

  void close() {
    if (!_open) return;
    artifactRoot.close();
    images.close();
    bundles.close();
    database.close();
    _open = false;
  }
}

Future<Directory> _privateDirectory(String path) async {
  final directory = await Directory(path).create();
  imageFileMode(directory.path, 0x1c0);
  return directory;
}

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _publicDownload(
  ArtifactApplicationService artifacts,
  Artifact artifact,
  Directory temporary, {
  int expectedStatus = HttpStatus.ok,
}) async {
  final router = PublicApiRouter();
  ArtifactApiHandlers(artifacts: artifacts).register(router);
  final logger = RotatingLogger(path: '${temporary.path}/restored-api.log');
  final server = PublicApiServer(
    socketPath: '${temporary.path}/restored-api.sock',
    openApiDocument: const {},
    systemHealth: _Health(),
    router: router,
    logger: logger,
  );
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (_, _, _) => Socket.startConnect(
      InternetAddress(server.socketPath, type: InternetAddressType.unix),
      0,
    );
  try {
    await server.start();
    final request = await client.getUrl(
      Uri.parse('http://localhost${artifact.downloadUrl}'),
    );
    final response = await request.close().timeout(const Duration(seconds: 5));
    expect(response.statusCode, expectedStatus);
    expect(
      () => RequestId(response.headers.value('x-request-id')!),
      returnsNormally,
    );
    if (expectedStatus != HttpStatus.ok) {
      final body =
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>;
      expect(body['code'], 'INTERNAL_ERROR');
      expect(body['request_id'], response.headers.value('x-request-id'));
      expect(body['type'], endsWith('/artifact-content-unavailable'));
      expect(jsonEncode(body), isNot(contains(temporary.path)));
      return;
    }
    expect(response.contentLength, artifact.sizeBytes);
    expect(
      response.headers.value('digest'),
      'sha-256=${base64.encode([for (var i = 7; i < artifact.digest.length; i += 2) int.parse(artifact.digest.substring(i, i + 2), radix: 16)])}',
    );
    expect(
      await response
          .expand((chunk) => chunk)
          .toList()
          .timeout(const Duration(seconds: 5)),
      [0, 255, 10, 128],
    );
  } finally {
    client.close(force: true);
    await server.close();
    await logger.flush();
  }
}

class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
