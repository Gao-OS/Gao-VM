import 'sqlite_database.dart';
import 'sqlite_vm_intent_adoption.dart';
import 'vm_command_dispatcher.dart';
import 'vm_command_repository.dart';
import 'vm_controller.dart';
import 'vm_registry.dart';
import 'vm_repository.dart';

/// Connects durable lifecycle delivery to the one controller for each VM.
/// The daemon's reconcile tick resumes recovered execution after backlog ACK;
/// delivery itself never waits for a complete VM boot or shutdown.
final class SqliteVmCommandTarget implements VmCommandTarget {
  const SqliteVmCommandTarget({
    required GaoVmDatabase database,
    required VmRegistry registry,
    required TransactionalVmEffectRunner effectRunner,
  }) : _database = database,
       _registry = registry,
       _effectRunner = effectRunner;

  final GaoVmDatabase _database;
  final VmRegistry _registry;
  final TransactionalVmEffectRunner _effectRunner;

  @override
  Future<VmIntentAdoptionDisposition> adopt(VmCommandRecord record) async {
    if (await SqliteVmIntentAdoption.isDurablyAdopted(
      database: _database,
      record: record,
    )) {
      // In particular, a delete may have finished before the worker's ACK.
      // Its tombstone is not grounds for recreating a controller or cleanup.
      return VmIntentAdoptionDisposition.duplicate;
    }
    final controller = await _registry.get(record.vmId);
    if (controller == null) throw VmNotFoundException(record.vmId);
    return controller.adopt(
      SqliteVmIntentAdoption(
        database: _database,
        record: record,
        effectRunner: _effectRunner,
      ),
    );
  }
}
