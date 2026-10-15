import 'dart:convert';
import 'dart:io';

import 'daemon_ownership.dart';
import 'image_filesystem.dart';
import 'macos_driver_inventory.dart';

/// External observations only. The native implementation binds these to the
/// previously inspected owning app; fixtures never register or stop services.
abstract interface class ColdStateHost {
  String get appPath;
  Future<ProcessResult> serviceStatus();
  Future<DriverInventorySnapshot> inventory({required bool driver});
  Future<Set<int>> stateReferences(Directory state);
}

final class ColdStateFailure implements Exception {
  const ColdStateFailure(this.stage, this.reason);
  final String stage;
  final String reason;
  @override
  String toString() => 'cold state refused ($stage): $reason';
}

/// A held, cooperative state lock plus fresh service/process/reference checks.
/// This is a precondition, NOT a complete cold snapshot/upgrade certificate:
/// catalog work, external disks and publication fencing need separate checks.
final class ColdStateLease {
  ColdStateLease._(
    this._root,
    this._ownership,
    this._bundleIdentifier,
    this._host,
  );
  final OwnedImageDirectory _root;
  final DaemonOwnership _ownership;
  final String _bundleIdentifier;
  final ColdStateHost _host;
  bool _closed = false;
  String get path => _root.path;
  String get appPath => _host.appPath;
  String get bundleIdentifier => _bundleIdentifier;

  static Future<ColdStateLease> acquire(
    Directory state, {
    required String bundleIdentifier,
    required ColdStateHost host,
  }) async {
    final broadRoots = {
      '/',
      await Directory.current.resolveSymbolicLinks(),
      await Directory.systemTemp.resolveSymbolicLinks(),
      if (Platform.environment['HOME'] case final String home) home,
    };
    if (!RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$',
        ).hasMatch(bundleIdentifier) ||
        bundleIdentifier.length > 255 ||
        broadRoots.contains(state.path) ||
        !host.appPath.startsWith('/') ||
        state.path == host.appPath ||
        state.path.startsWith('${host.appPath}/') ||
        host.appPath.startsWith('${state.path}/') ||
        state.path != state.absolute.path ||
        await state.resolveSymbolicLinks() != state.path ||
        await FileSystemEntity.type(state.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const ColdStateFailure(
        'inputs',
        'explicit canonical state required',
      );
    }
    final root = await OwnedImageDirectory.open(state);
    DaemonOwnership? ownership;
    try {
      if (root.path != state.path) {
        throw const ColdStateFailure('inputs', 'state canonical path changed');
      }
      ownership = await DaemonOwnership.tryAcquire(root);
      if (ownership == null) {
        throw const ColdStateFailure('ownership', 'state already has an owner');
      }
      final lease = ColdStateLease._(root, ownership, bundleIdentifier, host);
      await lease.verify();
      return lease;
    } catch (_) {
      ownership?.close();
      root.close();
      rethrow;
    }
  }

  /// Recheck at every preparation boundary. Failure retains ownership until
  /// explicit close; never automatically release a potentially active fence.
  Future<void> verify() async {
    if (_closed) throw StateError('cold state lease is closed');
    await _ownership.verify();
    await _verifyService();
    for (final driver in [false, true]) {
      final inventory = await _host.inventory(driver: driver);
      if (inventory.unresolvedProcessIds.isNotEmpty ||
          inventory.processes.isNotEmpty) {
        throw ColdStateFailure(
          driver ? 'driver_processes' : 'daemon_processes',
          'live or unresolved processes remain',
        );
      }
    }
    final references = await _host.stateReferences(Directory(path));
    if (references.any((process) => process != pid)) {
      throw const ColdStateFailure(
        'state_references',
        'other processes remain',
      );
    }
    await _verifyService();
    await _ownership.verify();
  }

  Future<void> _verifyService() async {
    final result = await _host.serviceStatus();
    final value = jsonDecode(result.stdout as String);
    final expected = {
      'action': 'status',
      'bundle_identifier': _bundleIdentifier,
      'plist_name': 'gaovmd.plist',
      'authorization_state': 'notRegistered',
      'native_status': 0,
      'outcome': 'observed',
      'error_code': null,
    };
    if (result.exitCode != 0 ||
        (result.stderr as String).isNotEmpty ||
        value is! Map<String, Object?> ||
        value['native_status'] is! int ||
        value.length != expected.length ||
        expected.entries.any(
          (entry) =>
              !value.containsKey(entry.key) || value[entry.key] != entry.value,
        )) {
      throw const ColdStateFailure(
        'service',
        'owning service is not confirmed unregistered',
      );
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _ownership.close();
    _root.close();
  }
}
