import 'package:gaovm_models/gaovm_models.dart';

import 'idempotency_repository.dart';
import 'operation_application_service.dart';
import 'sqlite_database.dart';
import 'vm_application_service.dart';
import 'vm_create_intent.dart';

/// Commits create intent only. A provisioning worker owns all filesystem IO
/// after this boundary; acceptance never implies a published or runnable VM.
final class SqliteVmCreateAcceptance implements VmCreateAcceptor {
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

  @override
  Future<OperationAcceptance> create(VmCreateCommand command) =>
      accept(command);

  Future<OperationAcceptance> accept(VmCreateCommand command) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('create acceptance must own its commit boundary');
    }
    Future<IdempotencyResponse> create() async {
      final accepted = await commitVmCreateIntent(
        database: _database,
        command: command,
        now: _now,
      );
      return IdempotencyResponse(JsonObjectValue.fromJson(accepted.toJson()));
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
