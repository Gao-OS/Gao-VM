import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'host_scheduler.dart';
import 'host_scheduler_models.dart';
import 'sqlite_database.dart';
import 'vm_intent_recovery_repository.dart';
import 'vm_repository.dart';

/// Resolves resource quantities from the same immutable spec as execution.
final class SqliteHostCapacityCatalog implements HostCapacityCatalog {
  const SqliteHostCapacityCatalog(
    this._database, {
    required int Function(VmSpec spec) diskBytes,
  }) : _diskBytes = diskBytes;

  final GaoVmDatabase _database;
  final int Function(VmSpec spec) _diskBytes;

  @override
  Future<HostCapacityRequest> requestFor(
    VmId vmId, {
    required HostLeasePhase phase,
    int? specGeneration,
  }) => _database.transaction((db) async {
    final vm = await SqliteVmRepository(_database).get(vmId);
    if (vm == null) throw VmNotFoundException(vmId);
    final generation = specGeneration ?? vm.status.specGeneration;
    final rows = db.select(
      'SELECT spec_json FROM vm_specs WHERE vm_id = ? AND generation = ?',
      [vmId.value, generation],
    );
    if (rows.isEmpty) {
      throw StateError('requested capacity spec generation is unavailable');
    }
    final spec = VmSpec.fromJson(
      jsonDecode(rows.single['spec_json'] as String),
    );
    return HostCapacityRequest(
      vmId: vmId,
      cpuCount: spec.cpu,
      memoryBytes: spec.memoryBytes,
      diskBytes: _diskBytes(spec),
      phase: phase,
      specGeneration: generation,
      operationId: null,
    );
  });

  @override
  Future<List<HostCapacityRequest>> recoveryRequests() => _database.transaction(
    (_) async {
      final requests = <HostCapacityRequest>[];
      final recovery = SqliteVmIntentRecoveryRepository(_database);
      for (final vm in await SqliteVmRepository(_database).list()) {
        if (vm.status.phase == VmPhase.provisioning) continue;
        final state = (await recovery.restore(vm.metadata.id))?.executionState;
        if ((state?.desiredState ?? vm.status.desiredState) !=
            DesiredState.running)
          continue;
        requests.add(
          await requestFor(
            vm.metadata.id,
            phase: vm.status.phase == VmPhase.running
                ? HostLeasePhase.running
                : HostLeasePhase.booting,
            specGeneration: state?.specGeneration ?? vm.status.specGeneration,
          ),
        );
      }
      requests.sort(
        (left, right) => left.vmId.value.compareTo(right.vmId.value),
      );
      return List<HostCapacityRequest>.unmodifiable(requests);
    },
  );
}
