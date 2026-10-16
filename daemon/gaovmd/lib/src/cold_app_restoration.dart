part of 'cold_state_lease.dart';

/// Typed app placement attached to one held whole-state restoration. Owns its
/// app/journal readers through that state context; never retires either fence.
/// There is intentionally no retry, automatic reversal or startup admission.
final class ColdAppRestoration {
  ColdAppRestoration._(
    this._state,
    this._storage,
    this._root,
    this._lock,
    this._sourceParent,
    this._targetParent,
    this._intent,
  );

  static const _lockName = '.gaovm-app-restoration.lock';
  final ColdStateRestoration _state;
  final OwnedImageDirectory _storage, _root, _sourceParent, _targetParent;
  final OwnedImageLock _lock;
  final Map<String, Object?> _intent;
  final _hosts = <MacOsColdStateHost>[];
  final _provenance = <String, MaintenanceTree>{};
  bool _closed = false, _reading = false;
  bool _nativeReady = false;
  String? _oldPath, _completionName;

  String get sourceAppPath => _intent['source_app'] as String;
  String get appPath => _intent['target_app'] as String;
  String? get retainedAppPath => _intent['retained_app'] as String?;
  Set<String> get sourceAppPaths =>
      (_state._intent['apps'] as Map).keys.cast<String>().toSet();
  Set<String> get provenancePaths => _provenance.keys.toSet();

  Map<String, Object?> toJson() {
    if (_closed ||
        _reading ||
        _state._closed ||
        _state._busy ||
        _completionName != 'completed') {
      throw StateError('complete available app restoration required');
    }
    return jsonDecode(jsonEncode(_completedRecord)) as Map<String, Object?>;
  }

  /// Filesystem-only, exact frozen app mapping for fresh native observers. No
  /// arbitrary path override and no authority to acquire ordinary startup.
  Future<String> relocatedPathFor(String original) async {
    if (_closed ||
        _state._closed ||
        _reading ||
        !sourceAppPaths.contains(original)) {
      throw StateError('exact available app restoration binding required');
    }
    _reading = true;
    try {
      await _state._verifyFiles(moved: true);
      if (original == sourceAppPath) return _oldPath!;
      if (original == appPath && retainedAppPath != null) {
        return _oldPath == sourceAppPath &&
                !maintenancePathEntryExists(retainedAppPath!)
            ? appPath
            : retainedAppPath!;
      }
      // An originally vacant installation slot is not an observer source.
      if ((_state._intent['apps'] as Map)[original] == null) {
        throw const FormatException('vacant original app has no observer');
      }
      return original;
    } finally {
      _reading = false;
    }
  }

  static Future<ColdAppRestoration> _create(
    ColdStateRestoration state,
    OwnedImageDirectory storage,
    String name,
    Future<void> Function() observePreparedInputs,
    Future<void> Function(ColdAppRestoration) verifyPreparedInputs,
  ) async {
    final oldHost = state._old._host,
        currentHost = state._current._source._host;
    if (oldHost is! MacOsColdStateHost ||
        currentHost is! MacOsColdStateHost ||
        oldHost.isValidatingCandidate ||
        currentHost.isValidatingCandidate ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name) ||
        name.endsWith('.partial')) {
      throw const FormatException(
        'held non-executing native app observers and fixed unused child required',
      );
    }
    final source = state._old.appPath;
    final target = state._current._source.installationPath;
    final appEvidence = state._intent['apps'] as Map;
    if (source == target ||
        !source.endsWith('.app') ||
        !target.endsWith('.app') ||
        appEvidence[source] == null ||
        !appEvidence.containsKey(target)) {
      throw const FormatException(
        'independent old app and frozen installation slot required',
      );
    }
    final provenance = <String, Object?>{
      ...await oldHost.rollbackProvenance(),
      ...await currentHost.rollbackProvenance(),
    };
    final output = '${storage.path}/$name';
    final executable = await File(
      Platform.resolvedExecutable,
    ).resolveSymbolicLinks();
    final script = Platform.script.scheme == 'file'
        ? await File.fromUri(Platform.script).resolveSymbolicLinks()
        : null;
    for (final protected in {
      ...state._apps.keys,
      state.path,
      state._current.path,
      state._old.path,
      state._root.path,
      state._current._root.path,
      state._current._original.path,
      state._current._destination.path,
      ...provenance.keys,
    }) {
      if (storage.path == protected ||
          storage.path.startsWith('$protected/') ||
          PreservedColdState._overlap(output, protected) ||
          PreservedColdState._inside(executable, protected) ||
          script != null && PreservedColdState._inside(script, protected)) {
        throw const FormatException(
          'app restoration overlaps protected inputs or code',
        );
      }
    }
    if (maintenancePathEntryExists(output) ||
        PreservedColdState._inside(executable, output) ||
        script != null && PreservedColdState._inside(script, output)) {
      throw const FormatException(
        'unused app restoration destination required',
      );
    }
    await PreservedColdState._private(storage);
    final ownedStorage = await OwnedImageDirectory.open(
      Directory(storage.path),
    );
    OwnedImageDirectory? root, sourceParent, targetParent;
    OwnedImageLock? lock;
    ColdAppRestoration? result;
    try {
      lock = await ownedStorage.tryAcquireMaintenanceLock(_lockName);
      if (lock == null)
        throw StateError('app restoration namespace already owned');
      await PreservedColdState._lockFile(ownedStorage, _lockName);
      sourceParent = await OwnedImageDirectory.open(Directory(source).parent);
      targetParent = await OwnedImageDirectory.open(Directory(target).parent);
      await ColdStateRestoration._parent(sourceParent);
      await ColdStateRestoration._parent(targetParent);
      root = ownedStorage.createDirectory(name);
      result = ColdAppRestoration._(
        state,
        ownedStorage,
        root,
        lock,
        sourceParent,
        targetParent,
        {
          'format': 'gaovm.cold-app-restoration-intent.v1',
          'source_app': source,
          'target_app': target,
          'retained_app': appEvidence[target] == null
              ? null
              : '${root.path}/retained.app',
          'state_restoration_digest': PreservedColdState._hash(state._intent),
          'workspace_identity': await root.maintenanceIdentity(),
          'source_parent_identity': await sourceParent.maintenanceIdentity(),
          'target_parent_identity': await targetParent.maintenanceIdentity(),
          'provenance': provenance,
        },
      );
      for (final path in provenance.keys) {
        result._provenance[path] = await MaintenanceTree.open(Directory(path));
      }
      await PreservedColdState._write(root, 'intent.json', result._intent);
      await result._writeCheckpoint('prepared', result._preparedRecord);
      final namespace = ownedStorage.file(_lockName);
      try {
        await namespace.sync();
      } finally {
        namespace.close();
      }
      await ownedStorage.sync();
      // Full native checks still use the original exact app placements. The
      // typed transition is attached only after these original proofs pass.
      await state._old._ownership.verify();
      await state._current._source._ownership.verify();
      await state._verifyFiles(moved: true);
      state._appRestoration = result;
      await result._verifyBindings();
      await verifyPreparedInputs(result);
      await state._verifyFiles(moved: true);
      if (result.retainedAppPath != null) {
        final original = await MaintenanceTree.open(Directory(target));
        try {
          final moved = await original.moveForMaintenanceTo(
            targetParent,
            root,
            'retained.app',
          );
          moved.close();
        } finally {
          original.close();
        }
      }
      await state._verifyFiles(moved: true);
      await verifyPreparedInputs(result);
      await state._verifyFiles(moved: true);
      final staged = await MaintenanceTree.open(Directory(source));
      try {
        final moved = await staged.moveForMaintenanceTo(
          sourceParent,
          targetParent,
          Directory(
            target,
          ).uri.pathSegments.where((part) => part.isNotEmpty).last,
        );
        moved.close();
      } finally {
        staged.close();
      }
      await state._verifyFiles(moved: true);
      result._hosts.addAll(await oldHost.reopenForRollback(result));
      result._hosts.addAll(await currentHost.reopenForRollback(result));
      result._nativeReady = true;
      await result._verifyNative();
      await observePreparedInputs();
      await verifyPreparedInputs(result);
      await state._verifyFiles(moved: true);
      await result._writeCheckpoint('completed', result._completedRecord);
      await state._verifyFiles(moved: true);
      return result;
    } catch (_) {
      // Once attached, keep every moved input/reader until the state owner is
      // explicitly closed. A failed future must never imply an automatic undo.
      if (result != null && !identical(state._appRestoration, result)) {
        result._closeResources();
      } else if (result == null) {
        root?.close();
        sourceParent?.close();
        targetParent?.close();
        lock?.close();
        ownedStorage.close();
      }
      rethrow;
    }
  }

  Map<String, Object?> get _preparedRecord => {
    'format': 'gaovm.cold-app-restoration-prepared.v1',
    'phase': 'old_app_ready',
    'intent_digest': PreservedColdState._hash(_intent),
    'startup_allowed': false,
  };
  Map<String, Object?> get _completedRecord => {
    'format': 'gaovm.cold-app-restoration-completed.v1',
    'phase': 'old_pair_restored',
    'intent_digest': PreservedColdState._hash(_intent),
    'source_app': sourceAppPath,
    'app_path': appPath,
    'retained_app': retainedAppPath,
    'state_path': _state.path,
    'retained_state': _state._current.path,
    'canonical_state_restored': true,
    'installed_pair_restored': true,
    'committed': false,
    'startup_allowed': false,
    'service_actions_performed': false,
  };

  Future<void> _writeCheckpoint(
    String name,
    Map<String, Object?> record,
  ) async {
    final partial = '.$name.partial';
    final directory = _root.createDirectory(partial);
    if (name == 'completed') _completionName = partial;
    try {
      await PreservedColdState._write(directory, 'record.json', record);
      await directory.sync();
    } finally {
      directory.close();
    }
    await _root.renameDirectoryNoReplace(partial, name);
    if (name == 'completed') _completionName = name;
  }

  Future<void> _verifyTree(String path, Map evidence) async {
    final directory = await OwnedImageDirectory.open(Directory(path));
    MaintenanceTree? tree;
    try {
      tree = await MaintenanceTree.open(Directory(path));
      if (!PreservedColdState._same(
        await directory.maintenanceIdentity(),
        evidence['identity'],
      )) {
        throw const FormatException('restored app or provenance inode changed');
      }
      await tree.verify(
        evidence['manifest'] as Map<String, Object?>,
        nativeMetadata: true,
      );
      await directory.verifyPathBinding();
    } finally {
      tree?.close();
      directory.close();
    }
  }

  Future<void> _verifyBindings() async {
    if (_closed ||
        !identical(_state._appRestoration, this) ||
        _intent['state_restoration_digest'] !=
            PreservedColdState._hash(_state._intent)) {
      throw StateError('held exact app restoration required');
    }
    await PreservedColdState._private(_storage);
    await PreservedColdState._private(_root);
    _lock.verifyPathBinding();
    await PreservedColdState._lockFile(_storage, _lockName);
    await ColdStateRestoration._parent(_sourceParent);
    await ColdStateRestoration._parent(_targetParent);
    for (final pair in [
      (_root, 'workspace_identity'),
      (_sourceParent, 'source_parent_identity'),
      (_targetParent, 'target_parent_identity'),
    ]) {
      if (!PreservedColdState._same(
        await pair.$1.maintenanceIdentity(),
        _intent[pair.$2],
      )) {
        throw const FormatException('app restoration namespace changed');
      }
    }
    final staged = maintenancePathEntryExists(sourceAppPath);
    final installed = maintenancePathEntryExists(appPath);
    final retained =
        retainedAppPath != null && maintenancePathEntryExists(retainedAppPath!);
    if ((!staged && !installed) ||
        (retainedAppPath == null && staged && installed) ||
        (retainedAppPath != null && !retained && (!staged || !installed)) ||
        (retained && staged && installed)) {
      throw const FormatException('unknown app restoration placement');
    }
    final evidence = _state._intent['apps'] as Map;
    _oldPath = staged ? sourceAppPath : appPath;
    await _verifyTree(_oldPath!, evidence[sourceAppPath] as Map);
    if (retainedAppPath != null) {
      await _verifyTree(
        retained ? retainedAppPath! : appPath,
        evidence[appPath] as Map,
      );
    }
    for (final path in sourceAppPaths.difference({sourceAppPath, appPath})) {
      final expected = evidence[path];
      if (expected == null) {
        if (maintenancePathEntryExists(path))
          throw const FormatException('vacant app slot changed');
      } else {
        await _verifyTree(path, expected as Map);
      }
    }
    for (final entry in _provenance.entries) {
      final expected = (_intent['provenance'] as Map)[entry.key] as Map;
      await _verifyTree(entry.key, expected);
      await entry.value.verify(
        expected['manifest'] as Map<String, Object?>,
        nativeMetadata: true,
      );
    }
    await PreservedColdState._entries(_root, {
      'intent.json',
      'prepared',
      if (retained) 'retained.app',
      if (_completionName != null) _completionName!,
    });
    await PreservedColdState._check(_root, 'intent.json', _intent);
    for (final pair in [
      ('prepared', _preparedRecord),
      if (_completionName != null) (_completionName!, _completedRecord),
    ]) {
      final checkpoint = _root.directory(pair.$1);
      try {
        await PreservedColdState._private(checkpoint);
        await PreservedColdState._entries(checkpoint, {'record.json'});
        await PreservedColdState._check(checkpoint, 'record.json', pair.$2);
      } finally {
        checkpoint.close();
      }
    }
    if (_completionName != null && _oldPath != appPath) {
      throw const FormatException('completion without installed old app');
    }
  }

  Future<void> _verifyNative() async {
    if (!_nativeReady || _oldPath != appPath)
      throw StateError('fresh restored app observers required');
    await _state._old._ownership.verify();
    await _state._current._source._ownership.verify();
    for (final host in _hosts) {
      await _state._old._verifyService(observer: host);
      for (final driver in [false, true]) {
        final inventory = await host.inventory(driver: driver);
        if (inventory.processes.isNotEmpty ||
            inventory.unresolvedProcessIds.isNotEmpty) {
          throw const ColdStateFailure(
            'restored_processes',
            'live or unresolved processes remain',
          );
        }
      }
      for (final path in [_state.path, _state._current.path]) {
        if ((await host.stateReferences(
          Directory(path),
        )).any((other) => other != pid)) {
          throw const ColdStateFailure(
            'restored_references',
            'other processes remain',
          );
        }
      }
      await _state._old._verifyService(observer: host);
    }
    await _state._old._ownership.verify();
    await _state._current._source._ownership.verify();
  }

  void _closeResources() {
    if (_closed) return;
    if (_reading) throw StateError('app restoration observation is pending');
    _closed = true;
    for (final host in _hosts) host.close();
    for (final tree in _provenance.values) tree.close();
    _sourceParent.close();
    _targetParent.close();
    _root.close();
    _lock.close();
    _storage.close();
  }
}
