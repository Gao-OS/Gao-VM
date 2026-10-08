import 'package:gaovm_models/gaovm_models.dart';

import 'event_repository.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';
import 'vm_provisioning_repository.dart';
import 'vm_repository.dart';

final class TestRunReadinessOutcome {
  const TestRunReadinessOutcome({
    required this.testRunId,
    required this.operationId,
    required this.vmId,
    required this.requestId,
    required this.driverGeneration,
    required this.ready,
    this.error,
  });
  final TestRunId testRunId;
  final OperationId operationId;
  final VmId? vmId;
  final RequestId requestId;
  final int? driverGeneration;
  final bool ready;
  final Object? error;
}

/// Observes committed state only. Readiness never starts a guest command or
/// changes a VM's desired/runtime state. Infrastructure errors retry per run.
final class TestRunReadinessWorker {
  TestRunReadinessWorker({required this.database, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final GaoVmDatabase database;
  final DateTime Function() _now;
  TestRunId? _cursor;

  Future<List<TestRunReadinessOutcome>> dispatchOnce({int limit = 100}) async {
    if (limit < 1 || limit > 200)
      throw RangeError.range(limit, 1, 200, 'limit');
    if (database.hasActiveCallerTransaction)
      throw StateError('TestRun readiness must own its commit boundary');
    final items = await database.read((db) {
      const query = '''
        SELECT t.id, t.operation_id, t.vm_id, o.request_id, s.driver_generation
        FROM test_runs t JOIN operations o ON o.id = t.operation_id
        LEFT JOIN test_run_vm_start s ON s.test_run_id = t.id
        WHERE t.state = 'waiting_ready' AND t.id > ? ORDER BY t.id LIMIT ?
      ''';
      var rows = db.select(query, [_cursor?.value ?? '', limit]);
      if (rows.isEmpty && _cursor != null) rows = db.select(query, ['', limit]);
      return [
        for (final row in rows)
          (
            id: TestRunId(row['id'] as String),
            operation: OperationId(row['operation_id'] as String),
            vm: row['vm_id'] == null ? null : VmId(row['vm_id'] as String),
            request: RequestId(row['request_id'] as String),
            generation: row['driver_generation'] as int?,
          ),
      ];
    });
    _cursor = items.lastOrNull?.id;
    final outcomes = <TestRunReadinessOutcome>[];
    for (final item in items) {
      var ready = false;
      Object? failure;
      try {
        ready = await _advance(item.id);
      } catch (error) {
        failure = error;
      }
      outcomes.add(
        TestRunReadinessOutcome(
          testRunId: item.id,
          operationId: item.operation,
          vmId: item.vm,
          requestId: item.request,
          driverGeneration: item.generation,
          ready: ready,
          error: failure,
        ),
      );
    }
    return List.unmodifiable(outcomes);
  }

  Future<bool> _advance(TestRunId id) => database.transaction((db) async {
    final runs = SqliteTestRunRepository(database, now: _now);
    final run = await runs.get(id);
    if (run == null || run.state != TestRunState.waitingReady) return false;
    final operations = SqliteOperationRepository(database);
    final parent = await operations.get(run.operationId);
    if (parent == null ||
        parent.type != 'test.run' ||
        parent.resourceType != ResourceType.testRun ||
        parent.resourceId != id ||
        parent.state != OperationState.running)
      throw StateError('TestRun readiness operation is not active');
    final bindings = db.select(
      '''
      SELECT s.*, p.vm_id AS provisioned_vm_id, p.operation_id AS provisioning_operation_id
      FROM test_run_vm_start s JOIN test_run_vm_provisioning p ON p.test_run_id = s.test_run_id
      WHERE s.test_run_id = ?
    ''',
      [id.value],
    );
    if (run.vmId == null || bindings.length != 1)
      throw StateError('TestRun readiness has no owned start checkpoint');
    final binding = bindings.single;
    final start = await operations.get(
      OperationId(binding['operation_id'] as String),
    );
    final create = await operations.get(
      OperationId(binding['provisioning_operation_id'] as String),
    );
    if (binding['vm_id'] != run.vmId!.value ||
        binding['provisioned_vm_id'] != run.vmId!.value ||
        binding['driver_generation'] == null ||
        binding['abort_operation_id'] != null ||
        start == null ||
        start.type != 'vm.start' ||
        start.resourceType != ResourceType.virtualMachine ||
        start.resourceId != run.vmId ||
        start.state != OperationState.succeeded ||
        start.request.toJson()['intent_revision'] !=
            binding['intent_revision'] ||
        create == null ||
        create.type != 'vm.create' ||
        create.resourceType != ResourceType.virtualMachine ||
        create.resourceId != run.vmId ||
        create.state != OperationState.succeeded)
      throw StateError('TestRun readiness ownership differs');
    if (db.select('SELECT cancel_requested FROM test_runs WHERE id = ?', [
          id.value,
        ]).single['cancel_requested'] ==
        1) {
      await runs.transition(
        id,
        expectedState: run.state,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      return false;
    }
    final window = await runs.readinessWindow(id);
    if (!_now().toUtc().isBefore(window.deadlineAt)) {
      await _fail(
        runs,
        run,
        ErrorCode.waitTimeout,
        'The TestRun readiness deadline expired.',
        generation: binding['driver_generation'] as int,
        deadlineAt: window.deadlineAt,
        timeoutScope: parent.deadlineAt == window.deadlineAt
            ? 'overall'
            : 'readiness',
      );
      return false;
    }
    final vm = await SqliteVmRepository(database).get(run.vmId!);
    final current = db.select(
      '''
      SELECT v.intent_revision, v.deleting_at, r.applied_intent_revision
      FROM vms v JOIN vm_runtime r ON r.vm_id = v.id WHERE v.id = ?
    ''',
      [run.vmId!.value],
    );
    final plan = await SqliteVmProvisioningRepository(database).get(run.vmId!);
    if (plan == null)
      throw StateError('TestRun readiness provisioning plan is missing');
    if (vm == null) {
      await _fail(
        runs,
        run,
        ErrorCode.vmNotFound,
        'The TestRun VM is no longer available.',
        generation: binding['driver_generation'] as int,
      );
      return false;
    }
    final revision = binding['intent_revision'] as int;
    if (current.single['deleting_at'] != null ||
        current.single['intent_revision'] != revision ||
        current.single['applied_intent_revision'] != revision ||
        vm.status.driverGeneration != binding['driver_generation'] ||
        vm.status.specGeneration != plan.plan.specGeneration ||
        vm.status.observedGeneration != plan.plan.specGeneration ||
        start.request.toJson()['spec_generation'] != plan.plan.specGeneration) {
      await _fail(
        runs,
        run,
        ErrorCode.vmOperationConflict,
        'The TestRun VM has a different generation, spec, or lifecycle intent.',
        generation: binding['driver_generation'] as int,
        observedGeneration: vm.status.driverGeneration,
      );
      return false;
    }
    if (vm.status.phase != VmPhase.running ||
        vm.status.desiredState != DesiredState.running) {
      await _fail(
        runs,
        run,
        ErrorCode.vmNotRunning,
        'The TestRun VM stopped before readiness.',
        generation: binding['driver_generation'] as int,
      );
      return false;
    }
    final ready = switch (run.spec.wait.condition) {
      WaitCondition.runtimeRunning => true,
      WaitCondition.guestAgentReady =>
        vm.status.guestAgent == GuestAgentState.ready,
      // Service readiness needs the host Guest Session's persisted service proof.
      WaitCondition.guestServiceReady => false,
    };
    if (!ready) return false;
    await runs.transition(
      id,
      expectedState: run.state,
      nextState: TestRunState.runningSteps,
    );
    await SqliteEventRepository(database, now: _now).append(
      type: 'test_run.readiness_reached',
      resourceType: ResourceType.testRun,
      resourceId: id,
      vmId: run.vmId,
      operationId: run.operationId,
      testRunId: id,
      payload: JsonObjectValue.fromJson({
        ...run.spec.wait.toJson(),
        'driver_generation': vm.status.driverGeneration,
        'intent_revision': revision,
      }),
    );
    return true;
  });

  Future<TestRun> _fail(
    SqliteTestRunRepository runs,
    TestRun run,
    ErrorCode code,
    String message, {
    required int generation,
    int? observedGeneration,
    DateTime? deadlineAt,
    String? timeoutScope,
  }) => runs.transition(
    run.id,
    expectedState: run.state,
    nextState: TestRunState.collecting,
    outcome: TestRunState.failed,
    error: OperationError(
      code: code,
      message: message,
      retryable: false,
      details: JsonObjectValue.fromJson({
        'phase': 'waiting_ready',
        'vm_id': run.vmId!.value,
        'driver_generation': generation,
        if (observedGeneration != null)
          'observed_driver_generation': observedGeneration,
        if (deadlineAt != null)
          'deadline_at': formatPersistenceTimestamp(deadlineAt),
        if (timeoutScope != null) 'timeout_scope': timeoutScope,
        ...run.spec.wait.toJson(),
      }),
    ),
  );
}
