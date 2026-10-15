import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'image_filesystem.dart';

/// Content binding and no-replace snapshots; never writes source entries.
final class MaintenanceTree {
  MaintenanceTree._(this._root, [this._stateBoundary]);
  final OwnedImageDirectory _root;
  final Future<Map<String, Object?>> Function()? _stateBoundary;
  String get path => _root.path;

  static Future<MaintenanceTree> open(Directory directory) async {
    if (directory.path != directory.absolute.path ||
        directory.absolute.path != await directory.resolveSymbolicLinks() ||
        await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const FormatException(
        'maintenance tree must be a canonical directory',
      );
    }
    final root = await OwnedImageDirectory.open(directory);
    if (root.path != directory.path) {
      root.close();
      throw const FormatException('maintenance canonical path changed');
    }
    return MaintenanceTree._(root);
  }

  Future<Map<String, Object?>> capture({bool nativeMetadata = false}) async {
    await _verifyStateBoundary();
    final result = <String, Object?>{};
    var count = 0;
    Future<void> visit(
      OwnedImageDirectory directory,
      String prefix,
      int depth,
    ) async {
      if (depth > 32 || ++count > 16384) {
        throw const FormatException(
          'maintenance tree exceeds traversal bounds',
        );
      }
      await directory.verifyPathBinding();
      if (directory.mode & 0xc12 != 0) {
        throw const FormatException(
          'maintenance directory is writable by other users',
        );
      }
      final metadata = nativeMetadata
          ? await directory.maintenanceMetadata()
          : null;
      result[prefix] = Map<String, Object?>.unmodifiable({
        'kind': 'directory',
        'mode': directory.mode & 0xfff,
        if (metadata != null) 'metadata': metadata,
      });
      final entries = <FileSystemEntity>[];
      await for (final entry in Directory(
        directory.path,
      ).list(followLinks: false)) {
        if (entries.length + count >= 16384) {
          throw const FormatException(
            'maintenance tree exceeds traversal bounds',
          );
        }
        entries.add(entry);
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        final name = entry.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        if (_stateBoundary != null && prefix.isEmpty && name == 'run') continue;
        final relative = prefix.isEmpty ? name : '$prefix/$name';
        final type = await FileSystemEntity.type(
          entry.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          final child = directory.directory(name);
          try {
            await visit(child, relative, depth + 1);
          } finally {
            child.close();
          }
        } else if (type == FileSystemEntityType.file) {
          if (++count > 16384) {
            throw const FormatException(
              'maintenance tree exceeds traversal bounds',
            );
          }
          final source = directory.file(name);
          try {
            final before = source.stat();
            final fileMetadata = nativeMetadata
                ? await source.maintenanceMetadata()
                : null;
            if (before.linkCount != 1 || before.mode & 0xc12 != 0) {
              throw const FormatException(
                'maintenance file has unsafe permissions or links',
              );
            }
            final digest =
                'sha256:${await sha256.bind(source.openRead()).first}';
            await source.verifyPathBinding();
            if (source.stat() != before) {
              throw const FormatException(
                'maintenance file changed during capture',
              );
            }
            if (fileMetadata != null &&
                jsonEncode(await source.maintenanceMetadata()) !=
                    jsonEncode(fileMetadata)) {
              throw const FormatException(
                'maintenance file metadata changed during capture',
              );
            }
            result[relative] = Map<String, Object?>.unmodifiable({
              'kind': 'file',
              'mode': before.mode & 0xfff,
              'size': before.size,
              'digest': digest,
              if (fileMetadata != null) 'metadata': fileMetadata,
            });
          } finally {
            source.close();
          }
        } else {
          throw const FormatException(
            'maintenance tree contains a link or special file',
          );
        }
      }
      await directory.verifyPathBinding();
      if (metadata != null &&
          jsonEncode(await directory.maintenanceMetadata()) !=
              jsonEncode(metadata)) {
        throw const FormatException(
          'maintenance directory metadata changed during capture',
        );
      }
    }

    await visit(_root, '', 0);
    if (_stateBoundary != null &&
        (!nativeMetadata ||
            result.values.any(
              (entry) =>
                  ((entry as Map)['metadata'] as Map)['has_acl'] != false,
            ))) {
      throw const FormatException(
        'cold state requires native metadata without ACL grants',
      );
    }
    await _verifyStateBoundary();
    return Map.unmodifiable(result);
  }

  Future<Map<String, Object?>?> _verifyStateBoundary() async {
    final verify = _stateBoundary;
    if (verify == null) return null;
    final evidence = await verify();
    if (evidence['source_state'] != path) {
      throw const FormatException('cold boundary belongs to another state');
    }
    await _root.verifyPathBinding();
    return evidence;
  }

  /// Internal copy mechanism for ColdStateSnapshot, not a coldness verifier.
  /// Its coordinator must verify all native/catalog/file boundaries each call.
  /// Only root run/ is omitted; the receipt records that fixed exclusion and
  /// the observations. Ordinary tree snapshots retain their no-exclusion policy.
  Future<Map<String, Object?>> snapshotStateDataTo(
    OwnedImageDirectory parent,
    String name, {
    required Future<Map<String, Object?>> Function() verifyBoundary,
  }) => MaintenanceTree._(_root, verifyBoundary).snapshotTo(parent, name);

  /// Fixed guarded state view for paired-snapshot capacity/source checks.
  /// The coordinator must establish and hold the original cold boundary.
  Future<Map<String, Object?>> captureStateData({
    required Future<Map<String, Object?>> Function() verifyBoundary,
  }) => MaintenanceTree._(_root, verifyBoundary).capture(nativeMetadata: true);

  /// Verify contained bytes/native metadata against caller-held observations.
  /// Imported receipts confer no coldness, ownership or restore authority.
  static Future<void> verifySnapshotContents(
    OwnedImageDirectory snapshot,
    Map<String, Object?> receipt,
  ) async {
    final payloadName = receipt['payload_name'];
    if (payloadName != 'payload' && payloadName != 'payload.app') {
      throw const FormatException('unknown snapshot payload');
    }
    await snapshot.verifyPathBinding();
    final names = await Directory(snapshot.path)
        .list(followLinks: false)
        .take(3)
        .map((entry) => entry.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toList();
    if (names.length != 2 ||
        !names.contains(payloadName) ||
        !names.contains('receipt.json')) {
      throw const FormatException('snapshot wrapper entries changed');
    }
    await _verifyStateOutput(
      snapshot,
      payloadName as String,
      (receipt['manifest'] as Map).cast<String, Object?>(),
      utf8.encode('${jsonEncode(receipt)}\n'),
    );
  }

  Future<void> verify(
    Map<String, Object?> expected, {
    bool nativeMetadata = false,
  }) async {
    if (jsonEncode(await capture(nativeMetadata: nativeMetadata)) !=
        jsonEncode(expected)) {
      throw const FormatException('maintenance tree changed after inspection');
    }
  }

  /// Relocate this complete tree with before/after byte/native verification.
  /// Caller supplies serialized parents, durable intent and cold authorization;
  /// this does not grant any of them or flush uncommitted payload writes.
  /// The old reader retains its old pathname. Failure may be post-rename: retain
  /// both namespaces for identity-based recovery, never automatically move back.
  Future<MaintenanceTree> moveForMaintenanceTo(
    OwnedImageDirectory sourceParent,
    OwnedImageDirectory destinationParent,
    String destinationName,
  ) async {
    if (_stateBoundary != null) {
      throw StateError(
        'a guarded state view cannot transfer its cold boundary',
      );
    }
    final expected = await capture(nativeMetadata: true);
    MaintenanceTree? moved;
    try {
      final root = await _root.moveForMaintenanceTo(
        sourceParent,
        destinationParent,
        destinationName,
      );
      moved = MaintenanceTree._(root);
      await moved.verify(expected, nativeMetadata: true);
      return moved;
    } catch (error) {
      moved?.close();
      if (error is MaintenanceDirectoryMoveFailure) rethrow;
      throw MaintenanceDirectoryMoveFailure(
        path,
        '${destinationParent.path}/$destinationName',
        error,
      );
    }
  }

  /// Snapshot every entry, without runtime exclusions. Callers must separately
  /// establish cold ownership and account for external files before using this
  /// as an upgrade snapshot. Never time out/abandon an in-flight native copy.
  Future<Map<String, Object?>> snapshotTo(
    OwnedImageDirectory parent,
    String name,
  ) async {
    if (!Platform.isMacOS) throw UnsupportedError('Darwin snapshot required');
    const lockName = '.gaovm-maintenance.lock';
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name == lockName ||
        name.contains('/') ||
        name.contains('\x00')) {
      throw ArgumentError.value(name, 'name');
    }
    final destination = '${parent.path}/$name';
    final stagingName = '.$name.partial';
    final stagingPath = '${parent.path}/$stagingName';
    bool overlap(String target) =>
        path == target ||
        path.startsWith('$target/') ||
        target.startsWith('$path/');
    if (overlap(destination) ||
        overlap(stagingPath) ||
        parent.path == path ||
        parent.path.startsWith('$path/')) {
      throw const FormatException('snapshot and source must be disjoint');
    }
    await parent.verifyPathBinding();
    final parentMetadata = await parent.maintenanceMetadata();
    if (parent.mode & 0xc3f != 0 || parentMetadata['has_acl'] != false) {
      throw const FormatException(
        'snapshot storage must be private without inherited ACLs',
      );
    }
    for (final child in [name, stagingName]) {
      final existing = parent.directoryOrNull(child);
      if (existing != null) {
        existing.close();
        throw const FormatException(
          'snapshot destination or retained staging already exists',
        );
      }
    }
    final previousLock = parent.fileOrNull(lockName);
    if (previousLock != null) {
      try {
        await previousLock.verifyPathBinding();
        final stat = previousLock.stat();
        if (stat.mode & 0xfff != 0x180 ||
            stat.size != 0 ||
            stat.linkCount != 1) {
          throw const FormatException('unrecognized snapshot namespace lock');
        }
      } finally {
        previousLock.close();
      }
    }
    final lock = await parent.tryAcquireLock(lockName);
    if (lock == null) throw StateError('snapshot storage already has an owner');
    OwnedImageDirectory? staging;
    try {
      final boundary = await _verifyStateBoundary();
      final manifest = await capture(nativeMetadata: true);
      final payloadName = path.endsWith('.app') ? 'payload.app' : 'payload';
      final receipt = <String, Object?>{
        'format': boundary == null
            ? 'gaovm.tree-snapshot.v1'
            : 'gaovm.cold-state-snapshot.v1',
        if (boundary != null) ...{
          'omitted_paths': ['run'],
          'boundary': boundary,
        },
        'source_path': path,
        'snapshot_path': destination,
        'payload_name': payloadName,
        'manifest_digest':
            'sha256:${sha256.convert(utf8.encode(jsonEncode(manifest)))}',
        'manifest': manifest,
      };
      final encoded = utf8.encode('${jsonEncode(receipt)}\n');
      var requiredBytes = encoded.length + manifest.length * 4096 + 65536;
      for (final value in manifest.values.cast<Map<String, Object?>>()) {
        requiredBytes += (value['size'] as int?) ?? 0;
        final metadata = value['metadata'] as Map<String, Object?>;
        for (final attribute
            in (metadata['xattrs'] as Map).values.cast<Map>()) {
          requiredBytes += attribute['size'] as int;
        }
      }
      if (await parent.availableBytes() < requiredBytes) {
        throw const FormatException(
          'insufficient snapshot space before copying',
        );
      }
      await parent.verifyPathBinding();
      lock.verifyPathBinding();
      staging = parent.createDirectory(stagingName);
      final payload = staging.createDirectory(payloadName);
      try {
        await staging.sync();
        await parent.sync();
        final children = <String, List<String>>{};
        for (final relative in manifest.keys.where((key) => key.isNotEmpty)) {
          final slash = relative.lastIndexOf('/');
          final directory = slash < 0 ? '' : relative.substring(0, slash);
          children.putIfAbsent(directory, () => []).add(relative);
        }
        Future<void> copy(
          OwnedImageDirectory input,
          OwnedImageDirectory output,
          String prefix,
        ) async {
          await input.verifyPathBinding();
          await output.verifyPathBinding();
          for (final relative in children[prefix] ?? <String>[]) {
            final childName = relative.substring(
              prefix.isEmpty ? 0 : prefix.length + 1,
            );
            if ((manifest[relative] as Map)['kind'] == 'directory') {
              final from = input.directory(childName);
              OwnedImageDirectory? to;
              try {
                to = output.createDirectory(childName);
                await copy(from, to, relative);
              } finally {
                to?.close();
                from.close();
              }
            } else {
              final from = input.file(childName);
              try {
                await from.verifyPathBinding();
                await from.copyForMaintenance(output, childName);
                await from.verifyPathBinding();
              } finally {
                from.close();
              }
            }
          }
          await input.verifyPathBinding();
          await output.verifyPathBinding();
          await input.copyMetadataForMaintenance(output);
        }

        await copy(_root, payload, '');
        final saved = MaintenanceTree._(payload);
        await saved.verify(manifest, nativeMetadata: true);
        await verify(manifest, nativeMetadata: true);
      } finally {
        payload.close();
      }
      final record = staging.createFile('receipt.json');
      try {
        final writer = await record.openWrite();
        try {
          await writer.writeFrom(encoded);
          await writer.flush();
        } finally {
          await writer.close();
        }
        await record.seal();
      } finally {
        record.close();
      }
      await staging.sync();
      await staging.verifyPathBinding();
      await parent.verifyPathBinding();
      lock.verifyPathBinding();
      if (_stateBoundary != null) {
        await verify(manifest, nativeMetadata: true);
        await _verifyStateOutput(staging, payloadName, manifest, encoded);
      }
      await parent.renameDirectoryNoReplace(stagingName, name);
      await parent.verifyPathBinding();
      lock.verifyPathBinding();
      await _verifyStateBoundary();
      if (_stateBoundary != null) {
        final published = parent.directory(name);
        try {
          await _verifyStateOutput(published, payloadName, manifest, encoded);
        } finally {
          published.close();
        }
        await parent.verifyPathBinding();
        lock.verifyPathBinding();
      }
      return Map.unmodifiable(receipt);
    } catch (error) {
      if (staging != null) {
        throw MaintenanceSnapshotFailure(stagingPath, destination, error);
      }
      rethrow;
    } finally {
      staging?.close();
      lock.close();
    }
  }

  static Future<void> _verifyStateOutput(
    OwnedImageDirectory snapshot,
    String payloadName,
    Map<String, Object?> manifest,
    List<int> encoded,
  ) async {
    await snapshot.verifyPathBinding();
    final payload = snapshot.directory(payloadName);
    try {
      await MaintenanceTree._(payload).verify(manifest, nativeMetadata: true);
    } finally {
      payload.close();
    }
    final receipt = snapshot.file('receipt.json');
    try {
      final before = receipt.stat();
      if (before.size != encoded.length ||
          before.linkCount != 1 ||
          before.mode & 0xc12 != 0 ||
          (await receipt.maintenanceMetadata())['has_acl'] != false ||
          sha256
                  .convert(await receipt.readBounded(encoded.length))
                  .toString() !=
              sha256.convert(encoded).toString()) {
        throw const FormatException('state snapshot receipt changed');
      }
      await receipt.verifyPathBinding();
      if (receipt.stat() != before)
        throw const FormatException(
          'state snapshot receipt changed during verification',
        );
    } finally {
      receipt.close();
    }
    await snapshot.verifyPathBinding();
  }

  void close() => _root.close();
}

final class MaintenanceSnapshotFailure implements Exception {
  const MaintenanceSnapshotFailure(
    this.stagingPath,
    this.snapshotPath,
    this.cause,
  );
  final String stagingPath;
  final String snapshotPath;
  final Object cause;
  @override
  String toString() =>
      'snapshot failed; retain staging/final paths $stagingPath and $snapshotPath: $cause';
}
