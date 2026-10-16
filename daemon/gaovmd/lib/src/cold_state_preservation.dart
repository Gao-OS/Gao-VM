part of 'cold_state_lease.dart';

/// A read-only held post-upgrade generation, not a daemon/commit/startup permit.
/// The original canonical fence and a second retained-path fence remain active.
/// The caller keeps the original fence and borrowed native host open until close.
final class PreservedColdState {
  PreservedColdState._(
    this._source,
    this._original,
    this._storage,
    this._lock,
    this._root,
    this._destination,
    this._intent,
  );

  static const _lockName = '.gaovm-state-preservation.lock';
  static const _limit = 16 * 1024 * 1024;
  final ColdStateLease _source;
  final MaintenanceStateFence _original, _destination;
  final OwnedImageDirectory _storage, _root;
  final OwnedImageLock _lock;
  final Map<String, Object?> _intent;
  OwnedImageDirectory? _state;
  Map<String, Object?>? _record;
  String? _completionName;
  bool _ownsState = false, _busy = false, _closed = false;

  String get path => '${_root.path}/state';
  Map<String, Object?> toJson() {
    if (_closed || _record == null || _completionName != 'completed') {
      throw StateError('complete preserved state required');
    }
    return jsonDecode(jsonEncode(_record)) as Map<String, Object?>;
  }

  // Only restoration recovery may read this occupied-original-slot layout.
  // No public admission, native helper or ownership is granted here: the caller
  // must independently close the full restoration read set before either.
  static Future<PreservedColdState> _readForRestoration(
    MaintenanceStateFence original,
    OwnedImageDirectory storage,
    String name, {
    required String bundleIdentifier,
    required String installationPath,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name) ||
        name.endsWith('.partial') ||
        original.retiredForCommit) {
      throw const FormatException('fixed preserved checkpoint required');
    }
    await original.verify();
    await _private(storage);
    final ownedStorage = await OwnedImageDirectory.open(
      Directory(storage.path),
    );
    OwnedImageDirectory? root, state;
    OwnedImageLock? lock;
    MaintenanceStateFence? destination;
    try {
      lock = await ownedStorage.tryAcquireMaintenanceLock(
        _lockName,
        create: false,
      );
      if (lock == null)
        throw StateError('preservation namespace already owned');
      await _lockFile(ownedStorage, _lockName);
      root = ownedStorage.directory(name);
      await _private(root);
      final intent = await _read(root, 'intent.json');
      if (intent.length != 10 ||
          intent['format'] != 'gaovm.cold-state-preservation-intent.v1' ||
          intent['source_state'] != original.sourceStatePath ||
          intent['source_app'] != installationPath ||
          intent['bundle_identifier'] != bundleIdentifier ||
          intent['original_fence_path'] != original.path ||
          intent['state_manifest'] is! Map<String, Object?> ||
          !_same(
            intent['workspace_identity'],
            await root.maintenanceIdentity(),
          )) {
        throw const FormatException('preserved recovery inputs changed');
      }
      state = root.directory('state');
      await _private(state);
      destination = await MaintenanceStateFence.open(Directory(state.path));
      await original.verifyRelocatedOriginal(
        state,
        destination,
        bundleIdentifier: bundleIdentifier,
        appPath: installationPath,
      );
      final source = ColdStateLease._unowned(
        state,
        bundleIdentifier,
        installationPath,
      ).._maintenanceFence = destination;
      return PreservedColdState._(
          source,
          original,
          ownedStorage,
          lock,
          root,
          destination,
          intent,
        )
        .._state = state
        .._record = _completedRecord(intent, state.path)
        .._completionName = 'completed'
        .._closed = true;
    } catch (_) {
      state?.close();
      destination?.close();
      root?.close();
      lock?.close();
      ownedStorage.close();
      rethrow;
    }
  }

  /// Reopen only the fixed post-move preservation checkpoint. All selectors
  /// come from the caller; recorded paths never choose a filesystem mutation.
  /// Both persistent fences and fresh actual state ownership are mandatory.
  static Future<PreservedColdState> open(
    Directory originalState,
    MaintenanceStateFence original,
    OwnedImageDirectory storage,
    String name, {
    required String bundleIdentifier,
    required ColdStateHost host,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name) ||
        name.endsWith('.partial') ||
        original.retiredForCommit ||
        (host is MacOsColdStateHost && host.isValidatingCandidate) ||
        originalState.path != original.sourceStatePath ||
        maintenancePathEntryExists(originalState.path)) {
      throw const FormatException(
        'fixed preserved generation recovery required',
      );
    }
    await original.verify();
    await _private(storage);
    final installation = host is MacOsColdStateHost
        ? host.installationPath
        : host.appPath;
    for (final protected in {originalState.path, installation, host.appPath}) {
      if (!protected.startsWith('/') || _overlap(storage.path, protected)) {
        throw const FormatException('disjoint preservation recovery required');
      }
    }
    final ownedStorage = await OwnedImageDirectory.open(
      Directory(storage.path),
    );
    OwnedImageLock? lock;
    OwnedImageDirectory? root, state;
    MaintenanceStateFence? destination;
    DaemonOwnership? ownership;
    PreservedColdState? result;
    try {
      lock = await ownedStorage.tryAcquireMaintenanceLock(
        _lockName,
        create: false,
      );
      if (lock == null)
        throw StateError('preservation namespace already owned');
      await _lockFile(ownedStorage, _lockName);
      root = ownedStorage.directory(name);
      await _private(root);
      final intent = await _read(root, 'intent.json');
      if (intent.length != 10 ||
          intent['format'] != 'gaovm.cold-state-preservation-intent.v1' ||
          intent['source_state'] != originalState.path ||
          intent['source_app'] != installation ||
          intent['bundle_identifier'] != bundleIdentifier ||
          intent['original_fence_path'] != original.path ||
          intent['state_manifest'] is! Map<String, Object?> ||
          !_same(
            intent['workspace_identity'],
            await root.maintenanceIdentity(),
          )) {
        throw const FormatException(
          'preservation intent or explicit inputs changed',
        );
      }
      state = root.directory('state');
      await _private(state);
      destination = await MaintenanceStateFence.open(Directory(state.path));
      await original.verifyRelocatedOriginal(
        state,
        destination,
        bundleIdentifier: bundleIdentifier,
        appPath: installation,
      );
      if (!_same(await state.maintenanceIdentity(), intent['state_identity']) ||
          !_same(await _fenceEvidence(original), intent['original_fence']) ||
          !_same(
            await _fenceEvidence(destination),
            intent['destination_fence'],
          )) {
        throw const FormatException(
          'preserved generation or fence was substituted',
        );
      }
      final marker = destination.path.substring(root.path.length + 1);
      final hasComplete = maintenancePathEntryExists('${root.path}/completed');
      final hasPartial = maintenancePathEntryExists(
        '${root.path}/.completed.partial',
      );
      if (hasComplete && hasPartial) {
        throw const FormatException('ambiguous preservation completion');
      }
      final completionName = hasComplete
          ? 'completed'
          : hasPartial
          ? '.completed.partial'
          : null;
      await _entries(root, {
        'intent.json',
        'prepared',
        if (completionName != null) completionName,
        'state',
        marker,
        '$marker.lock',
      });
      final prepared = root.directory('prepared');
      try {
        await _private(prepared);
        await _entries(prepared, {'record.json'});
        await _check(prepared, 'record.json', {
          'format': 'gaovm.cold-state-preservation-prepared.v1',
          'phase': 'relocation_prepared',
          'intent_digest': _hash(intent),
          'startup_allowed': false,
        });
      } finally {
        prepared.close();
      }
      final record = _completedRecord(intent, state.path);
      if (completionName != null) {
        final complete = root.directory(completionName);
        try {
          await _private(complete);
          await _entries(complete, {'record.json'});
          await _check(complete, 'record.json', record);
        } finally {
          complete.close();
        }
      }
      final tree = await MaintenanceTree.open(Directory(state.path));
      try {
        await tree.verify(
          intent['state_manifest'] as Map<String, Object?>,
          nativeMetadata: true,
        );
      } finally {
        tree.close();
      }
      // Fixed checkpoint and full native contents precede cold helpers and
      // lock acquisition: a missing/copied lock is not repaired into ownership.
      ownership = await DaemonOwnership.tryAcquireForMaintenance(
        state,
        destination,
      );
      if (ownership == null)
        throw const ColdStateFailure(
          'ownership',
          'preserved state already owned',
        );
      final source = ColdStateLease._(
        state,
        ownership,
        bundleIdentifier,
        host,
        destination,
      ).._closed = true;
      result =
          PreservedColdState._(
              source,
              original,
              ownedStorage,
              lock,
              root,
              destination,
              intent,
            )
            .._state = state
            .._record = record
            .._completionName = completionName
            .._ownsState = true;
      await result.verify();
      if (completionName != 'completed') {
        // Only a fully proved original moved inode can complete this fixed
        // post-move phase. Never rerun the move or repair an incomplete record.
        if (completionName == null) {
          final partial = root.createDirectory('.completed.partial');
          try {
            await _write(partial, 'record.json', record);
            await partial.sync();
          } finally {
            partial.close();
          }
        }
        await root.renameDirectoryNoReplace('.completed.partial', 'completed');
        result._completionName = 'completed';
        await result.verify();
      }
      return result;
    } catch (_) {
      if (result != null) {
        result.close();
      } else {
        ownership?.close();
        state?.close();
        destination?.close();
        root?.close();
        lock?.close();
        ownedStorage.close();
      }
      rethrow;
    }
  }

  static Future<PreservedColdState> _create(
    ColdStateLease source,
    MaintenanceStateFence original,
    OwnedImageDirectory storage,
    String name,
    Future<void> Function() verifyPreparedInputs,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name) ||
        name.endsWith('.partial') ||
        original.retiredForCommit) {
      throw const FormatException('fixed unused preservation child required');
    }
    await source.verify();
    await original.verifyFor(
      source._root,
      bundleIdentifier: source.bundleIdentifier,
      appPath: source.installationPath,
    );
    await _private(storage);
    final executable = await File(
      Platform.resolvedExecutable,
    ).resolveSymbolicLinks();
    final script = Platform.script.scheme == 'file'
        ? await File.fromUri(Platform.script).resolveSymbolicLinks()
        : null;
    for (final input in {
      source.path,
      source.appPath,
      source.installationPath,
    }) {
      if (_overlap(storage.path, input) ||
          _inside(executable, input) ||
          script != null && _inside(script, input)) {
        throw const FormatException(
          'preservation must be disjoint and outside running code',
        );
      }
    }
    if (_inside(executable, storage.path) ||
        script != null && _inside(script, storage.path) ||
        maintenancePathEntryExists('${storage.path}/$name')) {
      throw const FormatException(
        'unused outside-executable preservation storage required',
      );
    }
    final ownedStorage = await OwnedImageDirectory.open(
      Directory(storage.path),
    );
    OwnedImageLock? lock;
    OwnedImageDirectory? root;
    MaintenanceStateFence? destination;
    PreservedColdState? result;
    try {
      lock = await ownedStorage.tryAcquireMaintenanceLock(_lockName);
      if (lock == null)
        throw StateError('preservation namespace already owned');
      await _lockFile(ownedStorage, _lockName);
      root = ownedStorage.createDirectory(name);
      final sourceTree = await MaintenanceTree.open(Directory(source.path));
      late Map<String, Object?> manifest;
      try {
        manifest = await sourceTree.capture(nativeMetadata: true);
      } finally {
        sourceTree.close();
      }
      destination = await MaintenanceStateFence.reserveRelocation(
        source,
        original,
        root,
        'state',
      );
      final intent = <String, Object?>{
        'format': 'gaovm.cold-state-preservation-intent.v1',
        'source_state': source.path,
        'source_app': source.installationPath,
        'bundle_identifier': source.bundleIdentifier,
        'state_identity': await source._root.maintenanceIdentity(),
        'state_manifest': manifest,
        'workspace_identity': await root.maintenanceIdentity(),
        'original_fence_path': original.path,
        'original_fence': await _fenceEvidence(original),
        'destination_fence': await _fenceEvidence(destination),
      };
      result = PreservedColdState._(
        source,
        original,
        ownedStorage,
        lock,
        root,
        destination,
        intent,
      );
      // Failures, including a post-rename failure, keep all readers/owners
      // reachable from the original lease until its explicit close.
      source._pendingPreservation = result;
      await _write(root, 'intent.json', intent);
      final prepared = root.createDirectory('.prepared.partial');
      try {
        await _write(prepared, 'record.json', {
          'format': 'gaovm.cold-state-preservation-prepared.v1',
          'phase': 'relocation_prepared',
          'intent_digest': _hash(intent),
          'startup_allowed': false,
        });
        await prepared.sync();
      } finally {
        prepared.close();
      }
      await root.renameDirectoryNoReplace('.prepared.partial', 'prepared');
      final namespace = ownedStorage.file(_lockName);
      try {
        await namespace.sync();
      } finally {
        namespace.close();
      }
      await ownedStorage.sync();
      await source.verify();
      await verifyPreparedInputs();
      await result._verifyFiles(moved: false);
      final sourceParent = await OwnedImageDirectory.open(
        Directory(source.path).parent,
      );
      try {
        result._state = await source._root.moveForMaintenanceTo(
          sourceParent,
          root,
          'state',
        );
      } finally {
        sourceParent.close();
      }
      await source._ownership.rebindAfterMaintenanceMove(
        result._state!,
        maintenanceFence: destination,
      );
      result._record = _completedRecord(intent, result.path);
      final complete = root.createDirectory('.completed.partial');
      try {
        await _write(complete, 'record.json', result._record!);
        await complete.sync();
      } finally {
        complete.close();
      }
      await root.renameDirectoryNoReplace('.completed.partial', 'completed');
      result._completionName = 'completed';
      await result.verify();
      source._closed = true;
      source._pendingPreservation = null;
      result._ownsState = true;
      return result;
    } catch (_) {
      if (result == null) {
        destination?.close();
        root?.close();
        lock?.close();
        ownedStorage.close();
      }
      rethrow;
    }
  }

  Future<void> verify() async {
    if (_closed || _busy || _state == null || _record == null) {
      throw StateError('complete available preserved state required');
    }
    _busy = true;
    try {
      await _verifyHeld();
    } finally {
      _busy = false;
    }
  }

  Future<void> _verifyHeld({ColdStateRestoration? restoration}) async {
    await _source._ownership.verify();
    final host = _source._host;
    if (host is MacOsColdStateHost && host.isRetired) {
      await host.verifyRetirementFor(
        _state!,
        _destination,
        bundleIdentifier: _source.bundleIdentifier,
        installationPath: _source.installationPath,
        preservedOriginal: _original,
      );
    }
    await _source._verifyService();
    for (final driver in [false, true]) {
      final inventory = await host.inventory(driver: driver);
      if (inventory.unresolvedProcessIds.isNotEmpty ||
          inventory.processes.isNotEmpty) {
        throw const ColdStateFailure(
          'preserved_processes',
          'live or unresolved processes remain',
        );
      }
    }
    if ((await host.stateReferences(
      Directory(path),
    )).any((other) => other != pid)) {
      throw const ColdStateFailure(
        'preserved_references',
        'other processes remain',
      );
    }
    await _source._verifyService();
    await _source._ownership.verify();
    // Complete filesystem-only read-set closure after the last native callback.
    await _verifyFiles(moved: true, restoration: restoration);
  }

  Future<void> _verifyFiles({
    required bool moved,
    ColdStateRestoration? restoration,
  }) async {
    await _private(_storage);
    _lock.verifyPathBinding();
    await _lockFile(_storage, _lockName);
    await _private(_root);
    if (!_same(
      await _root.maintenanceIdentity(),
      _intent['workspace_identity'],
    )) {
      throw const FormatException('preservation workspace inode changed');
    }
    final marker = _destination.path.substring(_root.path.length + 1);
    await _entries(_root, {
      'intent.json',
      'prepared',
      marker,
      '$marker.lock',
      if (moved) 'state',
      if (_completionName != null) _completionName!,
    });
    await _check(_root, 'intent.json', _intent);
    final prepared = _root.directory('prepared');
    try {
      await _private(prepared);
      await _entries(prepared, {'record.json'});
      await _check(prepared, 'record.json', {
        'format': 'gaovm.cold-state-preservation-prepared.v1',
        'phase': 'relocation_prepared',
        'intent_digest': _hash(_intent),
        'startup_allowed': false,
      });
    } finally {
      prepared.close();
    }
    final actual = moved ? _state! : _source._root;
    if (moved) {
      await _original.verifyRelocatedOriginal(
        actual,
        _destination,
        bundleIdentifier: _source.bundleIdentifier,
        appPath: _source.installationPath,
      );
      if (maintenancePathEntryExists(_intent['source_state'] as String)) {
        if (restoration == null || !identical(restoration._current, this)) {
          throw const FormatException(
            'vacated original state slot became occupied',
          );
        }
        await restoration._verifyInstalledBinding();
      }
    } else {
      await _original.verifyFor(
        actual,
        bundleIdentifier: _source.bundleIdentifier,
        appPath: _source.installationPath,
      );
      await _destination.verify();
      if (maintenancePathEntryExists(path)) {
        throw const FormatException(
          'preservation state destination became occupied',
        );
      }
    }
    if (!_same(await actual.maintenanceIdentity(), _intent['state_identity']) ||
        !_same(await _fenceEvidence(_original), _intent['original_fence']) ||
        !_same(
          await _fenceEvidence(_destination),
          _intent['destination_fence'],
        )) {
      throw const FormatException(
        'preservation state or fence identity changed',
      );
    }
    final tree = await MaintenanceTree.open(Directory(actual.path));
    try {
      await tree.verify(
        _intent['state_manifest'] as Map<String, Object?>,
        nativeMetadata: true,
      );
    } finally {
      tree.close();
    }
    if (_completionName != null) {
      final completed = _root.directory(_completionName!);
      try {
        await _private(completed);
        await _entries(completed, {'record.json'});
        await _check(completed, 'record.json', _record!);
      } finally {
        completed.close();
      }
    }
    _lock.verifyPathBinding();
  }

  static Map<String, Object?> _completedRecord(
    Map<String, Object?> intent,
    String statePath,
  ) => {
    'format': 'gaovm.cold-state-preservation-completed.v1',
    'phase': 'current_state_preserved',
    'intent_digest': _hash(intent),
    'source_state': intent['source_state'],
    'retained_state': statePath,
    'state_identity': intent['state_identity'],
    'canonical_state_restored': false,
    'committed': false,
    'startup_allowed': false,
    'service_actions_performed': false,
  };

  static Future<Map<String, Object?>> _fenceEvidence(
    MaintenanceStateFence fence,
  ) async {
    await fence.verify();
    final root = await OwnedImageDirectory.open(Directory(fence.retainedPath));
    try {
      final file = root.file('intent.json');
      try {
        return {
          'identity': await root.maintenanceIdentity(),
          'intent_digest':
              'sha256:${sha256.convert(await file.readBounded(16384))}',
        };
      } finally {
        file.close();
      }
    } finally {
      root.close();
    }
  }

  static Future<void> _private(OwnedImageDirectory directory) async {
    await directory.verifyPathBinding();
    if (directory.mode & 0xfff != 0x1c0 ||
        (await directory.maintenanceMetadata())['has_acl'] != false ||
        await Directory(directory.path).resolveSymbolicLinks() !=
            directory.path) {
      throw const FormatException(
        'canonical private preservation directory required',
      );
    }
  }

  static Future<void> _lockFile(OwnedImageDirectory root, String name) async {
    final file = root.file(name);
    try {
      final stat = file.stat();
      if (stat.mode & 0xfff != 0x180 ||
          stat.size != 0 ||
          stat.linkCount != 1 ||
          (await file.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('preservation namespace lock changed');
      }
      await file.verifyPathBinding();
      if (stat != file.stat())
        throw const FormatException(
          'preservation lock changed during observation',
        );
    } finally {
      file.close();
    }
  }

  static Future<void> _entries(
    OwnedImageDirectory root,
    Set<String> expected,
  ) async {
    final entries = await Directory(root.path)
        .list(followLinks: false)
        .take(expected.length + 1)
        .map((entry) => entry.uri.pathSegments.where((p) => p.isNotEmpty).last)
        .toList();
    if (entries.length != expected.length ||
        !entries.toSet().containsAll(expected)) {
      throw const FormatException('preservation checkpoint entries changed');
    }
  }

  static List<int> _encode(Map<String, Object?> value) {
    final bytes = utf8.encode('${jsonEncode(value)}\n');
    if (bytes.length > _limit)
      throw const FormatException('preservation record too large');
    return bytes;
  }

  static String _hash(Map<String, Object?> value) =>
      'sha256:${sha256.convert(_encode(value))}';
  static Future<void> _write(
    OwnedImageDirectory root,
    String name,
    Map<String, Object?> value,
  ) async {
    final bytes = _encode(value), output = root.createFile(name);
    try {
      final writer = await output.openWrite();
      try {
        await writer.writeFrom(bytes);
        await writer.flush();
      } finally {
        await writer.close();
      }
      await output.seal();
    } finally {
      output.close();
    }
    await root.sync();
  }

  static Future<void> _check(
    OwnedImageDirectory root,
    String name,
    Map<String, Object?> value,
  ) async {
    final file = root.file(name);
    try {
      final stat = file.stat();
      if (stat.mode & 0xfff != 0x100 ||
          stat.linkCount != 1 ||
          stat.size > _limit ||
          (await file.maintenanceMetadata())['has_acl'] != false ||
          !_same(await file.readBounded(_limit), _encode(value))) {
        throw const FormatException('sealed preservation record changed');
      }
      await file.verifyPathBinding();
      if (stat != file.stat())
        throw const FormatException(
          'preservation record changed during observation',
        );
    } finally {
      file.close();
    }
  }

  static Future<Map<String, Object?>> _read(
    OwnedImageDirectory root,
    String name,
  ) async {
    final file = root.file(name);
    try {
      final stat = file.stat();
      if (stat.mode & 0xfff != 0x100 ||
          stat.linkCount != 1 ||
          stat.size > _limit ||
          (await file.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('sealed preservation input required');
      }
      final bytes = await file.readBounded(_limit);
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, Object?> || !_same(bytes, _encode(value))) {
        throw const FormatException('canonical preservation record required');
      }
      await file.verifyPathBinding();
      if (file.stat() != stat)
        throw const FormatException('preservation input changed during read');
      return value;
    } finally {
      file.close();
    }
  }

  static bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
  static bool _inside(String file, String root) =>
      file == root || file.startsWith('$root/');
  static bool _overlap(String a, String b) => _inside(a, b) || _inside(b, a);

  void _closeUntransferred() {
    if (_closed) return;
    _closed = true;
    _closeResources();
  }

  void _closeResources() {
    _state?.close();
    _destination.close();
    _root.close();
    _lock.close();
    _storage.close();
  }

  void close() {
    if (_busy) throw StateError('preserved state verification is pending');
    if (_closed) return;
    if (!_ownsState)
      throw StateError('preservation still belongs to original lease');
    _source._ownership.close();
    _source._root.close();
    _source._ownedRetiredHost?.close();
    _closeUntransferred();
  }
}
