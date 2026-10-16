part of 'cold_catalog_inspection.dart';

/// Held composition of an independently proved old pair and restored whole
/// state, then explicit old-app installation. Restoration keeps both generations
/// fenced and uncommitted. Only the separate acknowledged commit may retire the
/// canonical fence; the retained failed generation stays fenced. Owns its preparation,
/// including staged/recovered native hosts, external readers and both actual state
/// owners. Caller-owned current native hosts, original fence and work remain
/// borrowed and must stay open until this context closes.
final class ColdRollbackStateRestoration {
  ColdRollbackStateRestoration._(
    this._preparation,
    this._state,
    this.retainedStatePath,
  );

  final ColdRollbackPreparation _preparation;
  final ColdStateRestoration _state;
  final String retainedStatePath;
  bool _closed = false, _busy = false;
  bool _appCuttingOver = false;
  ColdAppRestoration? _app;
  ColdRollbackCommit? _commit;
  bool _commitAttempted = false;

  String get path => _state.path;

  /// Reopen only the fixed final old-app/old-state layout, never move an app,
  /// start a service or retire a fence. The operator repeats history-rewind
  /// acceptance and supplies the original native journal selectors explicitly.
  static Future<ColdRollbackStateRestoration> open(
    OwnedImageDirectory work,
    String preparationName,
    MaintenanceStateFence original, {
    required Directory installationApp,
    required ({OwnedImageDirectory storage, String name}) retirement,
    ({OwnedImageDirectory storage, String name})? publication,
    required String bundleIdentifier,
    required bool acceptHistoryRewind,
    required String oldVersion,
    required String newVersion,
    required String teamIdentifier,
    required int? sourceCatalogSchema,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) => _openRollbackPair(
    work,
    preparationName,
    original,
    installationApp: installationApp,
    retirement: retirement,
    publication: publication,
    bundleIdentifier: bundleIdentifier,
    acceptHistoryRewind: acceptHistoryRewind,
    oldVersion: oldVersion,
    newVersion: newVersion,
    teamIdentifier: teamIdentifier,
    sourceCatalogSchema: sourceCatalogSchema,
    host: host,
    observer: observer,
    inventory: inventory,
  );

  Map<String, Object?> toJson() {
    if (_closed || _busy || _appCuttingOver || !_preparation._consumed) {
      throw StateError(
        'complete available rollback state restoration required',
      );
    }
    if (_commitAttempted) {
      final commit = _commit;
      if (commit == null) throw StateError('rollback commit did not complete');
      return commit.toJson();
    }
    return _app?.toJson() ?? _state.toJson();
  }

  Future<void> verify() async {
    if (_closed || _busy || _appCuttingOver) {
      throw StateError('available rollback state restoration required');
    }
    _busy = true;
    try {
      if (_commitAttempted) {
        final commit = _commit;
        if (commit == null)
          throw StateError('rollback commit did not complete');
        await commit.verify();
        return;
      }
      await _preparation._verifyRestoredState(
        _state,
        retainedStatePath,
        app: _app,
      );
    } finally {
      _busy = false;
    }
  }

  /// Explicit next phase, still cold/uncommitted. The frozen installation slot
  /// may contain only the known failed app (which is retained), or be vacant.
  /// Failure retains both state owners and all app placements; no blind retry.
  Future<void> restoreOldApp() async {
    if (_app != null || _appCuttingOver)
      throw StateError('app restoration already attempted');
    await verify();
    _busy = true;
    _appCuttingOver = true;
    try {
      _app = await _state.restoreAppForRollback(
        _preparation._work,
        'restored-old-app',
        observePreparedInputs: _preparation._verifySnapshotReferences,
        verifyPreparedInputs: (app) => _preparation._verifyRestoredFiles(
          _state,
          retainedStatePath,
          app: app,
        ),
      );
      _appCuttingOver = false;
    } finally {
      _busy = false;
    }
  }

  /// One explicit cold rollback commit; registration/start remains manual.
  /// A failed attempt is retained for fixed-checkpoint recovery, never replayed.
  Future<Map<String, Object?>> commit({
    required bool acceptHistoryRewind,
    required bool allowStartup,
  }) async {
    if (!acceptHistoryRewind || !allowStartup)
      throw const FormatException(
        'explicit history rewind and startup acknowledgement required',
      );
    if (_commitAttempted || _app == null)
      throw StateError('complete uncommitted matching pair required');
    await verify();
    _busy = true;
    _commitAttempted = true;
    try {
      _commit = await ColdRollbackCommit.prepare(
        _state,
        acceptHistoryRewind: acceptHistoryRewind,
        allowStartup: allowStartup,
        pairing: {
          'source_intent_digest': ColdRollbackPreparation._hash(
            _preparation._sourceIntent,
          ),
          'source_record_digest': ColdRollbackPreparation._hash(
            _preparation._sourceRecord,
          ),
          'rollback_intent_digest': ColdRollbackPreparation._hash(
            _preparation._intent,
          ),
          'rollback_record_digest': ColdRollbackPreparation._hash(
            _preparation._record!,
          ),
        },
        observePreparedInputs: _preparation._verifySnapshotReferences,
        verifyPreparedInputs: () => _preparation._verifyRestoredFiles(
          _state,
          retainedStatePath,
          app: _app,
        ),
      );
      return await _commit!.commit();
    } finally {
      _busy = false;
    }
  }

  void close() {
    if (_busy || _preparation._busy) {
      throw StateError('rollback state restoration verification is pending');
    }
    if (_closed) return;
    _preparation._closeResources();
    _closed = true;
  }
}
