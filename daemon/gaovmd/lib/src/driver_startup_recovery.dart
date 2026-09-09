import 'dart:convert';

import 'daemon_ownership.dart';
import 'driver_runtime_discovery.dart';
import 'driver_runtime_layout.dart';
import 'driver_runtime_metadata.dart';
import 'driver_startup_teardown.dart';
import 'macos_driver_inventory.dart';

/// Startup-only barrier before lease recovery or controller activation.
/// The caller keeps daemon ownership held and supplies a complete native driver
/// inventory (including unresolved processes), not just recorded PIDs.
/// Failures preserve leases; this component never acquires or releases them.
final class DriverStartupRecovery {
  DriverStartupRecovery({
    required this.ownership,
    required this.layout,
    required this.discovery,
    required this.readInventory,
    Duration orphanGrace = const Duration(seconds: 20),
    Duration terminateGrace = const Duration(seconds: 5),
    Duration killGrace = const Duration(seconds: 5),
  }) : _teardown = DriverStartupTeardown(
         ownership: ownership,
         orphanGrace: orphanGrace,
         terminateGrace: terminateGrace,
         killGrace: killGrace,
       ) {
    if (layout.runRoot != discovery.root.path ||
        discovery.root.path != '${ownership.stateDirectoryPath}/run') {
      throw ArgumentError(
        'runtime layout must belong to the owned state directory',
      );
    }
  }

  final DaemonOwnership ownership;
  final DriverRuntimeLayout layout;
  final DriverRuntimeDiscovery discovery;
  final Future<DriverInventorySnapshot> Function() readInventory;
  final DriverStartupTeardown _teardown;
  Future<void>? _recovery;

  Future<void> recover() => _recovery ??= _recover();

  Future<void> _recover() async {
    await ownership.verify();
    final snapshot = await discovery.scan();
    if (snapshot.issues.isNotEmpty) {
      throw StateError('runtime discovery remains unresolved');
    }
    final paths = <(DriverRuntimeMetadata, DriverRuntimePaths)>[];
    for (final record in snapshot.records) {
      final recovered = await layout.recoverPaths(record.correlation);
      await _verifyRecord(record);
      paths.add((record, recovered));
    }
    final known = {
      for (final record in snapshot.records)
        if (record.processIdentity case final identity?) identity,
    };
    if ((await readInventory()).countUnmanaged(known) != 0) {
      throw StateError('unrecorded drivers prevent startup recovery');
    }
    await _teardown.terminateRecorded(snapshot);
    await _requireNoDrivers();
    // Serialize namespace cleanup: multiple old generations may share a VM
    // parent, whose quarantine must not race another generation's cleanup.
    for (final (record, expected) in paths) {
      await ownership.verify();
      await _verifyRecord(record);
      final current = await layout.recoverPaths(record.correlation);
      if (current.cleanupToken != expected.cleanupToken ||
          current.vmCleanupToken != expected.vmCleanupToken) {
        throw StateError('runtime ownership changed during startup recovery');
      }
      await layout.remove(current);
    }
    final remaining = await discovery.scan();
    if (remaining.records.isNotEmpty || remaining.issues.isNotEmpty) {
      throw StateError('runtime files remain unresolved after cleanup');
    }
    await _requireNoDrivers();
    await ownership.verify();
  }

  Future<void> _requireNoDrivers() async {
    if ((await readInventory()).countUnmanaged({}) != 0) {
      throw StateError('drivers remain after startup teardown');
    }
  }

  Future<void> _verifyRecord(DriverRuntimeMetadata expected) async {
    final vm = discovery.root.directory(expected.correlation.vmId.value);
    try {
      final generation = vm.directory(
        '${expected.correlation.driverGeneration}',
      );
      try {
        final current = await DriverRuntimeMetadata.readFrom(
          generation,
          correlation: expected.correlation,
          executable: expected.executable,
          bundlePath: expected.bundlePath,
        );
        if (current == null ||
            jsonEncode(current.toJson()) != jsonEncode(expected.toJson())) {
          throw StateError('runtime metadata changed during startup recovery');
        }
      } finally {
        generation.close();
      }
      await vm.verifyPathBinding();
    } finally {
      vm.close();
    }
    await discovery.root.verifyPathBinding();
  }
}
