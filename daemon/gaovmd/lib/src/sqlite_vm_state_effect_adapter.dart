import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'vm_controller_reducer.dart';
import 'vm_effect_runner.dart';
import 'vm_repository.dart';

final class SqliteVmStateEffectAdapter implements VmStateEffectAdapter {
  SqliteVmStateEffectAdapter(this._database, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final GaoVmDatabase _database;
  final DateTime Function() _now;

  @override
  Future<void> persistVm(VmControllerState state) => _database.transaction((
    connection,
  ) {
    final current = connection.select(
      'SELECT v.intent_revision FROM vms v JOIN vm_runtime r ON r.vm_id = v.id WHERE v.id = ?',
      [state.vmId.value],
    );
    if (current.isEmpty) throw VmNotFoundException(state.vmId);
    // A newer accepted command owns desired/spec intent. Finishing an old
    // execution remains valid, but must not restore its superseded intent.
    if (current.single['intent_revision'] != state.appliedIntentRevision)
      return;
    final timestamp = formatPersistenceTimestamp(_now().toUtc());
    final deleting = state.deletionState != VmDeletionState.active;
    final deleted = state.deletionState == VmDeletionState.deleted;
    connection.execute(
      '''
            UPDATE vms
            SET revision = revision + CASE
                  WHEN ? = 1 AND deleted_at IS NULL
                    THEN CASE WHEN deleting_at IS NULL THEN 2 ELSE 1 END
                  WHEN ? = 1 AND deleting_at IS NULL THEN 1
                  ELSE 0
                END,
                updated_at = CASE
                  WHEN (? = 1 AND deleted_at IS NULL)
                    OR (? = 1 AND deleting_at IS NULL)
                  THEN ? ELSE updated_at END,
                deleting_at = CASE WHEN ? = 1
                  THEN COALESCE(deleting_at, ?) ELSE deleting_at END,
                deleted_at = CASE WHEN ? = 1
                  THEN COALESCE(deleted_at, ?) ELSE deleted_at END
            WHERE id = ? AND intent_revision = ?
          ''',
      [
        deleted ? 1 : 0,
        deleting ? 1 : 0,
        deleted ? 1 : 0,
        deleting ? 1 : 0,
        timestamp,
        deleting ? 1 : 0,
        timestamp,
        deleted ? 1 : 0,
        timestamp,
        state.vmId.value,
        state.appliedIntentRevision,
      ],
    );
    if (connection.updatedRows != 1) throw VmNotFoundException(state.vmId);
    connection.execute(
      'UPDATE vm_runtime SET desired_state = ? WHERE vm_id = ?',
      [_desiredState(state.desiredState), state.vmId.value],
    );
    if (connection.updatedRows != 1) throw VmNotFoundException(state.vmId);
  });

  @override
  Future<void> persistRuntime(VmControllerState state) =>
      _database.transaction((connection) {
        final checkpoint = connection.select(
          'SELECT applied_intent_revision FROM vm_runtime WHERE vm_id = ?',
          [state.vmId.value],
        );
        if (checkpoint.isEmpty) throw VmNotFoundException(state.vmId);
        if ((checkpoint.single['applied_intent_revision'] as int) >
            state.appliedIntentRevision)
          return;
        final phase = _phase(state.phase);
        final error = state.lastError;
        connection.execute(
          '''
            UPDATE vm_runtime
            SET phase = ?, observed_generation = ?, driver_generation = ?,
                restart_required = CASE
                  WHEN (SELECT spec_generation FROM vms WHERE id = vm_runtime.vm_id) > ?
                  THEN restart_required ELSE ? END,
                last_error_json = ?,
                applied_intent_revision = ?, active_operation_id = ?,
                execution_desired_state = ?, execution_spec_generation = ?,
                last_transition_at = CASE
                  WHEN phase <> ? THEN ? ELSE last_transition_at END
            WHERE vm_id = ?
          ''',
          [
            phase,
            state.observedGeneration,
            state.driverGeneration,
            state.specGeneration,
            state.restartRequired ? 1 : 0,
            error == null ? null : jsonEncode(error.toJson()),
            state.appliedIntentRevision,
            state.currentOperation?.id.value,
            state.desiredState.name,
            state.specGeneration,
            phase,
            formatPersistenceTimestamp(_now().toUtc()),
            state.vmId.value,
          ],
        );
        if (connection.updatedRows != 1) throw VmNotFoundException(state.vmId);
      });
}

String _desiredState(DesiredState state) => state.name;

String _phase(VmPhase phase) => switch (phase) {
  VmPhase.spawningDriver => 'spawning_driver',
  _ => phase.name,
};
