import 'package:gaovm_models/gaovm_models.dart';

import 'idempotency_repository.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'vm_provisioning_repository.dart';

/// Cancellation acceptance for VM provisioning only. Other operation kinds
/// require their own cleanup-aware acceptor; this never cancels them directly.
final class SqliteVmProvisioningCancellation
    implements OperationMutationAcceptor {
  SqliteVmProvisioningCancellation({
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

  @override
  Future<OperationAcceptance> cancel(OperationCancelCommand command) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('cancellation acceptance must own its commit boundary');
    }
    return _database.transaction((db) async {
      Future<IdempotencyResponse> accept() async {
        final operations = SqliteOperationRepository(_database, now: _now);
        final target = await operations.get(command.operationId);
        if (target == null)
          throw OperationNotFoundException(command.operationId);
        if (target.type != 'vm.create' ||
            target.resourceType != ResourceType.virtualMachine ||
            !target.cancellable ||
            (target.state != OperationState.pending &&
                target.state != OperationState.running)) {
          throw OperationNotCancellableException(target.id);
        }
        final jobs = SqliteVmProvisioningRepository(_database, now: _now);
        final job = await jobs.get(target.resourceId as VmId);
        if (job == null ||
            job.plan.operationId != target.id ||
            job.completion != null) {
          throw OperationNotCancellableException(target.id);
        }
        await jobs.requestCancellation(job.plan.vmId, operationId: target.id);
        final action = await operations.create(
          type: 'operation.cancel',
          resourceType: ResourceType.operation,
          resourceId: target.id,
          requestId: command.requestId,
          idempotencyKey: command.idempotencyKey,
          cancellable: false,
          request: JsonObjectValue.fromJson({
            'vm_id': job.plan.vmId.value,
            'spec_generation': job.plan.specGeneration,
          }),
        );
        db.execute(
          'INSERT INTO vm_provisioning_cancellations(action_id, target_id) VALUES (?, ?)',
          [action.id.value, target.id.value],
        );
        return IdempotencyResponse(
          JsonObjectValue.fromJson(
            OperationAcceptance.fromOperation(action).toJson(),
          ),
        );
      }

      final key = command.idempotencyKey;
      final response = key == null
          ? (await accept()).response
          : (await _idempotency.execute(
              scope: 'POST /v1/operations/${command.operationId.value}/cancel',
              key: key,
              requestBody: command.requestBody,
              action: accept,
            )).response;
      return OperationAcceptance.fromJson(response.toJson());
    });
  }
}
