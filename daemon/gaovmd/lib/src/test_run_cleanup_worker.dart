import 'package:gaovm_models/gaovm_models.dart';

import 'sqlite_database.dart';
import 'test_run_repository.dart';

final class TestRunCleanupOutcome {
  const TestRunCleanupOutcome({
    required this.testRunId,
    required this.operationId,
    required this.requestId,
    required this.completed,
    this.vmId,
    this.driverGeneration,
    this.error,
  });
  final TestRunId testRunId;
  final OperationId operationId;
  final RequestId requestId;
  final VmId? vmId;
  final int? driverGeneration;
  final bool completed;
  final Object? error;
}

/// Completes collected runs which never allocated a VM. Bound VM cleanup must
/// still use recoverable lifecycle intents; it is not inferred from a null
/// public VM binding while provisioning work owns a VM.
final class TestRunCleanupWorker {
  TestRunCleanupWorker({required this.database, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final GaoVmDatabase database;
  final DateTime Function() _now;
  TestRunId? _cursor;

  Future<List<TestRunCleanupOutcome>> dispatchOnce({int limit = 100}) async {
    if (limit < 1 || limit > 200)
      throw RangeError.range(limit, 1, 200, 'limit');
    if (database.hasActiveCallerTransaction)
      throw StateError('TestRun cleanup must own its commit boundary');
    final items = await database.read((db) {
      const query = '''
        SELECT t.id, t.operation_id, o.request_id
        FROM test_runs t JOIN operations o ON o.id = t.operation_id
        JOIN test_run_collection c ON c.test_run_id = t.id
        LEFT JOIN test_run_vm_provisioning p ON p.test_run_id = t.id
        LEFT JOIN test_run_vm_start s ON s.test_run_id = t.id
        WHERE t.state IN ('collecting', 'cleaning_up')
          AND c.completed_at IS NOT NULL
          AND t.vm_id IS NULL AND p.vm_id IS NULL AND s.vm_id IS NULL
          AND t.id > ? ORDER BY t.id LIMIT ?
      ''';
      var rows = db.select(query, [_cursor?.value ?? '', limit]);
      if (rows.isEmpty && _cursor != null) rows = db.select(query, ['', limit]);
      return [
        for (final row in rows)
          (
            id: TestRunId(row['id'] as String),
            operation: OperationId(row['operation_id'] as String),
            request: RequestId(row['request_id'] as String),
          ),
      ];
    });
    _cursor = items.lastOrNull?.id;
    final outcomes = <TestRunCleanupOutcome>[];
    for (final item in items) {
      Object? failure;
      var completed = false;
      try {
        completed = await _finishWithoutVm(item.id);
      } catch (error) {
        failure = error;
      }
      outcomes.add(
        TestRunCleanupOutcome(
          testRunId: item.id,
          operationId: item.operation,
          requestId: item.request,
          completed: completed,
          error: failure,
        ),
      );
    }
    return List.unmodifiable(outcomes);
  }

  Future<bool> _finishWithoutVm(TestRunId id) => database.transaction((
    db,
  ) async {
    final runs = SqliteTestRunRepository(database, now: _now);
    var run = await runs.get(id);
    if (run == null ||
        !const {
          TestRunState.collecting,
          TestRunState.cleaningUp,
        }.contains(run.state))
      return false;
    final ready = db.select(
      '''
      SELECT t.planned_outcome FROM test_runs t
      JOIN test_run_collection c ON c.test_run_id = t.id
      LEFT JOIN test_run_vm_provisioning p ON p.test_run_id = t.id
      LEFT JOIN test_run_vm_start s ON s.test_run_id = t.id
      WHERE t.id = ? AND c.completed_at IS NOT NULL
        AND t.vm_id IS NULL AND p.vm_id IS NULL AND s.vm_id IS NULL
    ''',
      [id.value],
    );
    if (ready.isEmpty) return false;
    final outcome = switch (ready.single['planned_outcome']) {
      'cancelled' => TestRunState.cancelled,
      'failed' => TestRunState.failed,
      _ => throw StateError('An unprovisioned TestRun has no abort outcome'),
    };
    if (run.state == TestRunState.collecting) {
      run = await runs.transition(
        id,
        expectedState: run.state,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: 'not_required',
      );
    }
    if (run.cleanupDecision != 'not_required')
      throw StateError('Unprovisioned TestRun cleanup decision differs');
    // The run, owning operation, cancellation actions, events and outbox rows
    // commit together. A failure leaves collection complete and retryable.
    await runs.finish(id, outcome: outcome);
    return true;
  });
}
