part of 'image_filesystem.dart';

extension MaintenanceDirectoryCopy on OwnedImageDirectory {
  Future<Map<String, Object?>> maintenanceMetadata() {
    _requireOpen();
    return _maintenanceMetadata(_fd);
  }

  /// Apply only to the caller's new, exclusively owned staging directory,
  /// after copying all its children so final directory times stay intact.
  Future<void> copyMetadataForMaintenance(
    OwnedImageDirectory destination,
  ) async {
    _requireOpen();
    destination._requireOpen();
    if (!Platform.isMacOS) throw UnsupportedError('Darwin metadata required');
    final sourceFd = _duplicateDescriptor(_fd);
    var destinationFd = -1;
    try {
      destinationFd = _duplicateDescriptor(destination._fd);
      final outputFd = destinationFd;
      await Isolate.run(
        () => _copyDarwinMaintenanceMetadata(sourceFd, outputFd),
      );
    } finally {
      if (destinationFd >= 0) _close(destinationFd);
      _close(sourceFd);
    }
  }
}

extension MaintenanceFileCopy on OwnedImageFile {
  Future<Map<String, Object?>> maintenanceMetadata() {
    _requireOpen();
    return _maintenanceMetadata(_fd);
  }

  /// Copy to a newly created child, retaining partial output on failure.
  /// Preserve Darwin metadata, not the private/sealed image-import policy.
  /// Callers serialize reads/copies of the held source and sync the parent.
  Future<void> copyForMaintenance(
    OwnedImageDirectory destination,
    String childName,
  ) async {
    _requireOpen();
    destination._requireOpen();
    _validateChildName(childName);
    if (!Platform.isMacOS) {
      throw UnsupportedError('Darwin maintenance copy required');
    }
    final sourceFd = _duplicateDescriptor(_fd);
    OwnedImageOutputFile? output;
    try {
      output = destination.createFile(childName);
      final outputFd = output._fd;
      final displayPath = output.path;
      await Isolate.run(() {
        final seek = _libc
            .lookupFunction<
              Int64 Function(Int32, Int64, Int32),
              int Function(int, int, int)
            >('lseek');
        final copy = _libc
            .lookupFunction<
              Int32 Function(Int32, Int32, Pointer<Void>, Uint32),
              int Function(int, int, Pointer<Void>, int)
            >('fcopyfile');
        // Duplicated descriptors share offsets; a prior hash/read may be at EOF.
        // COPYFILE_DATA | COPYFILE_DATA_SPARSE; metadata is applied below.
        if (seek(sourceFd, 0, 0) != 0 ||
            seek(outputFd, 0, 0) != 0 ||
            copy(sourceFd, outputFd, nullptr, 0x8 | (1 << 27)) != 0) {
          throw FileSystemException(
            'maintenance copy failed; partial output retained',
            displayPath,
            OSError('lseek/fcopyfile data failed', _currentErrno()),
          );
        }
        _copyDarwinMaintenanceMetadata(sourceFd, outputFd);
      });
    } finally {
      output?.close();
      _close(sourceFd);
    }
  }
}

void _copyDarwinMaintenanceMetadata(int source, int destination) {
  final statBuffer = calloc<Uint8>(144);
  final attributes = calloc<Uint8>(24);
  final times = calloc<Uint8>(48);
  try {
    final stat = _libc
        .lookupFunction<
          Int32 Function(Int32, Pointer<Uint8>),
          int Function(int, Pointer<Uint8>)
        >(Abi.current() == Abi.macosX64 ? 'fstat\$INODE64' : 'fstat');
    final copy = _libc
        .lookupFunction<
          Int32 Function(Int32, Int32, Pointer<Void>, Uint32),
          int Function(int, int, Pointer<Void>, int)
        >('fcopyfile');
    if (stat(source, statBuffer) != 0 ||
        copy(source, destination, nullptr, 5 /* ACL | XATTR */) != 0) {
      throw FileSystemException(
        'cannot copy maintenance ACL/xattrs',
        '',
        OSError('fstat/fcopyfile failed', _currentErrno()),
      );
    }
    final value = ByteData.sublistView(statBuffer.asTypedList(144));
    final chown = _libc
        .lookupFunction<
          Int32 Function(Int32, Uint32, Uint32),
          int Function(int, int, int)
        >('fchown');
    final flags = _libc
        .lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
          'fchflags',
        );
    final set = _libc
        .lookupFunction<
          Int32 Function(
            Int32,
            Pointer<Uint8>,
            Pointer<Uint8>,
            UintPtr,
            Uint32,
          ),
          int Function(int, Pointer<Uint8>, Pointer<Uint8>, int, int)
        >('fsetattrlist');
    ByteData.sublistView(attributes.asTypedList(24))
      ..setUint16(0, 5, Endian.host)
      ..setUint32(4, 0x200 | 0x400 | 0x1000, Endian.host);
    final timestamps = ByteData.sublistView(times.asTypedList(48));
    for (final (to, from) in [(0, 80), (16, 48), (32, 32)]) {
      timestamps.setInt64(to, value.getInt64(from, Endian.host), Endian.host);
      timestamps.setInt64(
        to + 8,
        value.getInt64(from + 8, Endian.host),
        Endian.host,
      );
    }
    if (chown(
              destination,
              value.getUint32(16, Endian.host),
              value.getUint32(20, Endian.host),
            ) !=
            0 ||
        _fchmod(destination, value.getUint16(4, Endian.host) & 0xfff) != 0 ||
        set(destination, attributes, times, 48, 0) != 0 ||
        flags(destination, value.getUint32(116, Endian.host)) != 0 ||
        _fsync(destination) != 0) {
      throw FileSystemException(
        'cannot preserve maintenance ownership/stat',
        '',
        OSError(
          'fchown/fchmod/fsetattrlist/fchflags/fsync failed',
          _currentErrno(),
        ),
      );
    }
  } finally {
    calloc.free(times);
    calloc.free(attributes);
    calloc.free(statBuffer);
  }
}

Future<Map<String, Object?>> _maintenanceMetadata(int descriptor) async {
  if (!Platform.isMacOS) throw UnsupportedError('Darwin metadata required');
  final fd = _duplicateDescriptor(descriptor);
  try {
    return await Isolate.run(() => _darwinMetadata(fd));
  } finally {
    _close(fd);
  }
}

Map<String, Object?> _darwinMetadata(int fd) {
  final buffer = calloc<Uint8>(144);
  final aclGet = _libc
      .lookupFunction<
        Pointer<Void> Function(Int32, Int32),
        Pointer<Void> Function(int, int)
      >('acl_get_fd_np');
  final aclFree = _libc
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('acl_free');
  var acl = aclGet(fd, 0x100); // ACL_TYPE_EXTENDED, not unsupported POSIX ACLs.
  final aclError = acl == nullptr ? _currentErrno() : 0;
  // filesec_get_property(FILESEC_ACL) reports ENOENT for an absent ACL on
  // this still-held descriptor. Other lookup errors remain unavailable.
  if (acl == nullptr && aclError == 2) {
    acl = _libc
        .lookupFunction<
          Pointer<Void> Function(Int32),
          Pointer<Void> Function(int)
        >('acl_init')(0);
  }
  try {
    final stat = _libc
        .lookupFunction<
          Int32 Function(Int32, Pointer<Uint8>),
          int Function(int, Pointer<Uint8>)
        >(Abi.current() == Abi.macosX64 ? 'fstat\$INODE64' : 'fstat');
    if (stat(fd, buffer) != 0 || acl == nullptr) {
      throw FileSystemException(
        'cannot read maintenance stat/ACL',
        '',
        OSError(
          acl == nullptr ? 'acl_get_fd_np failed' : 'fstat failed',
          acl == nullptr ? aclError : _currentErrno(),
        ),
      );
    }
    final bytes = ByteData.sublistView(buffer.asTypedList(144));
    final aclSize = _libc
        .lookupFunction<
          IntPtr Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('acl_size')(acl);
    if (aclSize < 1 || aclSize > 65536)
      throw const FormatException('maintenance ACL exceeds bounds');
    final serialized = calloc<Uint8>(aclSize);
    final entry = calloc<Pointer<Void>>();
    try {
      final count = _libc
          .lookupFunction<
            IntPtr Function(Pointer<Uint8>, Pointer<Void>, IntPtr),
            int Function(Pointer<Uint8>, Pointer<Void>, int)
          >('acl_copy_ext')(serialized, acl, aclSize);
      if (count != aclSize)
        throw const FormatException('maintenance ACL is incomplete');
      final hasEntry =
          _libc.lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Void>>),
            int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
          >('acl_get_entry')(acl, 0, entry) ==
          0;
      return Map.unmodifiable({
        'uid': bytes.getUint32(16, Endian.host),
        'gid': bytes.getUint32(20, Endian.host),
        'mode': bytes.getUint16(4, Endian.host) & 0xfff,
        'flags': bytes.getUint32(116, Endian.host),
        'modified': [
          bytes.getInt64(48, Endian.host),
          bytes.getInt64(56, Endian.host),
        ],
        'created': [
          bytes.getInt64(80, Endian.host),
          bytes.getInt64(88, Endian.host),
        ],
        'has_acl': hasEntry,
        'acl_digest': 'sha256:${sha256.convert(serialized.asTypedList(count))}',
        'xattrs': _darwinXattrs(fd),
      });
    } finally {
      calloc.free(entry);
      calloc.free(serialized);
    }
  } finally {
    if (acl != nullptr) aclFree(acl);
    calloc.free(buffer);
  }
}

Map<String, Object?> _darwinXattrs(int fd) {
  final list = _libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, UintPtr, Int32),
        int Function(int, Pointer<Uint8>, int, int)
      >('flistxattr');
  final get = _libc
      .lookupFunction<
        IntPtr Function(
          Int32,
          Pointer<Utf8>,
          Pointer<Uint8>,
          UintPtr,
          Uint32,
          Int32,
        ),
        int Function(int, Pointer<Utf8>, Pointer<Uint8>, int, int, int)
      >('fgetxattr');
  const options = 0x20; // Expose compression metadata instead of hiding it.
  final size = list(fd, nullptr, 0, options);
  if (size < 0 || size > 65536)
    throw const FormatException('maintenance xattr names exceed bounds');
  if (size == 0) return const {};
  final namesBuffer = calloc<Uint8>(size);
  try {
    if (list(fd, namesBuffer, size, options) != size)
      throw const FormatException('maintenance xattr names changed');
    final raw = utf8.decode(namesBuffer.asTypedList(size));
    if (!raw.endsWith('\x00'))
      throw const FormatException('maintenance xattr names are incomplete');
    final names = raw.substring(0, raw.length - 1).split('\x00')..sort();
    if (names.any((name) => name.isEmpty) ||
        names.toSet().length != names.length)
      throw const FormatException('maintenance xattr names are invalid');
    final result = <String, Object?>{};
    for (final name in names) {
      final native = name.toNativeUtf8();
      try {
        final valueSize = get(fd, native, nullptr, 0, 0, options);
        final fork = name == 'com.apple.ResourceFork';
        if (valueSize < 0 || valueSize > (fork ? 0xffffffff : 16 * 1024 * 1024))
          throw const FormatException('maintenance xattr value exceeds bounds');
        final capacity = fork ? 65536 : (valueSize == 0 ? 1 : valueSize);
        final value = calloc<Uint8>(capacity);
        try {
          final digest = _MaintenanceDigest();
          final sink = sha256.startChunkedConversion(digest);
          var offset = 0;
          do {
            final wanted = valueSize - offset < capacity
                ? valueSize - offset
                : capacity;
            final read = get(fd, native, value, wanted, offset, options);
            if (read != wanted)
              throw const FormatException('maintenance xattr value changed');
            sink.add(value.asTypedList(read));
            offset += read;
          } while (offset < valueSize);
          sink.close();
          if (get(fd, native, nullptr, 0, 0, options) != valueSize)
            throw const FormatException('maintenance xattr size changed');
          result[name] = Map<String, Object?>.unmodifiable({
            'size': valueSize,
            'digest': 'sha256:${digest.value!}',
          });
        } finally {
          calloc.free(value);
        }
      } finally {
        malloc.free(native);
      }
    }
    return Map.unmodifiable(result);
  } finally {
    calloc.free(namesBuffer);
  }
}

final class _MaintenanceDigest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
