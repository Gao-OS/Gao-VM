import 'dart:io';

import 'cold_state_lease.dart' show ColdStateRestoration;
import 'image_filesystem.dart';
import 'maintenance_state_fence.dart';

/// Cooperative ownership of one private state directory. Keep it through
/// startup recovery and runtime shutdown; never unlink the persistent lock file.
final class DaemonOwnership {
  DaemonOwnership._(this._root, this._lock);
  OwnedImageDirectory _root;
  final OwnedImageLock _lock;
  bool _rebinding = false;
  bool _closed = false;

  String get stateDirectoryPath => _root.path;

  /// The caller keeps [root] open until ownership is released.
  static Future<DaemonOwnership?> tryAcquire(OwnedImageDirectory root) =>
      _tryAcquire(root);

  /// Recovery holds a verified sibling fence and still acquires the real state
  /// inode's kernel lock. This entry point never starts a daemon or clears it.
  static Future<DaemonOwnership?> tryAcquireForMaintenance(
    OwnedImageDirectory root,
    MaintenanceStateFence fence,
  ) => _tryAcquire(root, maintenanceFence: fence);

  /// Fixed restored-state recovery proves both complete generations before
  /// acquiring an EXISTING ownership file. It cannot recreate or normalize it.
  static Future<DaemonOwnership?> tryAcquireForRestoration(
    OwnedImageDirectory root,
    ColdStateRestoration restoration,
  ) async {
    await restoration.verifyOwnershipFor(root);
    if (root.mode & 0x3f != 0) {
      throw const FormatException('daemon state directory must be private');
    }
    final lock = await root.tryAcquireMaintenanceLock(
      '.gaovmd.lock',
      create: false,
    );
    if (lock == null) return null;
    try {
      await restoration.verifyOwnershipFor(root);
      final ownership = DaemonOwnership._(root, lock);
      await ownership.verify();
      return ownership;
    } catch (_) {
      lock.close();
      rethrow;
    }
  }

  static Future<DaemonOwnership?> _tryAcquire(
    OwnedImageDirectory root, {
    MaintenanceStateFence? maintenanceFence,
  }) async {
    Future<void> admission() => maintenanceFence == null
        ? MaintenanceStateFence.requireUnfenced(Directory(root.path))
        : maintenanceFence.verifyFor(root);
    await admission();
    if (root.mode & 0x3f != 0) {
      throw const FormatException('daemon state directory must be private');
    }
    await root.verifyPathBinding();
    final lock = await root.tryAcquireLock('.gaovmd.lock');
    if (lock == null) return null;
    try {
      await admission();
      final ownership = DaemonOwnership._(root, lock);
      await ownership.verify();
      return ownership;
    } catch (_) {
      lock.close();
      rethrow;
    }
  }

  Future<void> verify() async {
    if (_closed) throw StateError('daemon ownership is closed');
    if (_root.mode & 0x3f != 0) {
      throw const FormatException('daemon state directory must be private');
    }
    await _root.verifyPathBinding();
    _lock.verifyPathBinding();
  }

  /// Rebind only after this exact state inode was moved by its maintenance
  /// coordinator. This does not move it or authorize a rollback. Both borrowed
  /// readers must remain open until this future settles. An error retains the
  /// original kernel lock; callers must not retry by closing/reopening it.
  /// Ordinary admission still refuses fences. An explicit held destination
  /// fence must bind the exact moved inode, never a copied ownership file.
  Future<void> rebindAfterMaintenanceMove(
    OwnedImageDirectory moved, {
    MaintenanceStateFence? maintenanceFence,
  }) => _rebind(moved, () async {
    if (maintenanceFence == null) {
      await MaintenanceStateFence.requireUnfenced(Directory(moved.path));
    } else {
      if (maintenanceFence.retiredForCommit) {
        throw const FormatException('active relocation fence required');
      }
      await maintenanceFence.verifyFor(moved);
    }
  });

  /// Only the sealed restoration context can admit its exact replacement inode
  /// while the original ordinary-startup marker remains continuously present.
  Future<void> rebindAfterRestorationMove(
    OwnedImageDirectory moved,
    ColdStateRestoration restoration,
  ) => _rebind(moved, () => restoration.verifyFor(moved));

  Future<void> _rebind(
    OwnedImageDirectory moved,
    Future<void> Function() admission,
  ) async {
    if (_closed || _rebinding) {
      throw StateError('daemon ownership is unavailable');
    }
    _rebinding = true;
    try {
      if (moved.mode & 0x3f != 0) {
        throw const FormatException('daemon state directory must be private');
      }
      await admission();
      await moved.verifyPathBinding();
      _lock.rebindAfterMaintenanceMove(_root, moved);
      _root = moved;
      await verify();
      await admission();
    } finally {
      _rebinding = false;
    }
  }

  void close() {
    if (_rebinding) throw StateError('daemon ownership rebind is pending');
    if (_closed) return;
    _closed = true;
    _lock.close();
  }
}
