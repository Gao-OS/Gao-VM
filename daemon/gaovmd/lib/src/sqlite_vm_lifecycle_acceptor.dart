import 'idempotency_repository.dart';
import 'operation_application_service.dart';
import 'sqlite_database.dart';
import 'sqlite_vm_lifecycle_acceptance.dart';
import 'vm_application_service.dart';
import 'vm_controller.dart';
import 'vm_registry.dart';
import 'vm_repository.dart';

/// Public lifecycle acceptance, without dispatching or waiting for runtime IO.
/// The registry must use this catalog's durable intent recovery repository.
final class SqliteVmLifecycleAcceptor implements VmLifecycleAcceptor {
  SqliteVmLifecycleAcceptor({
    required GaoVmDatabase database,
    required VmRegistry registry,
    required Duration idempotencyRetention,
    DateTime Function()? now,
  }) : _database = database,
       _registry = registry,
       _now = now ?? DateTime.now,
       _idempotency = SqliteIdempotencyRepository(
         database,
         retention: idempotencyRetention,
         now: now,
       );

  final GaoVmDatabase _database;
  final VmRegistry _registry;
  final DateTime Function() _now;
  final SqliteIdempotencyRepository _idempotency;

  @override
  Future<OperationAcceptance> lifecycle(VmLifecycleCommand command) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('lifecycle acceptance must own its commit boundary');
    }
    final replay = await _replay(command);
    if (replay != null) return replay;
    try {
      final controller = await _registry.get(command.vmId);
      if (controller == null) throw VmNotFoundException(command.vmId);
      // A lookup miss is not a reservation. The acceptance transaction checks
      // idempotency again while holding the controller's durable-write gate.
      return await controller.accept(
        SqliteVmLifecycleAcceptance(
          database: _database,
          command: command,
          idempotencyRetention: _idempotency.retention,
          now: _now,
        ),
      );
    } catch (error) {
      // A concurrent request may have committed and retired this VM after the
      // first lookup. Replay its durable response, never recreate the resource.
      if (error is VmNotFoundException ||
          error is VmControllerClosedException ||
          error is VmRegistryClosedException) {
        final completed = await _replay(command);
        if (completed != null) return completed;
      }
      rethrow;
    }
  }

  Future<OperationAcceptance?> _replay(VmLifecycleCommand command) async {
    final key = command.idempotencyKey;
    if (key == null) return null;
    final stored = await _idempotency.lookup(
      scope: SqliteVmLifecycleAcceptance.scopeFor(command),
      key: key,
      requestBody: command.requestBody,
    );
    return stored == null
        ? null
        : SqliteVmLifecycleAcceptance.decodeResponse(
            command,
            stored.response,
          ).result;
  }
}
