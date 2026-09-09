import 'dart:io';

import 'daemon_ownership.dart';
import 'driver_runtime_discovery.dart';
import 'driver_runtime_metadata.dart';
import 'macos_driver_inventory.dart';

/// Stops only catalog-bound records supplied by startup discovery. Successful
/// completion is not proof about unrecorded processes, files, or host leases.
final class DriverStartupTeardown {
  DriverStartupTeardown({
    required this.ownership,
    this.orphanGrace = const Duration(seconds: 20),
    this.terminateGrace = const Duration(seconds: 5),
    this.killGrace = const Duration(seconds: 5),
  }) {
    if (orphanGrace <= Duration.zero ||
        terminateGrace <= Duration.zero ||
        killGrace <= Duration.zero) {
      throw ArgumentError('startup teardown deadlines must be positive');
    }
  }

  final DaemonOwnership ownership;
  final Duration orphanGrace;
  final Duration terminateGrace;
  final Duration killGrace;

  Future<void> terminateRecorded(DriverDiscoverySnapshot discovery) async {
    await ownership.verify();
    if (discovery.issues.isNotEmpty)
      throw StateError('runtime discovery remains unresolved');
    final pids = <int>{};
    for (final record in discovery.records) {
      final identity = record.processIdentity;
      if (identity == null || identity.pidVersion == null) {
        throw StateError('runtime metadata lacks versioned process identity');
      }
      if (!pids.add(identity.pid))
        throw StateError('runtime records claim the same PID');
    }
    // Drain every started task even if one fails. The owner must remain held
    // while another VM still has a signal or exit observation in flight.
    await Future.wait([
      for (final record in discovery.records) _terminate(record),
    ]);
    await ownership.verify();
  }

  Future<void> _terminate(DriverRuntimeMetadata record) async {
    final identity = record.processIdentity!;
    await ownership.verify();
    var observation = await MacOsDriverExit.waitForExit(identity, orphanGrace);
    for (final stage in [
      (ProcessSignal.sigterm, terminateGrace),
      (ProcessSignal.sigkill, killGrace),
    ]) {
      if (observation == DriverExitObservation.exited) return;
      if (observation == DriverExitObservation.identityChanged) {
        throw StateError(
          'runtime identity changed for ${record.correlation.vmId} generation ${record.correlation.driverGeneration}',
        );
      }
      await ownership.verify();
      // Neither a delivered signal nor an absent signal target proves exit.
      await MacOsDriverSignaler.signal(identity, stage.$1);
      observation = await MacOsDriverExit.waitForExit(identity, stage.$2);
    }
    if (observation != DriverExitObservation.exited) {
      throw StateError(
        'runtime exit unconfirmed for ${record.correlation.vmId} generation ${record.correlation.driverGeneration}: ${observation.name}',
      );
    }
  }
}
