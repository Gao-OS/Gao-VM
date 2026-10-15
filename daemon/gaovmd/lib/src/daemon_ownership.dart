import 'dart:io';

import 'image_filesystem.dart';
import 'maintenance_state_fence.dart';

/// Cooperative ownership of one private state directory. Keep it through
/// startup recovery and runtime shutdown; never unlink the persistent lock file.
final class DaemonOwnership {
  DaemonOwnership._(this._root, this._lock);
  final OwnedImageDirectory _root;
  final OwnedImageLock _lock;
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

  void close() {
    if (_closed) return;
    _closed = true;
    _lock.close();
  }
}
