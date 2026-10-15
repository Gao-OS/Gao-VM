import 'dart:io';

import 'cold_state_lease.dart';
import 'macos_driver_inventory.dart';
import 'macos_open_references.dart';
import 'macos_release_inspection.dart';
import 'maintenance_tree.dart';

/// Native read-only cold observations bound to one freshly inspected app.
/// No registration, stop, signal, replacement or catalog opening is performed.
final class MacOsColdStateHost implements ColdStateHost {
  MacOsColdStateHost._(this._app, this._manifest, this._host);
  final MaintenanceTree _app;
  final Map<String, Object?> _manifest;
  final ReleaseInspectionHost _host;
  @override
  String get appPath => _app.path;

  static Future<MacOsColdStateHost> open(
    Directory app, {
    required String bundleIdentifier,
    required String version,
    required String teamIdentifier,
    required int catalogSchema,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
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
      return MacOsColdStateHost._(tree, manifest, host);
    } catch (_) {
      tree.close();
      rethrow;
    }
  }

  @override
  Future<ProcessResult> serviceStatus() async {
    await _app.verify(_manifest);
    final result = await _host.run(
      '${_app.path}/Contents/MacOS/gaovm-service',
      ['status'],
    );
    await _app.verify(_manifest);
    return result;
  }

  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) =>
      MacOsDriverInventory(
        executablePath: driver
            ? '${_app.path}/Contents/Helpers/gaovm-driver-vz'
            : '${_app.path}/Contents/MacOS/gaovmd',
      ).snapshot();

  @override
  Future<Set<int>> stateReferences(Directory state) =>
      MacOsOpenReferences().directory(state);

  void close() => _app.close();
}
