import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late Image source;
  TestRunApplicationService service() =>
      TestRunApplicationService(database: database);
  TestRunCreateCommand command({String? key = 'run-smoke', TestRunSpec? spec}) {
    final input = spec ?? _spec(source.id);
    return TestRunCreateCommand(
      requestId: RequestId.generate(),
      idempotencyKey: key,
      requestBody: utf8.encode(jsonEncode(input.toJson())),
      spec: input,
    );
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('gvm-test-accept-');
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    final manifest = ImageManifest.create(
      type: ImageType.rawDisk,
      objects: {
        'payload': {'digest': contentDigest('disk'), 'size_bytes': 4},
      },
    );
    source = await ImageRepository(database).insert(
      Image(
        id: ImageId.generate(),
        digest: manifest.digest,
        type: ImageType.rawDisk,
        architecture: Architecture.arm64,
        manifest: JsonObjectValue.fromJson(manifest.toJson()),
        createdAt: DateTime.utc(2026, 10, 8),
      ),
    );
  });

  tearDown(() async {
    database.close();
    await temporary.delete(recursive: true);
  });

  test(
    'acceptance returns a pending operation and preserves the complete input',
    () async {
      final request = command();
      final accepted = await service().create(request);
      expect(accepted.resourceType, ResourceType.testRun);
      expect(accepted.state, OperationState.pending);
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final run = await service().get(accepted.resourceId as TestRunId);
      expect(run.spec, request.spec);
      expect(run.operationId, accepted.operationId);
      expect(run.state, TestRunState.pending);
      expect(run.vmId, isNull);
      expect(run.steps.single.request, request.spec.steps.single);
      final operation = (await SqliteOperationRepository(
        database,
      ).get(run.operationId))!;
      expect(operation.requestId, request.requestId);
      expect(operation.idempotencyKey, request.idempotencyKey);
      expect(operation.request.toJson(), request.spec.toJson());
      expect(await Directory('${temporary.path}/vms').exists(), isFalse);
    },
  );

  test(
    'retry replays original acceptance after completion and source deletion',
    () async {
      final accepted = await service().create(command());
      final id = accepted.resourceId as TestRunId;
      final runs = SqliteTestRunRepository(database);
      await runs.transition(
        id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.failed,
        error: OperationError(
          code: ErrorCode.driverStartFailed,
          message: 'test fixture startup failure',
          retryable: false,
          details: JsonObjectValue.empty,
        ),
      );
      await runs.transition(
        id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'retain',
      );
      await runs.finish(id, outcome: TestRunState.failed);
      await ImageRepository(database).delete(source.id);
      final events = await SqliteEventRepository(database).list();
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final replay = await service().create(command());
      expect(replay.toJson(), accepted.toJson());
      expect(replay.state, OperationState.pending);
      expect((await service().get(id)).state, TestRunState.failed);
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(await SqliteEventRepository(database).list(), events);
    },
  );

  test(
    'missing source rejects acceptance without consuming the retry key',
    () async {
      await ImageRepository(database).delete(source.id);
      final events = await SqliteEventRepository(database).list();
      await expectLater(
        service().create(command()),
        throwsA(isA<ImageNotFound>()),
      );
      expect(await SqliteTestRunRepository(database).listUnfinished(), isEmpty);
      expect(await SqliteOperationRepository(database).list(), isEmpty);
      expect(await SqliteEventRepository(database).list(), events);
      await ImageRepository(database).insert(source);
      expect((await service().create(command())).state, OperationState.pending);
    },
  );

  test(
    'unfinished runs protect their source until cleanup is completed',
    () async {
      final accepted = await service().create(command());
      final id = accepted.resourceId as TestRunId;
      final images = ImageRepository(database);
      expect(await images.references(source.id), contains(id.value));
      await expectLater(images.delete(source.id), throwsA(isA<ImageInUse>()));
      final runs = SqliteTestRunRepository(database);
      await runs.requestCancel(id);
      await runs.transition(
        id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      await runs.transition(
        id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'delete',
      );
      await expectLater(images.delete(source.id), throwsA(isA<ImageInUse>()));
      await runs.finish(id, outcome: TestRunState.cancelled);
      expect(await images.delete(source.id), source);
      expect(
        (await service().get(id)).spec.source,
        ImageTestRunSource(source.id),
      );
    },
  );

  test(
    'cancellation durably fences work without completing either operation',
    () async {
      final accepted = await service().create(command());
      final id = accepted.resourceId as TestRunId;
      final cancellation = await service().cancelRun(
        TestRunCancelCommand(
          testRunId: id,
          requestId: RequestId.generate(),
          idempotencyKey: 'cancel-smoke',
          requestBody: const [],
        ),
      );
      expect(cancellation.resourceType, ResourceType.testRun);
      expect(cancellation.resourceId, id);
      expect(cancellation.state, OperationState.pending);
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final run = await service().get(id);
      final operations = SqliteOperationRepository(database);
      final action = (await operations.get(cancellation.operationId))!;
      expect(action.type, 'test.cancel');
      expect(action.cancellable, isFalse);
      expect(action.state, OperationState.pending);
      expect(
        (await operations.get(run.operationId))!.state,
        OperationState.pending,
      );
      final runs = SqliteTestRunRepository(database);
      expect((await runs.listUnfinished()).single.cancelRequested, isTrue);
      await expectLater(
        runs.transition(
          id,
          expectedState: TestRunState.pending,
          nextState: TestRunState.provisioning,
        ),
        throwsA(isA<TestRunConflictException>()),
      );
    },
  );

  test(
    'cleanup completion finishes the cancellation action and keeps retries stable',
    () async {
      final accepted = await service().create(command());
      final id = accepted.resourceId as TestRunId;
      final request = TestRunCancelCommand(
        testRunId: id,
        requestId: RequestId.generate(),
        idempotencyKey: 'cancel-smoke',
        requestBody: const [],
      );
      final cancellation = await service().cancelRun(request);
      final runs = SqliteTestRunRepository(database);
      await runs.transition(
        id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      await runs.transition(
        id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'delete',
      );
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(cancellation.operationId))!.state,
        OperationState.pending,
      );
      await runs.finish(id, outcome: TestRunState.cancelled);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.cancelled,
      );
      final completed = (await operations.get(cancellation.operationId))!;
      expect(completed.state, OperationState.succeeded);
      expect(completed.result!.toJson(), {
        'test_run_id': id.value,
        'target_operation_id': accepted.operationId.value,
        'outcome': 'cancelled',
        'cleanup_decision': 'delete',
      });
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect(
        (await service().cancelRun(request)).toJson(),
        cancellation.toJson(),
      );
      await expectLater(
        service().cancelRun(
          TestRunCancelCommand(
            testRunId: id,
            requestId: RequestId.generate(),
            idempotencyKey: 'new-cancel',
            requestBody: const [],
          ),
        ),
        throwsA(isA<OperationNotCancellableException>()),
      );
    },
  );

  test(
    'operation cancellation records the same durable TestRun intent',
    () async {
      final accepted = await service().create(command());
      final id = accepted.resourceId as TestRunId;
      final request = OperationCancelCommand(
        operationId: accepted.operationId,
        requestId: RequestId.generate(),
        idempotencyKey: 'cancel-smoke',
        requestBody: const [],
      );
      final cancellation = await service().cancel(request);
      expect(cancellation.resourceType, ResourceType.operation);
      expect(cancellation.resourceId, accepted.operationId);
      expect(cancellation.state, OperationState.pending);
      expect(
        (await SqliteTestRunRepository(
          database,
        ).listUnfinished()).single.cancelRequested,
        isTrue,
      );
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await operations.get(cancellation.operationId))!.type,
        'operation.cancel',
      );
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect((await service().cancel(request)).toJson(), cancellation.toJson());
      expect((await service().get(id)).state, TestRunState.pending);
    },
  );

  test(
    'both cancellation endpoints use separate keys and finish after one cleanup',
    () async {
      final accepted = await service().create(command());
      final id = accepted.resourceId as TestRunId;
      final direct = await service().cancelRun(
        TestRunCancelCommand(
          testRunId: id,
          requestId: RequestId.generate(),
          idempotencyKey: 'same-key',
          requestBody: const [],
        ),
      );
      final indirect = await service().cancel(
        OperationCancelCommand(
          operationId: accepted.operationId,
          requestId: RequestId.generate(),
          idempotencyKey: 'same-key',
          requestBody: const [],
        ),
      );
      expect(direct.operationId, isNot(indirect.operationId));
      final runs = SqliteTestRunRepository(database);
      await runs.transition(
        id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      await runs.transition(
        id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'retain',
      );
      await runs.finish(id, outcome: TestRunState.cancelled);
      final operations = SqliteOperationRepository(database);
      for (final action in [direct, indirect]) {
        expect(
          (await operations.get(action.operationId))!.state,
          OperationState.succeeded,
        );
      }
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: id,
        )).where((event) => event.type == 'test_run.cancel_requested'),
        hasLength(1),
      );
    },
  );

  test(
    'cleanup failure fails cancellation instead of reporting successful cleanup',
    () async {
      final accepted = await service().create(command());
      final id = accepted.resourceId as TestRunId;
      final cancellation = await service().cancelRun(
        TestRunCancelCommand(
          testRunId: id,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
        ),
      );
      final runs = SqliteTestRunRepository(database);
      await runs.transition(
        id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      await runs.transition(
        id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'delete',
      );
      final failure = OperationError(
        code: ErrorCode.internalError,
        message: 'test fixture cleanup failure',
        retryable: false,
        details: JsonObjectValue.fromJson({'stage': 'cleanup'}),
      );
      await runs.recordFailure(id, error: failure);
      await runs.finish(id, outcome: TestRunState.failed);
      final action = (await SqliteOperationRepository(
        database,
      ).get(cancellation.operationId))!;
      expect(action.state, OperationState.failed);
      expect(action.error, failure);
      expect((await service().get(id)).error, failure);
    },
  );

  test('acceptance also validates images referenced by VM overrides', () async {
    final missing = ImageId.generate();
    for (final overrides in [
      VmSpecPatch(boot: LinuxKernelBoot(kernelImageId: missing)),
      VmSpecPatch(
        disks: [
          VmDisk(
            id: 'root',
            source: ManagedImageDiskSource(missing),
            writable: true,
          ),
        ],
      ),
    ]) {
      final spec = TestRunSpec.fromJson({
        ..._spec(source.id).toJson(),
        'vm_overrides': overrides.toJson(),
      });
      await expectLater(
        service().create(command(spec: spec)),
        throwsA(isA<ImageNotFound>()),
      );
    }
    expect(await SqliteTestRunRepository(database).listUnfinished(), isEmpty);
    expect(await SqliteOperationRepository(database).list(), isEmpty);
  });
  test(
    'failed cancellation acceptance rolls back intent, action and retry reservation',
    () async {
      final accepted = await service().create(command());
      final id = accepted.resourceId as TestRunId;
      final request = TestRunCancelCommand(
        testRunId: id,
        requestId: RequestId.generate(),
        idempotencyKey: 'retry-cancel',
        requestBody: const [],
      );
      final events = await SqliteEventRepository(database).list();
      await database.transaction(
        (connection) => connection.execute('''
      CREATE TRIGGER inject_cancel_failure BEFORE INSERT ON operations
      WHEN NEW.type = 'test.cancel'
      BEGIN SELECT RAISE(ABORT, 'injected cancellation failure'); END;
    '''),
      );
      await expectLater(
        service().cancelRun(request),
        throwsA(isA<SqliteException>()),
      );
      expect(
        (await SqliteTestRunRepository(
          database,
        ).listUnfinished()).single.cancelRequested,
        isFalse,
      );
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(await SqliteEventRepository(database).list(), events);
      await database.transaction(
        (connection) =>
            connection.execute('DROP TRIGGER inject_cancel_failure'),
      );
      expect(
        (await service().cancelRun(request)).state,
        OperationState.pending,
      );
    },
  );

  test(
    'failed cancellation completion rolls back all terminal states and events',
    () async {
      final accepted = await service().create(command());
      final id = accepted.resourceId as TestRunId;
      final cancellation = await service().cancelRun(
        TestRunCancelCommand(
          testRunId: id,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
        ),
      );
      final runs = SqliteTestRunRepository(database);
      await runs.transition(
        id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      final before = await runs.transition(
        id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'retain',
      );
      final events = SqliteEventRepository(database);
      final beforeEvents = await events.list();
      final beforeOutbox = (await events.readUnpublishedOutbox())
          .map((row) => row.id)
          .toList();
      await database.transaction(
        (connection) => connection.execute('''
      CREATE TRIGGER inject_completion_failure BEFORE UPDATE ON operations
      WHEN NEW.type = 'test.cancel' AND NEW.state = 'succeeded'
      BEGIN SELECT RAISE(ABORT, 'injected completion failure'); END;
    '''),
      );
      await expectLater(
        runs.finish(id, outcome: TestRunState.cancelled),
        throwsA(isA<SqliteException>()),
      );
      expect(await runs.get(id), before);
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.running,
      );
      expect(
        (await operations.get(cancellation.operationId))!.state,
        OperationState.pending,
      );
      expect(await events.list(), beforeEvents);
      expect(
        (await events.readUnpublishedOutbox()).map((row) => row.id),
        beforeOutbox,
      );
      await database.transaction(
        (connection) =>
            connection.execute('DROP TRIGGER inject_completion_failure'),
      );
      await runs.finish(id, outcome: TestRunState.cancelled);
      expect(
        (await operations.get(cancellation.operationId))!.state,
        OperationState.succeeded,
      );
    },
  );
  test(
    'application acceptance refuses caller-owned transactions before mutation',
    () async {
      await database.transaction((_) async {
        await expectLater(service().create(command()), throwsStateError);
      });
      expect(await SqliteOperationRepository(database).list(), isEmpty);
      final accepted = await service().create(command());
      final id = accepted.resourceId as TestRunId;
      await database.transaction((_) async {
        await expectLater(
          service().cancelRun(
            TestRunCancelCommand(
              testRunId: id,
              requestId: RequestId.generate(),
              idempotencyKey: 'not-committed',
              requestBody: const [],
            ),
          ),
          throwsStateError,
        );
        await expectLater(
          service().cancel(
            OperationCancelCommand(
              operationId: accepted.operationId,
              requestId: RequestId.generate(),
              idempotencyKey: 'not-committed',
              requestBody: const [],
            ),
          ),
          throwsStateError,
        );
      });
      expect(
        (await SqliteTestRunRepository(
          database,
        ).listUnfinished()).single.cancelRequested,
        isFalse,
      );
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
    },
  );

  test(
    'concurrent retries accept once without fencing another run from the same image',
    () async {
      final connection = await GaoVmDatabase.open(
        '${temporary.path}/catalog.db',
      );
      try {
        final other = TestRunApplicationService(database: connection);
        final accepted = await Future.wait([
          service().create(command()),
          other.create(command()),
        ]);
        expect(accepted.first.toJson(), accepted.last.toJson());
        expect(await SqliteOperationRepository(database).list(), hasLength(1));
        final independent = await other.create(command(key: 'independent'));
        expect(independent.resourceId, isNot(accepted.first.resourceId));
        expect(
          await ImageRepository(database).references(source.id),
          containsAll([
            accepted.first.resourceId.value,
            independent.resourceId.value,
          ]),
        );
        await service().cancelRun(
          TestRunCancelCommand(
            testRunId: accepted.first.resourceId as TestRunId,
            requestId: RequestId.generate(),
            idempotencyKey: 'cancel-first',
            requestBody: const [],
          ),
        );
        final work = await SqliteTestRunRepository(connection).listUnfinished();
        expect(
          work
              .singleWhere((item) => item.id == independent.resourceId)
              .cancelRequested,
          isFalse,
        );
        expect(
          work
              .singleWhere((item) => item.id == accepted.first.resourceId)
              .cancelRequested,
          isTrue,
        );
      } finally {
        connection.close();
      }
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
  timeoutSeconds: 300,
  cleanup: CleanupPolicy.deleteOnSuccess,
  retainOnFailure: true,
);
