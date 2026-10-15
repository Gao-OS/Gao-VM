import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'cold_state_lease.dart';
import 'image_filesystem.dart';

final class MaintenanceFenceActive implements Exception {
  const MaintenanceFenceActive(this.statePath, this.markerPath);
  final String statePath;
  final String markerPath;

  @override
  String toString() =>
      'maintenance recovery required for $statePath; retained fence: $markerPath';
}

/// Durable admission fence outside the replaceable state inode. Closing the
/// maintenance process releases its kernel lock, NEVER the persistent marker.
/// This does not stop existing writers or authorize app/state replacement.
final class MaintenanceStateFence {
  MaintenanceStateFence._(
    this._parent,
    this._lock,
    this._marker,
    this.sourceStatePath,
    this._encoded,
    this._intent,
  );

  final OwnedImageDirectory _parent;
  final OwnedImageLock _lock;
  final OwnedImageDirectory _marker;
  final String sourceStatePath;
  final List<int> _encoded;
  final Map<String, Object?> _intent;
  bool _closed = false;
  String get path => _marker.path;

  /// Ordinary daemon admission only observes existence. Malformed/foreign
  /// entries block too; startup must never repair or remove a maintenance fence.
  static Future<void> requireUnfenced(Directory state) async {
    final target = await _canonicalStatePath(state);
    final marker = '${Directory(target).parent.path}/${_name(target)}';
    if (maintenancePathEntryExists(marker)) {
      throw MaintenanceFenceActive(target, marker);
    }
  }

  /// The caller retains its cold lease until all state work ends. Only an
  /// unused sibling destination is published; failed staging is retained.
  static Future<MaintenanceStateFence> begin(ColdStateLease state) async {
    await state.verify();
    final target = state.path;
    final name = _name(target);
    final parent = await OwnedImageDirectory.open(Directory(target).parent);
    OwnedImageLock? lock;
    OwnedImageDirectory? staging;
    OwnedImageDirectory? source;
    MaintenanceStateFence? fence;
    try {
      await _verifyParent(parent, Directory(target).parent.path);
      for (final child in [name, '$name.partial']) {
        if (maintenancePathEntryExists('${parent.path}/$child')) {
          throw FormatException(
            'maintenance destination already exists: $child',
          );
        }
      }
      lock = await parent.tryAcquireMaintenanceLock('$name.lock');
      if (lock == null) throw StateError('maintenance already has an owner');
      lock.verifyPathBinding();
      final lockFile = parent.file('$name.lock');
      try {
        await lockFile.sync();
      } finally {
        lockFile.close();
      }
      await parent.sync();
      await state.verify();
      source = parent.directory(
        Directory(target).uri.pathSegments.where((s) => s.isNotEmpty).last,
      );
      await source.verifyPathBinding();
      final intent = <String, Object?>{
        'format': 'gaovm.maintenance-state-fence.v1',
        'state_path': target,
        'state_identity': await source.maintenanceIdentity(),
        'app_path': state.appPath,
        'bundle_identifier': state.bundleIdentifier,
      };
      staging = parent.createDirectory('$name.partial');
      final encoded = utf8.encode('${jsonEncode(intent)}\n');
      final output = staging.createFile('intent.json');
      try {
        final writer = await output.openWrite();
        try {
          await writer.writeFrom(encoded);
          await writer.flush();
        } finally {
          await writer.close();
        }
        await output.seal();
      } finally {
        output.close();
      }
      await staging.sync();
      await parent.sync();
      await state.verify();
      if (sha256.convert(await _readIntent(staging)).toString() !=
          sha256.convert(encoded).toString()) {
        throw const FormatException('staged maintenance intent changed');
      }
      await _verifyParent(parent, Directory(target).parent.path);
      lock.verifyPathBinding();
      await parent.renameDirectoryNoReplace('$name.partial', name);
      final published = parent.directory(name);
      fence = MaintenanceStateFence._(
        parent,
        lock,
        published,
        target,
        encoded,
        intent,
      );
      await state.verify();
      await fence.verifyFor(
        source,
        bundleIdentifier: state.bundleIdentifier,
        appPath: state.appPath,
      );
      return fence;
    } catch (_) {
      if (fence != null) {
        fence.close();
      } else {
        lock?.close();
        parent.close();
      }
      rethrow;
    } finally {
      source?.close();
      staging?.close();
    }
  }

  /// Reopen only this canonical target's fixed sibling marker. JSON paths do
  /// not choose filesystem targets, and recovery never recreates a missing lock.
  static Future<MaintenanceStateFence> open(Directory state) async {
    final target = await _canonicalStatePath(state);
    if (target != state.path) {
      throw const FormatException(
        'explicit canonical recovery target required',
      );
    }
    final name = _name(target);
    final parent = await OwnedImageDirectory.open(state.parent);
    OwnedImageLock? lock;
    OwnedImageDirectory? marker;
    try {
      await _verifyParent(parent, Directory(target).parent.path);
      lock = await parent.tryAcquireMaintenanceLock(
        '$name.lock',
        create: false,
      );
      if (lock == null) throw StateError('maintenance already has an owner');
      marker = parent.directory(name);
      final encoded = await _readIntent(marker);
      final intent = jsonDecode(utf8.decode(encoded));
      if (intent is! Map<String, Object?> ||
          intent.length != 5 ||
          intent['format'] != 'gaovm.maintenance-state-fence.v1' ||
          intent['state_path'] != target ||
          intent['app_path'] is! String ||
          !(intent['app_path'] as String).startsWith('/') ||
          intent['bundle_identifier'] is! String ||
          !RegExp(
            r'^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$',
          ).hasMatch(intent['bundle_identifier'] as String) ||
          !_validIdentity(intent['state_identity']) ||
          utf8.decode(encoded) != '${jsonEncode(intent)}\n') {
        throw const FormatException('unrecognized maintenance intent');
      }
      final fence = MaintenanceStateFence._(
        parent,
        lock,
        marker,
        target,
        encoded,
        intent,
      );
      await fence.verify();
      return fence;
    } catch (_) {
      marker?.close();
      lock?.close();
      parent.close();
      rethrow;
    }
  }

  /// Recovery of the original inode only. A copied lock/manifest does not give
  /// a replacement directory admission or authorization to rewind its contents.
  Future<void> verifyFor(
    OwnedImageDirectory root, {
    String? bundleIdentifier,
    String? appPath,
  }) async {
    await verify();
    await root.verifyPathBinding();
    if (root.path != sourceStatePath ||
        jsonEncode(await root.maintenanceIdentity()) !=
            jsonEncode(_intent['state_identity']) ||
        (bundleIdentifier != null &&
            bundleIdentifier != _intent['bundle_identifier']) ||
        (appPath != null && appPath != _intent['app_path'])) {
      throw const FormatException('maintenance source identity changed');
    }
    await root.verifyPathBinding();
  }

  Future<void> verify() async {
    if (_closed) throw StateError('maintenance state fence is closed');
    await _verifyParent(_parent, Directory(sourceStatePath).parent.path);
    _lock.verifyPathBinding();
    final lockFile = _parent.file('${_name(sourceStatePath)}.lock');
    try {
      final stat = lockFile.stat();
      if (stat.mode & 0xfff != 0x180 ||
          stat.size != 0 ||
          stat.linkCount != 1 ||
          (await lockFile.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('maintenance lock changed');
      }
      await lockFile.verifyPathBinding();
    } finally {
      lockFile.close();
    }
    final encoded = await _readIntent(_marker);
    if (sha256.convert(encoded).toString() !=
        sha256.convert(_encoded).toString()) {
      throw const FormatException('maintenance intent changed');
    }
    _lock.verifyPathBinding();
    await _parent.verifyPathBinding();
  }

  static Future<List<int>> _readIntent(OwnedImageDirectory marker) async {
    final path = marker.path;
    await marker.verifyPathBinding();
    final names = await Directory(
      path,
    ).list(followLinks: false).take(2).toList();
    if (marker.mode & 0xfff != 0x1c0 ||
        (await marker.maintenanceMetadata())['has_acl'] != false ||
        names.length != 1 ||
        names.single.path != '$path/intent.json') {
      throw const FormatException('maintenance marker changed');
    }
    final intent = marker.file('intent.json');
    try {
      final stat = intent.stat();
      if (stat.mode & 0xfff != 0x100 ||
          stat.linkCount != 1 ||
          stat.size > 16384 ||
          (await intent.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('maintenance intent changed');
      }
      final encoded = await intent.readBounded(16384);
      await intent.verifyPathBinding();
      if (intent.stat() != stat) {
        throw const FormatException('maintenance intent changed while reading');
      }
      await marker.verifyPathBinding();
      return List<int>.unmodifiable(encoded);
    } finally {
      intent.close();
    }
  }

  static bool _validIdentity(Object? value) {
    if (value is! Map<String, Object?> || value.length != 5) return false;
    for (final key in ['device_major', 'device_minor', 'inode', 'uid']) {
      if (value[key] is! int || (value[key] as int) < 0) return false;
    }
    final created = value['created'];
    return created is List &&
        created.length == 2 &&
        created.every((v) => v is int) &&
        (created[1] as int) >= 0 &&
        (created[1] as int) < 1000000000;
  }

  /// Explicit close never clears the durable fence or failed staging.
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _lock.close();
    } finally {
      _marker.close();
      _parent.close();
    }
  }

  static String _name(String target) =>
      '.gaovmd-maintenance-${sha256.convert(utf8.encode(target))}';

  static Future<void> _verifyParent(
    OwnedImageDirectory parent,
    String expectedPath,
  ) async {
    if (parent.path != expectedPath ||
        await Directory(expectedPath).resolveSymbolicLinks() != expectedPath) {
      throw const FormatException('maintenance parent canonical path changed');
    }
    await parent.verifyPathBinding();
    if (parent.mode & 0xe12 != 0 ||
        (await parent.maintenanceMetadata())['has_acl'] != false) {
      throw const FormatException(
        'owned non-shared maintenance parent required',
      );
    }
  }

  // Normal startup supports missing ancestors and parent aliases such as /tmp.
  // Only ENOENT for an actually absent ancestor can be extended lexically.
  static Future<String> _canonicalStatePath(Directory state) async {
    final absolute = Directory(state.absolute.uri.normalizePath().toFilePath());
    final leaf = absolute.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .lastOrNull;
    if (leaf == null) throw const FormatException('state root cannot be /');
    var ancestor = absolute.parent;
    final missing = <String>[];
    while (true) {
      try {
        final canonical = await ancestor.resolveSymbolicLinks();
        return '${canonical == '/' ? '' : canonical}/${[...missing.reversed, leaf].join('/')}';
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 2 ||
            maintenancePathEntryExists(ancestor.path)) {
          rethrow;
        }
        missing.add(ancestor.uri.pathSegments.where((s) => s.isNotEmpty).last);
        ancestor = ancestor.parent;
      }
    }
  }
}
