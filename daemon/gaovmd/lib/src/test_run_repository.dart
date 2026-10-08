import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'event_repository.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';

abstract interface class TestRunRepository {
  /// Records a pending run only; public idempotency and source admission belong
  /// to application acceptance, not this catalog interface.
  Future<TestRun> create({
    required TestRunSpec spec,
    required RequestId requestId,
    String? idempotencyKey,
  });

  Future<TestRun?> get(TestRunId id);

  Future<List<TestRunWorkItem>> listUnfinished({
    TestRunId? afterId,
    int limit = 100,
  });

  Future<TestRun> requestCancel(TestRunId id);

  /// Retains the first failure as primary and journals subsequent failures.
  Future<TestRun> recordFailure(TestRunId id, {required OperationError error});

  Future<TestRun> transition(
    TestRunId id, {
    required TestRunState expectedState,
    required TestRunState nextState,
    VmId? vmId,
    String? cleanupDecision,
    TestRunState? outcome,
    JsonObjectValue? result,
    OperationError? error,
  });

  /// Claims one pending step. A running step is never automatically replayed.
  Future<TestRun> startStep(TestRunId id, {required int index});

  Future<TestRun> finishStep(
    TestRunId id, {
    required int index,
    required TestStepState state,
    JsonObjectValue? result,
    OperationError? error,
  });

  /// Called only after the worker has completed collection and cleanup. This
  /// records that completion; it does not perform or attest those external IOs.
  Future<TestRun> finish(
    TestRunId id, {
    required TestRunState outcome,
    JsonObjectValue? result,
    OperationError? error,
  });
}

/// Bounded recovery scan metadata; step results are loaded separately by get().
final class TestRunWorkItem {
  const TestRunWorkItem({
    required this.id,
    required this.state,
    required this.operationId,
    required this.vmId,
    required this.cancelRequested,
    required this.plannedOutcome,
  });
  final TestRunId id;
  final TestRunState state;
  final OperationId operationId;
  final VmId? vmId;
  final bool cancelRequested;
  final TestRunState? plannedOutcome;
}

final class TestRunConflictException implements Exception {
  const TestRunConflictException(this.id, this.message);
  final TestRunId id;
  final String message;
  @override
  String toString() => 'TestRun $id: $message';
}

final class TestRunNotFoundException implements Exception {
  const TestRunNotFoundException(this.id);
  final TestRunId id;
  @override
  String toString() => 'TestRun not found: $id';
}

/// Durable orchestration state, not a VM/guest executor. Application acceptance
/// owns source validation and idempotency; a worker owns provisioning, guest IO,
/// artifact publication and cleanup. Every mutation joins the catalog transaction.
/// Workers must validate VM/generation/operation correlation before supplying
/// guest results; phase/index guards are not transport authentication.
final class SqliteTestRunRepository implements TestRunRepository {
  SqliteTestRunRepository(
    this._database, {
    TestRunId Function()? newTestRunId,
    OperationId Function()? newOperationId,
    EventId Function()? newEventId,
    DateTime Function()? now,
  }) : _newTestRunId = newTestRunId ?? TestRunId.generate,
       _now = now ?? DateTime.now,
       _operations = SqliteOperationRepository(
         _database,
         newOperationId: newOperationId,
         newEventId: newEventId,
         now: now,
       ),
       _events = SqliteEventRepository(
         _database,
         newEventId: newEventId,
         now: now,
       );

  final GaoVmDatabase _database;
  final TestRunId Function() _newTestRunId;
  final DateTime Function() _now;
  final SqliteOperationRepository _operations;
  final SqliteEventRepository _events;

  @override
  Future<TestRun> create({
    required TestRunSpec spec,
    required RequestId requestId,
    String? idempotencyKey,
  }) => _database.transaction((connection) async {
    final id = _newTestRunId();
    final timeout = spec.timeoutSeconds;
    final operation = await _operations.create(
      type: 'test.run',
      resourceType: ResourceType.testRun,
      resourceId: id,
      requestId: requestId,
      idempotencyKey: idempotencyKey,
      cancellable: true,
      request: JsonObjectValue.fromJson(spec.toJson()),
      deadlineAt: timeout == null
          ? null
          : _now().toUtc().add(
              Duration(
                microseconds: (timeout * Duration.microsecondsPerSecond).ceil(),
              ),
            ),
    );
    connection.execute(
      '''
      INSERT INTO test_runs(
        id, state, spec_json, operation_id, artifact_ids_json, created_at
      ) VALUES (?, 'pending', ?, ?, '[]', ?)
      ''',
      [
        id.value,
        jsonEncode(spec.toJson()),
        operation.id.value,
        formatPersistenceTimestamp(operation.createdAt),
      ],
    );
    for (var index = 0; index < spec.steps.length; index++) {
      connection.execute(
        '''
        INSERT INTO test_steps(test_run_id, step_index, state, request_json)
        VALUES (?, ?, 'pending', ?)
        ''',
        [id.value, index, jsonEncode(spec.steps[index].toJson())],
      );
    }
    final created = _read(connection, id)!;
    await _append(created, 'test_run.created', operation.createdAt);
    return created;
  });

  @override
  Future<TestRun?> get(TestRunId id) =>
      _database.read((connection) => _read(connection, id));

  @override
  Future<List<TestRunWorkItem>> listUnfinished({
    TestRunId? afterId,
    int limit = 100,
  }) => _database.read((connection) {
    if (limit < 1 || limit > 200) {
      throw RangeError.range(limit, 1, 200, 'limit');
    }
    return List<TestRunWorkItem>.unmodifiable([
      for (final row in connection.select(
        '''SELECT id, state, operation_id, vm_id, cancel_requested, planned_outcome
               FROM test_runs WHERE state NOT IN ('succeeded', 'failed', 'cancelled')
               AND (? IS NULL OR id > ?) ORDER BY id LIMIT ?''',
        [afterId?.value, afterId?.value, limit],
      ))
        TestRunWorkItem(
          id: TestRunId(row['id'] as String),
          state: _parseState(row['state'] as String),
          operationId: OperationId(row['operation_id'] as String),
          vmId: row['vm_id'] == null ? null : VmId(row['vm_id'] as String),
          cancelRequested: row['cancel_requested'] == 1,
          plannedOutcome: row['planned_outcome'] == null
              ? null
              : _parseState(row['planned_outcome'] as String),
        ),
    ]);
  });

  @override
  Future<TestRun> requestCancel(TestRunId id) =>
      _database.transaction((connection) async {
        final run = _require(connection, id);
        if (_cancelRequested(connection, id)) return run;
        if (run.state == TestRunState.cleaningUp || _isTerminal(run.state)) {
          throw OperationNotCancellableException(run.operationId);
        }
        await _requireLiveOperation(run);
        if (!(await _operations.get(run.operationId))!.cancellable) {
          throw OperationNotCancellableException(run.operationId);
        }
        connection.execute(
          '''UPDATE test_runs SET cancel_requested = 1,
         planned_outcome = CASE WHEN planned_outcome = 'succeeded'
           THEN 'cancelled' ELSE planned_outcome END WHERE id = ?''',
          [id.value],
        );
        final updated = _require(connection, id);
        await _append(updated, 'test_run.cancel_requested', _now().toUtc());
        return updated;
      });

  bool _cancelRequested(Database connection, TestRunId id) =>
      connection.select('SELECT cancel_requested FROM test_runs WHERE id = ?', [
        id.value,
      ]).single['cancel_requested'] ==
      1;

  @override
  Future<TestRun> recordFailure(
    TestRunId id, {
    required OperationError error,
  }) => _database.transaction((connection) async {
    final run = _require(connection, id);
    if (run.state != TestRunState.collecting &&
        run.state != TestRunState.cleaningUp) {
      throw TestRunConflictException(
        id,
        'late failure requires collection or cleanup',
      );
    }
    await _requireLiveOperation(run);
    final planned = connection.select(
      'SELECT planned_outcome FROM test_runs WHERE id = ?',
      [id.value],
    ).single['planned_outcome'];
    if (run.error == error && planned == 'failed') return run;
    // Keep the first failure as primary; additional failures have their own
    // durable event instead of building an unbounded nested error chain.
    final primary = run.error ?? error;
    connection.execute(
      "UPDATE test_runs SET planned_outcome = 'failed', error_json = ? WHERE id = ?",
      [jsonEncode(primary.toJson()), id.value],
    );
    final updated = _require(connection, id);
    await _append(
      updated,
      'test_run.failure_recorded',
      _now().toUtc(),
      failure: error,
    );
    return updated;
  });

  @override
  Future<TestRun> startStep(TestRunId id, {required int index}) =>
      _database.transaction((connection) async {
        final run = _require(connection, id);
        await _requireExecuting(run);
        if (_cancelRequested(connection, id)) {
          throw TestRunConflictException(id, 'cancellation prevents new steps');
        }
        final step = _step(run, index);
        if (step.state != TestStepState.pending ||
            run.steps
                .take(index)
                .any((previous) => previous.state != TestStepState.succeeded)) {
          throw TestRunConflictException(
            id,
            'step cannot start before its predecessors succeed',
          );
        }
        final now = _now().toUtc();
        connection.execute(
          '''UPDATE test_steps SET state = 'running', started_at = ?
             WHERE test_run_id = ? AND step_index = ?''',
          [formatPersistenceTimestamp(now), id.value, index],
        );
        final updated = _require(connection, id);
        await _appendStep(updated, index, 'test_run.step_started', now);
        return updated;
      });

  @override
  Future<TestRun> finishStep(
    TestRunId id, {
    required int index,
    required TestStepState state,
    JsonObjectValue? result,
    OperationError? error,
  }) => _database.transaction((connection) async {
    final run = _require(connection, id);
    await _requireExecuting(run);
    if (_step(run, index).state != TestStepState.running ||
        !const {
          TestStepState.succeeded,
          TestStepState.failed,
          TestStepState.cancelled,
        }.contains(state)) {
      throw TestRunConflictException(
        id,
        'only a running step can complete once',
      );
    }
    if ((state == TestStepState.succeeded &&
            (result == null || error != null)) ||
        (state == TestStepState.failed && error == null)) {
      throw TestRunConflictException(
        id,
        'step outcome requires a matching structured result or error',
      );
    }
    final now = _now().toUtc();
    connection.execute(
      '''UPDATE test_steps SET state = ?, result_json = ?, error_json = ?, completed_at = ?
         WHERE test_run_id = ? AND step_index = ?''',
      [
        state.name,
        result == null ? null : jsonEncode(result.toJson()),
        error == null ? null : jsonEncode(error.toJson()),
        formatPersistenceTimestamp(now),
        id.value,
        index,
      ],
    );
    final updated = _require(connection, id);
    await _appendStep(updated, index, 'test_run.step_completed', now);
    return updated;
  });

  Future<void> _requireExecuting(TestRun run) async {
    if (run.state != TestRunState.runningSteps || run.vmId == null) {
      throw TestRunConflictException(
        run.id,
        'steps require a bound running_steps phase',
      );
    }
    await _requireLiveOperation(run);
  }

  TestStep _step(TestRun run, int index) {
    if (index < 0 || index >= run.steps.length) {
      throw RangeError.index(index, run.steps, 'index');
    }
    return run.steps[index];
  }

  @override
  Future<TestRun> finish(
    TestRunId id, {
    required TestRunState outcome,
    JsonObjectValue? result,
    OperationError? error,
  }) => _database.transaction((connection) async {
    final run = _require(connection, id);
    final planned = connection.select(
      'SELECT planned_outcome FROM test_runs WHERE id = ?',
      [id.value],
    ).single['planned_outcome'];
    if (run.state != TestRunState.cleaningUp ||
        run.cleanupDecision == null ||
        planned != _stateName(outcome)) {
      throw TestRunConflictException(
        id,
        'completion requires collecting and cleaning_up first',
      );
    }
    if (error != null && error != run.error) {
      throw TestRunConflictException(
        id,
        'failure must be recorded before completion',
      );
    }
    final failure = run.error;
    final summary = result ?? run.result;
    _validateOutcome(
      run,
      outcome,
      failure,
      cancelRequested: _cancelRequested(connection, id),
    );
    await _requireLiveOperation(run);
    final now = _now().toUtc();
    connection.execute(
      '''UPDATE test_runs SET state = ?, result_json = ?, error_json = ?, completed_at = ?
         WHERE id = ?''',
      [
        _stateName(outcome),
        summary == null ? null : jsonEncode(summary.toJson()),
        failure == null ? null : jsonEncode(failure.toJson()),
        formatPersistenceTimestamp(now),
        id.value,
      ],
    );
    switch (outcome) {
      case TestRunState.succeeded:
        await _operations.succeed(run.operationId, result: summary);
      case TestRunState.failed:
        await _operations.fail(run.operationId, error: failure!);
      case TestRunState.cancelled:
        await _operations.cancel(run.operationId);
      default:
        throw StateError('non-terminal TestRun outcome');
    }
    final completed = _require(connection, id);
    await _append(completed, 'test_run.completed', now);
    return completed;
  });

  @override
  Future<TestRun> transition(
    TestRunId id, {
    required TestRunState expectedState,
    required TestRunState nextState,
    VmId? vmId,
    String? cleanupDecision,
    TestRunState? outcome,
    JsonObjectValue? result,
    OperationError? error,
  }) => _database.transaction((connection) async {
    final current = _require(connection, id);
    if (current.state != expectedState ||
        !_canAdvance(current.state, nextState)) {
      throw TestRunConflictException(id, 'stale or invalid phase transition');
    }
    if (_cancelRequested(connection, id) &&
        nextState != TestRunState.collecting &&
        nextState != TestRunState.cleaningUp) {
      throw TestRunConflictException(
        id,
        'cancellation prevents new execution phases',
      );
    }
    if (nextState == TestRunState.cleaningUp
        ? cleanupDecision == null || cleanupDecision.trim().isEmpty
        : cleanupDecision != null) {
      throw TestRunConflictException(
        id,
        'cleanup decision must be recorded when cleaning_up starts',
      );
    }
    if (vmId != null &&
        (current.state != TestRunState.provisioning ||
            (nextState != TestRunState.startingVm &&
                nextState != TestRunState.collecting) ||
            current.vmId != null)) {
      throw TestRunConflictException(id, 'VM binding cannot be replaced');
    }
    if (nextState == TestRunState.startingVm && vmId == null) {
      throw TestRunConflictException(id, 'starting requires an explicit VM');
    }
    if (vmId != null &&
        connection.select(
          'SELECT id FROM vms WHERE id = ? AND deleted_at IS NULL',
          [vmId.value],
        ).isEmpty) {
      throw TestRunConflictException(
        id,
        'VM binding does not identify a live catalog resource',
      );
    }
    if (vmId != null &&
        connection.select(
          'SELECT id FROM test_runs WHERE vm_id = ? AND id <> ? LIMIT 1',
          [vmId.value, id.value],
        ).isNotEmpty) {
      throw TestRunConflictException(
        id,
        'VM is already owned by another TestRun',
      );
    }
    await _requireLiveOperation(current);
    if (nextState == TestRunState.collecting &&
        current.steps.any((step) => step.state == TestStepState.running)) {
      throw TestRunConflictException(
        id,
        'active step must complete or be cancelled before collection',
      );
    }
    if (nextState == TestRunState.collecting) {
      final planned =
          outcome ??
          (error != null ? TestRunState.failed : TestRunState.succeeded);
      _validateOutcome(
        current,
        planned,
        error,
        cancelRequested: _cancelRequested(connection, id),
      );
      connection.execute(
        'UPDATE test_runs SET planned_outcome = ?, result_json = ?, error_json = ? WHERE id = ?',
        [
          _stateName(planned),
          result == null ? null : jsonEncode(result.toJson()),
          error == null ? null : jsonEncode(error.toJson()),
          id.value,
        ],
      );
    } else if (outcome != null || result != null || error != null) {
      throw TestRunConflictException(
        id,
        'outcome must be recorded before collection',
      );
    }
    final now = _now().toUtc();
    connection.execute(
      '''UPDATE test_runs SET state = ?, vm_id = COALESCE(?, vm_id),
         cleanup_decision = COALESCE(?, cleanup_decision) WHERE id = ?''',
      [_stateName(nextState), vmId?.value, cleanupDecision, id.value],
    );
    if (current.state == TestRunState.pending) {
      await _operations.start(current.operationId);
    }
    if (nextState == TestRunState.collecting) {
      connection.execute(
        '''UPDATE test_steps SET state = 'skipped', completed_at = ?
           WHERE test_run_id = ? AND state = 'pending' ''',
        [formatPersistenceTimestamp(now), id.value],
      );
    }
    final updated = _require(connection, id);
    if (nextState == TestRunState.collecting) {
      for (final step in current.steps.where(
        (step) => step.state == TestStepState.pending,
      )) {
        await _appendStep(updated, step.index, 'test_run.step_skipped', now);
      }
    }
    await _append(updated, 'test_run.state_changed', now);
    return updated;
  });

  Future<void> _requireLiveOperation(TestRun run) async {
    final operation = await _operations.get(run.operationId);
    final expected = run.state == TestRunState.pending
        ? OperationState.pending
        : OperationState.running;
    if (operation == null ||
        operation.resourceType != ResourceType.testRun ||
        operation.resourceId != run.id ||
        operation.type != 'test.run' ||
        operation.state != expected) {
      throw TestRunConflictException(run.id, 'owning operation is not active');
    }
  }

  void _validateOutcome(
    TestRun run,
    TestRunState outcome,
    OperationError? error, {
    required bool cancelRequested,
  }) {
    if (!_isTerminal(outcome) ||
        (outcome == TestRunState.succeeded &&
            (error != null ||
                cancelRequested ||
                run.steps.any(
                  (step) => step.state != TestStepState.succeeded,
                ))) ||
        (outcome == TestRunState.failed && error == null) ||
        (outcome == TestRunState.cancelled &&
            (error != null ||
                run.steps.any((step) => step.state == TestStepState.failed) ||
                (!cancelRequested &&
                    !run.steps.any(
                      (step) => step.state == TestStepState.cancelled,
                    ))))) {
      throw TestRunConflictException(
        run.id,
        'outcome does not match durable steps or cancellation',
      );
    }
  }

  TestRun _require(Database connection, TestRunId id) =>
      _read(connection, id) ?? (throw TestRunNotFoundException(id));

  Future<void> _append(
    TestRun run,
    String type,
    DateTime occurredAt, {
    OperationError? failure,
  }) async {
    final metadata = await _database.read(
      (connection) => connection.select(
        'SELECT cancel_requested, planned_outcome FROM test_runs WHERE id = ?',
        [run.id.value],
      ).single,
    );
    await _events.append(
      type: type,
      resourceType: ResourceType.testRun,
      resourceId: run.id,
      vmId: run.vmId,
      operationId: run.operationId,
      testRunId: run.id,
      payload: JsonObjectValue.fromJson({
        'state': _stateName(run.state),
        'cancel_requested': metadata['cancel_requested'] == 1,
        'planned_outcome': metadata['planned_outcome'],
        'cleanup_decision': run.cleanupDecision,
        'result': run.result?.toJson(),
        'error': run.error?.toJson(),
        if (failure != null) 'failure': failure.toJson(),
      }),
      occurredAt: occurredAt,
    );
  }

  Future<void> _appendStep(
    TestRun run,
    int index,
    String type,
    DateTime occurredAt,
  ) async {
    await _events.append(
      type: type,
      resourceType: ResourceType.testRun,
      resourceId: run.id,
      vmId: run.vmId,
      operationId: run.operationId,
      testRunId: run.id,
      payload: JsonObjectValue.fromJson({'step': run.steps[index].toJson()}),
      occurredAt: occurredAt,
    );
  }

  TestRun? _read(Database connection, TestRunId id) {
    final rows = connection.select('SELECT * FROM test_runs WHERE id = ?', [
      id.value,
    ]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return TestRun.fromJson({
      'id': row['id'],
      'state': row['state'],
      'spec': jsonDecode(row['spec_json'] as String),
      'vm_id': row['vm_id'],
      'operation_id': row['operation_id'],
      'steps': [
        for (final step in connection.select(
          'SELECT * FROM test_steps WHERE test_run_id = ? ORDER BY step_index',
          [id.value],
        ))
          {
            'index': step['step_index'],
            'state': step['state'],
            'request': jsonDecode(step['request_json'] as String),
            'result': _decodeNullable(step['result_json']),
            'error': _decodeNullable(step['error_json']),
            'started_at': step['started_at'],
            'completed_at': step['completed_at'],
          },
      ],
      'cleanup_decision': row['cleanup_decision'],
      'result': _decodeNullable(row['result_json']),
      'error': _decodeNullable(row['error_json']),
      'artifact_ids': jsonDecode(row['artifact_ids_json'] as String),
      'created_at': row['created_at'],
      'completed_at': row['completed_at'],
    });
  }
}

Object? _decodeNullable(Object? value) =>
    value == null ? null : jsonDecode(value as String);

bool _canAdvance(TestRunState current, TestRunState target) =>
    switch ((current, target)) {
      (TestRunState.pending, TestRunState.provisioning) ||
      (TestRunState.provisioning, TestRunState.startingVm) ||
      (TestRunState.startingVm, TestRunState.waitingReady) ||
      (TestRunState.waitingReady, TestRunState.runningSteps) ||
      (
        TestRunState.pending ||
            TestRunState.provisioning ||
            TestRunState.startingVm ||
            TestRunState.waitingReady ||
            TestRunState.runningSteps,
        TestRunState.collecting,
      ) ||
      (TestRunState.collecting, TestRunState.cleaningUp) => true,
      _ => false,
    };

String _stateName(TestRunState state) => switch (state) {
  TestRunState.startingVm => 'starting_vm',
  TestRunState.waitingReady => 'waiting_ready',
  TestRunState.runningSteps => 'running_steps',
  TestRunState.cleaningUp => 'cleaning_up',
  _ => state.name,
};

TestRunState _parseState(String value) => TestRunState.values.firstWhere(
  (state) => _stateName(state) == value,
  orElse: () => throw FormatException('unsupported TestRun state: $value'),
);

bool _isTerminal(TestRunState state) => const {
  TestRunState.succeeded,
  TestRunState.failed,
  TestRunState.cancelled,
}.contains(state);
