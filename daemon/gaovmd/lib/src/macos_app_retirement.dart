part of 'macos_cold_state_host.dart';

/// Durable intent plus an observed original app inode at one fixed child.
/// This is neither candidate publication nor activation/rollback authority.
final class _AppRetirement {
  _AppRetirement(
    this._parent,
    this._sourceParent,
    this._lock,
    this._root,
    this._intent,
  ) : _bytes = _encode(_intent);

  static const _lockName = '.gaovm-app-retirement.lock';
  static const _limit = 64 * 1024 * 1024;
  final OwnedImageDirectory _parent;
  final OwnedImageDirectory _sourceParent;
  final OwnedImageLock _lock;
  OwnedImageDirectory _root;
  final Map<String, Object?> _intent;
  final List<int> _bytes;
  _CandidatePublication? _publication;
  bool _closed = false;
  String get sourceAppPath => _intent['source_app'] as String;

  static Future<MacOsColdStateHost> open(
    Directory originalApp,
    Directory state,
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name, {
    required String bundleIdentifier,
    required String version,
    required String teamIdentifier,
    required int catalogSchema,
    required ReleaseInspectionHost host,
    required MacOsOpenReferences observer,
    required Future<DriverInventorySnapshot> Function(String) inventory,
    MaintenanceStateFence? preservedOriginal,
    ({
      OwnedImageDirectory storage,
      String name,
      String version,
      int catalogSchema,
    })?
    publication,
  }) async {
    _validateName(name);
    await _private(storage);
    if (originalApp.path != originalApp.absolute.path ||
        !originalApp.path.endsWith('.app') ||
        state.path != state.absolute.path ||
        await state.resolveSymbolicLinks() != state.path ||
        _overlap(originalApp.path, state.path) ||
        _overlap('${storage.path}/$name', originalApp.path) ||
        _overlap('${storage.path}/$name', state.path) ||
        maintenancePathEntryExists('${storage.path}/.$name.partial')) {
      throw const FormatException(
        'explicit disjoint retirement targets required',
      );
    }
    final parent = await OwnedImageDirectory.open(Directory(storage.path));
    OwnedImageDirectory? sourceParent, root, stateRoot;
    OwnedImageLock? lock;
    _AppRetirement? retirement;
    MaintenanceTree? app;
    final origin = preservedOriginal ?? fence;
    Future<void> verifyState() async {
      await fence.verifyFor(
        stateRoot!,
        bundleIdentifier: bundleIdentifier,
        appPath: originalApp.path,
      );
      if (preservedOriginal != null) {
        await preservedOriginal.verifyRelocatedOriginal(
          stateRoot,
          fence,
          bundleIdentifier: bundleIdentifier,
          appPath: originalApp.path,
        );
        if (maintenancePathEntryExists(origin.sourceStatePath)) {
          throw const FormatException(
            'vacated original state slot is occupied',
          );
        }
      }
    }

    try {
      await storage.verifyPathBinding();
      if (!_equal(
        await storage.maintenanceIdentity(),
        await parent.maintenanceIdentity(),
      )) {
        throw const FormatException('retirement storage changed');
      }
      sourceParent = await OwnedImageDirectory.open(originalApp.parent);
      if (sourceParent.path != originalApp.parent.path) {
        throw const FormatException(
          'explicit canonical original app parent required',
        );
      }
      await _appParent(sourceParent);
      stateRoot = await OwnedImageDirectory.open(state);
      await verifyState();
      lock = await parent.tryAcquireMaintenanceLock(_lockName, create: false);
      if (lock == null) throw StateError('retirement namespace already owned');
      root = parent.directory(name);
      await _private(root);
      final intent = await _readIntent(root);
      if (intent.length != 14 ||
          intent['format'] != 'gaovm.app-retirement-intent.v1' ||
          intent['source_app'] != originalApp.path ||
          intent['source_state'] != origin.sourceStatePath ||
          intent['fence_path'] != origin.path ||
          intent['bundle_identifier'] != bundleIdentifier ||
          intent['version'] != version ||
          intent['team_identifier'] != teamIdentifier ||
          intent['catalog_schema'] != catalogSchema ||
          intent['catalog_schema'] is! int ||
          intent['native_manifest'] is! Map<String, Object?> ||
          intent['release'] is! Map<String, Object?> ||
          (intent['release'] as Map)['app_path'] != originalApp.path ||
          !_equal(
            intent['state_identity'],
            await stateRoot.maintenanceIdentity(),
          )) {
        throw const FormatException(
          'retirement intent disagrees with explicit inputs',
        );
      }
      retirement = _AppRetirement(parent, sourceParent, lock, root, intent);
      if (publication != null) {
        retirement._publication = await _CandidatePublication.open(
          retirement,
          stateRoot,
          fence,
          publication.storage,
          publication.name,
          version: publication.version,
          catalogSchema: publication.catalogSchema,
          preservedOriginal: preservedOriginal,
        );
      }
      app = await MaintenanceTree.open(Directory('${root.path}/GaoVM.app'));
      // Bind all paths/inodes and complete bytes BEFORE executing any helper.
      await retirement.verify(app);
      final release = await inspectMacOsRelease(
        Directory(app.path),
        bundleIdentifier: bundleIdentifier,
        version: version,
        teamIdentifier: teamIdentifier,
        catalogSchema: catalogSchema,
        host: host,
      );
      if (!_sameRelease(release, intent['release'] as Map<String, Object?>)) {
        throw const FormatException('retired release evidence changed');
      }
      await _noReferences(observer, app.path);
      await verifyState();
      await retirement.verify(app);
      final recovered = MacOsColdStateHost._(
        app,
        release,
        host,
        observer,
        inventory,
        retirement,
      );
      await retirement._publication?.validateNative(recovered);
      await verifyState();
      await retirement.verify(app);
      return recovered;
    } catch (_) {
      app?.close();
      if (retirement != null) {
        retirement.close();
      } else {
        root?.close();
        lock?.close();
        sourceParent?.close();
        parent.close();
      }
      rethrow;
    } finally {
      stateRoot?.close();
    }
  }

  static Future<MacOsColdStateHost> create(
    MacOsColdStateHost original,
    ColdStateLease state,
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name, {
    required Future<void> Function() verifyPreparedInputs,
  }) async {
    _validateName(name);
    if (original.isRetired ||
        original.appPath != state.appPath ||
        original.appPath != state.installationPath) {
      throw const FormatException('original owning app required');
    }
    await state.verify();
    await _private(storage);
    final executable = await File(
      Platform.resolvedExecutable,
    ).resolveSymbolicLinks();
    for (final input in [state.path, original.appPath]) {
      if (_overlap(input, '${storage.path}/$name') ||
          _overlap(input, '${storage.path}/.$name.partial') ||
          storage.path == input ||
          storage.path.startsWith('$input/') ||
          executable == input ||
          executable.startsWith('$input/')) {
        throw const FormatException('retirement overlaps protected inputs');
      }
    }
    if (_overlap(executable, '${storage.path}/$name') ||
        _overlap(executable, '${storage.path}/.$name.partial')) {
      throw const FormatException('maintenance executable must remain outside');
    }
    final parent = await OwnedImageDirectory.open(Directory(storage.path));
    OwnedImageDirectory? sourceParent;
    OwnedImageDirectory? root;
    OwnedImageLock? lock;
    _AppRetirement? retirement;
    MaintenanceTree? moved;
    try {
      await storage.verifyPathBinding();
      if (!_equal(
        await parent.maintenanceIdentity(),
        await storage.maintenanceIdentity(),
      )) {
        throw const FormatException('retirement storage changed');
      }
      await _private(parent);
      sourceParent = await OwnedImageDirectory.open(
        Directory(original.appPath).parent,
      );
      await _appParent(sourceParent);
      for (final target in [name, '.$name.partial']) {
        if (maintenancePathEntryExists('${parent.path}/$target')) {
          throw const FormatException('retirement output already exists');
        }
      }
      lock = await parent.tryAcquireMaintenanceLock(_lockName);
      if (lock == null) throw StateError('retirement namespace already owned');
      final lockFile = parent.file(_lockName);
      try {
        await lockFile.sync();
      } finally {
        lockFile.close();
      }
      await parent.sync();
      final native = await original._app.capture(nativeMetadata: true);
      if (native.values.cast<Map>().any(
        (entry) => (entry['metadata'] as Map)['has_acl'] != false,
      )) {
        throw const FormatException('app ACL grants require investigation');
      }
      final source = await OwnedImageDirectory.open(
        Directory(original.appPath),
      );
      final stateRoot = await OwnedImageDirectory.open(Directory(state.path));
      late Map<String, Object?> sourceIdentity, stateIdentity;
      try {
        await fence.verifyFor(
          stateRoot,
          bundleIdentifier: state.bundleIdentifier,
          appPath: state.installationPath,
        );
        sourceIdentity = await source.maintenanceIdentity();
        stateIdentity = await stateRoot.maintenanceIdentity();
      } finally {
        source.close();
        stateRoot.close();
      }
      root = parent.createDirectory('.$name.partial');
      final intent = <String, Object?>{
        'format': 'gaovm.app-retirement-intent.v1',
        'source_app': original.appPath,
        'source_state': state.path,
        'fence_path': fence.path,
        'bundle_identifier': state.bundleIdentifier,
        'version': original._release['version'],
        'team_identifier': original._release['team_identifier'],
        'catalog_schema': original._release['required_catalog_schema'],
        'source_app_identity': sourceIdentity,
        'source_parent_identity': await sourceParent.maintenanceIdentity(),
        'state_identity': stateIdentity,
        'workspace_identity': await root.maintenanceIdentity(),
        'native_manifest': native,
        'release': original._release,
      };
      final bytes = _encode(intent);
      final file = root.createFile('intent.json');
      try {
        final writer = await file.openWrite();
        try {
          await writer.writeFrom(bytes);
          await writer.flush();
        } finally {
          await writer.close();
        }
        await file.seal();
      } finally {
        file.close();
      }
      await root.sync();
      await parent.sync();
      retirement = _AppRetirement(parent, sourceParent, lock, root, intent);
      await retirement._verifyNamespace(moved: false);
      await parent.renameDirectoryNoReplace('.$name.partial', name);
      final published = parent.directory(name);
      retirement._root.close();
      retirement._root = published;
      // All external callbacks finish BEFORE the complete source/intent reads.
      await state.verify();
      await _noReferences(original._observer, original.appPath);
      await verifyPreparedInputs();
      await retirement._verifyNamespace(moved: false);
      await original._app.verify(native, nativeMetadata: true);
      await retirement._verifySourceIdentity(original.appPath);
      moved = await original._app.moveForMaintenanceTo(
        sourceParent,
        published,
        'GaoVM.app',
      );
      final release = await inspectMacOsRelease(
        Directory(moved.path),
        bundleIdentifier: intent['bundle_identifier'] as String,
        version: intent['version'] as String,
        teamIdentifier: intent['team_identifier'] as String,
        catalogSchema: intent['catalog_schema'] as int,
        host: original._host,
      );
      if (!_sameRelease(release, original._release)) {
        throw const FormatException('retired release evidence changed');
      }
      await _noReferences(original._observer, moved.path);
      await retirement.verify(moved);
      return MacOsColdStateHost._(
        moved,
        release,
        original._host,
        original._observer,
        original._inventory,
        retirement,
      );
    } catch (_) {
      moved?.close();
      if (retirement != null) {
        retirement.close();
      } else {
        root?.close();
        lock?.close();
        sourceParent?.close();
        parent.close();
      }
      // No deletion, reversal, repair, or retry: rename might already be done.
      rethrow;
    }
  }

  Future<void> verify(MaintenanceTree app) async {
    if (app.path != '${_root.path}/GaoVM.app') {
      throw const FormatException('retired app is outside fixed journal child');
    }
    await _verifyNamespace(moved: true);
    if (_publication case final publication?) {
      await publication.verify();
    } else if (maintenancePathEntryExists(sourceAppPath)) {
      throw const FormatException('original installation slot is occupied');
    }
    await _verifySourceIdentity(app.path);
    await app.verify(
      _intent['native_manifest'] as Map<String, Object?>,
      nativeMetadata: true,
    );
    await _verifyNamespace(moved: true);
  }

  Future<void> _verifySourceIdentity(String path) async {
    final app = await OwnedImageDirectory.open(Directory(path));
    try {
      await app.verifyPathBinding();
      if (app.path != path ||
          !_equal(
            await app.maintenanceIdentity(),
            _intent['source_app_identity'],
          )) {
        throw const FormatException('original app inode changed');
      }
    } finally {
      app.close();
    }
  }

  Future<void> _verifyNamespace({required bool moved}) async {
    if (_closed) throw StateError('retirement journal is closed');
    await _private(_parent);
    await _appParent(_sourceParent);
    await _private(_root);
    if (!_equal(
          await _root.maintenanceIdentity(),
          _intent['workspace_identity'],
        ) ||
        !_equal(
          await _sourceParent.maintenanceIdentity(),
          _intent['source_parent_identity'],
        )) {
      throw const FormatException('retirement namespace identity changed');
    }
    _lock.verifyPathBinding();
    final lockFile = _parent.file(_lockName);
    try {
      final stat = lockFile.stat();
      if (stat.mode & 0xfff != 0x180 ||
          stat.size != 0 ||
          stat.linkCount != 1 ||
          (await lockFile.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('retirement namespace lock changed');
      }
      await lockFile.verifyPathBinding();
      if (lockFile.stat() != stat)
        throw const FormatException('retirement lock changed while reading');
    } finally {
      lockFile.close();
    }
    final expected = {'intent.json', if (moved) 'GaoVM.app'};
    final entries = await Directory(_root.path)
        .list(followLinks: false)
        .take(expected.length + 1)
        .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toList();
    if (entries.length != expected.length ||
        !entries.toSet().containsAll(expected)) {
      throw const FormatException('retirement journal entries changed');
    }
    final file = _root.file('intent.json');
    try {
      final stat = file.stat();
      if (stat.mode & 0xfff != 0x100 ||
          stat.size > _limit ||
          stat.linkCount != 1 ||
          (await file.maintenanceMetadata())['has_acl'] != false ||
          !_equal(await file.readBounded(_limit), _bytes)) {
        throw const FormatException('retirement intent changed');
      }
      await file.verifyPathBinding();
      if (file.stat() != stat)
        throw const FormatException('retirement intent changed while reading');
    } finally {
      file.close();
    }
    _lock.verifyPathBinding();
  }

  static bool _sameRelease(Map<String, Object?> a, Map<String, Object?> b) =>
      _equal({...a}..remove('app_path'), {...b}..remove('app_path'));
  static bool _equal(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
  static bool _overlap(String a, String b) =>
      a == b || a.startsWith('$b/') || b.startsWith('$a/');
  static void _validateName(String name) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name) ||
        name.endsWith('.partial')) {
      throw ArgumentError.value(name, 'name');
    }
  }

  static List<int> _encode(Map<String, Object?> intent) {
    final bytes = utf8.encode('${jsonEncode(intent)}\n');
    if (bytes.length > _limit)
      throw const FormatException('retirement intent exceeds bound');
    return bytes;
  }

  static Future<Map<String, Object?>> _readIntent(
    OwnedImageDirectory root,
  ) async {
    final file = root.file('intent.json');
    try {
      final stat = file.stat();
      if (stat.mode & 0xfff != 0x100 ||
          stat.size > _limit ||
          stat.linkCount != 1 ||
          (await file.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('unsafe retirement intent');
      }
      final bytes = await file.readBounded(_limit);
      await file.verifyPathBinding();
      if (file.stat() != stat)
        throw const FormatException('retirement intent changed while reading');
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, Object?> ||
          utf8.decode(bytes) != '${jsonEncode(value)}\n') {
        throw const FormatException('unrecognized retirement intent encoding');
      }
      return value;
    } finally {
      file.close();
    }
  }

  static Future<void> _private(OwnedImageDirectory directory) async {
    await directory.verifyPathBinding();
    if (directory.mode & 0xfff != 0x1c0 ||
        await Directory(directory.path).resolveSymbolicLinks() !=
            directory.path ||
        (await directory.maintenanceMetadata())['has_acl'] != false) {
      throw const FormatException(
        'private canonical retirement storage required',
      );
    }
  }

  static Future<void> _appParent(OwnedImageDirectory directory) async {
    await directory.verifyPathBinding();
    if (directory.mode & 0xe12 != 0 ||
        await Directory(directory.path).resolveSymbolicLinks() !=
            directory.path ||
        (await directory.maintenanceMetadata())['has_acl'] != false) {
      throw const FormatException('unsafe app retirement parent');
    }
  }

  static Future<void> _noReferences(
    MacOsOpenReferences observer,
    String path,
  ) async {
    if ((await observer.directory(
      Directory(path),
    )).any((process) => process != pid)) {
      throw const ColdStateFailure(
        'app_references',
        'other app references remain',
      );
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _publication?.close();
    _root.close();
    try {
      _lock.close();
    } finally {
      _sourceParent.close();
      _parent.close();
    }
  }
}
