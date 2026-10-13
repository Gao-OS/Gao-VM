import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';

/// Source-harness diagnostics only; never used by the production CLI.
final class NativeVmRuntimeInspection {
  NativeVmRuntimeInspection._(this._state, this.executable, this._observe);

  static Future<NativeVmRuntimeInspection> open({
    required Directory stateDirectory,
    required String executable,
    Future<DriverInventorySnapshot> Function()? observe,
  }) async {
    final state = await OwnedImageDirectory.open(stateDirectory);
    return NativeVmRuntimeInspection._(
      state,
      executable,
      observe ?? MacOsDriverInventory(executablePath: executable).snapshot,
    );
  }

  final OwnedImageDirectory _state;
  final String executable;
  final Future<DriverInventorySnapshot> Function() _observe;
  final _seen = <(VmId, int), DriverProcessIdentity>{};

  Future<List<DriverRuntimeMetadata>> check(List<VirtualMachine> vms) async {
    if (vms.length != 3 || vms.map((vm) => vm.metadata.id).toSet().length != 3)
      throw ArgumentError('three distinct owned VMs are required');
    if (_state.mode & 0x3f != 0)
      throw StateError('native inspection requires private state');
    await _state.verifyPathBinding();
    final run = _state.directory('run');
    final records = <DriverRuntimeMetadata>[];
    try {
      if (run.mode & 0x3f != 0)
        throw StateError('native inspection requires a private runtime root');
      for (final vm in vms) {
        final parent = run.directoryOrNull(vm.metadata.id.value);
        try {
          if (vm.status.phase != VmPhase.running) {
            if (vm.status.phase != VmPhase.stopped ||
                vm.status.desiredState != DesiredState.stopped)
              throw StateError('VM is neither running nor stopped');
            if (vm.status.driverGeneration == 0 && parent != null)
              throw StateError('the never-started VM has a runtime directory');
            continue;
          }
          if (parent == null || parent.mode & 0x3f != 0)
            throw StateError('running VM lacks its private runtime directory');
          final generation = parent.directory('${vm.status.driverGeneration}');
          try {
            final record = await DriverRuntimeMetadata.readFrom(
              generation,
              correlation: DriverCorrelation(
                vmId: vm.metadata.id,
                driverGeneration: vm.status.driverGeneration,
                operationId: null,
              ),
              executable: executable,
              bundlePath: '${_state.path}/vms/${vm.metadata.id.value}.gaovm',
            );
            if (record == null || record.processIdentity == null)
              throw StateError('running VM lacks a versioned process identity');
            records.add(record);
            await parent.verifyPathBinding();
          } finally {
            generation.close();
          }
        } finally {
          parent?.close();
        }
      }
      final inventory = await _observe();
      final identities = records
          .map((record) => record.processIdentity!)
          .toSet();
      if (inventory.unresolvedProcessIds.isNotEmpty ||
          inventory.processes.length != identities.length ||
          records.length != identities.length ||
          records.map((record) => record.pid).toSet().length !=
              records.length ||
          records.map((record) => record.socketPath).toSet().length !=
              records.length ||
          !identities.containsAll(inventory.processes))
        throw StateError(
          'live driver inventory does not match the owned VM bindings',
        );
      for (final record in records) {
        final key = (
          record.correlation.vmId,
          record.correlation.driverGeneration,
        );
        final previous = _seen[key];
        if (previous != null && previous != record.processIdentity)
          throw StateError(
            'the same VM generation changed its native process identity',
          );
      }
      await run.verifyPathBinding();
      await _state.verifyPathBinding();
      for (final record in records) {
        _seen[(record.correlation.vmId, record.correlation.driverGeneration)] =
            record.processIdentity!;
      }
      return records;
    } finally {
      run.close();
    }
  }

  void close() => _state.close();
}
