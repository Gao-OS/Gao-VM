part of 'image_filesystem.dart';

/// A failed move may already have renamed the directory (for example fsync or
/// post-move verification failed). Never infer a cleanup/rollback from this error.
final class MaintenanceDirectoryMoveFailure implements Exception {
  const MaintenanceDirectoryMoveFailure(
    this.sourcePath,
    this.destinationPath,
    this.cause,
  );
  final String sourcePath;
  final String destinationPath;
  final Object cause;
  @override
  String toString() =>
      'maintenance move unverified; inspect both $sourcePath and $destinationPath: $cause';
}

extension MaintenanceDirectoryMove on OwnedImageDirectory {
  /// Moves this exact inode between held same-user parent namespaces. The caller
  /// must serialize both namespaces, persist intent first, and retain its cold
  /// ownership/fence separately. This is NOT app/state replacement authority.
  ///
  /// Syncs both parents, never replaces a destination or falls back to copying.
  /// Returns a new bound reader; this borrowed reader keeps its OLD path and
  /// must be explicitly closed. On any failure, inspect both paths; never clean
  /// up or retry from the exception alone. No input handle is closed here.
  Future<OwnedImageDirectory> moveForMaintenanceTo(
    OwnedImageDirectory sourceParent,
    OwnedImageDirectory destinationParent,
    String destinationName,
  ) async {
    if (!Platform.isMacOS)
      throw UnsupportedError('Darwin maintenance move required');
    _requireOpen();
    sourceParent._requireOpen();
    destinationParent._requireOpen();
    _validateChildName(destinationName);
    final sourceName = path.startsWith('${sourceParent.path}/')
        ? path.substring(sourceParent.path.length + 1)
        : '';
    _validateChildName(sourceName);
    final destinationPath = '${destinationParent.path}/$destinationName';
    if (destinationPath == path ||
        destinationParent.path == path ||
        destinationParent.path.startsWith('$path/')) {
      throw const FormatException('maintenance move overlaps its source');
    }
    var sourceFd = -1, sourceParentFd = -1, destinationParentFd = -1;
    OwnedImageDirectory? output;
    try {
      await _verifyMaintenanceMoveParent(sourceParent);
      await _verifyMaintenanceMoveParent(destinationParent);
      await verifyPathBinding();
      if (_sourceStat(_fd).mode & 0xe12 != 0) {
        throw const FormatException(
          'unsafe maintenance move source permissions',
        );
      }
      sourceFd = _duplicateDescriptor(_fd);
      sourceParentFd = _duplicateDescriptor(sourceParent._fd);
      destinationParentFd = _duplicateDescriptor(destinationParent._fd);
      final heldSource = sourceFd,
          from = sourceParentFd,
          to = destinationParentFd;
      final sourcePath = path,
          fromPath = sourceParent.path,
          toPath = destinationParent.path;
      await Isolate.run(() {
        // No-follow opens relative to BOTH pinned parents; the named source must
        // still be this held inode immediately before the atomic no-replace move.
        _verifyMaintenanceMoveParentDescriptor(from, fromPath);
        _verifyMaintenanceMoveParentDescriptor(to, toPath);
        _verifyDescriptorPath(heldSource, sourcePath, directory: true);
        final entry = _openSource(sourceName, parent: from, directory: true);
        try {
          if (!_sameMaintenanceDirectory(entry.fd, heldSource)) {
            throw const FormatException('maintenance source identity changed');
          }
        } finally {
          _close(entry.fd);
        }
        final nativeSource = sourceName.toNativeUtf8();
        final nativeDestination = destinationName.toNativeUtf8();
        try {
          final rename = _libc
              .lookupFunction<
                Int32 Function(
                  Int32,
                  Pointer<Utf8>,
                  Int32,
                  Pointer<Utf8>,
                  Uint32,
                ),
                int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
              >('renameatx_np');
          if (rename(from, nativeSource, to, nativeDestination, 4) != 0) {
            // RENAME_EXCL
            throw FileSystemException(
              'cannot move maintenance directory without replacement',
              destinationPath,
              OSError('renameatx_np failed', _currentErrno()),
            );
          }
          final published = _openSource(
            destinationName,
            parent: to,
            directory: true,
          );
          try {
            if (!_sameMaintenanceDirectory(published.fd, heldSource)) {
              throw const FormatException(
                'maintenance move destination identity changed',
              );
            }
          } finally {
            _close(published.fd);
          }
          // A move changes TWO directory entries. A post-rename failure retains
          // the moved generation; it must not trigger an unjournaled reverse move.
          final destinationSynced = _fsync(to) == 0;
          final destinationError = destinationSynced ? 0 : _currentErrno();
          final sourceSynced = _fsync(from) == 0;
          if (!destinationSynced || !sourceSynced) {
            throw FileSystemException(
              'cannot sync both maintenance move parents',
              destinationPath,
              OSError(
                'fsync failed',
                destinationSynced ? _currentErrno() : destinationError,
              ),
            );
          }
          _verifyMaintenanceMoveParentDescriptor(from, fromPath);
          _verifyMaintenanceMoveParentDescriptor(to, toPath);
          _verifyDescriptorPath(heldSource, destinationPath, directory: true);
        } finally {
          malloc.free(nativeSource);
          malloc.free(nativeDestination);
        }
      });
      await _verifyMaintenanceMoveParent(sourceParent);
      await _verifyMaintenanceMoveParent(destinationParent);
      output = destinationParent.directory(destinationName);
      if (!_sameMaintenanceDirectory(output._fd, sourceFd)) {
        throw const FormatException(
          'maintenance moved reader identity changed',
        );
      }
      await output.verifyPathBinding();
      return output;
    } catch (error) {
      output?.close();
      throw MaintenanceDirectoryMoveFailure(path, destinationPath, error);
    } finally {
      if (destinationParentFd >= 0) _close(destinationParentFd);
      if (sourceParentFd >= 0) _close(sourceParentFd);
      if (sourceFd >= 0) _close(sourceFd);
    }
  }
}

bool _sameMaintenanceDirectory(int left, int right) {
  final a = _sourceStat(left, identity: true),
      b = _sourceStat(right, identity: true);
  return (a.deviceMajor, a.deviceMinor, a.inode, a.uid) ==
      (b.deviceMajor, b.deviceMinor, b.inode, b.uid);
}

void _verifyMaintenanceMoveParentDescriptor(int fd, String path) {
  _verifyDescriptorPath(fd, path, directory: true);
  final stat = _sourceStat(fd);
  if (stat.uid != _getuid() ||
      stat.mode & 0xe12 != 0 ||
      _darwinMetadata(fd)['has_acl'] != false) {
    throw const FormatException(
      'maintenance move parent permissions or ACL changed',
    );
  }
  _verifyDescriptorPath(fd, path, directory: true);
}

Future<void> _verifyMaintenanceMoveParent(OwnedImageDirectory parent) async {
  await parent.verifyPathBinding();
  if (await Directory(parent.path).resolveSymbolicLinks() != parent.path ||
      parent.mode & 0xe12 != 0 ||
      (await parent.maintenanceMetadata())['has_acl'] != false) {
    throw const FormatException(
      'canonical owned non-shared move parent without ACL grants required',
    );
  }
  await parent.verifyPathBinding();
}
