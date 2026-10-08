import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OwnedImageDirectory root;
  late ArtifactApplicationService artifacts;
  late PublicApiServer server;
  late HttpClient client;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('gvm-art-api-');
    imageFileMode(temporary.path, 0x1c0);
    final directory = await Directory('${temporary.path}/artifacts').create();
    imageFileMode(directory.path, 0x1c0);
    root = await OwnedImageDirectory.open(directory);
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    artifacts = ArtifactApplicationService(database: database, directory: root);
    final router = PublicApiRouter();
    ArtifactApiHandlers(artifacts: artifacts).register(router);
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
    root.close();
    database.close();
    await temporary.delete(recursive: true);
  });

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
    'streams exact binary bytes with digest and request ID over Unix HTTP',
    () async {
      final bytes = [0, 255, 10, 13, 128, 1];
      final artifact = await artifacts.publish(
        bytes: Stream.value(bytes),
        kind: ArtifactKind.stdout,
        contentType: 'text/plain',
        maxBytes: 16,
      );
      final request = await client.getUrl(
        Uri.parse('http://localhost${artifact.downloadUrl}'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      expect(response.statusCode, 200);
      expect(
        response.headers.contentType?.mimeType,
        'application/octet-stream',
      );
      expect(
        () => RequestId(response.headers.value('x-request-id')!),
        returnsNormally,
      );
      expect(
        response.headers.value('digest'),
        'sha-256=${base64.encode(sha256.convert(bytes).bytes)}',
      );
      expect(response.contentLength, bytes.length);
      expect(await response.expand((chunk) => chunk).toList(), bytes);
    },
  );

  test(
    'VM and TestRun lists have isolated stable pages when timestamps tie',
    () async {
      final vms = SqliteVmRepository(database);
      final first = await vms.create(name: 'first', spec: _vmSpec());
      final second = await vms.create(name: 'second', spec: _vmSpec());
      final runs = SqliteTestRunRepository(database);
      final run = await runs.create(
        requestId: RequestId.generate(),
        spec: TestRunSpec(
          source: ImageTestRunSource(ImageId.generate()),
          wait: VmWaitSpec(
            condition: WaitCondition.guestAgentReady,
            timeoutSeconds: 30,
          ),
          steps: [
            TestStepRequest(argv: ['true'], timeoutSeconds: 30),
          ],
          cleanup: CleanupPolicy.retain,
          retainOnFailure: true,
        ),
      );
      await runs.transition(
        run.id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.provisioning,
      );
      await runs.transition(
        run.id,
        expectedState: TestRunState.provisioning,
        nextState: TestRunState.startingVm,
        vmId: first.metadata.id,
      );
      final store = ArtifactApplicationService(
        database: database,
        directory: root,
        now: () => DateTime.utc(2026, 10, 8),
      );
      final expected = <Artifact>[];
      for (var index = 0; index < 3; index++) {
        expected.add(
          await store.publish(
            bytes: Stream.value([index]),
            kind: ArtifactKind.stdout,
            contentType: 'text/plain',
            maxBytes: 16,
            vmId: first.metadata.id,
            testRunId: run.id,
            operationId: run.operationId,
          ),
        );
      }
      final vmOnly = await store.publish(
        bytes: Stream.value([3]),
        kind: ArtifactKind.serial,
        contentType: 'text/plain',
        maxBytes: 16,
        vmId: first.metadata.id,
      );
      await store.publish(
        bytes: Stream.value([4]),
        kind: ArtifactKind.driver,
        contentType: 'text/plain',
        maxBytes: 16,
        vmId: second.metadata.id,
      );
      for (final entry in [
        ('/v1/vms/${first.metadata.id.value}/artifacts', [...expected, vmOnly]),
        ('/v1/test-runs/${run.id.value}/artifacts', expected),
      ]) {
        final received = <Artifact>[];
        String? cursor;
        do {
          final response = await getJson(
            '${entry.$1}?limit=2${cursor == null ? '' : '&cursor=$cursor'}',
          );
          expect(response.status, 200);
          expect(response.body.keys, unorderedEquals(['items', 'next_cursor']));
          expect(response.headers.value('x-request-id'), startsWith('req_'));
          final items = (response.body['items'] as List)
              .map(Artifact.fromJson)
              .toList();
          expect(items.length, lessThanOrEqualTo(2));
          received.addAll(items);
          cursor = response.body['next_cursor'] as String?;
        } while (cursor != null);
        final sorted = [...entry.$2]
          ..sort((a, b) => a.id.value.compareTo(b.id.value));
        expect(received, sorted);
      }
    },
  );

  test(
    'missing artifact owners and payload IDs return correlated typed problems',
    () async {
      for (final entry in [
        ('/v1/vms/${VmId.generate().value}/artifacts', 'VM_NOT_FOUND'),
        (
          '/v1/test-runs/${TestRunId.generate().value}/artifacts',
          'TEST_RUN_NOT_FOUND',
        ),
        ('/v1/artifacts/${ArtifactId.generate().value}', 'ARTIFACT_NOT_FOUND'),
      ]) {
        final response = await getJson(entry.$1);
        expect(response.status, 404);
        expect(response.body['code'], entry.$2);
        expect(
          response.body['request_id'],
          response.headers.value('x-request-id'),
        );
        expect(
          response.headers.contentType?.mimeType,
          'application/problem+json',
        );
        expect(response.body['retryable'], isFalse);
      }
    },
  );

  test(
    'malformed pagination, cross-owner cursors, query keys and GET bodies are rejected',
    () async {
      final vms = SqliteVmRepository(database);
      final first = await vms.create(name: 'first', spec: _vmSpec());
      final second = await vms.create(name: 'second', spec: _vmSpec());
      for (var index = 0; index < 2; index++) {
        await artifacts.publish(
          bytes: Stream.value([index]),
          kind: ArtifactKind.stdout,
          contentType: 'text/plain',
          maxBytes: 16,
          vmId: first.metadata.id,
        );
      }
      final list = '/v1/vms/${first.metadata.id.value}/artifacts';
      final initial = await getJson('$list?limit=1');
      final cursor = initial.body['next_cursor'] as String;
      final id = (initial.body['items'] as List).first['id'] as String;
      final paths = [
        '$list?limit=0',
        '$list?limit=201',
        '$list?limit=oops',
        '$list?cursor=',
        '$list?cursor=bad',
        '$list?cursor=${'a' * 513}',
        '$list?limit=1&limit=2',
        '$list?cursor=$cursor&cursor=$cursor',
        '$list?unknown=1',
        '$list?label_selector=env=test',
        '/v1/vms/${second.metadata.id.value}/artifacts?cursor=$cursor',
        '/v1/artifacts/$id?limit=1',
        '/v1/artifacts/not-an-id',
        '/v1/vms/not-an-id/artifacts',
        '/v1/test-runs/not-an-id/artifacts',
      ];
      for (final path in paths) {
        final response = await getJson(path);
        expect(response.status, 400, reason: path);
        expect(response.body['code'], 'INVALID_REQUEST');
        expect(
          response.body['request_id'],
          response.headers.value('x-request-id'),
        );
      }
      for (final path in [
        list,
        '/v1/artifacts/$id',
        '/v1/test-runs/${TestRunId.generate().value}/artifacts',
      ]) {
        final response = await getJson(path, body: '{}');
        expect(response.status, 400);
        expect(response.body['code'], 'INVALID_REQUEST');
      }
      final before = await SqliteEventRepository(database).list();
      expect((await getJson('$list?limit=200')).status, 200);
      expect(await SqliteEventRepository(database).list(), before);
    },
  );

  test(
    'damaged, linked and legacy unbacked payloads fail without exposing host paths',
    () async {
      final artifact = await artifacts.publish(
        bytes: Stream.value([1, 2, 3]),
        kind: ArtifactKind.stdout,
        contentType: 'text/plain',
        maxBytes: 16,
      );
      final payload = File('${root.path}/${artifact.id.value}/payload');
      imageFileMode(payload.path, 0x180);
      await payload.writeAsBytes([4, 5, 6]);
      imageFileMode(payload.path, 0x100);
      final outside = await File(
        '${temporary.path}/outside-secret',
      ).writeAsString('never return this');
      for (final linked in [false, true]) {
        if (linked) {
          await payload.delete();
          await Link(payload.path).create(outside.path);
        }
        final response = await getJson(artifact.downloadUrl);
        expect(response.status, 500);
        expect(response.body['code'], 'INTERNAL_ERROR');
        expect(jsonEncode(response.body), isNot(contains(temporary.path)));
        expect(jsonEncode(response.body), isNot(contains('never return this')));
      }
      final legacyId = ArtifactId.generate();
      final legacy = await ArtifactRepository(database).publish(
        Artifact.fromJson({
          ...artifact.toJson(),
          'id': legacyId.value,
          'download_url': '/v1/artifacts/${legacyId.value}',
        }),
      );
      expect((await getJson(legacy.downloadUrl)).status, 500);
      expect(await outside.readAsString(), 'never return this');
    },
  );

  test(
    'corrupt catalog metadata is a server error, not a client error',
    () async {
      final vm = await SqliteVmRepository(
        database,
      ).create(name: 'corrupt-metadata', spec: _vmSpec());
      final artifact = await artifacts.publish(
        bytes: Stream.value([1, 2, 3]),
        kind: ArtifactKind.stdout,
        contentType: 'text/plain',
        maxBytes: 16,
        vmId: vm.metadata.id,
      );
      await database.transaction((db) async {
        db.execute('UPDATE artifacts SET kind = ? WHERE id = ?', [
          'legacy_unknown',
          artifact.id.value,
        ]);
      });
      for (final path in [
        '/v1/vms/${vm.metadata.id.value}/artifacts',
        artifact.downloadUrl,
      ]) {
        final response = await getJson(path);
        expect(response.status, 500, reason: path);
        expect(response.body['code'], 'INTERNAL_ERROR');
        expect(
          response.body['request_id'],
          response.headers.value('x-request-id'),
        );
        expect(jsonEncode(response.body), isNot(contains(temporary.path)));
        expect(jsonEncode(response.body), isNot(contains('legacy_unknown')));
      }
    },
  );
}

VmSpec _vmSpec() => VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: LinuxKernelBoot(kernelImageId: ImageId.generate()),
  disks: [
    VmDisk(id: 'root', source: ExternalDiskSource('/tmp/disk'), writable: true),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
