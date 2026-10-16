part of 'cold_state_lease.dart';

/// An explicit paired cold commit. Borrows both real state owners and the
/// original/retained fences from one restoration; never starts a service.
/// Its sealed terminal proposal is not a commit until the exact canonical
/// marker has moved atomically and the complete read set has closed again.
final class ColdRollbackCommit {
  ColdRollbackCommit._(
    this._state,
    this._storage,
    this._lock,
    this._root,
    this._intent,
    this._pairing,
    this._observe,
    this._verifyInputs,
  );

  static const _name = 'rollback-commit';
  static const _lockName = '.gaovm-rollback-commit.lock';
  final ColdStateRestoration _state;
  final OwnedImageDirectory _storage;
  final OwnedImageLock _lock;
  OwnedImageDirectory _root;
  final Map<String, Object?> _intent, _pairing;
  final Future<void> Function() _observe, _verifyInputs;
  String? _completion;
  bool _busy = false, _closed = false, _verified = false;

  String get retainedStatePath => _state._current.path;

  static Future<ColdRollbackCommit> prepare(
    ColdStateRestoration state, {
    required bool acceptHistoryRewind,
    required bool allowStartup,
    required Map<String, Object?> pairing,
    required Future<void> Function() observePreparedInputs,
    required Future<void> Function() verifyPreparedInputs,
  }) async {
    if (!acceptHistoryRewind || !allowStartup)
      throw const FormatException(
        'explicit history rewind and startup acknowledgement required',
      );
    if (state._closed ||
        state._busy ||
        state._recovering ||
        !state._ownsStates ||
        state._startupCommit != null ||
        state._appRestoration?._completionName != 'completed') {
      throw StateError('complete available owned old pair required');
    }
    await state.verify();
    state._busy = true;
    OwnedImageDirectory? storage;
    OwnedImageLock? lock;
    OwnedImageDirectory? root;
    ColdRollbackCommit? result;
    try {
      storage = await OwnedImageDirectory.open(Directory(state._storage.path));
      await PreservedColdState._private(storage);
      for (final name in [_name, '.$_name.partial']) {
        if (maintenancePathEntryExists('${storage.path}/$name'))
          throw const FormatException('rollback commit output already exists');
      }
      lock = await storage.tryAcquireMaintenanceLock(_lockName);
      if (lock == null)
        throw StateError('rollback commit namespace already owned');
      final file = storage.file(_lockName);
      try {
        await file.sync();
      } finally {
        file.close();
      }
      await storage.sync();
      await state._verifyFiles(moved: true);
      await state._appRestoration!._verifyNative();
      await observePreparedInputs();
      await verifyPreparedInputs();
      await state._verifyFiles(moved: true);
      root = storage.createDirectory('.$_name.partial');
      final boundPairing =
          jsonDecode(jsonEncode(pairing)) as Map<String, Object?>;
      final intent = await _binding(state, storage, root, boundPairing);
      await PreservedColdState._write(root, 'intent.json', intent);
      final prepared = root.createDirectory('.prepared.partial');
      try {
        await PreservedColdState._write(
          prepared,
          'record.json',
          _prepared(intent),
        );
        await prepared.sync();
      } finally {
        prepared.close();
      }
      await root.renameDirectoryNoReplace('.prepared.partial', 'prepared');
      await storage.sync();
      result = ColdRollbackCommit._(
        state,
        storage,
        lock,
        root,
        intent,
        boundPairing,
        observePreparedInputs,
        verifyPreparedInputs,
      );
      state._startupCommit = result;
      await result._verifyHeld();
      await storage.renameDirectoryNoReplace('.$_name.partial', _name);
      root.close();
      result._root = storage.directory(_name);
      await result._verifyHeld();
      return result;
    } catch (_) {
      if (result == null) {
        root?.close();
        lock?.close();
        storage?.close();
      }
      // Once attached, even failed work belongs to the original context until
      // explicit close. Never clear the attempt or retry it as untouched input.
      rethrow;
    } finally {
      state._busy = false;
    }
  }

  static Future<Map<String, Object?>> _binding(
    ColdStateRestoration state,
    OwnedImageDirectory storage,
    OwnedImageDirectory root,
    Map<String, Object?> pairing,
  ) async => {
    'format': 'gaovm.cold-rollback-commit-intent.v1',
    'work_path': storage.path,
    'work_identity': await storage.maintenanceIdentity(),
    'workspace_identity': await root.maintenanceIdentity(),
    'source_state': state.path,
    'source_app': state._appRestoration!.appPath,
    'retained_state': state._current.path,
    'retained_app': state._appRestoration!.retainedAppPath,
    'state_restoration_digest': PreservedColdState._hash(state._intent),
    'app_restoration_digest': PreservedColdState._hash(
      state._appRestoration!._intent,
    ),
    'original_fence_path': state._current._original.path,
    'original_fence': state._intent['original_fence'],
    'retained_fence_path': state._current._destination.path,
    'retained_fence': state._intent['retained_fence'],
    'matching_pair': pairing,
    'history_rewind_accepted': true,
    'allow_startup_acknowledged': true,
  };

  static Map<String, Object?> _prepared(Map<String, Object?> intent) => {
    'format': 'gaovm.cold-rollback-commit-prepared.v1',
    'phase': 'rollback_commit_prepared',
    'intent_digest': PreservedColdState._hash(intent),
    'committed': false,
    'startup_allowed': false,
    'service_actions_performed': false,
  };

  Map<String, Object?> get _completed => {
    'format': 'gaovm.cold-rollback-commit.v1',
    'phase': 'rollback_committed',
    'intent_digest': PreservedColdState._hash(_intent),
    'source_app': _intent['source_app'],
    'source_state': _intent['source_state'],
    'retained_state': _intent['retained_state'],
    'retained_app': _intent['retained_app'],
    'checkpoint_path': '${_storage.path}/$_name',
    'retired_fence_path': '${_storage.path}/$_name/retired-fence',
    'retained_fence_path': _intent['retained_fence_path'],
    'history_rewind_accepted': true,
    'allow_startup_acknowledged': true,
    'installed_pair_restored': true,
    'retained_state_fenced': true,
    'ordinary_startup_fenced': false,
    'committed': true,
    'startup_allowed': true,
    'manual_start_required': true,
    'service_actions_performed': false,
    'ordinary_ready': false,
  };

  Map<String, Object?> toJson() {
    if (_closed ||
        _busy ||
        !_verified ||
        _completion != 'completed' ||
        !_state._current._original.retiredForCommit)
      throw StateError('complete verified rollback commit required');
    return jsonDecode(jsonEncode(_completed)) as Map<String, Object?>;
  }

  Future<Map<String, Object?>> commit() async {
    if (_closed || _busy || _state._busy || _completion != null)
      throw StateError('available unattempted rollback commit required');
    _busy = true;
    _state._busy = true;
    _verified = false;
    try {
      await _verifyHeld();
      if (_root.path != '${_storage.path}/$_name')
        throw const FormatException(
          'published rollback commit preparation required',
        );
      final pending = _root.createDirectory('.completed.partial');
      _completion = '.completed.partial';
      try {
        await PreservedColdState._write(pending, 'record.json', _completed);
        await pending.sync();
      } finally {
        pending.close();
      }
      await _root.sync();
      await _verifyHeld();
      await _state._current._original.retireToRollbackCommit(this, _root);
      await _verifyHeld();
      await _root.renameDirectoryNoReplace('.completed.partial', 'completed');
      _completion = 'completed';
      await _storage.sync();
      await _verifyHeld();
      _verified = true;
      return jsonDecode(jsonEncode(_completed)) as Map<String, Object?>;
    } finally {
      _state._busy = false;
      _busy = false;
    }
  }

  Future<void> verify() async {
    if (_closed || _busy || _state._busy)
      throw StateError('available rollback commit required');
    _busy = true;
    _state._busy = true;
    _verified = false;
    try {
      await _verifyHeld();
      if (_completion != 'completed' ||
          !_state._current._original.retiredForCommit)
        throw const FormatException('rollback has not committed');
      _verified = true;
    } finally {
      _state._busy = false;
      _busy = false;
    }
  }

  Future<void> _verifyHeld() async {
    await _verifyFiles();
    await _state._verifyFiles(moved: true);
    await _state._appRestoration!._verifyNative();
    await _observe();
    await _verifyInputs();
    await _state._verifyFiles(moved: true);
    await _verifyFiles();
  }

  Future<void> _verifyFiles() async {
    if (_closed || _state._closed || !identical(_state._startupCommit, this))
      throw StateError('held paired rollback commit required');
    await PreservedColdState._private(_storage);
    _lock.verifyPathBinding();
    await PreservedColdState._lockFile(_storage, _lockName);
    await PreservedColdState._private(_root);
    if (!{
          '${_storage.path}/$_name',
          '${_storage.path}/.$_name.partial',
        }.contains(_root.path) ||
        !PreservedColdState._same(
          _intent,
          await _binding(_state, _storage, _root, _pairing),
        ))
      throw const FormatException('rollback commit binding changed');
    final retired = _state._current._original.retiredForCommit;
    if (retired &&
            (_completion == null || _root.path != '${_storage.path}/$_name') ||
        _completion == 'completed' && !retired)
      throw const FormatException('rollback commit placement changed');
    await PreservedColdState._entries(_root, {
      'intent.json',
      'prepared',
      if (_completion != null) _completion!,
      if (retired) 'retired-fence',
    });
    await PreservedColdState._check(_root, 'intent.json', _intent);
    for (final entry in [
      ('prepared', _prepared(_intent)),
      if (_completion != null) (_completion!, _completed),
    ]) {
      final checkpoint = _root.directory(entry.$1);
      try {
        await PreservedColdState._private(checkpoint);
        await PreservedColdState._entries(checkpoint, {'record.json'});
        await PreservedColdState._check(checkpoint, 'record.json', entry.$2);
      } finally {
        checkpoint.close();
      }
    }
    await _state._old._ownership.verify();
    await _state._current._source._ownership.verify();
    _lock.verifyPathBinding();
  }

  /// Narrow typed adapter for the different old inode at the canonical slot.
  /// Ordinary original-fence admission and relocation checks stay unchanged.
  Future<void> verifyFenceRetirementFor(
    MaintenanceStateFence original,
    OwnedImageDirectory checkpoint,
  ) async {
    if (!identical(original, _state._current._original) ||
        checkpoint.path != '${_storage.path}/$_name' ||
        checkpoint.path != _root.path ||
        _completion == null)
      throw const FormatException(
        'exact proposed rollback retirement required',
      );
    await _verifyFiles();
    if (!PreservedColdState._same(
          await checkpoint.maintenanceIdentity(),
          _intent['workspace_identity'],
        ) ||
        original.retainedPath !=
            (original.retiredForCommit
                ? '${checkpoint.path}/retired-fence'
                : original.path) ||
        !PreservedColdState._same(
          await PreservedColdState._fenceEvidence(original),
          _intent['original_fence'],
        ) ||
        _state._current._destination.retiredForCommit)
      throw const FormatException(
        'rollback fence retirement provenance changed',
      );
    await _state._current._destination.verifyFor(
      _state._current._state!,
      bundleIdentifier: _state._old.bundleIdentifier,
      appPath: _state._current._source.installationPath,
    );
    if (!PreservedColdState._same(
      await PreservedColdState._fenceEvidence(_state._current._destination),
      _intent['retained_fence'],
    ))
      throw const FormatException('retained failed fence changed');
    await _state._verifyInstalledBinding();
  }

  void close() {
    if (_busy) throw StateError('rollback commit is pending');
    if (_closed) return;
    _closed = true;
    _root.close();
    _lock.close();
    _storage.close();
  }
}
