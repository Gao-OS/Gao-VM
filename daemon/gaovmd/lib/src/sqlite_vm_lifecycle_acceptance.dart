import 'package:gaovm_models/gaovm_models.dart';

import 'event_repository.dart';
import 'idempotency_repository.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'vm_application_service.dart';
import 'vm_command_repository.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'vm_repository.dart';

/// Run through VmController.accept so accepted intent shares the controller's
/// short durable-write gate without waiting for an external runtime effect.
final class SqliteVmLifecycleAcceptance
    implements VmAcceptanceAction<OperationAcceptance> {
  SqliteVmLifecycleAcceptance({
    required GaoVmDatabase database,
    required this.command,
    required this.idempotencyRetention,
    DateTime Function()? now,
  }) : _database = database,
       _now = now ?? DateTime.now;

  final GaoVmDatabase _database;
  final VmLifecycleCommand command;
  final Duration idempotencyRetention;
  final DateTime Function() _now;

  @override
  Future<VmAcceptedIntent<OperationAcceptance>> commit(
    VmControllerState executionState,
  ) async {
    if (executionState.vmId != command.vmId) {
      throw ArgumentError('acceptance target does not match its controller');
    }
    if (_database.hasActiveCallerTransaction) {
      throw StateError('controller acceptance must own its commit boundary');
    }
    final idempotency = SqliteIdempotencyRepository(
      _database,
      retention: idempotencyRetention,
      now: _now,
    );
    Future<IdempotencyResponse> accept() async {
      final rows = await _database.read(
        (db) => db.select(
          'SELECT * FROM vms WHERE id = ? AND deleted_at IS NULL',
          [command.vmId.value],
        ),
      );
      if (rows.isEmpty) throw VmNotFoundException(command.vmId);
      final vm = rows.single;
      if (vm['deleting_at'] != null) {
        if (command.action != VmLifecycleAction.delete) {
          throw VmAcceptanceConflict(command.vmId);
        }
        final deletes = (await SqliteOperationRepository(_database).list(
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
      final timestamp = formatPersistenceTimestamp(_now().toUtc());
      await _database.read((db) {
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
        if (db.updatedRows != 1)
          throw StateError('VM runtime record is missing');
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
      final operation = await SqliteOperationRepository(_database, now: _now)
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
      await SqliteVmCommandRepository(_database, now: _now).enqueue(
        action: VmCommandAction.values.byName(command.action.name),
        vmId: command.vmId,
        operationId: operation.id,
        payload: payload,
      );
      await SqliteEventRepository(_database, now: _now).append(
        type: 'vm.action_accepted',
        resourceType: ResourceType.virtualMachine,
        resourceId: command.vmId,
        vmId: command.vmId,
        operationId: operation.id,
        payload: payload,
      );
      return IdempotencyResponse(
        JsonObjectValue.fromJson({
          'intent_revision': revision,
          'acceptance': OperationAcceptance.fromOperation(operation).toJson(),
        }),
      );
    }

    return _database.transaction((_) async {
      final key = command.idempotencyKey;
      final JsonObjectValue response;
      if (key == null) {
        response = (await accept()).response;
      } else {
        response = (await idempotency.execute(
          scope: command.action == VmLifecycleAction.delete
              ? 'DELETE /v1/vms/${command.vmId.value}'
              : 'POST /v1/vms/${command.vmId.value}/actions/${command.action.name}',
          key: key,
          requestBody: command.requestBody,
          action: accept,
        )).response;
      }
      final json = response.toJson();
      return VmAcceptedIntent(
        intentRevision: json['intent_revision'] as int,
        result: OperationAcceptance.fromJson(
          Map<String, Object?>.from(json['acceptance'] as Map),
        ),
      );
    });
  }
}
