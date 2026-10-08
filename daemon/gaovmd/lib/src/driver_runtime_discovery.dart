import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'driver_runtime_metadata.dart';
import 'image_filesystem.dart';
import 'runtime_driver.dart';

final class DriverRecoveryBinding {
  const DriverRecoveryBinding({
    required this.driverGeneration,
    required this.executable,
    required this.bundlePath,
  });
  final int driverGeneration;
  final String executable;
  final String bundlePath;
}

enum DriverDiscoveryIssueKind {
  unknownEntry,
  missingMetadata,
  invalidMetadata,
  missingCatalogBinding,
}

final class DriverDiscoveryIssue {
  const DriverDiscoveryIssue(this.path, this.kind, {this.correlation});
  final String path;
  final DriverDiscoveryIssueKind kind;
  // Only a catalog-bound, canonical generation with absent metadata receives
  // this identity. Absence never supplies process identity or signal authority.
  final DriverCorrelation? correlation;
}

final class DriverDiscoverySnapshot {
  DriverDiscoverySnapshot(
    Iterable<DriverRuntimeMetadata> records,
    Iterable<DriverDiscoveryIssue> issues,
  ) : records = List.unmodifiable(records),
      issues = List.unmodifiable(issues);
  final List<DriverRuntimeMetadata> records;
  final List<DriverDiscoveryIssue> issues;
}

/// Read-only catalog-bound discovery. Startup recovery holds exclusive ownership;
/// live diagnostics may observe concurrent generation changes. Neither use
/// supplies authorization to signal a PID.
final class DriverRuntimeDiscovery {
  DriverRuntimeDiscovery({
    required this.root,
    required this.resolveBinding,
    Set<String> reservedNames = const {'api.sock'},
  }) : reservedNames = Set.unmodifiable(reservedNames) {
    if (reservedNames.any(
      (name) =>
          name.isEmpty || name.contains('/') || name == '.' || name == '..',
    )) {
      throw ArgumentError(
        'reserved runtime names must be single path components',
      );
    }
  }
  final OwnedImageDirectory root;
  final Future<DriverRecoveryBinding?> Function(VmId) resolveBinding;

  /// Live diagnostics pass only the verified current API socket link names.
  /// Startup retains its existing reservation and exclusive ownership contract.
  final Set<String> reservedNames;

  Future<DriverDiscoverySnapshot> scan() async {
    final records = <DriverRuntimeMetadata>[];
    final issues = <DriverDiscoveryIssue>[];
    for (final name in await _names(root)) {
      if (reservedNames.contains(name)) continue;
      final VmId vmId;
      try {
        vmId = VmId(name);
      } on FormatException {
        issues.add(
          DriverDiscoveryIssue(
            '${root.path}/$name',
            DriverDiscoveryIssueKind.unknownEntry,
          ),
        );
        continue;
      }
      final binding = await resolveBinding(vmId);
      if (binding == null) {
        issues.add(
          DriverDiscoveryIssue(
            '${root.path}/$name',
            DriverDiscoveryIssueKind.missingCatalogBinding,
          ),
        );
        continue;
      }
      OwnedImageDirectory? vm;
      try {
        vm = root.directory(name);
        for (final generationName in await _names(vm)) {
          if (_ownerMarker.hasMatch(generationName) &&
              await _isMarker(vm, generationName))
            continue;
          final generation = int.tryParse(generationName);
          final path = '${vm.path}/$generationName';
          if (generation == null ||
              generation <= 0 ||
              '$generation' != generationName ||
              generation > binding.driverGeneration) {
            issues.add(
              DriverDiscoveryIssue(path, DriverDiscoveryIssueKind.unknownEntry),
            );
            continue;
          }
          OwnedImageDirectory? directory;
          try {
            directory = vm.directory(generationName);
            final record = await DriverRuntimeMetadata.readFrom(
              directory,
              correlation: DriverCorrelation(
                vmId: vmId,
                driverGeneration: generation,
                operationId: null,
              ),
              executable: binding.executable,
              bundlePath: binding.bundlePath,
            );
            if (record == null) {
              issues.add(
                DriverDiscoveryIssue(
                  path,
                  DriverDiscoveryIssueKind.missingMetadata,
                  correlation: DriverCorrelation(
                    vmId: vmId,
                    driverGeneration: generation,
                    operationId: null,
                  ),
                ),
              );
            } else {
              records.add(record);
            }
          } on FormatException {
            issues.add(
              DriverDiscoveryIssue(
                path,
                DriverDiscoveryIssueKind.invalidMetadata,
              ),
            );
          } on FileSystemException {
            issues.add(
              DriverDiscoveryIssue(
                path,
                DriverDiscoveryIssueKind.invalidMetadata,
              ),
            );
          } finally {
            directory?.close();
          }
        }
      } on FileSystemException {
        issues.add(
          DriverDiscoveryIssue(
            '${root.path}/$name',
            DriverDiscoveryIssueKind.invalidMetadata,
          ),
        );
      } on FormatException {
        issues.add(
          DriverDiscoveryIssue(
            '${root.path}/$name',
            DriverDiscoveryIssueKind.invalidMetadata,
          ),
        );
      } finally {
        vm?.close();
      }
    }
    await root.verifyPathBinding();
    return DriverDiscoverySnapshot(records, issues);
  }
}

final _ownerMarker = RegExp(r'^\.gaovm-owner-[A-Za-z0-9_-]{32}$');

Future<bool> _isMarker(OwnedImageDirectory parent, String name) async {
  OwnedImageDirectory? marker;
  try {
    marker = parent.directory(name);
    return (await _names(marker)).isEmpty;
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  } finally {
    marker?.close();
  }
}

Future<List<String>> _names(OwnedImageDirectory directory) async {
  if (directory.mode & 0x3f != 0)
    throw const FormatException('runtime directory must be private');
  await directory.verifyPathBinding();
  final names = <String>[];
  await for (final entry in Directory(
    directory.path,
  ).list(followLinks: false)) {
    if (names.length >= 4096)
      throw StateError('runtime directory exceeds discovery limit');
    names.add(entry.path.split('/').last);
  }
  await directory.verifyPathBinding();
  names.sort();
  return names;
}
