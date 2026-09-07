import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final _libc = DynamicLibrary.process();
final _open = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)
    >('open');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _fsync = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'fsync',
);
final _fchmod = _libc
    .lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
      'fchmod',
    );
final _fcntl = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)
    >('fcntl');
final _unlinkat = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32),
      int Function(int, Pointer<Utf8>, int)
    >('unlinkat');
final _fclonefileat = Platform.isMacOS
    ? _libc.lookupFunction<
        Int32 Function(Int32, Int32, Pointer<Utf8>, Uint32),
        int Function(int, int, Pointer<Utf8>, int)
      >('fclonefileat')
    : null;
final _errnoLocation = Platform.isMacOS
    ? _libc
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            '__error',
          )
    : Platform.isLinux
    ? _libc
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            '__errno_location',
          )
    : null;
final int Function(int, Pointer<Uint8>)? _filesystemStat = Platform.isMacOS
    ? _libc.lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >(Abi.current() == Abi.macosX64 ? 'fstatfs\$INODE64' : 'fstatfs')
    : Platform.isLinux
    ? _libc.lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >('fstatvfs')
    : null;
final _chmod = _libc
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Uint32),
      int Function(Pointer<Utf8>, int)
    >('chmod');
final _getuid = _libc.lookupFunction<Uint32 Function(), int Function()>(
  'getuid',
);

void imageFileMode(String path, int mode) {
  final native = path.toNativeUtf8();
  try {
    if (_chmod(native, mode) != 0)
      throw FileSystemException('cannot set image file permissions', path);
  } finally {
    malloc.free(native);
  }
}

/// Flush directory entries as well as file contents before committing catalog
/// visibility. Unsupported filesystems fail the import instead of weakening it.
void syncImageDirectory(String path) {
  final native = path.toNativeUtf8();
  var fd = -1;
  try {
    fd = _open(native, 0);
    if (fd < 0 || _fsync(fd) != 0)
      throw FileSystemException('cannot sync image directory', path);
  } finally {
    if (fd >= 0) _close(fd);
    malloc.free(native);
  }
}

final _openat = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32),
      int Function(int, Pointer<Utf8>, int)
    >('openat');
final _openatCreate = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32, VarArgs<(Uint32,)>),
      int Function(int, Pointer<Utf8>, int, int)
    >('openat');

int get _sourceFlags => Platform.isMacOS
    ? 0x0100 |
          0x0004 |
          0x1000000 // NOFOLLOW | NONBLOCK | CLOEXEC
    : 0x20000 | 0x0800 | 0x80000;
int get _directoryFlag => Platform.isMacOS ? 0x100000 : 0x10000;
int get _outputFlags => Platform.isMacOS
    ? 0x0001 | 0x0200 | 0x0800 | 0x0100 | 0x1000000
    : 0x0001 | 0x0040 | 0x0080 | 0x20000 | 0x80000;

/// An owned descriptor remains bound to its inode across pathname replacement.
/// Child opens are relative to the held directory, with symlinks disallowed.
final class OwnedImageDirectory {
  OwnedImageDirectory._(this._fd, this.path);
  final int _fd;
  final String path;
  bool _closed = false;

  static Future<OwnedImageDirectory> open(Directory directory) async {
    final path = await directory.resolveSymbolicLinks();
    final source = _openSource(path, directory: true);
    return OwnedImageDirectory._(source.fd, path);
  }

  OwnedImageDirectory directory(String name) {
    _requireOpen();
    return OwnedImageDirectory._(
      _openSource(name, parent: _fd, directory: true).fd,
      '$path/$name',
    );
  }

  OwnedImageFile file(String name) {
    _requireOpen();
    final source = _openSource(name, parent: _fd);
    return OwnedImageFile._(source.fd, '$path/$name', source.size);
  }

  OwnedImageOutputFile createFile(String childName) {
    _requireOpen();
    _validateChildName(childName);
    final nativeName = childName.toNativeUtf8();
    try {
      final fd = _openatCreate(_fd, nativeName, _outputFlags, 0x180);
      if (fd < 0) {
        throw FileSystemException(
          'cannot create owned image output',
          '$path/$childName',
          OSError('openat failed', _currentErrno()),
        );
      }
      if (_fchmod(fd, 0x180) != 0) {
        final error = _currentErrno();
        _close(fd);
        if (_unlinkat(_fd, nativeName, 0) != 0) {
          throw FileSystemException(
            'cannot set output permissions or remove the invalid output',
            '$path/$childName',
            OSError(
              'fchmod failed with errno $error; unlinkat failed',
              _currentErrno(),
            ),
          );
        }
        if (_fsync(_fd) != 0) {
          throw FileSystemException(
            'cannot set output permissions or sync its cleanup',
            '$path/$childName',
            OSError(
              'fchmod failed with errno $error; directory fsync failed',
              _currentErrno(),
            ),
          );
        }
        throw FileSystemException(
          'cannot set owned image output permissions',
          '$path/$childName',
          OSError('fchmod failed', error),
        );
      }
      return OwnedImageOutputFile._(fd, '$path/$childName');
    } finally {
      malloc.free(nativeName);
    }
  }

  void removeFile(String childName) {
    _requireOpen();
    _validateChildName(childName);
    final nativeName = childName.toNativeUtf8();
    try {
      if (_unlinkat(_fd, nativeName, 0) != 0) {
        throw FileSystemException(
          'cannot remove owned image output',
          '$path/$childName',
          OSError('unlinkat failed', _currentErrno()),
        );
      }
    } finally {
      malloc.free(nativeName);
    }
  }

  Future<void> sync() async {
    _requireOpen();
    final fd = _duplicateDescriptor(_fd);
    final displayPath = path;
    try {
      await Isolate.run(() {
        if (_fsync(fd) != 0) {
          throw FileSystemException(
            'cannot sync owned image directory',
            displayPath,
            OSError('fsync failed', _currentErrno()),
          );
        }
      });
    } finally {
      _close(fd);
    }
  }

  Future<int> availableBytes() async {
    _requireOpen();
    final fd = _duplicateDescriptor(_fd);
    final displayPath = path;
    try {
      return await Isolate.run(
        () => _availableBytesForDescriptor(fd, displayPath),
      );
    } finally {
      _close(fd);
    }
  }

  void _requireOpen() {
    if (_closed) throw StateError('image source directory is closed');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _close(_fd);
  }
}

final class OwnedImageOutputFile {
  OwnedImageOutputFile._(this._fd, this.path);

  final int _fd;
  final String path;
  bool _closed = false;
  bool _writerOpened = false;

  Future<RandomAccessFile> openWrite() {
    if (_closed) throw StateError('image output file is closed');
    if (_writerOpened)
      throw StateError('image output writer was already opened');
    _writerOpened = true;
    return File(
      Platform.isMacOS ? '/dev/fd/$_fd' : '/proc/self/fd/$_fd',
    ).open(mode: FileMode.writeOnly);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _close(_fd);
  }
}

final class OwnedImageFile {
  OwnedImageFile._(this._fd, this.path, this.size);
  final int _fd;
  final String path;
  final int size;
  bool _closed = false;

  static Future<OwnedImageFile> open(File file) async {
    final path = await file.resolveSymbolicLinks();
    final source = _openSource(path);
    return OwnedImageFile._(source.fd, path, source.size);
  }

  /// Dart's asynchronous IO opens a duplicate of this held descriptor, never
  /// the original user pathname. Keep the descriptor alive until consumption
  /// ends. Linux procfs and Darwin devfs expose the process's descriptor table.
  Stream<List<int>> openRead() {
    if (_closed) throw StateError('image source file is closed');
    return File(
      Platform.isMacOS ? '/dev/fd/$_fd' : '/proc/self/fd/$_fd',
    ).openRead();
  }

  Future<Uint8List> readBounded(int maximumBytes) async {
    if (size > maximumBytes) throw FormatException('manifest exceeds 1 MiB');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in openRead()) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw FormatException('manifest exceeds 1 MiB');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<bool> tryCloneTo(
    OwnedImageDirectory destination,
    String childName,
  ) async {
    _requireOpen();
    destination._requireOpen();
    _validateChildName(childName);
    if (!Platform.isMacOS) return false;

    final sourceFd = _duplicateDescriptor(_fd);
    final displayPath = '${destination.path}/$childName';
    var destinationFd = -1;
    try {
      destinationFd = _duplicateDescriptor(destination._fd);
      return await Isolate.run(
        () =>
            _cloneFileOnDarwin(sourceFd, destinationFd, childName, displayPath),
      );
    } finally {
      _close(sourceFd);
      if (destinationFd >= 0) _close(destinationFd);
    }
  }

  void _requireOpen() {
    if (_closed) throw StateError('image source file is closed');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _close(_fd);
  }
}

int _duplicateDescriptor(int fd) {
  final duplicate = _fcntl(
    fd,
    Platform.isMacOS ? 67 : 1030, // F_DUPFD_CLOEXEC
    0,
  );
  if (duplicate < 0) {
    throw FileSystemException(
      'cannot duplicate image descriptor',
      null,
      OSError('fcntl(F_DUPFD_CLOEXEC) failed', _currentErrno()),
    );
  }
  return duplicate;
}

bool _cloneFileOnDarwin(
  int sourceFd,
  int destinationFd,
  String childName,
  String displayPath,
) {
  final nativeName = childName.toNativeUtf8();
  var cloneFd = -1;
  var created = false;
  try {
    if (_fclonefileat!(sourceFd, destinationFd, nativeName, 0x2) != 0) {
      final error = _currentErrno();
      if (error == 45 || error == 18) return false; // ENOTSUP | EXDEV
      throw FileSystemException(
        'cannot clone owned image file',
        displayPath,
        OSError('fclonefileat failed', error),
      );
    }
    created = true;
    cloneFd = _openat(destinationFd, nativeName, _sourceFlags);
    if (cloneFd < 0) {
      _throwCloneFinalization('cannot open cloned image file', displayPath);
    }
    if (_fchmod(cloneFd, 0x180) != 0) {
      _throwCloneFinalization(
        'cannot set cloned image file permissions',
        displayPath,
      );
    }
    if (_fsync(cloneFd) != 0) {
      _throwCloneFinalization('cannot sync cloned image file', displayPath);
    }
    if (_fsync(destinationFd) != 0) {
      _throwCloneFinalization(
        'cannot sync cloned image directory',
        displayPath,
      );
    }
    return true;
  } catch (error, stackTrace) {
    if (created) {
      if (cloneFd >= 0) {
        _close(cloneFd);
        cloneFd = -1;
      }
      if (_unlinkat(destinationFd, nativeName, 0) != 0) {
        Error.throwWithStackTrace(
          FileSystemException(
            'clone finalization failed ($error) and the new file could not be removed',
            displayPath,
            OSError('unlinkat failed', _currentErrno()),
          ),
          stackTrace,
        );
      }
      if (_fsync(destinationFd) != 0) {
        Error.throwWithStackTrace(
          FileSystemException(
            'clone finalization failed ($error) and cleanup could not be synced',
            displayPath,
            OSError('directory fsync failed', _currentErrno()),
          ),
          stackTrace,
        );
      }
    }
    Error.throwWithStackTrace(error, stackTrace);
  } finally {
    if (cloneFd >= 0) _close(cloneFd);
    malloc.free(nativeName);
  }
}

Never _throwCloneFinalization(String message, String path) {
  throw FileSystemException(
    message,
    path,
    OSError('clone finalization syscall failed', _currentErrno()),
  );
}

int _currentErrno() => _errnoLocation?.call().value ?? 0;

int _availableBytesForDescriptor(int fd, String displayPath) {
  final stat = _filesystemStat;
  if (stat == null) {
    throw UnsupportedError('owned filesystem capacity is unavailable');
  }
  final buffer = calloc<Uint8>(4096);
  try {
    if (stat(fd, buffer) != 0) {
      throw FileSystemException(
        'cannot read owned image directory capacity',
        displayPath,
        OSError('filesystem stat failed', _currentErrno()),
      );
    }
    final bytes = ByteData.sublistView(buffer.asTypedList(4096));
    final blockSize = Platform.isMacOS
        ? bytes.getUint32(0, Endian.host)
        : bytes.getUint64(8, Endian.host);
    final availableBlocks = bytes.getUint64(
      Platform.isMacOS ? 24 : 32,
      Endian.host,
    );
    if (blockSize == 0) {
      throw FileSystemException(
        'owned image directory reported an invalid block size',
        displayPath,
      );
    }
    return blockSize * availableBlocks;
  } finally {
    calloc.free(buffer);
  }
}

void _validateChildName(String name) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains('\u0000')) {
    throw ArgumentError.value(name, 'childName', 'requires one child name');
  }
}

({int fd, int size}) _openSource(
  String path, {
  int? parent,
  bool directory = false,
}) {
  if (!Platform.isMacOS && !Platform.isLinux) {
    throw UnsupportedError('owned image sources require Darwin or Linux');
  }
  if (parent != null &&
      (path.isEmpty || path == '.' || path == '..' || path.contains('/'))) {
    throw ArgumentError.value(path, 'path', 'requires one child name');
  }
  final native = path.toNativeUtf8();
  var fd = -1;
  try {
    final flags = _sourceFlags | (directory ? _directoryFlag : 0);
    fd = parent == null ? _open(native, flags) : _openat(parent, native, flags);
    if (fd < 0)
      throw FileSystemException('cannot open owned image source', path);
    final stat = _sourceStat(fd);
    if (stat.uid != _getuid() ||
        stat.mode & 0xf000 != (directory ? 0x4000 : 0x8000)) {
      throw FileSystemException(
        'image source must be an owned ${directory ? 'directory' : 'regular file'}',
        path,
      );
    }
    return (fd: fd, size: stat.size);
  } catch (_) {
    if (fd >= 0) _close(fd);
    rethrow;
  } finally {
    malloc.free(native);
  }
}

({int mode, int uid, int size}) _sourceStat(int fd) {
  // Darwin stat64 is 144 bytes on supported 64-bit ABIs. Linux statx is a
  // stable 256-byte UAPI structure, avoiding architecture-specific struct stat.
  final buffer = calloc<Uint8>(256);
  try {
    final bytes = ByteData.sublistView(buffer.asTypedList(256));
    if (Platform.isMacOS) {
      final fstat = _libc
          .lookupFunction<
            Int32 Function(Int32, Pointer<Uint8>),
            int Function(int, Pointer<Uint8>)
          >(Abi.current() == Abi.macosX64 ? 'fstat\$INODE64' : 'fstat');
      if (fstat(fd, buffer) != 0)
        throw FileSystemException('cannot stat image descriptor');
      return (
        mode: bytes.getUint16(4, Endian.host),
        uid: bytes.getUint32(16, Endian.host),
        size: bytes.getInt64(96, Endian.host),
      );
    }
    final statx = _libc
        .lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Int32, Uint32, Pointer<Uint8>),
          int Function(int, Pointer<Utf8>, int, int, Pointer<Uint8>)
        >('statx');
    final empty = ''.toNativeUtf8();
    try {
      const mask = 0x001 | 0x008 | 0x200; // TYPE | UID | SIZE
      if (statx(fd, empty, 0x1000, mask, buffer) != 0 ||
          bytes.getUint32(0, Endian.host) & mask != mask) {
        throw FileSystemException('cannot stat image descriptor');
      }
      return (
        mode: bytes.getUint16(28, Endian.host),
        uid: bytes.getUint32(20, Endian.host),
        size: bytes.getUint64(40, Endian.host),
      );
    } finally {
      malloc.free(empty);
    }
  } finally {
    calloc.free(buffer);
  }
}

Future<void> requireImagePathOwner(String path) async {
  final args = Platform.isMacOS ? ['-f', '%u', path] : ['-c', '%u', '--', path];
  final result = await Process.run('/usr/bin/stat', args);
  if (result.exitCode != 0 ||
      int.tryParse((result.stdout as String).trim()) != _getuid())
    throw FileSystemException('image path must be owned by daemon user', path);
}
