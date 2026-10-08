import 'package:gaovm_models/gaovm_models.dart';

import 'event_repository.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';
import 'vm_application_service.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'vm_lifecycle_intent.dart';
import 'vm_registry.dart';
import 'vm_repository.dart';

final class TestRunVmStartOutcome {
  const TestRunVmStartOutcome({
    required this.testRunId,
    required this.operationId,
    required this.vmId,
    this.error,
  });
  final TestRunId testRunId;
  final OperationId operationId;
  final VmId? vmId;
  final Object? error;
}

/// Acceptance and observation only. The existing VM command dispatcher and
/// per-VM controller own runtime IO, admission, generation and supervision.
final class TestRunVmStartWorker {
  TestRunVmStartWorker({
    required this.database,
    required this.registry,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final GaoVmDatabase database;
  final VmRegistry registry;
  final DateTime Function() _now;
  TestRunId? _cursor;

  Future<List<TestRunVmStartOutcome>> dispatchOnce({int limit = 100}) async {
    if (limit < 1 || limit > 200) throw RangeError.range(limit, 1, 200);
    if (database.hasActiveCallerTransaction) {
      throw StateError('TestRun VM start must own its commit boundary');
    }
    final items = await database.read((db) {
      const query = '''
        SELECT id, operation_id, vm_id FROM test_runs
        WHERE state = 'starting_vm' AND id > ? ORDER BY id LIMIT ?
      ''';
      var rows = db.select(query, [_cursor?.value ?? '', limit]);
      if (rows.isEmpty && _cursor != null) rows = db.select(query, ['', limit]);
      return [
        for (final row in rows)
          (
            id: TestRunId(row['id'] as String),
            operation: OperationId(row['operation_id'] as String),
            vm: row['vm_id'] == null ? null : VmId(row['vm_id'] as String),
          ),
      ];
    });
    _cursor = items.lastOrNull?.id;
    return List.unmodifiable(
      await Future.wait(
        items.map((item) async {
          Object? failure;
          try {
            if (item.vm == null) throw StateError('starting TestRun has no VM');
            final controller = await registry.get(item.vm!);
            if (controller == null) throw VmNotFoundException(item.vm!);
            await controller.accept(_StartAcceptance(database, item.id, _now));
          } catch (error) {
            failure = error;
          }
          return TestRunVmStartOutcome(
            testRunId: item.id,
            operationId: item.operation,
            vmId: item.vm,
            error: failure,
          );
        }),
      ),
    );
  }
}

final class _StartAcceptance implements VmAcceptanceAction<TestRun> {
  const _StartAcceptance(this.database, this.id, this.now);
  final GaoVmDatabase database;
  final TestRunId id;
  final DateTime Function() now;

  @override
  Future<VmAcceptedIntent<TestRun>> commit(VmControllerState execution) {
    if (database.hasActiveCallerTransaction) {
      throw StateError('TestRun start acceptance must own its commit boundary');
    }
    return database.transaction((db) async {
      final runs = SqliteTestRunRepository(database, now: now);
      final run = (await runs.get(id))!;
      VmAcceptedIntent<TestRun> unchanged(TestRun value, [int? revision]) =>
          VmAcceptedIntent(
            intentRevision: revision ?? execution.appliedIntentRevision,
            result: value,
          );
      if (run.state != TestRunState.startingVm) return unchanged(run);
      if (run.vmId != execution.vmId)
        throw StateError('TestRun VM target mismatch');
      final operations = SqliteOperationRepository(database);
      final parent = await operations.get(run.operationId);
      if (parent == null ||
          parent.type != 'test.run' ||
          parent.resourceType != ResourceType.testRun ||
          parent.resourceId != id ||
          parent.state != OperationState.running) {
        throw StateError('TestRun start operation is not active');
      }
      final cancelled =
          db.select('SELECT cancel_requested FROM test_runs WHERE id = ?', [
            id.value,
          ]).single['cancel_requested'] ==
          1;
      final expired =
          parent.deadlineAt != null &&
          !now().toUtc().isBefore(parent.deadlineAt!);
      final rows = db.select(
        'SELECT * FROM test_run_vm_start WHERE test_run_id = ?',
        [id.value],
      );
      if (rows.isEmpty) {
        if (cancelled)
          return unchanged(
            await runs.transition(
              id,
              expectedState: run.state,
              nextState: TestRunState.collecting,
              outcome: TestRunState.cancelled,
            ),
          );
        if (expired)
          return unchanged(await _fail(runs, run, ErrorCode.waitTimeout));
        final accepted = await commitVmLifecycleIntent(
          database: database,
          executionState: execution,
          now: now,
          command: VmLifecycleCommand(
            requestId: parent.requestId,
            idempotencyKey: null,
            requestBody: const [],
            vmId: run.vmId!,
            action: VmLifecycleAction.start,
            deadlineAt: parent.deadlineAt,
          ),
        );
        db.execute(
          '''INSERT INTO test_run_vm_start(test_run_id, vm_id, operation_id, intent_revision)
          VALUES (?, ?, ?, ?)''',
          [
            id.value,
            run.vmId!.value,
            accepted.result.operationId.value,
            accepted.intentRevision,
          ],
        );
        await SqliteEventRepository(database, now: now).append(
          type: 'test_run.vm_start_accepted',
          resourceType: ResourceType.testRun,
          resourceId: id,
          vmId: run.vmId,
          operationId: run.operationId,
          testRunId: id,
          payload: JsonObjectValue.fromJson({
            'start_operation_id': accepted.result.operationId.value,
            'intent_revision': accepted.intentRevision,
          }),
        );
        return unchanged(run, accepted.intentRevision);
      }
      final row = rows.single;
      final revision = row['intent_revision'] as int;
      final child = await operations.get(
        OperationId(row['operation_id'] as String),
      );
      if (row['vm_id'] != run.vmId!.value ||
          child == null ||
          child.type != 'vm.start' ||
          child.resourceType != ResourceType.virtualMachine ||
          child.resourceId != run.vmId ||
          child.request.toJson()['intent_revision'] != revision) {
        throw StateError('TestRun start checkpoint is mismatched');
      }
      if (row['abort_operation_id'] != null || cancelled || expired) {
        if (row['abort_operation_id'] == null) {
          if (child.state == OperationState.failed) {
            return unchanged(
              await _fail(
                runs,
                run,
                child.error?.code ?? ErrorCode.driverStartFailed,
                child: child,
              ),
              revision,
            );
          }
          final abort = await commitVmLifecycleIntent(
            database: database,
            executionState: execution,
            now: now,
            command: VmLifecycleCommand(
              requestId: parent.requestId,
              idempotencyKey: null,
              requestBody: const [],
              vmId: run.vmId!,
              action: VmLifecycleAction.stop,
              reason: 'TestRun execution aborted',
            ),
          );
          final reason = cancelled ? 'cancelled' : 'deadline';
          db.execute(
            '''UPDATE test_run_vm_start SET abort_operation_id = ?,
            abort_intent_revision = ?, abort_reason = ? WHERE test_run_id = ?''',
            [
              abort.result.operationId.value,
              abort.intentRevision,
              reason,
              id.value,
            ],
          );
          await SqliteEventRepository(database, now: now).append(
            type: 'test_run.vm_abort_accepted',
            resourceType: ResourceType.testRun,
            resourceId: id,
            vmId: run.vmId,
            operationId: run.operationId,
            testRunId: id,
            payload: JsonObjectValue.fromJson({
              'start_operation_id': child.id.value,
              'stop_operation_id': abort.result.operationId.value,
              'intent_revision': abort.intentRevision,
              'reason': reason,
            }),
          );
          return unchanged(run, abort.intentRevision);
        }
        final abortRevision = row['abort_intent_revision'] as int;
        final stop = await operations.get(
          OperationId(row['abort_operation_id'] as String),
        );
        if (stop == null ||
            stop.type != 'vm.stop' ||
            stop.resourceType != ResourceType.virtualMachine ||
            stop.resourceId != run.vmId ||
            stop.request.toJson()['intent_revision'] != abortRevision) {
          throw StateError('TestRun abort checkpoint is mismatched');
        }
        if (stop.state == OperationState.pending ||
            stop.state == OperationState.running) {
          return unchanged(run, abortRevision);
        }
        final vm = await SqliteVmRepository(database).get(run.vmId!);
        final applied = db.select(
          'SELECT applied_intent_revision FROM vm_runtime WHERE vm_id = ?',
          [run.vmId!.value],
        ).single['applied_intent_revision'];
        final drained =
            stop.state == OperationState.succeeded &&
            vm != null &&
            vm.status.phase == VmPhase.stopped &&
            vm.status.desiredState == DesiredState.stopped &&
            applied == abortRevision;
        TestRun collected;
        if (row['abort_reason'] == 'deadline') {
          collected = await _fail(runs, run, ErrorCode.waitTimeout);
          if (!drained)
            collected = await runs.recordFailure(
              id,
              error:
                  stop.error ??
                  OperationError(
                    code: ErrorCode.driverUnhealthy,
                    message: 'The TestRun VM did not drain after its deadline.',
                    retryable: true,
                    details: JsonObjectValue.empty,
                  ),
            );
        } else if (drained) {
          collected = await runs.transition(
            id,
            expectedState: run.state,
            nextState: TestRunState.collecting,
            outcome: TestRunState.cancelled,
          );
        } else {
          collected = await _fail(
            runs,
            run,
            stop.error?.code ?? ErrorCode.driverUnhealthy,
            child: stop,
          );
        }
        return unchanged(collected, abortRevision);
      }
      if (child.state == OperationState.pending ||
          child.state == OperationState.running) {
        return unchanged(run, revision);
      }
      if (child.state != OperationState.succeeded) {
        return unchanged(
          await _fail(
            runs,
            run,
            child.error?.code ?? ErrorCode.driverStartFailed,
            child: child,
          ),
          revision,
        );
      }
      final vm = await SqliteVmRepository(database).get(run.vmId!);
      final applied = db.select(
        'SELECT applied_intent_revision FROM vm_runtime WHERE vm_id = ?',
        [run.vmId!.value],
      ).single['applied_intent_revision'];
      if (vm == null ||
          vm.status.phase != VmPhase.running ||
          vm.status.desiredState != DesiredState.running ||
          vm.status.driverGeneration < 1 ||
          applied != revision) {
        return unchanged(
          await _fail(runs, run, ErrorCode.vmOperationConflict),
          revision,
        );
      }
      db.execute(
        'UPDATE test_run_vm_start SET driver_generation = ? WHERE test_run_id = ?',
        [vm.status.driverGeneration, id.value],
      );
      final ready = await runs.transition(
        id,
        expectedState: run.state,
        nextState: TestRunState.waitingReady,
      );
      await SqliteEventRepository(database, now: now).append(
        type: 'test_run.vm_started',
        resourceType: ResourceType.testRun,
        resourceId: id,
        vmId: run.vmId,
        operationId: run.operationId,
        testRunId: id,
        payload: JsonObjectValue.fromJson({
          'start_operation_id': child.id.value,
          'driver_generation': vm.status.driverGeneration,
          'intent_revision': revision,
        }),
      );
      return unchanged(ready, revision);
    });
  }

  Future<TestRun> _fail(
    SqliteTestRunRepository runs,
    TestRun run,
    ErrorCode code, {
    Operation? child,
  }) => runs.transition(
    id,
    expectedState: run.state,
    nextState: TestRunState.collecting,
    outcome: TestRunState.failed,
    error: OperationError(
      code: code,
      message:
          child?.error?.message ??
          (code == ErrorCode.waitTimeout
              ? 'The TestRun start deadline expired.'
              : 'Unable to start the TestRun VM.'),
      retryable: child?.error?.retryable ?? false,
      details: JsonObjectValue.fromJson({
        'phase': 'starting_vm',
        'vm_id': run.vmId!.value,
        if (child != null) 'start_operation_id': child.id.value,
        if (child?.error != null) 'cause': child!.error!.toJson(),
      }),
    ),
  );
}
