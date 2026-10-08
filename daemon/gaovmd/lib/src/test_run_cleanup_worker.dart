import 'package:gaovm_models/gaovm_models.dart';

import 'event_repository.dart';
import 'host_lease_repository.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';
import 'vm_application_service.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'vm_lifecycle_intent.dart';
import 'vm_provisioning_repository.dart';
import 'vm_registry.dart';
import 'vm_repository.dart';

/// Infrastructure failures are retryable pass errors. Durable cleanup failures
/// are journaled on the TestRun and retain its original primary failure.
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

enum _CleanupProgress { deferred, needsRuntime, completed }

/// Completes collected TestRuns using recoverable VM lifecycle intents.
/// Failed retention leaves runtime state unchanged for manual debugging.
/// Catalog-only paths do not need [registry]; runtime cleanup requires it.
final class TestRunCleanupWorker {
  TestRunCleanupWorker({
    required this.database,
    this.registry,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final GaoVmDatabase database;
  final VmRegistry? registry;
  final DateTime Function() _now;
  TestRunId? _cursor;

  Future<List<TestRunCleanupOutcome>> dispatchOnce({int limit = 100}) async {
    if (limit < 1 || limit > 200)
      throw RangeError.range(limit, 1, 200, 'limit');
    if (database.hasActiveCallerTransaction)
      throw StateError('TestRun cleanup must own its commit boundary');
    final items = await database.read((db) {
      const query = r'''
        SELECT t.id, t.operation_id, COALESCE(t.vm_id, p.vm_id, s.vm_id) AS vm_id,
          o.request_id, r.driver_generation
        FROM test_runs t JOIN operations o ON o.id = t.operation_id
        JOIN test_run_collection c ON c.test_run_id = t.id
        LEFT JOIN test_run_vm_provisioning p ON p.test_run_id = t.id
        LEFT JOIN test_run_vm_start s ON s.test_run_id = t.id
        LEFT JOIN vm_runtime r ON r.vm_id = COALESCE(t.vm_id, p.vm_id, s.vm_id)
        WHERE t.state IN ('collecting', 'cleaning_up')
          AND c.completed_at IS NOT NULL
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
            vm: row['vm_id'] == null ? null : VmId(row['vm_id'] as String),
            generation: row['driver_generation'] as int? ?? 0,
          ),
      ];
    });
    _cursor = items.lastOrNull?.id;
    final outcomes = <TestRunCleanupOutcome>[];
    for (final item in items) {
      Object? failure;
      var completed = false;
      try {
        var progress = (await _advance(item.id)).result;
        if (progress == _CleanupProgress.needsRuntime) {
          final runtime = registry;
          if (runtime == null)
            throw StateError('Allocated VM cleanup requires its registry');
          final controller = await runtime.get(item.vm!);
          if (controller == null) {
            progress = (await _advance(item.id)).result;
            if (progress == _CleanupProgress.needsRuntime)
              throw VmNotFoundException(item.vm!);
          } else {
            try {
              progress = await controller.accept(
                _CleanupAcceptance(this, item.id),
              );
            } on VmNotFoundException {
              progress = (await _advance(item.id)).result;
            }
          }
        }
        completed = progress == _CleanupProgress.completed;
      } catch (error) {
        failure = error;
      }
      outcomes.add(
        TestRunCleanupOutcome(
          testRunId: item.id,
          operationId: item.operation,
          requestId: item.request,
          vmId: item.vm,
          driverGeneration: item.generation > 0 ? item.generation : null,
          completed: completed,
          error: failure,
        ),
      );
    }
    return List.unmodifiable(outcomes);
  }

  Future<VmAcceptedIntent<_CleanupProgress>> _advance(
    TestRunId id, {
    VmControllerState? execution,
  }) => database.transaction((db) async {
    VmAcceptedIntent<_CleanupProgress> result(
      _CleanupProgress progress, [
      int? revision,
    ]) => VmAcceptedIntent(
      intentRevision: revision ?? execution?.appliedIntentRevision ?? 0,
      result: progress,
    );
    final runs = SqliteTestRunRepository(database, now: _now);
    var run = await runs.get(id);
    if (run == null ||
        !const {
          TestRunState.collecting,
          TestRunState.cleaningUp,
        }.contains(run.state))
      return result(_CleanupProgress.deferred);
    final ready = db.select(
      '''
      SELECT t.planned_outcome, p.vm_id AS provisioned_vm_id,
        p.operation_id AS provisioning_operation_id, s.vm_id AS started_vm_id
      FROM test_runs t
      JOIN test_run_collection c ON c.test_run_id = t.id
      LEFT JOIN test_run_vm_provisioning p ON p.test_run_id = t.id
      LEFT JOIN test_run_vm_start s ON s.test_run_id = t.id
      WHERE t.id = ? AND c.completed_at IS NOT NULL
    ''',
      [id.value],
    );
    if (ready.isEmpty) return result(_CleanupProgress.deferred);
    final outcome = switch (ready.single['planned_outcome']) {
      'succeeded' => TestRunState.succeeded,
      'cancelled' => TestRunState.cancelled,
      'failed' => TestRunState.failed,
      _ => throw StateError('TestRun cleanup has no planned outcome'),
    };
    final row = ready.single;
    final vmId = run.vmId;
    final String decision;
    OperationError? cleanupFailure;
    if (vmId == null) {
      if (row['provisioned_vm_id'] != null || row['started_vm_id'] != null)
        return result(_CleanupProgress.deferred);
      if (outcome == TestRunState.succeeded)
        throw StateError('An unprovisioned TestRun cannot succeed');
      decision = 'not_required';
    } else {
      if (row['provisioned_vm_id'] != vmId.value ||
          (row['started_vm_id'] != null && row['started_vm_id'] != vmId.value))
        throw StateError('TestRun VM cleanup ownership differs');
      final child = await SqliteOperationRepository(
        database,
      ).get(OperationId(row['provisioning_operation_id'] as String));
      if (child == null ||
          child.type != 'vm.create' ||
          child.resourceType != ResourceType.virtualMachine ||
          child.resourceId != vmId ||
          !const {
            OperationState.succeeded,
            OperationState.failed,
            OperationState.cancelled,
          }.contains(child.state))
        throw StateError('TestRun VM provisioning is not settled');
      final checkpoints = db.select(
        'SELECT * FROM test_run_vm_cleanup WHERE test_run_id = ?',
        [id.value],
      );
      if (checkpoints.isNotEmpty) {
        final checkpoint = checkpoints.single;
        final revision = checkpoint['intent_revision'] as int;
        final action = checkpoint['action'] as String;
        final expectedDecision = action == 'delete' ? 'delete' : 'retain';
        final cleanup = await SqliteOperationRepository(
          database,
        ).get(OperationId(checkpoint['operation_id'] as String));
        if (run.state != TestRunState.cleaningUp ||
            run.cleanupDecision != expectedDecision ||
            checkpoint['vm_id'] != vmId.value ||
            cleanup == null ||
            cleanup.type != 'vm.$action' ||
            cleanup.resourceType != ResourceType.virtualMachine ||
            cleanup.resourceId != vmId ||
            cleanup.request.toJson()['intent_revision'] != revision ||
            cleanup.request.toJson()['spec_generation'] !=
                checkpoint['spec_generation'])
          throw StateError('TestRun cleanup checkpoint is mismatched');
        if (cleanup.state == OperationState.pending ||
            cleanup.state == OperationState.running)
          return result(_CleanupProgress.deferred, revision);
        final vm = await SqliteVmRepository(
          database,
        ).get(vmId, includeDeleted: true);
        final current = db.select(
          '''
          SELECT v.intent_revision, v.deleting_at, v.deleted_at, r.applied_intent_revision
          FROM vms v JOIN vm_runtime r ON r.vm_id = v.id WHERE v.id = ?
        ''',
          [vmId.value],
        );
        final leases = (await SqliteHostLeaseRepository(
          database,
        ).list()).where((lease) => lease.request.vmId == vmId);
        final applied =
            current.isNotEmpty &&
            current.single['intent_revision'] == revision &&
            current.single['applied_intent_revision'] == revision &&
            vm != null &&
            vm.status.specGeneration == checkpoint['spec_generation'] &&
            vm.status.driverGeneration == checkpoint['driver_generation'] &&
            vm.status.desiredState == DesiredState.stopped &&
            leases.isEmpty;
        final drained =
            applied &&
            (action == 'delete'
                ? vm.status.phase == VmPhase.deleted &&
                      current.single['deleted_at'] != null
                : vm.status.phase == VmPhase.stopped &&
                      current.single['deleting_at'] == null &&
                      current.single['deleted_at'] == null);
        if (cleanup.state != OperationState.succeeded || !drained) {
          await runs.recordFailure(
            id,
            error:
                cleanup.error ??
                _failure(
                  vmId,
                  cleanup.state == OperationState.succeeded
                      ? ErrorCode.vmOperationConflict
                      : ErrorCode.driverUnhealthy,
                  'The TestRun VM did not complete its selected cleanup.',
                  decision: expectedDecision,
                  operation: cleanup.id,
                  generation: checkpoint['driver_generation'] as int,
                ),
          );
          await runs.finish(id, outcome: TestRunState.failed);
        } else {
          await runs.finish(id, outcome: outcome);
        }
        return result(_CleanupProgress.completed, revision);
      }
      final parent = await SqliteOperationRepository(
        database,
      ).get(run.operationId);
      if (parent == null ||
          parent.type != 'test.run' ||
          parent.resourceType != ResourceType.testRun ||
          parent.resourceId != id ||
          parent.state != OperationState.running)
        throw StateError('TestRun cleanup operation is not active');
      // Failure retention is explicit in UC-03. The always-delete override
      // conflict still needs an accepted policy decision and is left pending.
      if (outcome == TestRunState.failed &&
          run.spec.cleanup == CleanupPolicy.alwaysDelete &&
          run.spec.retainOnFailure)
        return result(_CleanupProgress.deferred);
      final keepFailed =
          outcome == TestRunState.failed &&
          run.spec.cleanup != CleanupPolicy.alwaysDelete;
      decision =
          keepFailed ||
              run.spec.cleanup == CleanupPolicy.retain ||
              (outcome == TestRunState.cancelled &&
                  run.spec.cleanup == CleanupPolicy.deleteOnSuccess)
          ? 'retain'
          : 'delete';
      final vm = await SqliteVmRepository(
        database,
      ).get(vmId, includeDeleted: true);
      final deletion = db.select(
        '''SELECT v.deleting_at, v.deleted_at, v.intent_revision,
          r.applied_intent_revision FROM vms v JOIN vm_runtime r ON r.vm_id = v.id
          WHERE v.id = ?''',
        [vmId.value],
      );
      final unavailable = vm == null || vm.status.phase == VmPhase.deleted;
      if (unavailable ||
          vm.status.phase == VmPhase.deleting ||
          deletion.single['deleting_at'] != null ||
          deletion.single['deleted_at'] != null)
        cleanupFailure = OperationError(
          code: unavailable
              ? ErrorCode.vmNotFound
              : ErrorCode.vmOperationConflict,
          message: unavailable
              ? 'The TestRun VM is no longer available for retention.'
              : 'Deletion of the TestRun VM was accepted before retention.',
          retryable: false,
          details: JsonObjectValue.fromJson({
            'phase': 'cleaning_up',
            'cleanup_decision': decision,
            'vm_id': vmId.value,
            if (vm != null && vm.status.driverGeneration > 0)
              'driver_generation': vm.status.driverGeneration,
          }),
        );
      if (!keepFailed && cleanupFailure == null) {
        final start = db.select(
          'SELECT * FROM test_run_vm_start WHERE test_run_id = ?',
          [id.value],
        );
        final expectedRevision = start.isEmpty
            ? 0
            : (start.single['abort_intent_revision'] ??
                      start.single['intent_revision'])
                  as int;
        final expectedGeneration = start.isEmpty
            ? 0
            : start.single['driver_generation'] as int?;
        final plan = await SqliteVmProvisioningRepository(database).get(vmId);
        if (plan == null)
          throw StateError('TestRun provisioning plan is missing');
        if (deletion.single['intent_revision'] != expectedRevision ||
            deletion.single['applied_intent_revision'] != expectedRevision ||
            vm!.status.specGeneration != plan.plan.specGeneration ||
            (expectedGeneration != null &&
                vm.status.driverGeneration != expectedGeneration)) {
          cleanupFailure = _failure(
            vmId,
            ErrorCode.vmOperationConflict,
            'The TestRun VM has a newer runtime, spec, or lifecycle intent.',
            decision: decision,
            generation: vm!.status.driverGeneration,
          );
        } else {
          if (execution == null) return result(_CleanupProgress.needsRuntime);
          if (execution.vmId != vmId)
            throw StateError('TestRun cleanup target differs');
          if (run.state == TestRunState.collecting)
            run = await runs.transition(
              id,
              expectedState: run.state,
              nextState: TestRunState.cleaningUp,
              cleanupDecision: decision,
            );
          if (run.cleanupDecision != decision)
            throw StateError('TestRun cleanup decision differs');
          final action = decision == 'delete'
              ? VmLifecycleAction.delete
              : VmLifecycleAction.stop;
          final accepted = await commitVmLifecycleIntent(
            database: database,
            executionState: execution,
            now: _now,
            command: VmLifecycleCommand(
              vmId: vmId,
              action: action,
              requestId: parent.requestId,
              idempotencyKey: null,
              requestBody: const [],
              reason: 'TestRun cleanup',
            ),
          );
          db.execute(
            '''INSERT INTO test_run_vm_cleanup(test_run_id, vm_id, operation_id,
            action, intent_revision, spec_generation, driver_generation)
            VALUES (?, ?, ?, ?, ?, ?, ?)''',
            [
              id.value,
              vmId.value,
              accepted.result.operationId.value,
              action.name,
              accepted.intentRevision,
              vm.status.specGeneration,
              vm.status.driverGeneration,
            ],
          );
          await SqliteEventRepository(database, now: _now).append(
            type: 'test_run.vm_cleanup_accepted',
            resourceType: ResourceType.testRun,
            resourceId: id,
            vmId: vmId,
            operationId: run.operationId,
            testRunId: id,
            payload: JsonObjectValue.fromJson({
              'cleanup_operation_id': accepted.result.operationId.value,
              'action': action.name,
              'intent_revision': accepted.intentRevision,
              'spec_generation': vm.status.specGeneration,
              'driver_generation': vm.status.driverGeneration,
            }),
          );
          return result(_CleanupProgress.deferred, accepted.intentRevision);
        }
      }
    }
    if (run.state == TestRunState.collecting) {
      run = await runs.transition(
        id,
        expectedState: run.state,
        nextState: TestRunState.cleaningUp,
        cleanupDecision: decision,
      );
    }
    if (run.cleanupDecision != decision)
      throw StateError('TestRun cleanup decision differs');
    if (cleanupFailure != null)
      await runs.recordFailure(id, error: cleanupFailure);
    // The run, owning operation, cancellation actions, events and outbox rows
    // commit together. A failure leaves collection complete and retryable.
    await runs.finish(
      id,
      outcome: cleanupFailure == null ? outcome : TestRunState.failed,
    );
    return result(_CleanupProgress.completed);
  });

  OperationError _failure(
    VmId vmId,
    ErrorCode code,
    String message, {
    required String decision,
    OperationId? operation,
    int? generation,
  }) => OperationError(
    code: code,
    message: message,
    retryable: false,
    details: JsonObjectValue.fromJson({
      'phase': 'cleaning_up',
      'vm_id': vmId.value,
      'cleanup_decision': decision,
      if (operation != null) 'cleanup_operation_id': operation.value,
      if (generation != null && generation > 0) 'driver_generation': generation,
    }),
  );
}

final class _CleanupAcceptance implements VmAcceptanceAction<_CleanupProgress> {
  const _CleanupAcceptance(this.worker, this.id);
  final TestRunCleanupWorker worker;
  final TestRunId id;

  @override
  Future<VmAcceptedIntent<_CleanupProgress>> commit(
    VmControllerState executionState,
  ) {
    if (worker.database.hasActiveCallerTransaction)
      throw StateError(
        'TestRun cleanup acceptance must own its commit boundary',
      );
    return worker._advance(id, execution: executionState);
  }
}
