import 'package:gaovm_models/gaovm_models.dart';

import 'idempotency_repository.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'vm_application_service.dart';
import 'vm_provisioning_plan.dart';
import 'vm_provisioning_repository.dart';
import 'vm_repository.dart';

/// Commits create intent only. A provisioning worker owns all filesystem IO
/// after this boundary; acceptance never implies a published or runnable VM.
final class SqliteVmCreateAcceptance {
  SqliteVmCreateAcceptance({
    required GaoVmDatabase database,
    required Duration idempotencyRetention,
    DateTime Function()? now,
  }) : _database = database,
       _now = now ?? DateTime.now,
       _idempotency = SqliteIdempotencyRepository(
         database,
         retention: idempotencyRetention,
         now: now,
       );

  final GaoVmDatabase _database;
  final DateTime Function() _now;
  final SqliteIdempotencyRepository _idempotency;

  Future<OperationAcceptance> accept(VmCreateCommand command) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('create acceptance must own its commit boundary');
    }
    Future<IdempotencyResponse> create() async {
      final vm = await SqliteVmRepository(
        _database,
        now: _now,
      ).create(name: command.name, labels: command.labels, spec: command.spec);
      final operation = await SqliteOperationRepository(_database, now: _now)
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
      final plan = await SqliteVmProvisioningPlanner(_database).plan(
        vmId: vm.metadata.id,
        operationId: operation.id,
        specGeneration: vm.status.specGeneration,
      );
      await SqliteVmProvisioningRepository(_database, now: _now).accept(plan);
      return IdempotencyResponse(
        JsonObjectValue.fromJson(
          OperationAcceptance.fromOperation(operation).toJson(),
        ),
      );
    }

    return _database.transaction((_) async {
      final key = command.idempotencyKey;
      final response = key == null
          ? (await create()).response
          : (await _idempotency.execute(
              scope: 'POST /v1/vms',
              key: key,
              requestBody: command.requestBody,
              action: create,
            )).response;
      return OperationAcceptance.fromJson(response.toJson());
    });
  }
}
