import 'package:gaovm_models/gaovm_models.dart';

import 'guest_exec_application_service.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';
import 'vm_repository.dart';

/// Coordinates durable intent/results only. GuestExecWorker owns the original
/// IO and joins cleanup before it completes a child job. No driver passthrough.
final class TestRunStepWorker {
  TestRunStepWorker({
    required this.database,
    required this.guestExec,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final GaoVmDatabase database;
  final GuestExecApplicationService guestExec;
  final DateTime Function() _now;
  String _cursor = '';
  Future<int>? _dispatching;
  Future<void>? _recovery;
  Future<void>? _closing;
  bool _recovered = false;
  bool _hasRun = false;
  bool _closed = false;

  Future<int> dispatchOnce({int limit = 100}) {
    if (limit < 1 || limit > 200)
      throw RangeError.range(limit, 1, 200, 'limit');
    if (database.hasActiveCallerTransaction)
      throw StateError('step dispatch must own its commit');
    if (_closed) return Future.value(0);
    return _dispatching ??= _dispatch(limit).whenComplete(() {
      _dispatching = null;
    });
  }

  Future<int> _dispatch(int limit) async {
    if (_recovery != null && !_recovered)
      throw StateError('TestRun startup recovery has not succeeded');
    _hasRun = true;
    final ids = await database.read((db) {
      List<TestRunId> read(String cursor) => [
        for (final row in db.select(
          '''
      SELECT id FROM test_runs WHERE state = 'running_steps' AND id > ? ORDER BY id LIMIT ?
    ''',
          [cursor, limit],
        ))
          TestRunId(row['id'] as String),
      ];
      final ids = read(_cursor);
      return ids.isEmpty && _cursor.isNotEmpty ? read('') : ids;
    });
    if (ids.isEmpty) {
      _cursor = '';
      return 0;
    }
    _cursor = ids.last.value;
    final counts = await Future.wait(ids.map((id) => _advance(id)));
    return counts.fold<int>(0, (sum, count) => sum + count);
  }

  /// Startup-only. The supplied barrier must positively retire original owners
  /// and settle their guest jobs before this worker inspects step results.
  /// Recovery never activates a controller or authorizes a replacement exec.
  Future<void> recoverInterrupted({
    required Future<void> Function() retireOriginalOwners,
  }) {
    if (_closed || _hasRun || database.hasActiveCallerTransaction) {
      throw StateError('TestRun recovery must precede worker activation');
    }
    return _recovery ??= _recoverInterrupted(retireOriginalOwners).then((_) {
      _recovered = true;
    });
  }

  Future<void> _recoverInterrupted(
    Future<void> Function() retireOriginalOwners,
  ) async {
    await retireOriginalOwners();
    var cursor = '';
    while (!_closed) {
      final ids = await database.read(
        (db) => [
          for (final row in db.select(
            "SELECT id FROM test_runs WHERE state = 'running_steps' AND id > ? ORDER BY id LIMIT 100",
            [cursor],
          ))
            TestRunId(row['id'] as String),
        ],
      );
      if (ids.isEmpty) return;
      for (final id in ids) {
        if (_closed) return;
        cursor = id.value;
        await _advance(id, recovering: true);
      }
    }
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= Future.wait([
      if (_dispatching case final dispatch?) dispatch.then<void>((_) {}),
      if (_recovery case final recovery?) recovery,
    ]).then<void>((_) {});
  }

  Future<int> _advance(TestRunId id, {bool recovering = false}) async {
    final runs = SqliteTestRunRepository(database);
    while (!_closed) {
      final run = await runs.get(id);
      if (run == null || run.state != TestRunState.runningSteps) return 0;
      final step = run.steps
          .where((step) => step.state != TestStepState.succeeded)
          .firstOrNull;
      final cancelled = await database.read(
        (db) =>
            db.select('SELECT cancel_requested FROM test_runs WHERE id = ?', [
              id.value,
            ]).single['cancel_requested'] ==
            1,
      );
      if (cancelled && (step == null || step.state == TestStepState.pending)) {
        await runs.transition(
          id,
          expectedState: run.state,
          nextState: TestRunState.collecting,
          outcome: TestRunState.cancelled,
        );
        return 0;
      }
      final parent = (await SqliteOperationRepository(
        database,
      ).get(run.operationId))!;
      final expired =
          parent.deadlineAt != null &&
          !_now().toUtc().isBefore(parent.deadlineAt!);
      final timeout = OperationError(
        code: ErrorCode.waitTimeout,
        message: 'The TestRun execution deadline expired.',
        retryable: false,
        details: JsonObjectValue.fromJson({
          'phase': 'running_steps',
          'timeout_scope': 'overall',
        }),
      );
      if (expired && step?.state == TestStepState.pending) {
        await runs.transition(
          id,
          expectedState: run.state,
          nextState: TestRunState.collecting,
          outcome: TestRunState.failed,
          error: timeout,
        );
        return 0;
      }
      if (step == null) {
        await runs.transition(
          id,
          expectedState: run.state,
          nextState: TestRunState.collecting,
        );
        return 0;
      }
      if (step.state == TestStepState.pending) {
        if (recovering) {
          await runs.transition(
            id,
            expectedState: run.state,
            nextState: TestRunState.collecting,
            outcome: TestRunState.failed,
            error: OperationError(
              code: ErrorCode.guestExecFailed,
              message: 'Daemon stopped before this TestRun step was accepted.',
              retryable: false,
              details: JsonObjectValue.fromJson({
                'outcome': 'not_started',
                'step_index': step.index,
              }),
            ),
          );
          return 0;
        }
        if (_closed) return 0;
        try {
          await guestExec.executeStep(id, index: step.index);
        } catch (error) {
          final code = switch (error) {
            GuestExecAdmissionException(:final code) => code,
            TestRunConflictException() => ErrorCode.vmOperationConflict,
            VmNotFoundException() => ErrorCode.vmNotFound,
            FormatException() => ErrorCode.invalidRequest,
            _ => null,
          };
          if (code == null) rethrow;
          // Cancellation can win while the short controller gate is queued.
          final current = await runs.get(id);
          if (current?.state != TestRunState.runningSteps) return 0;
          final cancelled = await database.read(
            (db) =>
                db.select(
                  'SELECT cancel_requested FROM test_runs WHERE id = ?',
                  [id.value],
                ).single['cancel_requested'] ==
                1,
          );
          await runs.transition(
            id,
            expectedState: run.state,
            nextState: TestRunState.collecting,
            outcome: cancelled ? TestRunState.cancelled : TestRunState.failed,
            error: cancelled
                ? null
                : OperationError(
                    code: code,
                    message:
                        'The original TestRun execution checkpoint is unavailable.',
                    retryable: false,
                    details: JsonObjectValue.fromJson({
                      'outcome': 'not_started',
                      'step_index': step.index,
                    }),
                  ),
          );
          return 0;
        }
        return 1;
      }
      if (step.state == TestStepState.failed ||
          step.state == TestStepState.cancelled) {
        await runs.transition(
          id,
          expectedState: run.state,
          nextState: TestRunState.collecting,
          outcome: step.state == TestStepState.failed
              ? TestRunState.failed
              : TestRunState.cancelled,
          error: step.error,
        );
        return 0;
      }
      if (step.state != TestStepState.running)
        throw StateError('running TestRun has an unexpected skipped step');
      if (expired)
        await database.transaction(
          (db) => db.execute(
            '''
        UPDATE guest_exec_jobs SET cancellation_requested = 1 WHERE completed_at IS NULL
          AND operation_id IN (SELECT operation_id FROM test_run_step_execs WHERE test_run_id = ? AND step_index = ?)
      ''',
            [id.value, step.index],
          ),
        );
      final bindings = await database.read(
        (db) => db.select(
          '''
        SELECT e.operation_id, j.completed_at FROM test_run_step_execs e
        JOIN guest_exec_jobs j ON j.operation_id = e.operation_id
        WHERE e.test_run_id = ? AND e.step_index = ? AND j.vm_id = ?
      ''',
          [id.value, step.index, run.vmId!.value],
        ),
      );
      // Missing ownership is not evidence that a previous execution retired.
      if (bindings.isEmpty) {
        if (!recovering) return 0;
        final error = OperationError(
          code: ErrorCode.guestExecFailed,
          message:
              'Interrupted TestRun step has no durable original execution binding; outcome is unknown.',
          retryable: false,
          details: JsonObjectValue.fromJson({
            'outcome': 'unknown',
            'step_index': step.index,
          }),
        );
        await database.transaction((_) async {
          await runs.finishStep(
            id,
            index: step.index,
            state: TestStepState.failed,
            error: error,
          );
          await runs.transition(
            id,
            expectedState: run.state,
            nextState: TestRunState.collecting,
            outcome: TestRunState.failed,
            error: error,
          );
        });
        return 0;
      }
      if (bindings.single['completed_at'] == null) {
        if (recovering)
          throw StateError(
            'original guest jobs must be settled before TestRun recovery',
          );
        return 0;
      }
      final child = (await SqliteOperationRepository(
        database,
      ).get(OperationId(bindings.single['operation_id'] as String)))!;
      final timedOut =
          expired &&
          (child.completedAt == null ||
              !child.completedAt!.isBefore(parent.deadlineAt!));
      if (child.state == OperationState.failed ||
          child.state == OperationState.cancelled ||
          timedOut) {
        final failed = child.state == OperationState.failed || timedOut;
        final error = timedOut ? timeout : child.error;
        await database.transaction((_) async {
          await runs.finishStep(
            id,
            index: step.index,
            state: failed ? TestStepState.failed : TestStepState.cancelled,
            result: child.result,
            error: error,
          );
          await runs.transition(
            id,
            expectedState: run.state,
            nextState: TestRunState.collecting,
            outcome: failed ? TestRunState.failed : TestRunState.cancelled,
            error: error,
          );
        });
        return 0;
      }
      if (child.state != OperationState.succeeded)
        throw StateError('completed child lacks a terminal result');
      await runs.finishStep(
        id,
        index: step.index,
        state: TestStepState.succeeded,
        result: child.result,
      );
    }
    return 0;
  }
}
