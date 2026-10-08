import 'package:gaovm_models/gaovm_models.dart';

import 'idempotency_repository.dart';
import 'operation_application_service.dart';
import 'sqlite_database.dart';
import 'vm_application_service.dart';
import 'vm_lifecycle_intent.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';

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

  static String scopeFor(VmLifecycleCommand command) =>
      command.action == VmLifecycleAction.delete
      ? 'DELETE /v1/vms/${command.vmId.value}'
      : 'POST /v1/vms/${command.vmId.value}/actions/${command.action.name}';

  static VmAcceptedIntent<OperationAcceptance> decodeResponse(
    VmLifecycleCommand command,
    JsonObjectValue response,
  ) {
    final json = response.toJson();
    final revision = json['intent_revision'];
    final value = json['acceptance'];
    if (json.length != 2 || revision is! int || revision < 1 || value is! Map) {
      throw const FormatException('invalid lifecycle acceptance response');
    }
    final acceptance = OperationAcceptance.fromJson(
      Map<String, Object?>.from(value),
    );
    if (acceptance.resourceType != ResourceType.virtualMachine ||
        acceptance.resourceId != command.vmId) {
      throw const FormatException('lifecycle acceptance target mismatch');
    }
    return VmAcceptedIntent(intentRevision: revision, result: acceptance);
  }

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
      final accepted = await commitVmLifecycleIntent(
        database: _database,
        command: command,
        executionState: executionState,
        now: _now,
      );
      return IdempotencyResponse(
        JsonObjectValue.fromJson({
          'intent_revision': accepted.intentRevision,
          'acceptance': accepted.result.toJson(),
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
          scope: scopeFor(command),
          key: key,
          requestBody: command.requestBody,
          action: accept,
        )).response;
      }
      return decodeResponse(command, response);
    });
  }
}
