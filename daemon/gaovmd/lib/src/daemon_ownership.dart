import 'image_filesystem.dart';

/// Cooperative ownership of one private state directory. Keep it through
/// startup recovery and runtime shutdown; never unlink the persistent lock file.
final class DaemonOwnership {
  DaemonOwnership._(this._root, this._lock);
  final OwnedImageDirectory _root;
  final OwnedImageLock _lock;
  bool _closed = false;

  String get stateDirectoryPath => _root.path;

  /// The caller keeps [root] open until ownership is released.
  static Future<DaemonOwnership?> tryAcquire(OwnedImageDirectory root) async {
    if (root.mode & 0x3f != 0) {
      throw const FormatException('daemon state directory must be private');
    }
    await root.verifyPathBinding();
    final lock = await root.tryAcquireLock('.gaovmd.lock');
    if (lock == null) return null;
    try {
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
