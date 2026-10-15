import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'cold_state_lease.dart';
import 'image_filesystem.dart';
import 'macos_driver_inventory.dart';
import 'macos_open_references.dart';
import 'macos_release_inspection.dart';
import 'maintenance_tree.dart';
import 'maintenance_state_fence.dart';

part 'macos_app_retirement.dart';

/// Native read-only cold observations bound to one freshly inspected app.
/// No registration, stop, signal, replacement or catalog opening is performed.
final class MacOsColdStateHost implements ColdStateHost {
  MacOsColdStateHost._(
    this._app,
    this._release,
    this._host,
    this._observer,
    this._inventory, [
    this._retirement,
  ]);
  final MaintenanceTree _app;
  final Map<String, Object?> _release;
  final ReleaseInspectionHost _host;
  final MacOsOpenReferences _observer;
  final Future<DriverInventorySnapshot> Function(String) _inventory;
  final _AppRetirement? _retirement;
  @override
  String get appPath => _app.path;
  String get installationPath => _retirement?.sourceAppPath ?? appPath;
  bool get isRetired => _retirement != null;
  Map<String, Object?> get retirementEvidence {
    final retirement = _retirement;
    if (retirement == null) throw StateError('app has not been retired');
    return {
      'phase': 'old_app_retired',
      'source_app': installationPath,
      'retired_app': appPath,
      'journal_path': retirement._root.path,
      'intent_digest': 'sha256:${sha256.convert(retirement._bytes)}',
      'installed_candidate_published': false,
      'activation_authorized': false,
      'rollback_authorized': false,
    };
  }

  static Future<MacOsColdStateHost> open(
    Directory app, {
    required String bundleIdentifier,
    required String version,
    required String teamIdentifier,
    required int catalogSchema,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) async {
    final inspected = await inspectMacOsRelease(
      app,
      bundleIdentifier: bundleIdentifier,
      version: version,
      teamIdentifier: teamIdentifier,
      catalogSchema: catalogSchema,
      host: host,
    );
    final manifest = inspected['tree'] as Map<String, Object?>;
    final tree = await MaintenanceTree.open(app);
    try {
      await tree.verify(manifest);
      return MacOsColdStateHost._(
        tree,
        inspected,
        host,
        observer ?? MacOsOpenReferences(),
        inventory ??
            (path) => MacOsDriverInventory(executablePath: path).snapshot(),
      );
    } catch (_) {
      tree.close();
      rethrow;
    }
  }

  /// Explicit read-only recovery of the old-app retirement gap. No paths from
  /// the journal select targets; the caller supplies the original slot, state,
  /// fence, storage/name and expected release. Still needs the real state lock.
  static Future<MacOsColdStateHost> openRetired(
    Directory originalApp,
    Directory state,
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name, {
    required String bundleIdentifier,
    required String version,
    required String teamIdentifier,
    required int catalogSchema,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) => _AppRetirement.open(
    originalApp,
    state,
    fence,
    storage,
    name,
    bundleIdentifier: bundleIdentifier,
    version: version,
    teamIdentifier: teamIdentifier,
    catalogSchema: catalogSchema,
    host: host,
    observer: observer ?? MacOsOpenReferences(),
    inventory:
        inventory ??
        (path) => MacOsDriverInventory(executablePath: path).snapshot(),
  );

  @override
  Future<ProcessResult> serviceStatus() async {
    await _verifyApp();
    final result = await _host.run(
      '${_app.path}/Contents/MacOS/gaovm-service',
      ['status'],
    );
    await _verifyApp();
    return result;
  }

  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async {
    final processes = <DriverProcessIdentity>{};
    final unresolved = <int>{};
    for (final root in {installationPath, appPath}) {
      final result = await _inventory(
        driver
            ? '$root/Contents/Helpers/gaovm-driver-vz'
            : '$root/Contents/MacOS/gaovmd',
      );
      processes.addAll(result.processes);
      unresolved.addAll(result.unresolvedProcessIds);
    }
    return DriverInventorySnapshot(
      processes: processes,
      unresolvedProcessIds: unresolved,
    );
  }

  @override
  Future<Set<int>> stateReferences(Directory state) async {
    final references = await _observer.directory(state);
    if (isRetired) await _AppRetirement._noReferences(_observer, appPath);
    return references;
  }

  Future<void> _verifyApp() async {
    await _retirement?.verify(_app);
    await _app.verify(_release['tree'] as Map<String, Object?>);
  }

  /// Used only by a held cold lease. Returns a new owner of the retired app and
  /// journal readers; the old host is deliberately not silently rebased.
  Future<MacOsColdStateHost> retireForMaintenance(
    ColdStateLease state,
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name, {
    required Future<void> Function() verifyPreparedInputs,
  }) => _AppRetirement.create(
    this,
    state,
    fence,
    storage,
    name,
    verifyPreparedInputs: verifyPreparedInputs,
  );

  Future<void> verifyRetirementFor(
    OwnedImageDirectory state,
    MaintenanceStateFence fence, {
    required String bundleIdentifier,
    required String installationPath,
  }) async {
    final retirement = _retirement;
    if (retirement == null) throw StateError('retirement proof required');
    await fence.verifyFor(
      state,
      bundleIdentifier: bundleIdentifier,
      appPath: installationPath,
    );
    if (retirement._intent['source_state'] != state.path ||
        retirement._intent['fence_path'] != fence.path ||
        retirement.sourceAppPath != installationPath ||
        retirement._intent['bundle_identifier'] != bundleIdentifier ||
        jsonEncode(retirement._intent['state_identity']) !=
            jsonEncode(await state.maintenanceIdentity())) {
      throw const FormatException('retirement does not belong to held state');
    }
    await _verifyApp();
  }

  void close() {
    _app.close();
    _retirement?.close();
  }
}
