import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late TestRunApplicationService runs;
  late ImageApplicationService images;
  late PublicApiServer server;
  late HttpClient client;
  late Image source;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gvm-tr-api-');
    imageFileMode(directory.path, 0x1c0);
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    images = ImageApplicationService(
      database: database,
      store: ImageStore(database, Directory('${directory.path}/images')),
    );
    source = await images.store.importFile(
      await File('${directory.path}/disk').writeAsString('disk'),
      type: ImageType.rawDisk,
    );
    runs = TestRunApplicationService(database: database);
    final router = PublicApiRouter();
    TestRunApiHandlers(runs: runs).register(router);
    ImageApiHandlers(images: images).register(router);
    server = PublicApiServer(
      socketPath: '${directory.path}/api.sock',
      openApiDocument: const {},
      systemHealth: _Health(),
      router: router,
    );
    await server.start();
    client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (_, _, _) => Socket.startConnect(
        InternetAddress(server.socketPath, type: InternetAddressType.unix),
        0,
      );
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
    database.close();
    await directory.delete(recursive: true);
  });

  Future<({int status, Map<String, dynamic> body, HttpHeaders headers})>
  request(String method, String path, {String? body, String? key}) async {
    final outgoing = await client.openUrl(
      method,
      Uri.parse('http://localhost$path'),
    );
    if (key != null) outgoing.headers.set('Idempotency-Key', key);
    if (body != null) {
      outgoing.headers.contentType = ContentType.json;
      final bytes = utf8.encode(body);
      outgoing.contentLength = bytes.length;
      outgoing.add(bytes);
    }
    final response = await outgoing.close().timeout(const Duration(seconds: 5));
    return (
      status: response.statusCode,
      body:
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
      headers: response.headers,
    );
  }

  test(
    'creates and retrieves a durable TestRun through the Unix HTTP API',
    () async {
      final spec = _spec(source.id);
      final body = jsonEncode(spec.toJson());
      final accepted = await request(
        'POST',
        '/v1/test-runs',
        body: body,
        key: 'smoke',
      );
      expect(accepted.status, 202);
      final acceptance = OperationAcceptance.fromJson(accepted.body);
      expect(acceptance.resourceType, ResourceType.testRun);
      expect(acceptance.state, OperationState.pending);
      expect(
        accepted.headers.value('location'),
        '/v1/operations/${acceptance.operationId.value}',
      );
      expect(accepted.headers.value('x-request-id'), startsWith('req_'));
      final response = await request(
        'GET',
        '/v1/test-runs/${acceptance.resourceId.value}',
      );
      expect(response.status, 200);
      final run = TestRun.fromJson(response.body);
      expect(run.spec, spec);
      expect(run.operationId, acceptance.operationId);
      expect(run.state, TestRunState.pending);
      expect(run.vmId, isNull);
      final replay = await request(
        'POST',
        '/v1/test-runs',
        body: body,
        key: 'smoke',
      );
      expect(replay.status, 202);
      expect(replay.body, accepted.body);
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
    },
  );
  test(
    'cancel returns a pending action and replays its original acceptance after cleanup',
    () async {
      final created = await request(
        'POST',
        '/v1/test-runs',
        body: jsonEncode(_spec(source.id).toJson()),
      );
      final id = TestRunId(created.body['resource_id'] as String);
      final cancellation = await request(
        'POST',
        '/v1/test-runs/${id.value}/cancel',
        key: 'cancel-smoke',
      );
      expect(cancellation.status, 202);
      expect(cancellation.body['resource_type'], 'test_run');
      expect(cancellation.body['resource_id'], id.value);
      expect(cancellation.body['state'], 'pending');
      final status = await request('GET', '/v1/test-runs/${id.value}');
      expect(status.body['state'], 'pending');
      final catalog = SqliteTestRunRepository(database);
      await catalog.transition(
        id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      await catalog.transition(
        id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'delete',
      );
      await catalog.finish(id, outcome: TestRunState.cancelled);
      final completed = await request('GET', '/v1/test-runs/${id.value}');
      expect(completed.body['state'], 'cancelled');
      expect(completed.body['cleanup_decision'], 'delete');
      final replay = await request(
        'POST',
        '/v1/test-runs/${id.value}/cancel',
        key: 'cancel-smoke',
      );
      expect(replay.status, 202);
      expect(replay.body, cancellation.body);
    },
  );
  test(
    'missing runs and images return typed problems rather than internal errors',
    () async {
      final missing = TestRunId.generate();
      for (final endpoint in [
        ('GET', '/v1/test-runs/${missing.value}'),
        ('POST', '/v1/test-runs/${missing.value}/cancel'),
      ]) {
        final response = await request(endpoint.$1, endpoint.$2);
        expect(response.status, 404);
        expect(response.body['code'], 'TEST_RUN_NOT_FOUND');
        expect(response.body['request_id'], startsWith('req_'));
        expect(
          response.headers.contentType!.mimeType,
          'application/problem+json',
        );
      }
      final response = await request(
        'POST',
        '/v1/test-runs',
        body: jsonEncode(_spec(ImageId.generate()).toJson()),
      );
      expect(response.status, 404);
      expect(response.body['code'], 'IMAGE_NOT_FOUND');
      expect(await SqliteOperationRepository(database).list(), isEmpty);
    },
  );
  test(
    'invalid requests are rejected before any TestRun operation is accepted',
    () async {
      final spec = _spec(source.id).toJson();
      final missing = TestRunId.generate().value;
      final cases = <({String method, String path, String? body, String? key})>[
        (
          method: 'POST',
          path: '/v1/test-runs?extra=1',
          body: jsonEncode(spec),
          key: null,
        ),
        (method: 'POST', path: '/v1/test-runs', body: null, key: null),
        (
          method: 'POST',
          path: '/v1/test-runs',
          body: jsonEncode({...spec, 'extra': true}),
          key: null,
        ),
        (
          method: 'POST',
          path: '/v1/test-runs',
          body: jsonEncode({...spec, 'steps': []}),
          key: null,
        ),
        (
          method: 'POST',
          path: '/v1/test-runs',
          body: jsonEncode({...spec, 'timeout_seconds': 0}),
          key: null,
        ),
        (
          method: 'POST',
          path: '/v1/test-runs',
          body: jsonEncode({
            ...spec,
            'source': {'template_vm_id': VmId.generate().value},
          }),
          key: null,
        ),
        (
          method: 'POST',
          path: '/v1/test-runs',
          body: jsonEncode(spec),
          key: '',
        ),
        (method: 'GET', path: '/v1/test-runs/not-an-id', body: null, key: null),
        (
          method: 'GET',
          path: '/v1/test-runs/$missing?extra=1',
          body: null,
          key: null,
        ),
        (method: 'GET', path: '/v1/test-runs/$missing', body: '{}', key: null),
        (
          method: 'POST',
          path: '/v1/test-runs/$missing/cancel',
          body: '{}',
          key: null,
        ),
        (
          method: 'POST',
          path: '/v1/test-runs/$missing/cancel?extra=1',
          body: null,
          key: null,
        ),
      ];
      for (final input in cases) {
        final response = await request(
          input.method,
          input.path,
          body: input.body,
          key: input.key,
        );
        expect(response.status, 400, reason: input.toString());
        expect(response.body['code'], 'INVALID_REQUEST');
        expect(await SqliteOperationRepository(database).list(), isEmpty);
      }
    },
  );
  test(
    'idempotency conflicts do not accept another run and keys are endpoint scoped',
    () async {
      final body = jsonEncode(_spec(source.id).toJson());
      final accepted = await request(
        'POST',
        '/v1/test-runs',
        body: body,
        key: 'same-key',
      );
      expect(accepted.status, 202);
      for (final different in [
        '$body ',
        jsonEncode({..._spec(source.id).toJson(), 'timeout_seconds': 30}),
      ]) {
        final rejected = await request(
          'POST',
          '/v1/test-runs',
          body: different,
          key: 'same-key',
        );
        expect(rejected.status, 409);
        expect(rejected.body['code'], 'IDEMPOTENCY_CONFLICT');
        expect(rejected.body['retryable'], isFalse);
      }
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      final cancellation = await request(
        'POST',
        '/v1/test-runs/${accepted.body['resource_id']}/cancel',
        key: 'same-key',
      );
      expect(cancellation.status, 202);
      expect(
        cancellation.body['operation_id'],
        isNot(accepted.body['operation_id']),
      );
    },
  );
  test(
    'new cancellation is rejected during cleanup while an accepted retry still replays',
    () async {
      final accepted = await request(
        'POST',
        '/v1/test-runs',
        body: jsonEncode(_spec(source.id).toJson()),
      );
      final id = TestRunId(accepted.body['resource_id'] as String);
      final cancellation = await request(
        'POST',
        '/v1/test-runs/${id.value}/cancel',
        key: 'first-cancel',
      );
      final catalog = SqliteTestRunRepository(database);
      await catalog.transition(
        id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      await catalog.transition(
        id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'retain',
      );
      for (final terminal in [false, true]) {
        if (terminal) await catalog.finish(id, outcome: TestRunState.cancelled);
        final rejected = await request(
          'POST',
          '/v1/test-runs/${id.value}/cancel',
          key: 'late-cancel',
        );
        expect(rejected.status, 409);
        expect(rejected.body['code'], 'OPERATION_NOT_CANCELLABLE');
        final replay = await request(
          'POST',
          '/v1/test-runs/${id.value}/cancel',
          key: 'first-cancel',
        );
        expect(replay.status, 202);
        expect(replay.body, cancellation.body);
      }
      expect(await SqliteOperationRepository(database).list(), hasLength(2));
    },
  );
  test(
    'a deletion accepted before a TestRun cannot remove its newly referenced source',
    () async {
      final deletion = await request('DELETE', '/v1/images/${source.id.value}');
      expect(deletion.status, 202);
      final accepted = await request(
        'POST',
        '/v1/test-runs',
        body: jsonEncode(_spec(source.id).toJson()),
      );
      expect(accepted.status, 202);
      await images.dispatchOnce();
      final operation = (await SqliteOperationRepository(
        database,
      ).get(OperationId(deletion.body['operation_id'] as String)))!;
      expect(operation.state, OperationState.failed);
      expect(operation.error!.code, ErrorCode.imageInUse);
      expect(await images.store.get(source.id), source);
      expect(
        await (await images.store.objectFile(
          source.id,
          'payload',
        )).readAsString(),
        'disk',
      );
      final retry = await request('DELETE', '/v1/images/${source.id.value}');
      expect(retry.status, 409);
      expect(retry.body['code'], 'IMAGE_IN_USE');
    },
  );
}

TestRunSpec _spec(ImageId id) => TestRunSpec(
  source: ImageTestRunSource(id),
  wait: VmWaitSpec(
    condition: WaitCondition.guestAgentReady,
    timeoutSeconds: 30,
  ),
  steps: [
    TestStepRequest(argv: ['gaoos-test', 'smoke'], timeoutSeconds: 60),
  ],
  cleanup: CleanupPolicy.deleteOnSuccess,
  retainOnFailure: true,
);

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
}
