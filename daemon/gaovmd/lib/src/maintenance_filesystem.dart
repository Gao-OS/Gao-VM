part of 'image_filesystem.dart';

/// No-follow presence lookup without requiring ownership of a normal startup's
/// parent directory. Dart's type() folds EACCES/other errors into notFound; an
/// unavailable maintenance namespace must never admit a writer.
bool maintenancePathEntryExists(String path) {
  final native = path.toNativeUtf8();
  final buffer = calloc<Uint8>(256);
  try {
    final stat = _libc
        .lookupFunction<
          Int32 Function(Int32, Pointer<Utf8>, Pointer<Uint8>, Int32),
          int Function(int, Pointer<Utf8>, Pointer<Uint8>, int)
        >(
          Platform.isMacOS && Abi.current() == Abi.macosX64
              ? 'fstatat\$INODE64'
              : 'fstatat',
        );
    if (stat(
          Platform.isMacOS ? -2 : -100,
          native,
          buffer,
          Platform.isMacOS ? 0x20 : 0x100,
        ) ==
        0)
      return true;
    final error = _currentErrno();
    if (error == 2) return false;
    throw FileSystemException(
      'maintenance namespace lookup unavailable',
      path,
      OSError('fstatat failed', error),
    );
  } finally {
    calloc.free(buffer);
    malloc.free(native);
  }
}

extension MaintenanceDirectoryCopy on OwnedImageDirectory {
  /// Nonblocking, no-follow acquisition without chmod of an existing inode.
  /// Maintenance refuses unknown lock contents, links, permissions or ACLs.
  Future<OwnedImageLock?> tryAcquireMaintenanceLock(
    String name, {
    bool create = true,
  }) {
    if (!Platform.isMacOS) {
      throw UnsupportedError('Darwin maintenance lock required');
    }
    return _acquireLock(name, wait: false, maintenance: true, create: create);
  }

  /// Bound directory identity, not a copy manifest: inode/device and birth time
  /// intentionally change when a snapshot is restored into another directory.
  Future<Map<String, Object?>> maintenanceIdentity() async {
    _requireOpen();
    final stat = _sourceStat(_fd, identity: true);
    final metadata = await maintenanceMetadata();
    return Map.unmodifiable({
      'device_major': stat.deviceMajor,
      'device_minor': stat.deviceMinor,
      'inode': stat.inode,
      'uid': stat.uid,
      'created': List<int>.unmodifiable(
        (metadata['created'] as List).cast<int>(),
      ),
    });
  }

  Future<Map<String, Object?>> maintenanceMetadata() {
    _requireOpen();
    return _maintenanceMetadata(_fd);
  }

  /// Inspect a known runtime socket without connecting, reading or unlinking.
  /// This binds one pathname observation, not socket liveness or cleanup rights.
  Future<Map<String, Object?>> maintenanceSocketMetadata(String name) async {
    _requireOpen();
    _validateChildName(name);
    if (!Platform.isMacOS)
      throw UnsupportedError('Darwin socket metadata required');
    await verifyPathBinding();
    final native = name.toNativeUtf8();
    final absolute = '$path/$name'.toNativeUtf8();
    final buffer = calloc<Uint8>(144);
    Pointer<Void> acl = nullptr;
    final entry = calloc<Pointer<Void>>();
    try {
      final stat = _libc
          .lookupFunction<
            Int32 Function(Int32, Pointer<Utf8>, Pointer<Uint8>, Int32),
            int Function(int, Pointer<Utf8>, Pointer<Uint8>, int)
          >(Abi.current() == Abi.macosX64 ? 'fstatat\$INODE64' : 'fstatat');
      Map<String, Object?> facts() {
        // AT_SYMLINK_NOFOLLOW; child lookup remains relative to the held parent.
        if (stat(_fd, native, buffer, 0x20) != 0) {
          throw FileSystemException(
            'cannot stat runtime socket',
            '$path/$name',
            OSError('fstatat failed', _currentErrno()),
          );
        }
        final value = ByteData.sublistView(buffer.asTypedList(144));
        final mode = value.getUint16(4, Endian.host);
        if (value.getUint32(16, Endian.host) != _getuid() ||
            mode & 0xf000 != 0xc000 ||
            mode & 0xc3f != 0 ||
            value.getUint16(6, Endian.host) < 1) {
          throw const FormatException('private owned runtime socket required');
        }
        return {
          'kind': 'socket',
          'device': value.getUint32(0, Endian.host),
          'inode': value.getUint64(8, Endian.host),
          'links': value.getUint16(6, Endian.host),
          'uid': value.getUint32(16, Endian.host),
          'gid': value.getUint32(20, Endian.host),
          'mode': mode & 0xfff,
          'flags': value.getUint32(116, Endian.host),
          for (final (key, offset) in [
            ('modified', 48),
            ('changed', 64),
            ('created', 80),
          ])
            key: [
              value.getInt64(offset, Endian.host),
              value.getInt64(offset + 8, Endian.host),
            ],
        };
      }

      final before = facts();
      // Sockets cannot be opened as ordinary files. The no-follow ACL lookup is
      // bracketed by parent binding and inode/stat checks, without a connection.
      acl = _libc
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>, Int32),
            Pointer<Void> Function(Pointer<Utf8>, int)
          >('acl_get_link_np')(absolute, 0x100);
      if (acl == nullptr && _currentErrno() != 2) {
        throw FileSystemException(
          'cannot inspect socket ACL',
          '$path/$name',
          OSError('acl_get_link_np failed', _currentErrno()),
        );
      }
      if (acl != nullptr &&
          _libc.lookupFunction<
                Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Void>>),
                int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
              >('acl_get_entry')(acl, 0, entry) ==
              0) {
        throw const FormatException('runtime socket grants ACL access');
      }
      if (jsonEncode(facts()) != jsonEncode(before)) {
        throw const FormatException('runtime socket changed during inspection');
      }
      await verifyPathBinding();
      return Map.unmodifiable({...before, 'has_acl': false});
    } finally {
      if (acl != nullptr)
        _libc.lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('acl_free')(acl);
      calloc.free(entry);
      calloc.free(buffer);
      malloc.free(absolute);
      malloc.free(native);
    }
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
