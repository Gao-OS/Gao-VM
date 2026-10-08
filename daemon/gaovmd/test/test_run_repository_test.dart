import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'gaovmd-test-run-repository-',
    );
    databasePath = '${temporaryDirectory.path}/gaovm.db';
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'creation persists the full spec, ordered steps and operation',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final now = DateTime.utc(2026, 10, 8, 12);
      final repository = SqliteTestRunRepository(database, now: () => now);
      final spec = _spec();
      final created = await repository.create(
        spec: spec,
        requestId: RequestId.generate(),
        idempotencyKey: 'test-network',
      );

      expect(created.state, TestRunState.pending);
      expect(created.spec, spec);
      expect(created.vmId, isNull);
      expect(created.steps.map((step) => step.index), [0, 1]);
      expect(created.steps.map((step) => step.request), spec.steps);
      expect(
        created.steps.every((step) => step.state == TestStepState.pending),
        isTrue,
      );
      expect(
        created.steps.every(
          (step) => step.startedAt == null && step.completedAt == null,
        ),
        isTrue,
      );
      expect(created.artifactIds, isEmpty);
      expect(created.createdAt, now);
      expect(created.completedAt, isNull);
      expect(await repository.get(created.id), created);
      final operation = (await SqliteOperationRepository(
        database,
      ).get(created.operationId))!;
      expect(operation.type, 'test.run');
      expect(operation.resourceType, ResourceType.testRun);
      expect(operation.resourceId, created.id);
      expect(operation.state, OperationState.pending);
      expect(operation.request.toJson(), spec.toJson());
      expect(operation.idempotencyKey, 'test-network');
      expect(operation.deadlineAt, now.add(const Duration(minutes: 5)));
      final events = SqliteEventRepository(database);
      expect(
        (await events.list(
          operationId: operation.id,
        )).map((event) => event.type),
        ['operation.created', 'test_run.created'],
      );
      expect(
        (await events.list(testRunId: created.id)).single.resourceId,
        created.id,
      );
      expect(await events.readUnpublishedOutbox(), hasLength(2));

      database.close();
      final reopened = await GaoVmDatabase.open(databasePath);
      addTearDown(reopened.close);
      expect(await SqliteTestRunRepository(reopened).get(created.id), created);
      expect(
        await SqliteOperationRepository(reopened).get(created.operationId),
        operation,
      );
    },
  );
  test(
    'phase advances guard stale workers and attach one explicit VM',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteTestRunRepository(database);
      final created = await repository.create(
        spec: _spec(),
        requestId: RequestId.generate(),
      );
      await expectLater(
        repository.transition(
          created.id,
          expectedState: TestRunState.pending,
          nextState: TestRunState.runningSteps,
        ),
        throwsA(isA<TestRunConflictException>()),
      );
      final provisioning = await repository.transition(
        created.id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.provisioning,
      );
      expect(provisioning.state, TestRunState.provisioning);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(created.operationId))!.state,
        OperationState.running,
      );
      await expectLater(
        repository.transition(
          created.id,
          expectedState: TestRunState.pending,
          nextState: TestRunState.provisioning,
        ),
        throwsA(isA<TestRunConflictException>()),
      );
      await expectLater(
        repository.transition(
          created.id,
          expectedState: TestRunState.provisioning,
          nextState: TestRunState.startingVm,
        ),
        throwsA(isA<TestRunConflictException>()),
      );
      final vm = await _vm(database);
      final starting = await repository.transition(
        created.id,
        expectedState: TestRunState.provisioning,
        nextState: TestRunState.startingVm,
        vmId: vm.metadata.id,
      );
      expect(starting.vmId, vm.metadata.id);
      await expectLater(
        repository.transition(
          created.id,
          expectedState: TestRunState.startingVm,
          nextState: TestRunState.waitingReady,
          vmId: VmId.generate(),
        ),
        throwsA(isA<TestRunConflictException>()),
      );
      await repository.transition(
        created.id,
        expectedState: TestRunState.startingVm,
        nextState: TestRunState.waitingReady,
      );
      final running = await repository.transition(
        created.id,
        expectedState: TestRunState.waitingReady,
        nextState: TestRunState.runningSteps,
      );
      expect(running.state, TestRunState.runningSteps);
      expect(running.vmId, vm.metadata.id);
      expect(running.spec, created.spec);
      expect(running.completedAt, isNull);
      final changes = await SqliteEventRepository(
        database,
      ).list(resourceType: ResourceType.testRun, testRunId: created.id);
      expect(changes.map((event) => event.payload.toJson()['state']), [
        'pending',
        'provisioning',
        'starting_vm',
        'waiting_ready',
        'running_steps',
      ]);
      expect(
        changes.skip(2).every((event) => event.vmId == vm.metadata.id),
        isTrue,
      );
    },
  );

  test(
    'steps execute once in order and retain structured terminal results',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      var now = DateTime.utc(2026, 10, 8, 12);
      final repository = SqliteTestRunRepository(database, now: () => now);
      final run = await _running(repository, database);
      final result = JsonObjectValue.fromJson({
        'exit_code': 0,
        'duration_ms': 10,
      });
      await expectLater(
        repository.startStep(run.id, index: 1),
        throwsA(isA<TestRunConflictException>()),
      );
      await expectLater(
        repository.finishStep(
          run.id,
          index: 0,
          state: TestStepState.succeeded,
          result: result,
        ),
        throwsA(isA<TestRunConflictException>()),
      );
      final started = await repository.startStep(run.id, index: 0);
      expect(started.steps[0].state, TestStepState.running);
      expect(started.steps[0].startedAt, now);
      expect(started.steps[1].state, TestStepState.pending);
      await expectLater(
        repository.startStep(run.id, index: 0),
        throwsA(isA<TestRunConflictException>()),
      );
      await expectLater(
        repository.startStep(run.id, index: 1),
        throwsA(isA<TestRunConflictException>()),
      );
      now = now.add(const Duration(seconds: 1));
      final first = await repository.finishStep(
        run.id,
        index: 0,
        state: TestStepState.succeeded,
        result: result,
      );
      expect(first.steps[0].state, TestStepState.succeeded);
      expect(first.steps[0].result, result);
      expect(first.steps[0].completedAt, now);
      await expectLater(
        repository.finishStep(
          run.id,
          index: 0,
          state: TestStepState.failed,
          error: _failure(),
        ),
        throwsA(isA<TestRunConflictException>()),
      );
      await repository.startStep(run.id, index: 1);
      final completed = await repository.finishStep(
        run.id,
        index: 1,
        state: TestStepState.succeeded,
        result: result,
      );
      expect(
        completed.steps.every((step) => step.state == TestStepState.succeeded),
        isTrue,
      );
      expect(completed.state, TestRunState.runningSteps);
      expect(completed.completedAt, isNull);
      expect(
        (await SqliteOperationRepository(database).get(run.operationId))!.state,
        OperationState.running,
      );
      expect(await repository.get(run.id), completed);
      final events = (await SqliteEventRepository(database).list(
        testRunId: run.id,
      )).where((event) => event.type.startsWith('test_run.step_')).toList();
      expect(events.map((event) => event.type), [
        'test_run.step_started',
        'test_run.step_completed',
        'test_run.step_started',
        'test_run.step_completed',
      ]);
      expect(
        events.map((event) => (event.payload.toJson()['step'] as Map)['index']),
        [0, 0, 1, 1],
      );
    },
  );

  test(
    'successful completion requires collection and recorded cleanup first',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteTestRunRepository(database);
      final run = await _running(repository, database);
      await expectLater(
        repository.finish(run.id, outcome: TestRunState.succeeded),
        throwsA(isA<TestRunConflictException>()),
      );
      for (final step in run.steps) {
        await repository.startStep(run.id, index: step.index);
        await repository.finishStep(
          run.id,
          index: step.index,
          state: TestStepState.succeeded,
          result: JsonObjectValue.fromJson({'exit_code': 0}),
        );
      }
      await repository.transition(
        run.id,
        expectedState: TestRunState.runningSteps,
        nextState: TestRunState.collecting,
      );
      await expectLater(
        repository.finish(run.id, outcome: TestRunState.succeeded),
        throwsA(isA<TestRunConflictException>()),
      );
      await expectLater(
        repository.transition(
          run.id,
          expectedState: TestRunState.collecting,
          nextState: TestRunState.cleaningUp,
        ),
        throwsA(isA<TestRunConflictException>()),
      );
      final cleaning = await repository.transition(
        run.id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'delete',
      );
      expect(cleaning.cleanupDecision, 'delete');
      expect(
        (await SqliteOperationRepository(database).get(run.operationId))!.state,
        OperationState.running,
      );
      final summary = JsonObjectValue.fromJson({'passed': 2, 'failed': 0});
      final completed = await repository.finish(
        run.id,
        outcome: TestRunState.succeeded,
        result: summary,
      );
      expect(completed.state, TestRunState.succeeded);
      expect(completed.result, summary);
      expect(completed.completedAt, isNotNull);
      expect(completed.cleanupDecision, 'delete');
      final operation = (await SqliteOperationRepository(
        database,
      ).get(run.operationId))!;
      expect(operation.state, OperationState.succeeded);
      expect(operation.result, summary);
      expect(operation.cancellable, isFalse);
      final events = await SqliteEventRepository(
        database,
      ).list(testRunId: run.id);
      expect(
        events.map((event) => event.type).toList().sublist(events.length - 2),
        ['operation.completed', 'test_run.completed'],
      );
      await expectLater(
        repository.finish(
          run.id,
          outcome: TestRunState.failed,
          error: _failure(),
        ),
        throwsA(isA<TestRunConflictException>()),
      );
      expect(await repository.get(run.id), completed);
    },
  );
  test(
    'cancellation intent survives restart and fences subsequent steps',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteTestRunRepository(database);
      final run = await _running(repository, database);
      await repository.startStep(run.id, index: 0);
      await repository.finishStep(
        run.id,
        index: 0,
        state: TestStepState.succeeded,
        result: JsonObjectValue.fromJson({'exit_code': 0}),
      );
      await repository.requestCancel(run.id);
      await repository.requestCancel(run.id);
      expect(
        (await SqliteOperationRepository(database).get(run.operationId))!.state,
        OperationState.running,
      );
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: run.id,
        )).where((event) => event.type == 'test_run.cancel_requested'),
        hasLength(1),
      );
      database.close();
      final reopened = await GaoVmDatabase.open(databasePath);
      addTearDown(reopened.close);
      final recovered = SqliteTestRunRepository(reopened);
      final work = (await recovered.listUnfinished()).single;
      expect(work.id, run.id);
      expect(work.vmId, run.vmId);
      expect(work.operationId, run.operationId);
      expect(work.cancelRequested, isTrue);
      expect(work.plannedOutcome, isNull);
      await expectLater(
        recovered.startStep(run.id, index: 1),
        throwsA(isA<TestRunConflictException>()),
      );
      expect(
        (await recovered.get(run.id))!.steps[1].state,
        TestStepState.pending,
      );
    },
  );
  test(
    'failure intent and skipped successors survive collection-time restart',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteTestRunRepository(database);
      final run = await _running(repository, database);
      final failure = _failure();
      final partial = JsonObjectValue.fromJson({'exit_code': 1});
      await repository.startStep(run.id, index: 0);
      await repository.finishStep(
        run.id,
        index: 0,
        state: TestStepState.failed,
        error: failure,
        result: partial,
      );
      await expectLater(
        repository.startStep(run.id, index: 1),
        throwsA(isA<TestRunConflictException>()),
      );
      final collecting = await repository.transition(
        run.id,
        expectedState: TestRunState.runningSteps,
        nextState: TestRunState.collecting,
        outcome: TestRunState.failed,
        error: failure,
        result: partial,
      );
      expect(collecting.steps[1].state, TestStepState.skipped);
      expect(collecting.steps[1].startedAt, isNull);
      expect(collecting.error, failure);
      expect(collecting.result, partial);
      expect(
        (await repository.listUnfinished()).single.plannedOutcome,
        TestRunState.failed,
      );
      database.close();
      final reopened = await GaoVmDatabase.open(databasePath);
      addTearDown(reopened.close);
      final recovered = SqliteTestRunRepository(reopened);
      expect(
        (await recovered.listUnfinished()).single.plannedOutcome,
        TestRunState.failed,
      );
      await recovered.transition(
        run.id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'retain',
      );
      await expectLater(
        recovered.finish(run.id, outcome: TestRunState.cancelled),
        throwsA(isA<TestRunConflictException>()),
      );
      final completed = await recovered.finish(
        run.id,
        outcome: TestRunState.failed,
      );
      expect(completed.error, failure);
      expect(completed.result, partial);
      final operation = (await SqliteOperationRepository(
        reopened,
      ).get(run.operationId))!;
      expect(operation.state, OperationState.failed);
      expect(operation.error, failure);
      expect(await recovered.listUnfinished(), isEmpty);
    },
  );
  test(
    'cleanup failure is durable and cannot become a successful completion',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteTestRunRepository(database);
      final run = await repository.create(
        spec: _spec(),
        requestId: RequestId.generate(),
      );
      await repository.requestCancel(run.id);
      await repository.transition(
        run.id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      await repository.transition(
        run.id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'retain',
      );
      final error = OperationError(
        code: ErrorCode.internalError,
        message: 'VM cleanup failed',
        retryable: false,
        details: JsonObjectValue.fromJson({'stage': 'cleanup'}),
      );
      final failed = await repository.recordFailure(run.id, error: error);
      expect(failed.error, error);
      expect(failed.state, TestRunState.cleaningUp);
      expect(
        (await repository.listUnfinished()).single.plannedOutcome,
        TestRunState.failed,
      );
      await expectLater(
        repository.finish(run.id, outcome: TestRunState.cancelled),
        throwsA(isA<TestRunConflictException>()),
      );
      final completed = await repository.finish(
        run.id,
        outcome: TestRunState.failed,
      );
      expect(completed.error, error);
      expect(
        completed.steps.every((step) => step.state == TestStepState.skipped),
        isTrue,
      );
      expect(
        (await SqliteOperationRepository(database).get(run.operationId))!.state,
        OperationState.failed,
      );
    },
  );
  test(
    'legacy missing outcome can be classified without losing the primary error',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteTestRunRepository(database);
      final run = await repository.create(
        spec: _spec(),
        requestId: RequestId.generate(),
      );
      final error = _failure();
      await repository.transition(
        run.id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.failed,
        error: error,
      );
      // Reproduce an upgraded v8 collecting row: the error exists but no outcome
      // was recorded by the older catalog. This is fault setup, not verification.
      await database.transaction(
        (connection) => connection.execute(
          'UPDATE test_runs SET planned_outcome = NULL WHERE id = ?',
          [run.id.value],
        ),
      );
      await repository.recordFailure(run.id, error: error);
      expect(
        (await repository.listUnfinished()).single.plannedOutcome,
        TestRunState.failed,
      );
      final later = OperationError(
        code: ErrorCode.internalError,
        message: 'artifact collection failed',
        retryable: false,
        details: JsonObjectValue.fromJson({'stage': 'collecting'}),
      );
      await repository.recordFailure(run.id, error: later);
      expect((await repository.get(run.id))!.error, error);
      final events = (await SqliteEventRepository(database).list(
        testRunId: run.id,
      )).where((event) => event.type == 'test_run.failure_recorded').toList();
      expect(events.last.payload.toJson()['failure'], later.toJson());
      expect(events.last.payload.toJson()['error'], error.toJson());
    },
  );
  test('one TestRun cannot claim another run VM', () async {
    final database = await GaoVmDatabase.open(databasePath);
    addTearDown(database.close);
    final repository = SqliteTestRunRepository(database);
    final first = await _running(repository, database);
    final second = await repository.create(
      spec: _spec(),
      requestId: RequestId.generate(),
    );
    await repository.transition(
      second.id,
      expectedState: TestRunState.pending,
      nextState: TestRunState.provisioning,
    );
    await expectLater(
      repository.transition(
        second.id,
        expectedState: TestRunState.provisioning,
        nextState: TestRunState.startingVm,
        vmId: first.vmId,
      ),
      throwsA(isA<TestRunConflictException>()),
    );
    expect((await repository.get(second.id))!.state, TestRunState.provisioning);
    expect((await repository.get(second.id))!.vmId, isNull);
    expect(await repository.get(first.id), first);
  });
  test(
    'cancellation during provisioning retains the VM binding for cleanup',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteTestRunRepository(database);
      final run = await repository.create(
        spec: _spec(),
        requestId: RequestId.generate(),
      );
      await repository.transition(
        run.id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.provisioning,
      );
      final vm = await _vm(database);
      await repository.requestCancel(run.id);
      final collecting = await repository.transition(
        run.id,
        expectedState: TestRunState.provisioning,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
        vmId: vm.metadata.id,
      );
      expect(collecting.vmId, vm.metadata.id);
      expect(
        collecting.steps.every((step) => step.state == TestStepState.skipped),
        isTrue,
      );
      expect(
        (await repository.listUnfinished()).single.plannedOutcome,
        TestRunState.cancelled,
      );
      await repository.transition(
        run.id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'retain',
      );
      final completed = await repository.finish(
        run.id,
        outcome: TestRunState.cancelled,
      );
      expect(completed.vmId, vm.metadata.id);
      expect(
        (await SqliteOperationRepository(database).get(run.operationId))!.state,
        OperationState.cancelled,
      );
    },
  );
  test(
    'failed creation rolls back the run, operation, events and outbox',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final id = TestRunId.generate();
      final duplicate = EventId.generate();
      final repository = SqliteTestRunRepository(
        database,
        newTestRunId: () => id,
        newEventId: () => duplicate,
      );
      await expectLater(
        repository.create(spec: _spec(), requestId: RequestId.generate()),
        throwsA(isA<SqliteException>()),
      );
      expect(await repository.get(id), isNull);
      expect(await repository.listUnfinished(), isEmpty);
      expect(await SqliteOperationRepository(database).list(), isEmpty);
      final events = SqliteEventRepository(database);
      expect(await events.list(), isEmpty);
      expect(await events.readUnpublishedOutbox(), isEmpty);
    },
  );

  test(
    'failed completion rolls back both terminal states and is retryable',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteTestRunRepository(database);
      final run = await repository.create(
        spec: _spec(),
        requestId: RequestId.generate(),
      );
      await repository.requestCancel(run.id);
      await repository.transition(
        run.id,
        expectedState: TestRunState.pending,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      final before = await repository.transition(
        run.id,
        expectedState: TestRunState.collecting,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'retain',
      );
      final events = SqliteEventRepository(database);
      final beforeEvents = await events.list();
      final beforeOutbox = await events.readUnpublishedOutbox();
      final failing = SqliteTestRunRepository(
        database,
        newEventId: () => beforeEvents.first.eventId,
      );
      await expectLater(
        failing.finish(run.id, outcome: TestRunState.cancelled),
        throwsA(isA<SqliteException>()),
      );
      expect(await repository.get(run.id), before);
      expect(
        (await SqliteOperationRepository(database).get(run.operationId))!.state,
        OperationState.running,
      );
      expect(await events.list(), beforeEvents);
      expect(
        (await events.readUnpublishedOutbox()).map((row) => row.id),
        beforeOutbox.map((row) => row.id),
      );
      expect(
        (await repository.finish(
          run.id,
          outcome: TestRunState.cancelled,
        )).state,
        TestRunState.cancelled,
      );
    },
  );

  test(
    'competing step claims have one winner and do not mutate another run',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final secondConnection = await GaoVmDatabase.open(databasePath);
      addTearDown(secondConnection.close);
      final repository = SqliteTestRunRepository(database);
      final competing = SqliteTestRunRepository(secondConnection);
      final run = await _running(repository, database);
      final other = await repository.create(
        spec: _spec(),
        requestId: RequestId.generate(),
      );
      Future<TestRun?> claim(SqliteTestRunRepository owner) async {
        try {
          return await owner.startStep(run.id, index: 0);
        } on TestRunConflictException {
          return null;
        }
      }

      final claims = await Future.wait([claim(repository), claim(competing)]);
      expect(claims.whereType<TestRun>(), hasLength(1));
      expect(
        (await repository.get(run.id))!.steps[0].state,
        TestStepState.running,
      );
      expect(await repository.get(other.id), other);
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: run.id,
        )).where((event) => event.type == 'test_run.step_started'),
        hasLength(1),
      );
    },
  );

  test(
    'active cancellation must finish the active step before collection',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteTestRunRepository(database);
      final run = await _running(repository, database);
      await repository.startStep(run.id, index: 0);
      await repository.requestCancel(run.id);
      await expectLater(
        repository.transition(
          run.id,
          expectedState: TestRunState.runningSteps,
          nextState: TestRunState.collecting,
          outcome: TestRunState.cancelled,
        ),
        throwsA(isA<TestRunConflictException>()),
      );
      await repository.finishStep(
        run.id,
        index: 0,
        state: TestStepState.cancelled,
        result: JsonObjectValue.fromJson({'signal': 'SIGTERM'}),
      );
      final collecting = await repository.transition(
        run.id,
        expectedState: TestRunState.runningSteps,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      expect(collecting.steps[0].state, TestStepState.cancelled);
      expect(collecting.steps[1].state, TestStepState.skipped);
      await expectLater(
        repository.finishStep(
          run.id,
          index: 0,
          state: TestStepState.succeeded,
          result: JsonObjectValue.fromJson({'exit_code': 0}),
        ),
        throwsA(isA<TestRunConflictException>()),
      );
    },
  );

  test(
    'recovery scan is bounded, paginated and contains only unfinished runs',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteTestRunRepository(database);
      final runs = [
        for (var index = 0; index < 3; index++)
          await repository.create(
            spec: _spec(),
            requestId: RequestId.generate(),
          ),
      ]..sort((a, b) => a.id.value.compareTo(b.id.value));
      final first = await repository.listUnfinished(limit: 2);
      expect(first.map((item) => item.id), runs.take(2).map((run) => run.id));
      final next = await repository.listUnfinished(
        afterId: first.last.id,
        limit: 2,
      );
      expect(next.single.id, runs.last.id);
      for (final limit in [0, 201]) {
        await expectLater(
          repository.listUnfinished(limit: limit),
          throwsRangeError,
        );
      }
      expect(await repository.get(TestRunId.generate()), isNull);
      await expectLater(
        repository.requestCancel(TestRunId.generate()),
        throwsA(isA<TestRunNotFoundException>()),
      );
    },
  );
}

OperationError _failure() => OperationError(
  code: ErrorCode.guestExecFailed,
  message: 'guest command failed',
  retryable: false,
  details: JsonObjectValue.fromJson({'exit_code': 1}),
);

Future<TestRun> _running(
  SqliteTestRunRepository repository,
  GaoVmDatabase database,
) async {
  final run = await repository.create(
    spec: _spec(),
    requestId: RequestId.generate(),
  );
  await repository.transition(
    run.id,
    expectedState: TestRunState.pending,
    nextState: TestRunState.provisioning,
  );
  final vm = await _vm(database);
  await repository.transition(
    run.id,
    expectedState: TestRunState.provisioning,
    nextState: TestRunState.startingVm,
    vmId: vm.metadata.id,
  );
  await repository.transition(
    run.id,
    expectedState: TestRunState.startingVm,
    nextState: TestRunState.waitingReady,
  );
  return repository.transition(
    run.id,
    expectedState: TestRunState.waitingReady,
    nextState: TestRunState.runningSteps,
  );
}

Future<VirtualMachine> _vm(GaoVmDatabase database) =>
    SqliteVmRepository(database).create(
      name: 'test-vm',
      spec: VmSpec(
        cpu: 2,
        memoryBytes: 2147483648,
        boot: LinuxKernelBoot(
          kernelImageId: ImageId('img_01J00000000000000000000002'),
        ),
        disks: [
          VmDisk(
            id: 'root',
            source: ExternalDiskSource('/tmp/root.img'),
            writable: true,
          ),
        ],
        networks: [SharedNetwork(id: 'net0')],
        graphics: GraphicsConfig(enabled: false),
        serial: const SerialConfig(enabled: true, capture: true),
        guestAgent: GuestAgentConfig(enabled: true, requiredForReady: true),
        restartPolicy: RestartPolicy.onFailure,
      ),
    );

TestRunSpec _spec() => TestRunSpec(
  source: ImageTestRunSource(ImageId('img_01J00000000000000000000001')),
  vmOverrides: VmSpecPatch(cpu: 2),
  wait: VmWaitSpec(
    condition: WaitCondition.guestAgentReady,
    timeoutSeconds: 30,
  ),
  steps: [
    TestStepRequest(
      name: 'network',
      argv: ['gaoos-test', 'network'],
      env: const {'TEST_MODE': 'smoke'},
      timeoutSeconds: 60,
    ),
    TestStepRequest(
      name: 'system',
      argv: ['gaoos-test', 'system'],
      cwd: '/tmp',
      timeoutSeconds: 20,
    ),
  ],
  timeoutSeconds: 300,
  cleanup: CleanupPolicy.deleteOnSuccess,
  retainOnFailure: true,
);
