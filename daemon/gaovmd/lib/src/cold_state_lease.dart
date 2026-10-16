import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'daemon_ownership.dart';
import 'image_filesystem.dart';
import 'macos_driver_inventory.dart';
import 'macos_cold_state_host.dart';
import 'maintenance_state_fence.dart';
import 'maintenance_tree.dart';

part 'cold_state_preservation.dart';
part 'cold_state_restoration.dart';
part 'cold_app_restoration.dart';
part 'cold_rollback_commit.dart';

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
    this._maintenanceFence,
  ) : installationPath = _host is MacOsColdStateHost
          ? _host.installationPath
          : _host.appPath;
  // Recovery builds filesystem proof before acquiring owners or opening native
  // hosts. This private shell is always consumed/closed to public lease APIs.
  ColdStateLease._unowned(
    this._root,
    this._bundleIdentifier,
    this.installationPath,
  ) : _maintenanceFence = null,
      _closed = true;
  final OwnedImageDirectory _root;
  late final DaemonOwnership _ownership;
  final String _bundleIdentifier;
  late ColdStateHost _host;
  MaintenanceStateFence? _maintenanceFence;
  MacOsColdStateHost? _ownedRetiredHost;
  bool _retiring = false;
  bool _closed = false;
  PreservedColdState? _pendingPreservation;
  ColdStateRestoration? _pendingRestoration;
  String get path => _root.path;
  String get appPath => _host.appPath;

  /// Fixed logical installation slot; [appPath] is the currently observed app.
  final String installationPath;
  String get bundleIdentifier => _bundleIdentifier;

  /// Scoped borrow for the installed candidate composition, not a raw owner
  /// getter or an ordinary-startup bypass. The callback must drain all work
  /// before returning and must not close or retain the borrowed resources.
  Future<T> withCandidateState<T>(
    Future<T> Function(OwnedImageDirectory root, DaemonOwnership ownership)
    action,
  ) async {
    final host = _host;
    if (_closed ||
        _retiring ||
        host is! MacOsColdStateHost ||
        !host.isValidatingCandidate ||
        _maintenanceFence == null) {
      throw StateError('executing published candidate and held fence required');
    }
    _retiring = true;
    try {
      await verify();
      return await action(_root, _ownership);
    } finally {
      try {
        await _ownership.verify();
      } finally {
        _retiring = false;
      }
    }
  }

  static Future<ColdStateLease> acquire(
    Directory state, {
    required String bundleIdentifier,
    required ColdStateHost host,
    MaintenanceStateFence? maintenanceFence,
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
      if (maintenanceFence != null) {
        await maintenanceFence.verifyFor(
          root,
          bundleIdentifier: bundleIdentifier,
          appPath: host is MacOsColdStateHost
              ? host.installationPath
              : host.appPath,
        );
      }
      if (host is MacOsColdStateHost && host.isRetired) {
        if (maintenanceFence == null) {
          throw const FormatException('retired app requires its held fence');
        }
        await host.verifyRetirementFor(
          root,
          maintenanceFence,
          bundleIdentifier: bundleIdentifier,
          installationPath: host.installationPath,
        );
      }
      ownership = maintenanceFence == null
          ? await DaemonOwnership.tryAcquire(root)
          : await DaemonOwnership.tryAcquireForMaintenance(
              root,
              maintenanceFence,
            );
      if (ownership == null) {
        throw const ColdStateFailure('ownership', 'state already has an owner');
      }
      final lease = ColdStateLease._(
        root,
        ownership,
        bundleIdentifier,
        host,
        maintenanceFence,
      );
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
    await _maintenanceFence?.verifyFor(
      _root,
      bundleIdentifier: _bundleIdentifier,
      appPath: installationPath,
    );
    await _ownership.verify();
    await _verifyRetirement();
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
    await _maintenanceFence?.verifyFor(
      _root,
      bundleIdentifier: _bundleIdentifier,
      appPath: installationPath,
    );
    await _verifyRetirement();
  }

  Future<void> _verifyRetirement() async {
    final host = _host;
    if (host is MacOsColdStateHost && host.isRetired) {
      final fence = _maintenanceFence;
      if (fence == null) throw StateError('retirement fence is missing');
      await host.verifyRetirementFor(
        _root,
        fence,
        bundleIdentifier: _bundleIdentifier,
        installationPath: installationPath,
      );
    }
  }

  /// Consumes the new native host while retaining this exact state kernel lock.
  /// Failure retains the lock, marker and all app/journal bytes, including when
  /// the physical rename completed before a later verification failed.
  /// The preparation coordinator's callback must re-read all persistent and
  /// external inputs/output using filesystem checks only, after native observers.
  Future<Map<String, Object?>> retireApp(
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name, {
    required Future<void> Function() verifyPreparedInputs,
  }) async {
    if (_closed || _retiring) throw StateError('cold lease is unavailable');
    final host = _host;
    if (host is! MacOsColdStateHost || host.isRetired) {
      throw StateError('fresh native owning-app host required');
    }
    _retiring = true;
    try {
      await verify();
      await fence.verifyFor(
        _root,
        bundleIdentifier: _bundleIdentifier,
        appPath: installationPath,
      );
      _maintenanceFence = fence;
      final retired = await host.retireForMaintenance(
        this,
        fence,
        storage,
        name,
        verifyPreparedInputs: verifyPreparedInputs,
      );
      _ownedRetiredHost = retired;
      _host = retired;
      await verify();
      return retired.retirementEvidence;
    } finally {
      _retiring = false;
    }
  }

  /// Explicit recovery after a move completed but this lease's old host could
  /// not finish inspection. Consumes the freshly reopened typed host only after
  /// it matches the original slot, state inode, held fence and retained lock.
  /// No ownership release/reacquire window and no arbitrary path override.
  Future<void> adoptRetiredApp(
    MacOsColdStateHost retired,
    MaintenanceStateFence fence,
  ) async {
    if (_closed ||
        _retiring ||
        !retired.isRetired ||
        _host is! MacOsColdStateHost ||
        (_host as MacOsColdStateHost).isRetired) {
      throw StateError('original held native lease and retired host required');
    }
    _retiring = true;
    try {
      await _ownership.verify();
      await retired.verifyRetirementFor(
        _root,
        fence,
        bundleIdentifier: _bundleIdentifier,
        installationPath: installationPath,
      );
      await _ownership.verify();
      _maintenanceFence = fence;
      _ownedRetiredHost = retired;
      _host = retired;
      await verify();
    } finally {
      _retiring = false;
    }
  }

  /// Publish an independent candidate copy into the original installation slot.
  /// Retains this exact state owner, old app and startup fence on every failure.
  /// This neither activates the candidate nor authorizes commit or rollback.
  Future<Map<String, Object?>> publishCandidate(
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name,
    Directory candidate, {
    required String version,
    required int catalogSchema,
    required Map<String, Object?> candidateManifest,
    required Future<void> Function() verifyPreparedInputs,
  }) async {
    if (_closed || _retiring) throw StateError('cold lease is unavailable');
    final host = _host;
    if (host is! MacOsColdStateHost || !host.isRetired) {
      throw StateError('held retired native app required');
    }
    _retiring = true;
    try {
      await verify();
      await fence.verifyFor(
        _root,
        bundleIdentifier: _bundleIdentifier,
        appPath: installationPath,
      );
      return await host.publishForMaintenance(
        this,
        fence,
        storage,
        name,
        candidate,
        version: version,
        catalogSchema: catalogSchema,
        candidateManifest: candidateManifest,
        verifyPreparedInputs: verifyPreparedInputs,
      );
    } finally {
      _retiring = false;
    }
  }

  Future<void> _verifyService({ColdStateHost? observer}) async {
    final result = await (observer ?? _host).serviceStatus();
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

  /// Explicit final cold-commit boundary, not service registration/activation.
  /// The callback closes the complete prepared read set after native observers.
  /// Closing this lease is refused until the original action has settled.
  Future<void> commitStartupFence(
    MaintenanceStateFence fence,
    OwnedImageDirectory checkpoint, {
    required Future<void> Function() verifyPreparedInputs,
  }) async {
    if (_closed || _retiring) throw StateError('cold lease is unavailable');
    _retiring = true;
    try {
      await verify();
      await fence.verifyFor(
        _root,
        bundleIdentifier: _bundleIdentifier,
        appPath: installationPath,
      );
      _maintenanceFence = fence;
      await verifyPreparedInputs();
      await _ownership.verify();
      await fence.retireToCommit(_root, checkpoint);
      await _ownership.verify();
    } finally {
      _retiring = false;
    }
  }

  /// Preserve this whole generation at a fixed private child under a second
  /// persistent fence. Consumes this lease only on success, keeping the exact
  /// kernel owner. On failure retain this lease until explicit close/recovery.
  Future<PreservedColdState> preserveForRollback(
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name, {
    required Future<void> Function() verifyPreparedInputs,
  }) async {
    if (_closed ||
        _retiring ||
        _pendingPreservation != null ||
        (_host is MacOsColdStateHost &&
            (_host as MacOsColdStateHost).isValidatingCandidate)) {
      throw StateError('available non-executing cold state required');
    }
    _retiring = true;
    try {
      return await PreservedColdState._create(
        this,
        fence,
        storage,
        name,
        verifyPreparedInputs,
      );
    } finally {
      _retiring = false;
    }
  }

  /// Install this independently verified old state at the preserved generation's
  /// original slot, keeping both owners and fences. The caller proves the old
  /// app/state pair and external inputs in the filesystem-only callback and
  /// keeps borrowed native hosts alive. This does not restore an app or commit.
  Future<ColdStateRestoration> restoreForRollback(
    PreservedColdState current,
    OwnedImageDirectory storage,
    String name, {
    required Future<void> Function() verifyPreparedInputs,
  }) async {
    if (_closed ||
        _retiring ||
        _pendingPreservation != null ||
        _pendingRestoration != null ||
        _maintenanceFence != null ||
        current._closed ||
        current._busy ||
        !current._ownsState ||
        identical(this, current._source) ||
        bundleIdentifier != current._source.bundleIdentifier ||
        (_host is MacOsColdStateHost &&
            (_host as MacOsColdStateHost).isValidatingCandidate)) {
      throw StateError('available old state and preserved generation required');
    }
    _retiring = true;
    try {
      await current.verify();
      current._busy = true;
      try {
        return await ColdStateRestoration._create(
          this,
          current,
          storage,
          name,
          verifyPreparedInputs,
        );
      } finally {
        current._busy = false;
      }
    } finally {
      _retiring = false;
    }
  }

  void close() {
    if (_closed) return;
    if (_retiring)
      throw StateError('await pending app maintenance before close');
    _closed = true;
    try {
      _ownership.close();
    } finally {
      _root.close();
      _ownedRetiredHost?.close();
      _pendingPreservation?._closeUntransferred();
      _pendingRestoration?._closeUntransferred();
    }
  }
}
