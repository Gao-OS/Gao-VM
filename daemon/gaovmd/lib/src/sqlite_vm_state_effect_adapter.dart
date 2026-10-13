import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'event_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'vm_controller_reducer.dart';
import 'vm_effect_runner.dart';
import 'vm_repository.dart';

final class SqliteVmStateEffectAdapter
    implements VmStateEffectAdapter, VmGuestReadinessEffectAdapter {
  SqliteVmStateEffectAdapter(this._database, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final GaoVmDatabase _database;
  final DateTime Function() _now;

  @override
  Future<void> persistGuestReadiness(
    VmControllerState state,
    bool ready, {
    bool Function()? stillCurrent,
  }) => _database.transaction((connection) async {
    if (stillCurrent?.call() == false) throw const GuestObservationSuperseded();
    if (state.phase != VmPhase.running ||
        state.desiredState != DesiredState.running ||
        state.deletionState != VmDeletionState.active ||
        state.activeDriverGeneration == null)
      return;
    final rows = connection.select(
      '''
          SELECT r.guest_agent, s.spec_json
          FROM vm_runtime r JOIN vms v ON v.id = r.vm_id
          JOIN vm_specs s ON s.vm_id = r.vm_id AND s.generation = r.observed_generation
          WHERE r.vm_id = ? AND r.driver_generation = ? AND r.phase = 'running'
            AND r.observed_generation = ? AND r.applied_intent_revision = ?
            AND r.desired_state = 'running' AND v.deleting_at IS NULL AND v.deleted_at IS NULL
        ''',
      [
        state.vmId.value,
        state.activeDriverGeneration,
        state.activeSpecGeneration ?? state.observedGeneration,
        state.appliedIntentRevision,
      ],
    );
    if (rows.isEmpty) return;
    final row = rows.single;
    final spec = VmSpec.fromJson(
      Map<String, Object?>.from(jsonDecode(row['spec_json'] as String) as Map),
    );
    if (!spec.guestAgent.enabled) return;
    final next = ready ? GuestAgentState.ready : GuestAgentState.unavailable;
    if (row['guest_agent'] == next.name) return;
    connection.execute(
      'UPDATE vm_runtime SET guest_agent = ? WHERE vm_id = ?',
      [next.name, state.vmId.value],
    );
    await SqliteEventRepository(_database, now: _now).append(
      type: ready ? 'vm.guest_agent_ready' : 'vm.guest_agent_unavailable',
      resourceType: ResourceType.virtualMachine,
      resourceId: state.vmId,
      vmId: state.vmId,
      payload: JsonObjectValue.fromJson({
        'driver_generation': state.activeDriverGeneration,
      }),
    );
    if (stillCurrent?.call() == false) throw const GuestObservationSuperseded();
  });

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
          '''
            SELECT r.applied_intent_revision, r.driver_generation, r.guest_agent, s.spec_json
            FROM vm_runtime r JOIN vms v ON v.id = r.vm_id
            LEFT JOIN vm_specs s ON s.vm_id = r.vm_id AND s.generation = COALESCE(?, v.spec_generation)
            WHERE r.vm_id = ?
          ''',
          [state.activeSpecGeneration, state.vmId.value],
        );
        if (checkpoint.isEmpty) throw VmNotFoundException(state.vmId);
        if ((checkpoint.single['applied_intent_revision'] as int) >
            state.appliedIntentRevision)
          return;
        final phase = _phase(state.phase);
        final error = state.lastError;
        final row = checkpoint.single;
        var guestAgent = row['guest_agent'] as String;
        if (state.phase != VmPhase.running ||
            state.activeDriverGeneration != state.driverGeneration ||
            row['driver_generation'] != state.driverGeneration) {
          final specJson = row['spec_json'] as String?;
          final enabled = specJson == null
              ? guestAgent != GuestAgentState.disabled.name
              : (jsonDecode(specJson) as Map)['guest_agent']['enabled'] == true;
          guestAgent = enabled
              ? GuestAgentState.unavailable.name
              : GuestAgentState.disabled.name;
        }
        connection.execute(
          '''
            UPDATE vm_runtime
            SET phase = ?, observed_generation = ?, driver_generation = ?,
                restart_required = CASE
                  WHEN (SELECT spec_generation FROM vms WHERE id = vm_runtime.vm_id) > ?
                  THEN restart_required ELSE ? END,
                last_error_json = ?, guest_agent = ?,
                applied_intent_revision = ?, active_operation_id = ?,
                execution_desired_state = ?, execution_spec_generation = ?,
                driver_operation_id = ?, display_state = ?, display_observed_at = ?,
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
            guestAgent,
            state.appliedIntentRevision,
            state.currentOperation?.id.value,
            state.desiredState.name,
            state.specGeneration,
            state.driverOperationId?.value,
            state.displayState.name,
            state.displayObservedAt == null
                ? null
                : formatPersistenceTimestamp(state.displayObservedAt!),
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
