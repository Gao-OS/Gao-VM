import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

class AtomicJsonFile {
  AtomicJsonFile(this.path) : _syncDirectory = _PosixDirectoryFsync.bestEffort;

  /// Reports directory-sync failure even when rename has already published the
  /// new bytes. Callers must reconcile uncertain publication, not assume rollback.
  /// [syncDirectory] is the filesystem boundary for fault injection.
  AtomicJsonFile.durable(
    this.path, {
    FutureOr<void> Function(String)? syncDirectory,
  }) : _syncDirectory = syncDirectory ?? _PosixDirectoryFsync.requiredSync;

  final String path;
  final FutureOr<void> Function(String) _syncDirectory;

  Future<void> write(Map<String, Object?> jsonMap) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    final tmp = File(
      '${target.path}.tmp.${pid}.${DateTime.now().microsecondsSinceEpoch}',
    );
    final raf = await tmp.open(mode: FileMode.write);
    try {
      final bytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(jsonMap),
      );
      await raf.writeFrom(bytes);
      await raf.writeString('\n');
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(target.path);
    await _syncDirectory(target.parent.path);
  }
}

final class _PosixDirectoryFsync {
  static final bool _enabled = Platform.isLinux || Platform.isMacOS;
  static final ffi.DynamicLibrary _libc = Platform.isMacOS
      ? ffi.DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
      : ffi.DynamicLibrary.open('libc.so.6');
  static final int Function(ffi.Pointer<Utf8>, int) _open = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Int32),
        int Function(ffi.Pointer<Utf8>, int)
      >('open');
  static final int Function(int) _fsync = _libc
      .lookupFunction<ffi.Int32 Function(ffi.Int32), int Function(int)>(
        'fsync',
      );
  static final int Function(int) _close = _libc
      .lookupFunction<ffi.Int32 Function(ffi.Int32), int Function(int)>(
        'close',
      );

  static void bestEffort(String dirPath) {
    try {
      requiredSync(dirPath);
    } catch (_) {
      // Legacy callers retain best-effort directory sync.
    }
  }

  static void requiredSync(String dirPath) {
    if (!_enabled) {
      throw UnsupportedError('directory sync is unavailable');
    }
    final ptr = dirPath.toNativeUtf8();
    try {
      final fd = _open(ptr, 0);
      if (fd < 0) {
        throw FileSystemException('cannot open directory for sync', dirPath);
      }
      try {
        if (_fsync(fd) != 0) {
          throw FileSystemException('cannot sync directory', dirPath);
        }
      } finally {
        _close(fd);
      }
    } finally {
      calloc.free(ptr);
    }
  }
}
