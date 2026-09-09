import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'atomic_json_file.dart';
import 'driver_runtime_metadata.dart';
import 'image_filesystem.dart';
import 'macos_driver_inventory.dart';
import 'runtime_driver.dart';

final class DriverRuntimePaths {
  const DriverRuntimePaths({
    required this.directory,
    required this.socketPath,
    required this.metadataPath,
    this.cleanupToken,
    this.vmCleanupToken,
  });

  final String directory;
  final String socketPath;
  final String metadataPath;
  final String? cleanupToken;
  final String? vmCleanupToken;
}

final class DriverRuntimeLayout {
  DriverRuntimeLayout(
    this.runRoot, {
    Random? secureRandom,
    FutureOr<void> Function(String)? metadataDirectorySync,
  }) : _random = secureRandom ?? Random.secure(),
       _metadataDirectorySync = metadataDirectorySync {
    if (!runRoot.startsWith('/')) {
      throw ArgumentError.value(runRoot, 'runRoot', 'must be absolute');
    }
  }

  final String runRoot;
  final Random _random;
  final FutureOr<void> Function(String)? _metadataDirectorySync;

  DriverRuntimePaths paths(DriverCorrelation correlation) {
    final directory =
        '$runRoot/${correlation.vmId.value}/${correlation.driverGeneration}';
    final socketPath = '$directory/driver.sock';
    if (utf8.encode(socketPath).length >= 104) {
      throw FileSystemException(
        'driver socket path exceeds the macOS Unix-domain limit',
        socketPath,
      );
    }
    return DriverRuntimePaths(
      directory: directory,
      socketPath: socketPath,
      metadataPath: '$directory/metadata.json',
    );
  }

  Future<DriverRuntimePaths> create(DriverCorrelation correlation) async {
    final unresolved = paths(correlation);
    final vmDirectory = '$runRoot/${correlation.vmId.value}';
    await _createAndRequireDirectory(runRoot, recursive: true);
    _DriverPosix.chmod(runRoot, 0x1c0);
    final vmCleanupToken = await _createVmDirectory(vmDirectory);
    _DriverPosix.chmod(vmDirectory, 0x1c0);
    final cleanupToken = await _publishOwnedDirectory(unresolved.directory);
    return DriverRuntimePaths(
      directory: unresolved.directory,
      socketPath: unresolved.socketPath,
      metadataPath: unresolved.metadataPath,
      cleanupToken: cleanupToken,
      vmCleanupToken: vmCleanupToken,
    );
  }

  Future<void> writeMetadata(
    DriverRuntimePaths paths, {
    required DriverCorrelation correlation,
    required int pid,
    required String executable,
    required String bundlePath,
    required DateTime createdAt,
    DriverProcessIdentity? processIdentity,
  }) =>
      AtomicJsonFile.durable(
        paths.metadataPath,
        syncDirectory: _metadataDirectorySync,
      ).write(
        DriverRuntimeMetadata.fromJson({
          'version': 1,
          'vm_id': correlation.vmId.value,
          'driver_generation': correlation.driverGeneration,
          'operation_id': correlation.operationId?.value,
          'pid': pid,
          'executable': executable,
          'bundle_path': bundlePath,
          'socket_path': paths.socketPath,
          'created_at': createdAt.toUtc().toIso8601String(),
          if (processIdentity != null)
            'process_identity': {
              'pid': processIdentity.pid,
              'uid': processIdentity.uid,
              'executable_path': processIdentity.executablePath,
              'started_at_microseconds': processIdentity.startedAtMicroseconds,
              if (processIdentity.pidVersion != null)
                'pid_version': processIdentity.pidVersion,
            },
        }).toJson(),
      );

  /// Reads existing ownership markers; it neither proves driver exit nor
  /// authorizes removing a running generation. Startup holds daemon ownership.
  Future<DriverRuntimePaths> recoverPaths(DriverCorrelation correlation) async {
    final unresolved = paths(correlation);
    if (await FileSystemEntity.type(runRoot, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'runtime root must be a real directory',
        runRoot,
      );
    }
    final root = await OwnedImageDirectory.open(Directory(runRoot));
    OwnedImageDirectory? vm;
    OwnedImageDirectory? generation;
    try {
      if (root.mode & 0x3f != 0) {
        throw FileSystemException('runtime root must be private', runRoot);
      }
      vm = root.directory(correlation.vmId.value);
      generation = vm.directory('${correlation.driverGeneration}');
      final vmToken = await _recoverToken(vm);
      final token = await _recoverToken(generation);
      await root.verifyPathBinding();
      return DriverRuntimePaths(
        directory: unresolved.directory,
        socketPath: unresolved.socketPath,
        metadataPath: unresolved.metadataPath,
        cleanupToken: token,
        vmCleanupToken: vmToken,
      );
    } finally {
      generation?.close();
      vm?.close();
      root.close();
    }
  }

  Future<String> _recoverToken(OwnedImageDirectory directory) async {
    const prefix = '.gaovm-owner-';
    final markers = <String>[];
    if (directory.mode & 0x3f != 0) {
      throw FileSystemException(
        'runtime directory must be private',
        directory.path,
      );
    }
    await directory.verifyPathBinding();
    var count = 0;
    await for (final entry in Directory(
      directory.path,
    ).list(followLinks: false)) {
      if (++count > 4096) {
        throw FileSystemException(
          'runtime directory exceeds discovery limit',
          directory.path,
        );
      }
      final name = entry.path.split(Platform.pathSeparator).last;
      if (name.startsWith(prefix)) markers.add(name);
    }
    if (markers.length != 1 ||
        !RegExp(
          r'^\.gaovm-owner-[A-Za-z0-9_-]{32}$',
        ).hasMatch(markers.single)) {
      throw FileSystemException(
        'runtime ownership marker is invalid',
        directory.path,
      );
    }
    final marker = directory.directory(markers.single);
    try {
      if (marker.mode & 0x3f != 0 ||
          !await Directory(marker.path).list(followLinks: false).isEmpty) {
        throw FileSystemException(
          'runtime ownership marker is invalid',
          marker.path,
        );
      }
      await marker.verifyPathBinding();
      await directory.verifyPathBinding();
      return markers.single.substring(prefix.length);
    } finally {
      marker.close();
    }
  }

  Future<void> remove(DriverRuntimePaths paths) async {
    final token = paths.cleanupToken;
    if (token == null) return;
    final quarantine = '${paths.directory}.cleanup.$token';
    final sourceType = await FileSystemEntity.type(
      paths.directory,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.directory) {
      _DriverPosix.renameNoReplace(paths.directory, quarantine);
    } else if (sourceType != FileSystemEntityType.notFound) {
      return;
    }
    if (await FileSystemEntity.type(quarantine, followLinks: false) ==
        FileSystemEntityType.notFound) {
      await _removeEmptyVmDirectory(paths);
      return;
    }
    final marker = Directory('$quarantine/.gaovm-owner-$token');
    final ownsDirectory =
        await FileSystemEntity.type(quarantine, followLinks: false) ==
            FileSystemEntityType.directory &&
        await FileSystemEntity.type(marker.path, followLinks: false) ==
            FileSystemEntityType.directory;
    if (ownsDirectory) {
      await _removeGenerationContents(quarantine, token);
      await Directory(quarantine).delete();
      await _removeEmptyVmDirectory(paths);
    } else if (sourceType == FileSystemEntityType.notFound &&
        await _removeEmptyQuarantine(quarantine)) {
      await _removeEmptyVmDirectory(paths);
    } else if (await FileSystemEntity.type(
          paths.directory,
          followLinks: false,
        ) ==
        FileSystemEntityType.notFound) {
      await _renameEntityBack(quarantine, paths.directory);
    }
  }

  // The caller supplies the retained cleanup token. An empty, pre-existing
  // quarantine can remain after marker removal and before the final rmdir.
  // Never apply this rule to a newly quarantined replacement source directory.
  Future<bool> _removeEmptyQuarantine(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory)
      return false;
    final parent = await OwnedImageDirectory.open(Directory(path).parent);
    final name = path.split(Platform.pathSeparator).last;
    OwnedImageDirectory? directory;
    try {
      directory = parent.directory(name);
      if (!await Directory(path).list(followLinks: false).isEmpty) return false;
      await directory.verifyPathBinding();
      parent.removeDirectory(name);
      await parent.sync();
      return true;
    } finally {
      directory?.close();
      parent.close();
    }
  }

  Future<void> _removeGenerationContents(String path, String token) async {
    final directory = await OwnedImageDirectory.open(Directory(path));
    final markerName = '.gaovm-owner-$token';
    try {
      final files = <String>[];
      // Validate every entry before removing anything. Unknown content remains
      // quarantined with its metadata so recovery can diagnose it.
      await for (final entry in Directory(path).list(followLinks: false)) {
        final name = entry.path.split(Platform.pathSeparator).last;
        final type = await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        );
        if (name == markerName && type == FileSystemEntityType.directory) {
          final marker = await directory.directory(name);
          try {
            if (!await Directory(
              marker.path,
            ).list(followLinks: false).isEmpty) {
              throw FileSystemException(
                'runtime ownership marker is not empty',
                entry.path,
              );
            }
            await marker.verifyPathBinding();
          } finally {
            marker.close();
          }
        } else if ((name == 'metadata.json' ||
                RegExp(
                  r'^metadata\.json\.tmp\.[0-9]+\.[0-9]+$',
                ).hasMatch(name)) &&
            type == FileSystemEntityType.file) {
          final file = await directory.file(name);
          file.close();
          files.add(name);
        } else if (name == 'driver.sock' &&
            type == FileSystemEntityType.unixDomainSock) {
          files.add(name);
        } else {
          throw FileSystemException(
            'unknown runtime content requires recovery',
            entry.path,
          );
        }
      }
      await directory.verifyPathBinding();
      for (final name in files) {
        directory.removeFile(name);
      }
      directory.removeDirectory(markerName);
      await directory.sync();
    } finally {
      directory.close();
    }
  }

  Future<String> _createVmDirectory(String path) async {
    final before = await FileSystemEntity.type(path, followLinks: false);
    if (before != FileSystemEntityType.notFound &&
        before != FileSystemEntityType.directory) {
      throw FileSystemException(
        'runtime VM path must be a real directory',
        path,
      );
    }
    if (before == FileSystemEntityType.notFound) {
      return _publishOwnedDirectory(path);
    }
    final token = await _readOwnershipToken(path);
    if (token == null) {
      throw FileSystemException(
        'runtime VM directory is not owned by GaoVM',
        path,
      );
    }
    return token;
  }

  Future<String> _publishOwnedDirectory(String path) async {
    final token = _newCleanupToken();
    final staging = await Directory(path).parent.createTemp('.gaovm-stage-');
    try {
      _DriverPosix.chmod(staging.path, 0x1c0);
      _DriverPosix.mkdirExclusive('${staging.path}/.gaovm-owner-$token', 0x1c0);
      // Publish the directory and its ownership marker together. A crash before
      // this rename leaves only staging, never a markerless generation path.
      _DriverPosix.renameNoReplace(staging.path, path);
      return token;
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _removeEmptyVmDirectory(DriverRuntimePaths paths) async {
    final token = paths.vmCleanupToken;
    if (token == null) return;
    final vmDirectory = Directory(paths.directory).parent.path;
    final sourceType = await FileSystemEntity.type(
      vmDirectory,
      followLinks: false,
    );
    if (sourceType != FileSystemEntityType.directory &&
        sourceType != FileSystemEntityType.notFound) {
      return;
    }
    final quarantine = '$vmDirectory.cleanup.$token';
    if (sourceType == FileSystemEntityType.directory) {
      _DriverPosix.renameNoReplace(vmDirectory, quarantine);
    }
    if (await FileSystemEntity.type(quarantine, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    if (await FileSystemEntity.type(quarantine, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'VM quarantine must be a real directory',
        quarantine,
      );
    }
    final marker = Directory('$quarantine/.gaovm-owner-$token');
    final entries = await Directory(
      quarantine,
    ).list(followLinks: false).toList();
    final ownedAndEmpty =
        await FileSystemEntity.type(marker.path, followLinks: false) ==
            FileSystemEntityType.directory &&
        entries.length == 1 &&
        entries.single.path == marker.path;
    if (ownedAndEmpty) {
      final directory = await OwnedImageDirectory.open(Directory(quarantine));
      try {
        // rmdir refuses a populated marker. Never recursively delete content
        // introduced after the VM directory was published.
        directory.removeDirectory('.gaovm-owner-$token');
        await directory.sync();
      } finally {
        directory.close();
      }
      await Directory(quarantine).delete();
    } else if (sourceType == FileSystemEntityType.notFound &&
        await _removeEmptyQuarantine(quarantine)) {
      return;
    } else if (await FileSystemEntity.type(vmDirectory, followLinks: false) ==
        FileSystemEntityType.notFound) {
      await _renameEntityBack(quarantine, vmDirectory);
    }
  }

  Future<String?> _readOwnershipToken(String directory) async {
    const prefix = '.gaovm-owner-';
    final markers = await Directory(directory)
        .list(followLinks: false)
        .where(
          (entry) =>
              entry is Directory &&
              entry.path.split(Platform.pathSeparator).last.startsWith(prefix),
        )
        .toList();
    if (markers.length != 1) return null;
    final name = markers.single.path.split(Platform.pathSeparator).last;
    final token = name.substring(prefix.length);
    return token.isEmpty ? null : token;
  }

  Future<void> _createAndRequireDirectory(
    String path, {
    bool recursive = false,
  }) async {
    final before = await FileSystemEntity.type(path, followLinks: false);
    if (before != FileSystemEntityType.notFound &&
        before != FileSystemEntityType.directory) {
      throw FileSystemException('runtime path must be a real directory', path);
    }
    if (before == FileSystemEntityType.notFound) {
      await Directory(path).create(recursive: recursive);
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('runtime path must be a real directory', path);
    }
  }

  Future<void> _renameEntityBack(String source, String target) async {
    _DriverPosix.renameNoReplace(source, target);
  }

  String _newCleanupToken() => base64Url
      .encode(
        Uint8List.fromList(List<int>.generate(24, (_) => _random.nextInt(256))),
      )
      .replaceAll('=', '');
}

final class _DriverPosix {
  static final ffi.DynamicLibrary _libc = Platform.isMacOS
      ? ffi.DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
      : ffi.DynamicLibrary.open('libc.so.6');
  static final int Function(ffi.Pointer<Utf8>, int) _chmod = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Uint32),
        int Function(ffi.Pointer<Utf8>, int)
      >('chmod');
  static final int Function(ffi.Pointer<Utf8>, int) _mkdir = _libc
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Uint32),
        int Function(ffi.Pointer<Utf8>, int)
      >('mkdir');

  static void renameNoReplace(String source, String target) {
    final sourcePointer = source.toNativeUtf8();
    final targetPointer = target.toNativeUtf8();
    try {
      final int result;
      if (Platform.isMacOS) {
        final rename = _libc
            .lookupFunction<
              ffi.Int32 Function(
                ffi.Pointer<Utf8>,
                ffi.Pointer<Utf8>,
                ffi.Uint32,
              ),
              int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, int)
            >('renamex_np');
        result = rename(sourcePointer, targetPointer, 0x4);
      } else if (Platform.isLinux) {
        final rename = _libc
            .lookupFunction<
              ffi.Int32 Function(
                ffi.Int32,
                ffi.Pointer<Utf8>,
                ffi.Int32,
                ffi.Pointer<Utf8>,
                ffi.Uint32,
              ),
              int Function(int, ffi.Pointer<Utf8>, int, ffi.Pointer<Utf8>, int)
            >('renameat2');
        result = rename(-100, sourcePointer, -100, targetPointer, 0x1);
      } else {
        throw FileSystemException(
          'atomic no-replace rename unavailable',
          source,
        );
      }
      if (result != 0) {
        throw FileSystemException('atomic no-replace rename failed', source);
      }
    } finally {
      calloc.free(sourcePointer);
      calloc.free(targetPointer);
    }
  }

  static void chmod(String path, int mode) {
    final pointer = path.toNativeUtf8();
    try {
      if (_chmod(pointer, mode) != 0) {
        throw FileSystemException('chmod failed', path);
      }
    } finally {
      calloc.free(pointer);
    }
  }

  static void mkdirExclusive(String path, int mode) {
    final pointer = path.toNativeUtf8();
    try {
      if (_mkdir(pointer, mode) != 0) {
        throw FileSystemException(
          'driver generation directory already exists or cannot be created',
          path,
        );
      }
    } finally {
      calloc.free(pointer);
    }
  }
}
