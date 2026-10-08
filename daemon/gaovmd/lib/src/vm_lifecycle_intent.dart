import 'package:gaovm_models/gaovm_models.dart';

import 'event_repository.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'vm_application_service.dart';
import 'vm_command_repository.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'vm_repository.dart';

/// Database-only intent shared by public lifecycle and TestRun ownership.
/// Call only under the VM controller's acceptance gate, within a transaction.
Future<VmAcceptedIntent<OperationAcceptance>> commitVmLifecycleIntent({
  required GaoVmDatabase database,
  required VmLifecycleCommand command,
  required VmControllerState executionState,
  required DateTime Function() now,
}) {
  if (!database.hasActiveCallerTransaction ||
      executionState.vmId != command.vmId) {
    throw StateError('VM lifecycle intent requires its controller transaction');
  }
  return database.transaction((_) async {
    final rows = await database.read(
      (db) => db.select(
        'SELECT v.*, r.phase FROM vms v JOIN vm_runtime r ON r.vm_id = v.id WHERE v.id = ? AND v.deleted_at IS NULL',
        [command.vmId.value],
      ),
    );
    if (rows.isEmpty) throw VmNotFoundException(command.vmId);
    final vm = rows.single;
    if (vm['phase'] == 'provisioning') {
      throw VmProvisioningConflictException(command.vmId);
    }
    if (vm['deleting_at'] != null) {
      if (command.action != VmLifecycleAction.delete) {
        throw VmAcceptanceConflict(command.vmId);
      }
      final deletes = (await SqliteOperationRepository(database).list(
        resourceType: ResourceType.virtualMachine,
        resourceId: command.vmId,
      )).where((operation) => operation.type == 'vm.delete');
      final retryable = deletes.any(
        (operation) =>
            operation.request.toJson()['intent_revision'] ==
                vm['intent_revision'] &&
            (operation.state == OperationState.failed ||
                operation.state == OperationState.cancelled),
      );
      if (!retryable ||
          deletes.any(
            (operation) =>
                operation.state == OperationState.pending ||
                operation.state == OperationState.running,
          )) {
        throw VmAcceptanceConflict(command.vmId);
      }
    }
    final revision = (vm['intent_revision'] as int) + 1;
    final desired = switch (command.action) {
      VmLifecycleAction.start || VmLifecycleAction.restart => 'running',
      _ => 'stopped',
    };
    final timestamp = formatPersistenceTimestamp(now().toUtc());
    await database.read((db) {
      db.execute(
        '''UPDATE vms SET intent_revision = ?,
          deleting_at = CASE WHEN ? = 1 THEN ? ELSE deleting_at END,
          revision = revision + CASE WHEN ? = 1 THEN 1 ELSE 0 END,
          updated_at = CASE WHEN ? = 1 THEN ? ELSE updated_at END WHERE id = ?''',
        [
          revision,
          command.action == VmLifecycleAction.delete ? 1 : 0,
          timestamp,
          command.action == VmLifecycleAction.delete ? 1 : 0,
          command.action == VmLifecycleAction.delete ? 1 : 0,
          timestamp,
          command.vmId.value,
        ],
      );
      db.execute('UPDATE vm_runtime SET desired_state = ? WHERE vm_id = ?', [
        desired,
        command.vmId.value,
      ]);
      if (db.updatedRows != 1) throw StateError('VM runtime record is missing');
    });
    final payload = JsonObjectValue.fromJson({
      'intent_revision': revision,
      'spec_generation': vm['spec_generation'],
      'desired_state': desired,
      'execution_intent_revision': executionState.appliedIntentRevision,
      'execution_desired_state': executionState.desiredState.name,
      'execution_spec_generation': executionState.specGeneration,
      'execution_restart_policy': executionState.restartPolicy.name,
      if (command.reason != null) 'reason': command.reason,
    });
    final operation = await SqliteOperationRepository(database, now: now)
        .create(
          type: 'vm.${command.action.name}',
          resourceType: ResourceType.virtualMachine,
          resourceId: command.vmId,
          requestId: command.requestId,
          idempotencyKey: command.idempotencyKey,
          cancellable: command.action != VmLifecycleAction.delete,
          request: payload,
          deadlineAt: command.deadlineAt,
        );
    await SqliteVmCommandRepository(database, now: now).enqueue(
      action: VmCommandAction.values.byName(command.action.name),
      vmId: command.vmId,
      operationId: operation.id,
      payload: payload,
    );
    await SqliteEventRepository(database, now: now).append(
      type: 'vm.action_accepted',
      resourceType: ResourceType.virtualMachine,
      resourceId: command.vmId,
      vmId: command.vmId,
      operationId: operation.id,
      payload: payload,
    );
    return VmAcceptedIntent(
      intentRevision: revision,
      result: OperationAcceptance.fromOperation(operation),
    );
  });
}
