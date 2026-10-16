import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/daemon_ownership.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/maintenance_state_fence.dart';

// Test-owned existing state only; never starts a daemon or removes its fence.
Future<void> main(List<String> arguments) async {
  final state = await OwnedImageDirectory.open(Directory(arguments[0]));
  final work = await OwnedImageDirectory.open(Directory(arguments[1]));
  MaintenanceStateFence? fence;
  DaemonOwnership? owner;
  final locks = <OwnedImageLock>[];
  try {
    fence = await MaintenanceStateFence.open(Directory(state.path));
    owner = await DaemonOwnership.tryAcquireForMaintenance(state, fence);
    if (owner == null) throw StateError('state still owned by parent');
    for (final name in [
      '.gaovm-cold-publication.lock',
      '.gaovm-upgrade.lock',
      '.gaovm-app-retirement.lock',
      '.gaovm-candidate-publication.lock',
    ]) {
      final lock = await work.tryAcquireMaintenanceLock(name, create: false);
      if (lock == null) throw StateError('namespace still owned by parent');
      locks.add(lock);
    }
    await owner.verify();
    await fence.verifyFor(state);
    for (final lock in locks) {
      lock.verifyPathBinding();
    }
    stdout.writeln(
      jsonEncode({'state_owned': true, 'namespace_locks': locks.length}),
    );
  } finally {
    for (final lock in locks.reversed) {
      lock.close();
    }
    owner?.close();
    fence?.close();
    work.close();
    state.close();
  }
}
