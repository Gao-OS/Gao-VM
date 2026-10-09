import 'dart:convert';
import 'dart:io';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/test_run_cleanup_worker.dart';
import 'package:gaovmd/src/test_run_collection_worker.dart';
import 'package:gaovmd/src/test_run_provisioning_worker.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late PublicApiServer server;
  late GaoVmApiClient client;
  late TestRunSpec spec;
  late OwnedImageDirectory artifactRoot;
  late ArtifactApplicationService artifacts;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('gvm-tr-cli-');
    imageFileMode(temporary.path, 0x1c0);
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    final directory = await Directory('${temporary.path}/artifacts').create();
    imageFileMode(directory.path, 0x1c0);
    artifactRoot = await OwnedImageDirectory.open(directory);
    artifacts = ArtifactApplicationService(
      database: database,
      directory: artifactRoot,
      now: () => DateTime.utc(2040),
    );
    final source =
        await ImageStore(
          database,
          Directory('${temporary.path}/images'),
        ).importFile(
          await File('${temporary.path}/disk').writeAsString('disk'),
          type: ImageType.rawDisk,
        );
    spec = TestRunSpec(
      source: ImageTestRunSource(source.id),
      vmOverrides: VmSpecPatch.fromJson({'cpu': 2}),
      wait: VmWaitSpec(
        condition: WaitCondition.guestAgentReady,
        timeoutSeconds: 30.5,
      ),
      steps: [
        TestStepRequest(
          name: 'first',
          argv: ['echo', 'first'],
          cwd: '/tmp',
          env: {'TEST_MODE': 'cli'},
          timeoutSeconds: 10.25,
        ),
        TestStepRequest(name: 'second', argv: ['true'], timeoutSeconds: 20.5),
      ],
      timeoutSeconds: 60.25,
      cleanup: CleanupPolicy.deleteOnSuccess,
      retainOnFailure: true,
    );
    final router = PublicApiRouter();
    TestRunApiHandlers(
      runs: TestRunApplicationService(database: database),
    ).register(router);
    EventApiHandlers(feed: SqliteDurableEventFeed(database)).register(router);
    ArtifactApiHandlers(artifacts: artifacts).register(router);
    server = PublicApiServer(
      socketPath: '${temporary.path}/api.sock',
      openApiDocument: const {},
      systemHealth: _Health(),
      router: router,
    );
    await server.start();
    client = GaoVmApiClient(socketPath: server.socketPath);
  });

  tearDown(() async {
    await server.close();
    artifactRoot.close();
    database.close();
    await temporary.delete(recursive: true);
  });

  Future<({int code, String output, String error})> invoke(
    List<String> args,
  ) async {
    final output = StringBuffer(), error = StringBuffer();
    final code = await runCli(
      ['--socket-path', server.socketPath, ...args, '--json'],
      output: output.writeln,
      error: error.writeln,
    );
    return (code: code, output: output.toString(), error: error.toString());
  }

  Future<OperationAcceptance> createRun() async => OperationAcceptance.fromJson(
    (await client.request(
      'POST',
      '/v1/test-runs',
      body: JsonObjectValue.fromJson(spec.toJson()),
    )).body.toJson(),
  );

  test(
    'test run accepts durable work queryable by another public client',
    () async {
      final result = await invoke([
        'test',
        'run',
        '--body-json',
        jsonEncode(spec.toJson()),
        '--idempotency-key',
        'create-test-once',
        '--timeout-seconds',
        '5',
      ]);
      expect(result.code, 0, reason: result.error);
      expect(result.error, isEmpty);
      final accepted = OperationAcceptance.fromJson(jsonDecode(result.output));
      expect(accepted.resourceType, ResourceType.testRun);
      expect(accepted.state, OperationState.pending);
      final response = await client.request(
        'GET',
        '/v1/test-runs/${accepted.resourceId.value}',
      );
      final run = TestRun.fromJson(response.body.toJson());
      expect(run.spec, spec);
      expect(run.operationId, accepted.operationId);
      expect(run.state, TestRunState.pending);
      expect(run.vmId, isNull);
      expect(run.steps.map((step) => step.request), spec.steps);
      expect(
        run.steps.every((step) => step.state == TestStepState.pending),
        isTrue,
      );
    },
  );

  test('test get reads a run created by another public client', () async {
    final acceptance = await createRun();
    final result = await invoke([
      'test',
      'get',
      acceptance.resourceId.value,
      '--timeout-seconds',
      '5',
    ]);
    expect(result.code, 0, reason: result.error);
    expect(result.error, isEmpty);
    final run = TestRun.fromJson(jsonDecode(result.output));
    expect(run.id, acceptance.resourceId);
    expect(run.spec, spec);
    expect(run.operationId, acceptance.operationId);
    expect(run.state, TestRunState.pending);
  });

  test(
    'test cancel durably accepts cancellation without claiming completion',
    () async {
      final created = await createRun();
      final result = await invoke([
        'test',
        'cancel',
        created.resourceId.value,
        '--idempotency-key',
        'cancel-test-once',
        '--timeout-seconds',
        '5',
      ]);
      expect(result.code, 0, reason: result.error);
      expect(result.error, isEmpty);
      final accepted = OperationAcceptance.fromJson(jsonDecode(result.output));
      expect(accepted.resourceId, created.resourceId);
      expect(accepted.operationId, isNot(created.operationId));
      expect(accepted.state, OperationState.pending);
      final event = await client
          .watchEvents(
            testRunId: created.resourceId as TestRunId,
            timeout: const Duration(seconds: 5),
          )
          .firstWhere((event) => event.type == 'test_run.cancel_requested');
      expect(event.testRunId, created.resourceId);
      expect(event.operationId, created.operationId);
      expect(event.payload.toJson()['cancel_requested'], isTrue);
      final pending = await client.request(
        'GET',
        '/v1/test-runs/${created.resourceId.value}',
      );
      expect(
        TestRun.fromJson(pending.body.toJson()).state,
        TestRunState.pending,
      );
      final replay = await invoke([
        'test',
        'cancel',
        created.resourceId.value,
        '--idempotency-key',
        'cancel-test-once',
      ]);
      expect(replay.code, 0, reason: replay.error);
      expect(jsonDecode(replay.output), jsonDecode(result.output));
    },
  );

  test(
    'test download verifies a large public artifact into a new local directory',
    () async {
      final run = await createRun();
      final artifact = await artifacts.publish(
        bytes: Stream.fromIterable(
          List.generate(32, (_) => List<int>.filled(8192, 0)),
        ),
        kind: ArtifactKind.stdout,
        contentType: 'application/octet-stream',
        maxBytes: 262144,
        operationId: run.operationId,
        testRunId: run.resourceId as TestRunId,
      );
      final output = await Directory('${temporary.path}/downloads').create();
      final marker = await File(
        '${output.path}/${artifact.id.value}',
      ).writeAsString('keep existing');
      final result = await invoke([
        'test',
        'download',
        run.resourceId.value,
        artifact.id.value,
        '--output-dir',
        output.path,
      ]);
      expect(result.code, 0, reason: result.error);
      expect(result.error, isEmpty);
      final receipt = jsonDecode(result.output) as Map;
      expect(Artifact.fromJson(receipt['artifact']), artifact);
      expect(receipt['verified'], isTrue);
      expect(RequestId(receipt['request_id'] as String), isA<RequestId>());
      final file = File(receipt['output_path'] as String);
      expect(await file.length(), artifact.sizeBytes);
      expect(file.parent.parent.path, await output.resolveSymbolicLinks());
      expect(
        await file.openRead().expand((chunk) => chunk).any((byte) => byte != 0),
        isFalse,
      );
      expect(await marker.readAsString(), 'keep existing');
    },
  );

  test('test artifacts resumes isolated public metadata pages', () async {
    final runs = [for (var index = 0; index < 2; index++) await createRun()];
    final expected = <Artifact>[];
    for (var index = 0; index < 4; index++) {
      final run = index < 3 ? runs.first : runs.last;
      final artifact = await artifacts.publish(
        bytes: Stream.value(utf8.encode('fixture output $index')),
        kind: ArtifactKind.stdout,
        contentType: 'text/plain',
        maxBytes: 128,
        operationId: run.operationId,
        testRunId: run.resourceId as TestRunId,
      );
      if (index < 3) expected.add(artifact);
    }
    final first = await invoke([
      'test',
      'artifacts',
      runs.first.resourceId.value,
      '--limit',
      '2',
      '--timeout-seconds',
      '5',
    ]);
    expect(first.code, 0, reason: first.error);
    expect(first.error, isEmpty);
    final page = jsonDecode(first.output) as Map;
    expect(page['items'], hasLength(2));
    expect(page['next_cursor'], isA<String>());
    final second = await invoke([
      'test',
      'artifacts',
      runs.first.resourceId.value,
      '--limit',
      '2',
      '--cursor',
      page['next_cursor'] as String,
    ]);
    expect(second.code, 0, reason: second.error);
    final next = jsonDecode(second.output) as Map;
    expect(next['items'], hasLength(1));
    expect(next['next_cursor'], isNull);
    final listed = [
      ...(page['items'] as List).map(Artifact.fromJson),
      ...(next['items'] as List).map(Artifact.fromJson),
    ];
    expect(listed.toSet(), expected.toSet());
    expect(
      listed.every((item) => item.testRunId == runs.first.resourceId),
      isTrue,
    );
    final other = await invoke([
      'test',
      'artifacts',
      runs.last.resourceId.value,
      '--cursor',
      page['next_cursor'] as String,
    ]);
    expect(other.code, 1);
    expect(other.output, isEmpty);
    expect(
      Problem.fromJson(jsonDecode(other.error)).code,
      ErrorCode.invalidRequest,
    );
  });

  test(
    'test run replays one acceptance and preserves idempotency conflicts',
    () async {
      final args = [
        'test',
        'run',
        '--body-json',
        jsonEncode(spec.toJson()),
        '--idempotency-key',
        'cli-test-retry',
      ];
      final first = await invoke(args);
      expect(first.code, 0, reason: first.error);
      final replay = await invoke(args);
      expect(replay.code, 0, reason: replay.error);
      expect(jsonDecode(replay.output), jsonDecode(first.output));
      final changed = {...spec.toJson(), 'cleanup': 'retain'};
      final conflict = await invoke([
        'test',
        'run',
        '--body-json',
        jsonEncode(changed),
        '--idempotency-key',
        'cli-test-retry',
      ]);
      expect(conflict.code, 1);
      expect(conflict.output, isEmpty);
      final problem = Problem.fromJson(jsonDecode(conflict.error));
      expect(problem.code, ErrorCode.idempotencyConflict);
      expect(problem.status, HttpStatus.conflict);
      expect(problem.requestId.value, startsWith('req_'));
    },
  );

  test(
    'missing TestRuns preserve typed API failures for every read or cancel',
    () async {
      final id = TestRunId.generate().value;
      for (final verb in ['get', 'cancel', 'artifacts']) {
        final result = await invoke(['test', verb, id]);
        expect(result.code, 1, reason: verb);
        expect(result.output, isEmpty);
        final problem = Problem.fromJson(jsonDecode(result.error));
        expect(problem.code, ErrorCode.testRunNotFound);
        expect(problem.status, HttpStatus.notFound);
        expect(problem.requestId.value, startsWith('req_'));
      }
    },
  );

  test(
    'an accepted run with no collected artifacts returns an empty page',
    () async {
      final run = await createRun();
      final result = await invoke(['test', 'artifacts', run.resourceId.value]);
      expect(result.code, 0, reason: result.error);
      expect(jsonDecode(result.output), {'items': [], 'next_cursor': null});
    },
  );

  test('TestRun semantic validation remains owned by the public API', () async {
    final cases = [
      (body: <String, Object?>{}, code: ErrorCode.invalidRequest),
      (
        body: {
          ...spec.toJson(),
          'source': {'image_id': ImageId.generate().value},
        },
        code: ErrorCode.imageNotFound,
      ),
    ];
    for (final item in cases) {
      final result = await invoke([
        'test',
        'run',
        '--body-json',
        jsonEncode(item.body),
      ]);
      expect(result.code, 1, reason: result.error);
      expect(result.output, isEmpty);
      final problem = Problem.fromJson(jsonDecode(result.error));
      expect(problem.code, item.code);
      expect(problem.requestId.value, startsWith('req_'));
    }
  });

  test(
    'TestRun usage errors reject wrong targets, bodies and options locally',
    () async {
      final id = TestRunId.generate().value;
      final cases = <List<String>>[
        ['test', 'run'],
        ['test', 'run', '--body-json', '[]'],
        ['test', 'run', '--body-json', '{'],
        ['test', 'run', id, '--body-json', '{}'],
        ['test', 'get', id, '--body-json', '{}'],
        ['test', 'cancel', id, '--body-json', '{}'],
        ['test', 'get', id, '--idempotency-key', 'read-key'],
        ['test', 'artifacts', id, '--idempotency-key', 'read-key'],
        ['test', 'artifacts', id, '--limit', '201'],
        ['test', 'artifacts', id, '--cursor', ''],
        ['test', 'artifacts', id, '--sort', 'id'],
        ['test', 'get', id, '--limit', '1'],
        ['test', 'cancel', id, '--condition', 'runtime_running'],
        ['test', 'get', id, '--timeout-seconds', '0'],
        ['test', 'get', id, '--timeout-seconds', '86401'],
        for (final verb in ['get', 'cancel', 'artifacts']) ...[
          ['test', verb],
          ['test', verb, 'default'],
          ['test', verb, VmId.generate().value],
          ['test', verb, OperationId.generate().value],
          ['test', verb, '$id/other'],
        ],
      ];
      for (final args in cases) {
        final output = StringBuffer(), error = StringBuffer();
        final code = await runCli(
          ['--socket-path', '${temporary.path}/absent.sock', ...args, '--json'],
          output: output.writeln,
          error: error.writeln,
        );
        expect(code, 2, reason: args.join(' '));
        expect(output.toString(), isEmpty);
        expect(jsonDecode(error.toString())['code'], 'CLI_USAGE');
      }
    },
  );
  test(
    'the CLI executable queries a collected pre-allocation cancellation',
    () async {
      final created = await invoke([
        'test',
        'run',
        '--body-json',
        jsonEncode(spec.toJson()),
      ]);
      expect(created.code, 0, reason: created.error);
      final accepted = OperationAcceptance.fromJson(jsonDecode(created.output));
      final id = accepted.resourceId as TestRunId;
      final cancel = await invoke(['test', 'cancel', id.value]);
      expect(cancel.code, 0, reason: cancel.error);
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      final directory = await Directory('${temporary.path}/vms').create();
      imageFileMode(directory.path, 0x1c0);
      final bundles = await OwnedImageDirectory.open(directory);
      try {
        expect(
          (await TestRunCollectionWorker(
            database: database,
            bundles: bundles,
            artifacts: artifacts,
          ).dispatchOnce()).single.collected,
          isTrue,
        );
        expect(
          (await TestRunCleanupWorker(
            database: database,
          ).dispatchOnce()).single.completed,
          isTrue,
        );
      } finally {
        bundles.close();
      }
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/bin/gaovm_cli.dart',
        '--socket-path',
        server.socketPath,
        'test',
        'get',
        id.value,
        '--json',
        '--timeout-seconds',
        '5',
      ]).timeout(const Duration(seconds: 15));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stderr, isEmpty);
      expect((result.stdout as String).trim().split('\n'), hasLength(1));
      final run = TestRun.fromJson(jsonDecode(result.stdout as String));
      expect(run.state, TestRunState.cancelled);
      expect(run.vmId, isNull);
      expect(
        run.steps.every((step) => step.state == TestStepState.skipped),
        isTrue,
      );
      expect(run.cleanupDecision, 'not_required');
      final listed = await invoke(['test', 'artifacts', id.value]);
      expect(listed.code, 0, reason: listed.error);
      final page = jsonDecode(listed.output) as Map;
      final artifact = Artifact.fromJson((page['items'] as List).single);
      expect(artifact.kind, ArtifactKind.result);
      expect(artifact.testRunId, id);
      expect(artifact.operationId, accepted.operationId);
      expect(run.artifactIds, [artifact.id]);
      final download = HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionFactory = (_, _, _) => Socket.startConnect(
          InternetAddress(server.socketPath, type: InternetAddressType.unix),
          0,
        );
      try {
        final response = await (await download.getUrl(
          Uri.parse('http://localhost${artifact.downloadUrl}'),
        )).close();
        expect(response.statusCode, HttpStatus.ok);
        final snapshot =
            jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        expect(snapshot['execution_outcome'], 'cancelled');
        expect(snapshot['vm_id'], isNull);
      } finally {
        download.close(force: true);
      }
    },
  );
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
