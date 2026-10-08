import 'package:gaovm_models/gaovm_models.dart';

import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'vm_application_service.dart';
import 'vm_provisioning_plan.dart';
import 'vm_provisioning_repository.dart';
import 'vm_repository.dart';

/// Database-only VM creation shared by public acceptance and TestRun ownership.
/// The caller must atomically commit its own durable association in this scope.
Future<OperationAcceptance> commitVmCreateIntent({
  required GaoVmDatabase database,
  required VmCreateCommand command,
  required DateTime Function() now,
}) async {
  if (!database.hasActiveCallerTransaction) {
    throw StateError('VM create intent requires a caller transaction');
  }
  return database.transaction((_) async {
    final vm = await SqliteVmRepository(
      database,
      now: now,
    ).create(name: command.name, labels: command.labels, spec: command.spec);
    final operation = await SqliteOperationRepository(database, now: now)
        .create(
          type: 'vm.create',
          resourceType: ResourceType.virtualMachine,
          resourceId: vm.metadata.id,
          requestId: command.requestId,
          idempotencyKey: command.idempotencyKey,
          cancellable: true,
          request: JsonObjectValue.fromJson({
            'spec_generation': vm.status.specGeneration,
          }),
        );
    final plan = await SqliteVmProvisioningPlanner(database).plan(
      vmId: vm.metadata.id,
      operationId: operation.id,
      specGeneration: vm.status.specGeneration,
    );
    await SqliteVmProvisioningRepository(database, now: now).accept(plan);
    return OperationAcceptance.fromOperation(operation);
  });
}
