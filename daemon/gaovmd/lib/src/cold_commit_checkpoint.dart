part of 'cold_catalog_inspection.dart';

/// Sealed cold-commit preparation and explicit startup acknowledgement.
/// Borrows the recovered validation and work; closing retains every output.
final class ColdCommitCheckpoint {
  ColdCommitCheckpoint._(
    this._validation,
    this._work,
    this._lock,
    this._root,
    this._intent,
    this._record, [
    this._preparationName = 'prepared',
  ]);

  static const _name = 'commit', _partial = '.commit.partial';
  static const _lockName = '.gaovm-cold-commit.lock';
  static const _baseEntries = {
    '.gaovm-cold-publication.lock',
    '.gaovm-upgrade.lock',
    'preparation',
    '.gaovm-app-retirement.lock',
    'retirement',
    '.gaovm-candidate-publication.lock',
    'publication',
    'validation',
  };
  final ColdValidationCheckpoint _validation;
  final OwnedImageDirectory _work;
  final OwnedImageLock _lock;
  OwnedImageDirectory _root;
  final Map<String, Object?> _intent, _record;
  String _preparationName;
  String? _completionName;
  bool _closed = false;

  Map<String, Object?> toJson() =>
      (jsonDecode(jsonEncode(_record)) as Map).cast<String, Object?>();

  /// Requires a fresh successful recovery and its still-held real cold owner.
  /// An imported result, closed owner or existing output cannot opt in.
  static Future<ColdCommitCheckpoint> prepare(
    ColdValidationCheckpoint validation,
    OwnedImageDirectory work, {
    required MacOsOpenReferences observer,
  }) async {
    await _verifyOwner(validation, work);
    await ColdUpgradePreparation._entries(work, _baseEntries);
    OwnedImageLock? lock;
    OwnedImageDirectory? root;
    ColdCommitCheckpoint? result;
    try {
      lock = await work.tryAcquireMaintenanceLock(_lockName);
      if (lock == null) throw StateError('cold commit already has an owner');
      final file = work.file(_lockName);
      try {
        await file.sync();
      } finally {
        file.close();
      }
      await work.sync();
      await validation._verify(validation._current!, observer);
      root = work.createDirectory(_partial);
      final intent = await _binding(validation, work, root);
      final record = _recordFor(work, intent);
      await ColdUpgradePreparation._writeRecord(root, 'intent.json', intent);
      await root.sync();
      await work.sync();
      final prepared = root.createDirectory('.prepared.partial');
      try {
        await ColdUpgradePreparation._writeRecord(
          prepared,
          'record.json',
          record,
        );
        await prepared.sync();
      } finally {
        prepared.close();
      }
      await root.renameDirectoryNoReplace('.prepared.partial', 'prepared');
      await root.sync();
      await work.sync();
      result = ColdCommitCheckpoint._(
        validation,
        work,
        lock,
        root,
        intent,
        record,
      );
      root = null;
      lock = null;
      await result._verify(observer);
      await work.renameDirectoryNoReplace(_partial, _name);
      result._root.close();
      result._root = work.directory(_name);
      await work.sync();
      await result._verify(observer);
      return result;
    } catch (_) {
      result?.close();
      root?.close();
      lock?.close();
      rethrow;
    }
  }

  /// Recover only fixed complete sealed output. A complete partial checkpoint
  /// may be published after fresh verification; nothing is patched or replayed.
  static Future<ColdCommitCheckpoint> open(
    ColdValidationCheckpoint validation,
    OwnedImageDirectory work, {
    required MacOsOpenReferences observer,
  }) async {
    await _verifyOwner(validation, work);
    final published = maintenancePathEntryExists('${work.path}/$_name');
    final partial = maintenancePathEntryExists('${work.path}/$_partial');
    if (published == partial) {
      throw const FormatException(
        'exactly one cold commit checkpoint required',
      );
    }
    final name = published ? _name : _partial;
    await ColdUpgradePreparation._entries(work, {
      ..._baseEntries,
      _lockName,
      name,
    });
    OwnedImageLock? lock;
    OwnedImageDirectory? root;
    ColdCommitCheckpoint? result;
    try {
      lock = await work.tryAcquireMaintenanceLock(_lockName, create: false);
      if (lock == null) throw StateError('cold commit already has an owner');
      root = work.directory(name);
      final parsed = await _readCheckpoint(work, root);
      final partialRecord = parsed.preparationName == '.prepared.partial';
      result = ColdCommitCheckpoint._(
        validation,
        work,
        lock,
        root,
        parsed.intent,
        parsed.record,
        parsed.preparationName,
      ).._completionName = parsed.completionName;
      root = null;
      lock = null;
      await result._verify(observer);
      if (partialRecord) {
        await result._root.renameDirectoryNoReplace(
          '.prepared.partial',
          'prepared',
        );
        result._preparationName = 'prepared';
        await result._root.sync();
        await work.sync();
        await result._verify(observer);
      }
      if (partial) {
        await work.renameDirectoryNoReplace(_partial, _name);
        result._root.close();
        result._root = work.directory(_name);
        await work.sync();
        await result._verify(observer);
      }
      return result;
    } catch (_) {
      result?.close();
      root?.close();
      lock?.close();
      rethrow;
    }
  }

  static Map<String, Object?> _recordFor(
    OwnedImageDirectory work,
    Map<String, Object?> intent,
  ) => {
    'format': 'gaovm.cold-commit-preparation.v1',
    'phase': 'cold_commit_prepared',
    'checkpoint_path': '${work.path}/$_name',
    'intent_digest': ColdValidationCheckpoint._hash(intent),
    'validation_record_digest': intent['validation_record_digest'],
    'applied_catalog_schema': intent['applied_catalog_schema'],
    'ordinary_startup_fenced': true,
    'activation_authorized': false,
    'committed': false,
    'state_unchanged': true,
    'public_api_rerun': false,
  };

  Map<String, Object?> _commitRecord() =>
      _commitRecordFor(_work, _intent, _record);

  static Map<String, Object?> _commitRecordFor(
    OwnedImageDirectory work,
    Map<String, Object?> intent,
    Map<String, Object?> record,
  ) => {
    'format': 'gaovm.cold-upgrade-commit.v1',
    'phase': 'upgrade_committed',
    'intent_digest': ColdValidationCheckpoint._hash(intent),
    'preparation_record_digest': ColdValidationCheckpoint._hash(record),
    'validation_record_digest': intent['validation_record_digest'],
    'source_app': intent['source_app'],
    'source_state': intent['source_state'],
    'checkpoint_path': '${work.path}/$_name',
    'applied_catalog_schema': intent['applied_catalog_schema'],
    'fence_path': intent['fence_path'],
    'retired_fence_path': '${work.path}/$_name/retired-fence',
    'ordinary_startup_fenced': false,
    'startup_allowed': true,
    'allow_startup_acknowledged': true,
    'committed': true,
    'service_actions_performed': false,
    'ordinary_ready': false,
    'manual_start_required': true,
    'state_unchanged': true,
    'public_api_rerun': false,
    'rollback_authorized': false,
  };

  /// Fixed-placement preflight only, not a validation or state ownership grant.
  /// The caller must subsequently reacquire and recover the real cold state.
  static Future<MaintenanceStateFence> openRecoveryFence(
    OwnedImageDirectory work,
    Directory state,
  ) async {
    final finalExists = maintenancePathEntryExists('${work.path}/$_name');
    if (finalExists == maintenancePathEntryExists('${work.path}/$_partial')) {
      throw const FormatException(
        'exactly one cold commit checkpoint required',
      );
    }
    final root = work.directory(finalExists ? _name : _partial);
    MaintenanceStateFence? fence;
    try {
      final parsed = await _readCheckpoint(work, root);
      if (parsed.intent['source_state'] != state.path ||
          parsed.intent['fence_identity'] is! Map<String, Object?> ||
          parsed.intent['fence_intent_digest'] is! String) {
        throw const FormatException('cold commit fence binding changed');
      }
      fence = parsed.retired
          ? await MaintenanceStateFence.openRetiredForCommit(
              state,
              root,
              expectedIdentity:
                  parsed.intent['fence_identity'] as Map<String, Object?>,
              expectedIntentDigest:
                  parsed.intent['fence_intent_digest'] as String,
            )
          : await MaintenanceStateFence.open(state);
      if (fence.path != parsed.intent['fence_path']) {
        throw const FormatException('cold commit logical fence changed');
      }
      return fence;
    } catch (_) {
      fence?.close();
      rethrow;
    } finally {
      root.close();
    }
  }

  static Future<
    ({
      String preparationName,
      String? completionName,
      bool retired,
      Map<String, Object?> intent,
      Map<String, Object?> record,
    })
  >
  _readCheckpoint(OwnedImageDirectory work, OwnedImageDirectory root) async {
    await ColdUpgradePreparation._verifyPrivate(root);
    final complete = maintenancePathEntryExists('${root.path}/prepared');
    final partial = maintenancePathEntryExists(
      '${root.path}/.prepared.partial',
    );
    final completed = maintenancePathEntryExists('${root.path}/completed');
    final completing = maintenancePathEntryExists(
      '${root.path}/.completed.partial',
    );
    final retired = maintenancePathEntryExists('${root.path}/retired-fence');
    final published = root.path == '${work.path}/$_name';
    if (complete == partial ||
        published && partial ||
        completed && completing ||
        (!published || partial) && (completed || completing || retired) ||
        completed && !retired ||
        retired && !completed && !completing) {
      throw const FormatException('unrecognized cold commit record placement');
    }
    final preparationName = complete ? 'prepared' : '.prepared.partial';
    final completionName = completed
        ? 'completed'
        : completing
        ? '.completed.partial'
        : null;
    await ColdUpgradePreparation._entries(root, {
      'intent.json',
      preparationName,
      if (completionName != null) completionName,
      if (retired) 'retired-fence',
    });
    final intent = await ColdUpgradePreparation._readRecord(
      root,
      'intent.json',
    );
    if (intent['format'] != 'gaovm.cold-commit-intent.v1' ||
        intent['work_path'] != work.path ||
        !ColdValidationCheckpoint._same(
          intent['work_identity'],
          await work.maintenanceIdentity(),
        ) ||
        !ColdValidationCheckpoint._same(
          intent['workspace_identity'],
          await root.maintenanceIdentity(),
        )) {
      throw const FormatException('cold commit checkpoint identity changed');
    }
    final prepared = root.directory(preparationName);
    late Map<String, Object?> record;
    try {
      await ColdUpgradePreparation._verifyPrivate(prepared);
      await ColdUpgradePreparation._entries(prepared, {'record.json'});
      record = await ColdUpgradePreparation._readRecord(
        prepared,
        'record.json',
      );
      if (!ColdValidationCheckpoint._same(record, _recordFor(work, intent))) {
        throw const FormatException('invalid sealed cold commit preparation');
      }
    } finally {
      prepared.close();
    }
    if (completionName != null) {
      final completion = root.directory(completionName);
      try {
        await ColdUpgradePreparation._verifyPrivate(completion);
        await ColdUpgradePreparation._entries(completion, {'record.json'});
        await ColdUpgradePreparation._checkRecord(
          completion,
          'record.json',
          _commitRecordFor(work, intent, record),
        );
      } finally {
        completion.close();
      }
    }
    return (
      preparationName: preparationName,
      completionName: completionName,
      retired: retired,
      intent: intent,
      record: record,
    );
  }

  /// The terminal record is only a proposal while in .completed.partial.
  /// The exact fence's atomic no-replace retirement is the commit point; the
  /// state kernel owner remains held through final independent verification.
  Future<Map<String, Object?>> commit({
    required bool allowStartup,
    required MacOsOpenReferences observer,
  }) async {
    if (!allowStartup) {
      throw const FormatException('explicit --allow-startup required');
    }
    await _verify(observer);
    if (_root.path != '${_work.path}/$_name' ||
        _preparationName != 'prepared') {
      throw const FormatException('published cold commit preparation required');
    }
    if (_completionName == null) {
      final pending = _root.createDirectory('.completed.partial');
      try {
        await ColdUpgradePreparation._writeRecord(
          pending,
          'record.json',
          _commitRecord(),
        );
        await pending.sync();
      } finally {
        pending.close();
      }
      _completionName = '.completed.partial';
      await _root.sync();
      await _work.sync();
    }
    await _verify(observer);
    if (!_validation._fence.retiredForCommit) {
      await _validation._current!._state.commitStartupFence(
        _validation._fence,
        _root,
        verifyPreparedInputs: () => _verify(observer),
      );
    }
    await _verify(observer);
    if (_completionName == '.completed.partial') {
      await _root.renameDirectoryNoReplace('.completed.partial', 'completed');
      _completionName = 'completed';
      await _root.sync();
      await _work.sync();
    }
    await _verify(observer);
    return _commitRecord();
  }

  static Future<void> _verifyOwner(
    ColdValidationCheckpoint validation,
    OwnedImageDirectory work,
  ) async {
    if (validation._closed ||
        !validation._recovered ||
        validation._current == null ||
        validation._prepared == null ||
        validation._completionName != 'completed' ||
        work.path != Directory(validation._root.path).parent.path) {
      throw const FormatException(
        'complete recovered validation owner required',
      );
    }
    await ColdUpgradePreparation._verifyPrivate(work);
    if (!ColdValidationCheckpoint._same(
      await work.maintenanceIdentity(),
      await validation._prepared!._parent.maintenanceIdentity(),
    )) {
      throw const FormatException('cold commit work identity changed');
    }
  }

  static Future<Map<String, Object?>> _binding(
    ColdValidationCheckpoint validation,
    OwnedImageDirectory work,
    OwnedImageDirectory root,
  ) async {
    final original = validation._intent;
    final marker = await OwnedImageDirectory.open(
      Directory(validation._fence.retainedPath),
    );
    try {
      final fenceIntent = await ColdUpgradePreparation._readRecord(
        marker,
        'intent.json',
      );
      return {
        'format': 'gaovm.cold-commit-intent.v1',
        'workspace_identity': await root.maintenanceIdentity(),
        'work_path': work.path,
        'work_identity': await work.maintenanceIdentity(),
        'source_app': original['source_app'],
        'source_state': original['source_state'],
        'state_identity': await ColdUpgradePreparation._identity(
          validation._current!._state.path,
        ),
        'bundle_identifier': original['bundle_identifier'],
        'old_version': original['old_version'],
        'new_version': original['new_version'],
        'team_identifier': original['team_identifier'],
        'source_catalog_schema': original['source_catalog_schema'],
        'applied_catalog_schema': validation._record['applied_catalog_schema'],
        'validation_workspace_identity': original['workspace_identity'],
        'validation_intent_digest': ColdValidationCheckpoint._hash(original),
        'validation_record_digest': ColdValidationCheckpoint._hash(
          validation._record,
        ),
        'preparation_digest': original['preparation_digest'],
        'publication': original['publication'],
        'closed_state_digest':
            validation._record['closed_session_state_digest'],
        'fence_path': validation._fence.path,
        'fence_identity': await marker.maintenanceIdentity(),
        'fence_intent_digest': ColdValidationCheckpoint._hash(fenceIntent),
      };
    } finally {
      marker.close();
    }
  }

  Future<void> _verify(MacOsOpenReferences observer) async {
    if (_closed) throw StateError('cold commit checkpoint is closed');
    await _verifyOwner(_validation, _work);
    await _verifyRecords();
    await _validation._verify(_validation._current!, observer);
    // Native observers are over. Re-read the entire newly published evidence.
    await _verifyRecords();
  }

  Future<void> _verifyRecords() async {
    await ColdUpgradePreparation._verifyPrivate(_work);
    await ColdUpgradePreparation._verifyPrivate(_root);
    _lock.verifyPathBinding();
    final file = _work.file(_lockName);
    try {
      final before = file.stat();
      if (before.mode & 0xfff != 0x180 ||
          before.size != 0 ||
          before.linkCount != 1 ||
          (await file.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('cold commit namespace lock changed');
      }
      await file.verifyPathBinding();
      if (file.stat() != before) {
        throw const FormatException('cold commit lock changed while reading');
      }
    } finally {
      file.close();
    }
    final name = _root.path == '${_work.path}/$_name' ? _name : _partial;
    if (_root.path != '${_work.path}/$name') {
      throw const FormatException('cold commit path changed');
    }
    await ColdUpgradePreparation._entries(_work, {
      ..._baseEntries,
      _lockName,
      name,
    });
    if (!{'prepared', '.prepared.partial'}.contains(_preparationName) ||
        name == _name && _preparationName != 'prepared') {
      throw const FormatException('cold commit record placement changed');
    }
    await ColdUpgradePreparation._entries(_root, {
      'intent.json',
      _preparationName,
      if (_completionName != null) _completionName!,
      if (_validation._fence.retiredForCommit) 'retired-fence',
    });
    if ((_completionName != null &&
            (name != _name || _preparationName != 'prepared')) ||
        (_completionName == 'completed' &&
            !_validation._fence.retiredForCommit) ||
        (_validation._fence.retiredForCommit &&
            (_completionName == null ||
                _validation._fence.retainedPath !=
                    '${_root.path}/retired-fence'))) {
      throw const FormatException('cold commit completion placement changed');
    }
    if (!ColdValidationCheckpoint._same(_record, _recordFor(_work, _intent))) {
      throw const FormatException('invalid sealed cold commit preparation');
    }
    if (!ColdValidationCheckpoint._same(
      await _binding(_validation, _work, _root),
      _intent,
    )) {
      throw const FormatException('cold commit validation binding changed');
    }
    await ColdUpgradePreparation._checkRecord(_root, 'intent.json', _intent);
    final prepared = _root.directory(_preparationName);
    try {
      await ColdUpgradePreparation._verifyPrivate(prepared);
      await ColdUpgradePreparation._entries(prepared, {'record.json'});
      await ColdUpgradePreparation._checkRecord(
        prepared,
        'record.json',
        _record,
      );
    } finally {
      prepared.close();
    }
    if (_completionName != null) {
      final completed = _root.directory(_completionName!);
      try {
        await ColdUpgradePreparation._verifyPrivate(completed);
        await ColdUpgradePreparation._entries(completed, {'record.json'});
        await ColdUpgradePreparation._checkRecord(
          completed,
          'record.json',
          _commitRecord(),
        );
      } finally {
        completed.close();
      }
    }
    _lock.verifyPathBinding();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _root.close();
    _lock.close();
  }
}
