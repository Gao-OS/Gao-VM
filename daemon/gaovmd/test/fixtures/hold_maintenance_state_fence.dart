import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:gaovmd/src/maintenance_state_fence.dart';

Future<void> main(List<String> args) async {
  final lease = await ColdStateLease.acquire(
    Directory(args[0]),
    bundleIdentifier: 'org.gaovm.tests.Fence',
    host: _Host(args[1]),
  );
  MaintenanceStateFence? fence;
  try {
    fence = await MaintenanceStateFence.begin(lease);
    stdout.writeln(fence.path);
    await stdin.drain<void>();
  } finally {
    fence?.close();
    lease.close();
  }
}

// Only external native observations are replaced; filesystem fencing and state
// ownership are real. This fixture never registers/stops a service or driver.
final class _Host implements ColdStateHost {
  _Host(this.appPath);
  @override
  final String appPath;
  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async =>
      DriverInventorySnapshot(processes: [], unresolvedProcessIds: []);
  @override
  Future<Set<int>> stateReferences(Directory state) async => {pid};
  @override
  Future<ProcessResult> serviceStatus() async => ProcessResult(
    pid,
    0,
    jsonEncode({
      'action': 'status',
      'bundle_identifier': 'org.gaovm.tests.Fence',
      'plist_name': 'gaovmd.plist',
      'authorization_state': 'notRegistered',
      'native_status': 0,
      'outcome': 'observed',
      'error_code': null,
    }),
    '',
  );
}
