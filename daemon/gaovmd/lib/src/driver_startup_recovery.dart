import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'daemon_ownership.dart';
import 'driver_runtime_discovery.dart';
import 'driver_runtime_layout.dart';
import 'driver_runtime_metadata.dart';
import 'driver_startup_teardown.dart';
import 'image_filesystem.dart';
import 'macos_driver_inventory.dart';
import 'runtime_driver.dart';

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
    final emptyCleanup = await _restoreInterruptedCleanup();
    final emptyPaths = {
      for (final (vmId, name, _) in emptyCleanup)
        '${discovery.root.path}/${vmId == null ? '' : '${vmId.value}/'}$name',
    };
    final snapshot = await discovery.scan();
    final incomplete = <DriverCorrelation>[];
    for (final issue in snapshot.issues) {
      if (issue.kind == DriverDiscoveryIssueKind.unknownEntry &&
          emptyPaths.contains(issue.path))
        continue;
      final correlation = issue.correlation;
      if (issue.kind != DriverDiscoveryIssueKind.missingMetadata ||
          correlation == null ||
          issue.path != layout.paths(correlation).directory) {
        throw StateError('runtime discovery remains unresolved');
      }
      incomplete.add(correlation);
    }
    final paths = <(DriverRuntimeMetadata, DriverRuntimePaths)>[];
    for (final record in snapshot.records) {
      final recovered = await layout.recoverPaths(record.correlation);
      await _verifyRecord(record);
      paths.add((record, recovered));
    }
    final incompletePaths = <(DriverCorrelation, DriverRuntimePaths)>[];
    for (final correlation in incomplete) {
      final recovered = await layout.recoverPaths(correlation);
      await _verifyNoMetadata(correlation);
      incompletePaths.add((correlation, recovered));
    }
    final known = {
      for (final record in snapshot.records)
        if (record.processIdentity case final identity?) identity,
    };
    if ((await readInventory()).countUnmanaged(known) != 0) {
      throw StateError('unrecorded drivers prevent startup recovery');
    }
    await _teardown.terminateRecorded(
      DriverDiscoverySnapshot(snapshot.records, const []),
    );
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
    for (final (vmId, name, canonical) in emptyCleanup) {
      await ownership.verify();
      await _requireNoDrivers();
      final parent = vmId == null
          ? discovery.root
          : discovery.root.directory(vmId.value);
      try {
        final directory = parent.directory(name);
        try {
          if ((await _names(directory)).isNotEmpty ||
              await FileSystemEntity.type(
                    '${parent.path}/$canonical',
                    followLinks: false,
                  ) !=
                  FileSystemEntityType.notFound) {
            throw StateError('interrupted cleanup namespace changed');
          }
          await parent.verifyPathBinding();
          parent.removeDirectory(name);
          await parent.sync();
        } finally {
          directory.close();
        }
      } finally {
        if (vmId != null) parent.close();
      }
    }
    // No PID may be guessed for a crash-before-metadata directory. Complete
    // inventory must first prove that even unrecorded drivers are absent.
    for (final (correlation, expected) in incompletePaths) {
      await ownership.verify();
      await _requireNoDrivers();
      await _verifyNoMetadata(correlation);
      final current = await layout.recoverPaths(correlation);
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

  // Restore marked quarantines to their canonical paths before read-only
  // discovery. This preserves contents and lets metadata retain its original
  // socket binding. Empty, markerless final-rmdir remnants are deferred until
  // recorded teardown and complete inventory confirm that no driver remains.
  Future<List<(VmId?, String, String)>> _restoreInterruptedCleanup() async {
    final empty = <(VmId?, String, String)>[];
    for (final name in await _names(discovery.root)) {
      final match = _cleanupName.firstMatch(name);
      if (match == null) continue;
      final vmId = _vmIdOrNull(match[1]!);
      if (vmId == null || await discovery.resolveBinding(vmId) == null)
        continue;
      if (await _restoreCleanup(discovery.root, name, vmId.value, match[2]!)) {
        empty.add((null, name, vmId.value));
      }
    }
    for (final name in await _names(discovery.root)) {
      final vmId = _vmIdOrNull(name);
      if (vmId == null) continue;
      final binding = await discovery.resolveBinding(vmId);
      if (binding == null) continue;
      final vm = discovery.root.directory(name);
      try {
        for (final child in await _names(vm)) {
          final match = _cleanupName.firstMatch(child);
          if (match == null) continue;
          final generation = int.tryParse(match[1]!);
          if (generation == null ||
              generation <= 0 ||
              '$generation' != match[1] ||
              generation > binding.driverGeneration)
            continue;
          if (await _restoreCleanup(vm, child, '$generation', match[2]!)) {
            empty.add((vmId, child, '$generation'));
          }
        }
      } finally {
        vm.close();
      }
    }
    return empty;
  }

  // Returns true only for a verified empty final-rmdir remnant. No file is
  // removed here; nonempty directories require the exact empty owner marker.
  Future<bool> _restoreCleanup(
    OwnedImageDirectory parent,
    String name,
    String canonical,
    String token,
  ) async {
    await ownership.verify();
    final directory = parent.directory(name);
    try {
      final names = await _names(directory);
      if (await FileSystemEntity.type(
            '${parent.path}/$canonical',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw StateError('quarantine conflicts with a canonical runtime path');
      }
      if (names.isEmpty) return true;
      final markerName = '.gaovm-owner-$token';
      final markers = names
          .where((name) => name.startsWith('.gaovm-owner-'))
          .toList();
      if (markers.length != 1 || markers.single != markerName) {
        throw StateError('quarantine ownership token does not match');
      }
      final marker = directory.directory(markerName);
      try {
        if ((await _names(marker)).isNotEmpty) {
          throw StateError('quarantine ownership marker is not empty');
        }
      } finally {
        marker.close();
      }
      await directory.verifyPathBinding();
      await parent.verifyPathBinding();
      await parent.renameDirectoryNoReplace(name, canonical);
      return false;
    } finally {
      directory.close();
    }
  }

  Future<void> _requireNoDrivers() async {
    if ((await readInventory()).countUnmanaged({}) != 0) {
      throw StateError('drivers remain after startup teardown');
    }
  }

  Future<void> _verifyNoMetadata(DriverCorrelation correlation) async {
    final vm = discovery.root.directory(correlation.vmId.value);
    try {
      final generation = vm.directory('${correlation.driverGeneration}');
      try {
        final metadata = generation.fileOrNull('metadata.json');
        if (metadata != null) {
          metadata.close();
          throw StateError('runtime metadata appeared during startup recovery');
        }
        await generation.verifyPathBinding();
      } finally {
        generation.close();
      }
      await vm.verifyPathBinding();
    } finally {
      vm.close();
    }
    await discovery.root.verifyPathBinding();
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

final _cleanupName = RegExp(r'^(.*)\.cleanup\.([A-Za-z0-9_-]{32})$');

VmId? _vmIdOrNull(String name) {
  try {
    return VmId(name);
  } on FormatException {
    return null;
  }
}

Future<List<String>> _names(OwnedImageDirectory directory) async {
  if (directory.mode & 0x3f != 0) {
    throw const FormatException('runtime directory must be private');
  }
  await directory.verifyPathBinding();
  final names = <String>[];
  await for (final entry in Directory(
    directory.path,
  ).list(followLinks: false)) {
    if (names.length >= 4096)
      throw StateError('runtime discovery limit exceeded');
    names.add(entry.path.split('/').last);
  }
  await directory.verifyPathBinding();
  names.sort();
  return names;
}
