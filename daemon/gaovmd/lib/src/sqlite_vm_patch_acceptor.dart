import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'event_repository.dart';
import 'idempotency_repository.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'vm_application_service.dart';
import 'vm_command_repository.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'vm_registry.dart';
import 'vm_repository.dart';
import 'vm_provisioning_plan.dart';

/// Commits spec/metadata and a FIFO notification under the controller's durable
/// write gate. Runtime adoption is separate; HTTP never performs driver IO.
final class SqliteVmPatchAcceptor implements VmPatchAcceptor {
  SqliteVmPatchAcceptor({
    required GaoVmDatabase database,
    required VmRegistry registry,
    required Duration idempotencyRetention,
  }) : _database = database,
       _registry = registry,
       _idempotency = SqliteIdempotencyRepository(
         database,
         retention: idempotencyRetention,
       );

  final GaoVmDatabase _database;
  final VmRegistry _registry;
  final SqliteIdempotencyRepository _idempotency;

  @override
  Future<OperationAcceptance> patch(VmPatchCommand command) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('patch acceptance must own its commit boundary');
    }
    final replay = await _replay(command);
    if (replay != null) return replay;
    try {
      final controller = await _registry.get(command.vmId);
      if (controller == null) throw VmNotFoundException(command.vmId);
      return await controller.accept(
        _PatchAcceptance(_database, _idempotency, command),
      );
    } catch (error) {
      if (error is VmNotFoundException ||
          error is VmControllerClosedException ||
          error is VmRegistryClosedException) {
        final replay = await _replay(command);
        if (replay != null) return replay;
      }
      rethrow;
    }
  }

  Future<OperationAcceptance?> _replay(VmPatchCommand command) async {
    final key = command.idempotencyKey;
    if (key == null) return null;
    final stored = await _idempotency.lookup(
      scope: _scope(command),
      key: key,
      requestBody: _fingerprint(command),
    );
    return stored == null ? null : _decode(command, stored.response).result;
  }
}

final class _PatchAcceptance
    implements VmAcceptanceAction<OperationAcceptance> {
  const _PatchAcceptance(this.database, this.idempotency, this.command);
  final GaoVmDatabase database;
  final SqliteIdempotencyRepository idempotency;
  final VmPatchCommand command;

  @override
  Future<VmAcceptedIntent<OperationAcceptance>> commit(
    VmControllerState execution,
  ) {
    if (execution.vmId != command.vmId || database.hasActiveCallerTransaction) {
      throw StateError(
        'patch acceptance requires its controller commit boundary',
      );
    }
    return database.transaction((db) async {
      Future<IdempotencyResponse> accept() async {
        final rows = db.select(
          'SELECT intent_revision, deleting_at FROM vms WHERE id = ? AND deleted_at IS NULL',
          [command.vmId.value],
        );
        if (rows.isEmpty) throw VmNotFoundException(command.vmId);
        if (rows.single['deleting_at'] != null)
          throw VmAcceptanceConflict(command.vmId);
        final repository = SqliteVmRepository(database);
        final before = (await repository.get(command.vmId))!;
        final updated = await repository.patch(
          command.vmId,
          expectedRevision: command.expectedRevision,
          name: command.name,
          labels: command.labels,
          spec: command.spec,
        );
        final boot = updated.spec.boot;
        final imageReferences = <(ImageId, VmProvisioningImageRole)>[
          if (boot is LinuxKernelBoot) ...[
            (boot.kernelImageId, VmProvisioningImageRole.kernel),
            if (boot.initrdImageId != null)
              (boot.initrdImageId!, VmProvisioningImageRole.initrd),
          ],
          for (final disk in updated.spec.disks)
            if (disk.source case ManagedImageDiskSource(:final imageId))
              (imageId, VmProvisioningImageRole.rootDisk),
        ];
        for (final (id, role) in imageReferences) {
          await resolveVmImageObject(
            database,
            id: id,
            role: role,
            architecture: updated.spec.architecture,
          );
        }
        final revision = (rows.single['intent_revision'] as int) + 1;
        db.execute('UPDATE vms SET intent_revision = ? WHERE id = ?', [
          revision,
          command.vmId.value,
        ]);
        final payload = JsonObjectValue.fromJson({
          'intent_revision': revision,
          'spec_generation': updated.status.specGeneration,
          'desired_state': updated.status.desiredState.name,
          'restart_policy': updated.spec.restartPolicy.name,
          'restart_required': vmSpecRequiresRestart(before.spec, updated.spec),
          'execution_intent_revision': execution.appliedIntentRevision,
          'execution_desired_state': execution.desiredState.name,
          'execution_spec_generation': execution.specGeneration,
          'execution_restart_policy': execution.restartPolicy.name,
        });
        final operation = await SqliteOperationRepository(database).create(
          type: 'vm.patch',
          resourceType: ResourceType.virtualMachine,
          resourceId: command.vmId,
          requestId: command.requestId,
          idempotencyKey: command.idempotencyKey,
          cancellable: false,
          request: payload,
        );
        await SqliteVmCommandRepository(database).enqueue(
          action: VmCommandAction.patch,
          vmId: command.vmId,
          operationId: operation.id,
          payload: payload,
        );
        await SqliteEventRepository(database).append(
          type: 'vm.patch_accepted',
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

      final key = command.idempotencyKey;
      final response = key == null
          ? (await accept()).response
          : (await idempotency.execute(
              scope: _scope(command),
              key: key,
              requestBody: _fingerprint(command),
              action: accept,
            )).response;
      return _decode(command, response);
    });
  }
}

String _scope(VmPatchCommand command) => 'PATCH /v1/vms/${command.vmId.value}';
List<int> _fingerprint(VmPatchCommand command) => [
  ...utf8.encode('${command.expectedRevision}:'),
  ...command.requestBody,
];

VmAcceptedIntent<OperationAcceptance> _decode(
  VmPatchCommand command,
  JsonObjectValue response,
) {
  final json = response.toJson();
  final revision = json['intent_revision'];
  final value = json['acceptance'];
  if (json.length != 2 || revision is! int || revision < 1 || value is! Map) {
    throw const FormatException('invalid patch acceptance response');
  }
  final acceptance = OperationAcceptance.fromJson(
    Map<String, Object?>.from(value),
  );
  if (acceptance.resourceId != command.vmId ||
      acceptance.resourceType != ResourceType.virtualMachine) {
    throw const FormatException('patch acceptance target mismatch');
  }
  return VmAcceptedIntent(intentRevision: revision, result: acceptance);
}
