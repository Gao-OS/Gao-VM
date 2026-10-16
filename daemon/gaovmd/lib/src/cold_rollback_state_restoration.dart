part of 'cold_catalog_inspection.dart';

/// Held composition of an independently proved old pair and restored whole
/// state, then optional explicit old-app installation. Both generations remain
/// fenced; neither phase authorizes commit or ordinary startup. Owns its preparation,
/// including its staged native host, external readers and both actual state
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
    return _app?.toJson() ?? _state.toJson();
  }

  Future<void> verify() async {
    if (_closed || _busy || _appCuttingOver) {
      throw StateError('available rollback state restoration required');
    }
    _busy = true;
    try {
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

  void close() {
    if (_busy || _preparation._busy) {
      throw StateError('rollback state restoration verification is pending');
    }
    if (_closed) return;
    _preparation._closeResources();
    _closed = true;
  }
}
