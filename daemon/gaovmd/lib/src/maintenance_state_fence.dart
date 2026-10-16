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
  OwnedImageDirectory _marker;
  final String sourceStatePath;
  final List<int> _encoded;
  final Map<String, Object?> _intent;
  bool _closed = false;

  /// Stable logical admission path, including after explicit cold commit.
  String get path => '${_parent.path}/${_name(sourceStatePath)}';
  String get retainedPath => _marker.path;
  bool get retiredForCommit => retainedPath != path;

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

  /// Reserve a second startup fence BEFORE relocating the original state inode.
  /// Requires its original held cold context and active fence. The target must
  /// be unused, private and disjoint; no state directory is created or copied.
  /// The original marker remains active. This grants no replacement admission.
  static Future<MaintenanceStateFence> reserveRelocation(
    ColdStateLease state,
    MaintenanceStateFence original,
    OwnedImageDirectory destinationParent,
    String destinationName,
  ) async {
    if (!RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
        ).hasMatch(destinationName) ||
        original.retiredForCommit) {
      throw const FormatException(
        'active original fence and fixed child required',
      );
    }
    await state.verify();
    await _verifyParent(destinationParent, destinationParent.path);
    if (destinationParent.mode & 0x3f != 0) {
      throw const FormatException('private relocation storage required');
    }
    for (final protected in {
      state.path,
      state.appPath,
      state.installationPath,
    }) {
      if (destinationParent.path == protected ||
          destinationParent.path.startsWith('$protected/') ||
          protected.startsWith('${destinationParent.path}/')) {
        throw const FormatException(
          'relocation storage overlaps protected input',
        );
      }
    }
    final target = '${destinationParent.path}/$destinationName';
    final name = _name(target);
    final parent = await OwnedImageDirectory.open(
      Directory(destinationParent.path),
    );
    OwnedImageDirectory? source, staging;
    OwnedImageLock? lock;
    MaintenanceStateFence? reservation;
    try {
      source = await OwnedImageDirectory.open(Directory(state.path));
      await original.verifyFor(
        source,
        bundleIdentifier: state.bundleIdentifier,
        appPath: state.installationPath,
      );
      for (final child in [destinationName, name, '$name.partial']) {
        if (maintenancePathEntryExists('${parent.path}/$child')) {
          throw const FormatException('relocation destination already exists');
        }
      }
      lock = await parent.tryAcquireMaintenanceLock('$name.lock');
      if (lock == null) throw StateError('relocation fence already owned');
      final lockFile = parent.file('$name.lock');
      try {
        await lockFile.sync();
      } finally {
        lockFile.close();
      }
      await parent.sync();
      final intent = <String, Object?>{
        'format': 'gaovm.maintenance-state-fence.v1',
        'state_path': target,
        'state_identity': await source.maintenanceIdentity(),
        'app_path': state.installationPath,
        'bundle_identifier': state.bundleIdentifier,
      };
      final encoded = utf8.encode('${jsonEncode(intent)}\n');
      staging = parent.createDirectory('$name.partial');
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
      await original.verifyFor(source);
      await _verifyParent(parent, destinationParent.path);
      await destinationParent.verifyPathBinding();
      if (parent.mode & 0x3f != 0 ||
          maintenancePathEntryExists(target) ||
          sha256.convert(await _readIntent(staging)).toString() !=
              sha256.convert(encoded).toString()) {
        throw const FormatException('relocation reservation changed');
      }
      lock.verifyPathBinding();
      await parent.renameDirectoryNoReplace('$name.partial', name);
      reservation = MaintenanceStateFence._(
        parent,
        lock,
        parent.directory(name),
        target,
        encoded,
        intent,
      );
      await state.verify();
      await original.verifyFor(source);
      await reservation.verify();
      await destinationParent.verifyPathBinding();
      if (parent.mode & 0x3f != 0 || maintenancePathEntryExists(target)) {
        throw const FormatException('reserved relocation boundary changed');
      }
      return reservation;
    } catch (_) {
      if (reservation != null) {
        reservation.close();
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
  static Future<MaintenanceStateFence> open(Directory state) => _open(state);

  /// Fixed retained placement only, bound to the sealed commit's expected
  /// native identity and bytes. This reacquires the original sibling lock;
  /// callers still need fresh real state ownership and complete cold checks.
  static Future<MaintenanceStateFence> openRetiredForCommit(
    Directory state,
    OwnedImageDirectory checkpoint, {
    required Map<String, Object?> expectedIdentity,
    required String expectedIntentDigest,
  }) => _open(
    state,
    checkpoint: checkpoint,
    expectedIdentity: expectedIdentity,
    expectedIntentDigest: expectedIntentDigest,
  );

  static Future<MaintenanceStateFence> _open(
    Directory state, {
    OwnedImageDirectory? checkpoint,
    Map<String, Object?>? expectedIdentity,
    String? expectedIntentDigest,
  }) async {
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
      if (checkpoint != null) {
        await checkpoint.verifyPathBinding();
        if (checkpoint.mode & 0xfff != 0x1c0 ||
            (await checkpoint.maintenanceMetadata())['has_acl'] != false ||
            maintenancePathEntryExists('${parent.path}/$name') ||
            !_validIdentity(expectedIdentity) ||
            !RegExp(
              r'^sha256:[0-9a-f]{64}$',
            ).hasMatch(expectedIntentDigest ?? '')) {
          throw const FormatException('invalid retained commit fence boundary');
        }
      }
      marker = checkpoint == null
          ? parent.directory(name)
          : checkpoint.directory('retired-fence');
      final encoded = await _readIntent(marker);
      if (checkpoint != null &&
          (jsonEncode(await marker.maintenanceIdentity()) !=
                  jsonEncode(expectedIdentity) ||
              'sha256:${sha256.convert(encoded)}' != expectedIntentDigest)) {
        throw const FormatException('retained commit fence binding changed');
      }
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

  /// Read-only provenance for the SAME original inode at a reserved location.
  /// Admission there still requires its independently held destination fence.
  /// Never authorizes a copied/replacement state at the original canonical path.
  Future<void> verifyRelocatedOriginal(
    OwnedImageDirectory root,
    MaintenanceStateFence destination, {
    required String bundleIdentifier,
    required String appPath,
  }) async {
    await verify();
    if (retiredForCommit ||
        destination.retiredForCommit ||
        root.path == sourceStatePath ||
        root.path.startsWith('$sourceStatePath/') ||
        sourceStatePath.startsWith('${root.path}/') ||
        bundleIdentifier != _intent['bundle_identifier'] ||
        appPath != _intent['app_path'] ||
        jsonEncode(await root.maintenanceIdentity()) !=
            jsonEncode(_intent['state_identity'])) {
      throw const FormatException('relocated original state binding changed');
    }
    await destination.verifyFor(
      root,
      bundleIdentifier: bundleIdentifier,
      appPath: appPath,
    );
    await verify();
    await root.verifyPathBinding();
  }

  Future<void> verify() async {
    if (_closed) throw StateError('maintenance state fence is closed');
    await _verifyParent(_parent, Directory(sourceStatePath).parent.path);
    if (retiredForCommit &&
        (!retainedPath.endsWith('/retired-fence') ||
            maintenancePathEntryExists(path))) {
      throw const FormatException(
        'retired maintenance fence placement changed',
      );
    }
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

  /// Fixed no-replace marker move only. The cold-commit coordinator must hold
  /// the real state lease and seal/recheck its complete intent before calling.
  /// A failure can follow the rename; no reverse move or cleanup is attempted.
  Future<void> retireToCommit(
    OwnedImageDirectory source,
    OwnedImageDirectory checkpoint,
  ) async {
    if (_closed || retiredForCommit) {
      throw StateError('active maintenance fence required for cold commit');
    }
    await verifyFor(source);
    await checkpoint.verifyPathBinding();
    if (checkpoint.mode & 0xfff != 0x1c0 ||
        (await checkpoint.maintenanceMetadata())['has_acl'] != false) {
      throw const FormatException('private commit checkpoint required');
    }
    final moved = await _marker.moveForMaintenanceTo(
      _parent,
      checkpoint,
      'retired-fence',
    );
    _marker.close();
    _marker = moved;
    await verifyFor(source);
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
