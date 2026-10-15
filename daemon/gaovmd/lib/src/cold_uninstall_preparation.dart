part of 'cold_catalog_inspection.dart';

/// Sealed retained-data evidence for an explicit cold uninstall. No state copy,
/// deletion, service action or rollback authority. Borrows the held cold lease.
final class ColdUninstallPreparation {
  ColdUninstallPreparation._(
    this._state,
    this._fence,
    this._parent,
    this._lock,
    this._root,
    this._record,
    this._host,
    this._observer,
  );

  static const _lockName = '.gaovm-uninstall.lock';
  final ColdStateSnapshot _state;
  final MaintenanceStateFence _fence;
  final OwnedImageDirectory _parent;
  final OwnedImageLock _lock;
  OwnedImageDirectory _root;
  final Map<String, Object?> _record;
  final ReleaseInspectionHost _host;
  final MacOsOpenReferences _observer;
  bool _closed = false;
  String get path => _root.path;

  /// Reopen only the explicit fixed checkpoint; records never select targets.
  /// The caller has reacquired the actual state lock and independently inspected
  /// the current catalog/external/runtime inputs in a new private directory.
  static Future<ColdUninstallPreparation> open(
    ColdStateSnapshot state,
    MaintenanceStateFence fence,
    OwnedImageDirectory parent, {
    required String version,
    required String teamIdentifier,
    required ReleaseInspectionHost host,
    required MacOsOpenReferences observer,
  }) async {
    await ColdUpgradePreparation._verifyPrivate(parent);
    for (final source in [
      state._state.path,
      state._state.installationPath,
      state._inspectionPath,
    ]) {
      if (ColdUpgradePreparation._overlap(parent.path, source)) {
        throw const FormatException(
          'uninstall recovery overlaps protected inputs',
        );
      }
    }
    if (maintenancePathEntryExists('${parent.path}/.uninstall.partial')) {
      throw const FormatException(
        'incomplete uninstall requires investigation',
      );
    }
    final lock = await parent.tryAcquireMaintenanceLock(
      _lockName,
      create: false,
    );
    if (lock == null) throw StateError('uninstall namespace already owned');
    OwnedImageDirectory? root;
    ColdUninstallPreparation? preparation;
    try {
      root = parent.directory('uninstall');
      await ColdUpgradePreparation._verifyPrivate(root);
      await ColdUpgradePreparation._entries(root, {'record.json'});
      final record = await ColdUpgradePreparation._readRecord(
        root,
        'record.json',
      );
      if (record.length != 16 ||
          record['format'] != 'gaovm.cold-uninstall-preparation.v1' ||
          record['source_app'] != state._state.installationPath ||
          record['source_state'] != state._state.path ||
          record['bundle_identifier'] != state._state.bundleIdentifier ||
          record['version'] != version ||
          record['team_identifier'] != teamIdentifier ||
          record['catalog_schema'] != state.observedCatalogSchema ||
          record['fence_path'] != fence.path ||
          record['source_state_identity'] is! Map<String, Object?> ||
          record['source_app_identity'] is! Map<String, Object?> ||
          record['workspace_identity'] is! Map<String, Object?> ||
          record['state_manifest'] is! Map<String, Object?> ||
          record['app_manifest'] is! Map<String, Object?> ||
          record['external_files'] is! Map<String, Object?> ||
          record['release'] is! Map<String, Object?>) {
        throw const FormatException(
          'uninstall checkpoint disagrees with explicit inputs',
        );
      }
      preparation = ColdUninstallPreparation._(
        state,
        fence,
        parent,
        lock,
        root,
        record,
        host,
        observer,
      );
      await preparation.verify();
      return preparation;
    } catch (_) {
      if (preparation != null) {
        preparation.close();
      } else {
        root?.close();
        lock.close();
      }
      rethrow;
    }
  }

  static Future<ColdUninstallPreparation> create(
    ColdStateSnapshot state,
    MaintenanceStateFence fence,
    OwnedImageDirectory parent, {
    required String version,
    required String teamIdentifier,
    required ReleaseInspectionHost host,
    required MacOsOpenReferences observer,
  }) async {
    await state.verify();
    await ColdUpgradePreparation._verifyFence(state, fence);
    await ColdUpgradePreparation._verifyPrivate(parent);
    for (final source in [
      state._state.path,
      state._state.installationPath,
      state._inspectionPath,
    ]) {
      if (ColdUpgradePreparation._overlap(parent.path, source)) {
        throw const FormatException(
          'uninstall storage overlaps protected inputs',
        );
      }
    }
    for (final name in ['uninstall', '.uninstall.partial']) {
      if (maintenancePathEntryExists('${parent.path}/$name')) {
        throw const FormatException('uninstall output already exists');
      }
    }
    final lock = await parent.tryAcquireMaintenanceLock(_lockName);
    if (lock == null) throw StateError('uninstall namespace already owned');
    OwnedImageDirectory? root;
    ColdUninstallPreparation? preparation;
    try {
      final lockFile = parent.file(_lockName);
      try {
        await lockFile.sync();
      } finally {
        lockFile.close();
      }
      await parent.sync();
      final release = await inspectMacOsRelease(
        Directory(state._state.appPath),
        bundleIdentifier: state._state.bundleIdentifier,
        version: version,
        teamIdentifier: teamIdentifier,
        catalogSchema: state.observedCatalogSchema ?? 0,
        host: host,
      );
      final app = await MaintenanceTree.open(Directory(state._state.appPath));
      late Map<String, Object?> manifest;
      try {
        await app.verify(release['tree'] as Map<String, Object?>);
        manifest = await app.capture(nativeMetadata: true);
      } finally {
        app.close();
      }
      if (manifest.values.cast<Map>().any(
        (entry) => (entry['metadata'] as Map)['has_acl'] != false,
      )) {
        throw const FormatException('app ACL grants require investigation');
      }
      final retained = await state._capture();
      final external = await _external(state);
      root = parent.createDirectory('.uninstall.partial');
      final record = <String, Object?>{
        'format': 'gaovm.cold-uninstall-preparation.v1',
        'source_app': state._state.installationPath,
        'source_state': state._state.path,
        'bundle_identifier': state._state.bundleIdentifier,
        'version': version,
        'team_identifier': teamIdentifier,
        'catalog_schema': state.observedCatalogSchema,
        'fence_path': fence.path,
        'source_state_identity': await ColdUpgradePreparation._identity(
          state._state.path,
        ),
        'source_app_identity': await ColdUpgradePreparation._identity(
          state._state.appPath,
        ),
        'workspace_identity': await root.maintenanceIdentity(),
        'state_manifest': retained,
        'app_manifest': manifest,
        'external_files': external,
        'runtime': state._runtime?.toJson(),
        'release': release,
      };
      if (await parent.availableBytes() <
          ColdUpgradePreparation._encode(record).length + 1024 * 1024) {
        throw const FormatException('insufficient uninstall checkpoint space');
      }
      await ColdUpgradePreparation._writeRecord(root, 'record.json', record);
      await root.sync();
      await parent.sync();
      preparation = ColdUninstallPreparation._(
        state,
        fence,
        parent,
        lock,
        root,
        record,
        host,
        observer,
      );
      await preparation.verify();
      await parent.renameDirectoryNoReplace('.uninstall.partial', 'uninstall');
      final published = parent.directory('uninstall');
      preparation._root.close();
      preparation._root = published;
      await preparation.verify();
      return preparation;
    } catch (_) {
      if (preparation != null) {
        preparation.close();
      } else {
        root?.close();
        lock.close();
      }
      rethrow;
    }
  }

  Future<void> verify() async {
    await _verifyFiles();
    await _state.verify();
    final release = await inspectMacOsRelease(
      Directory(_state._state.appPath),
      bundleIdentifier: _state._state.bundleIdentifier,
      version: _record['version'] as String,
      teamIdentifier: _record['team_identifier'] as String,
      catalogSchema: _state.observedCatalogSchema ?? 0,
      host: _host,
    );
    if (!ColdUpgradePreparation._equal(
      {...release}..remove('app_path'),
      {..._record['release'] as Map<String, Object?>}..remove('app_path'),
    )) {
      throw const FormatException('uninstall release evidence changed');
    }
    await ColdUpgradePreparation._noReferences(
      _observer,
      _state._state.appPath,
    );
    await _state.verify();
    await ColdUpgradePreparation._verifyFence(_state, _fence);
    // Complete filesystem-only reads AFTER the last native observation.
    await _verifyFiles();
  }

  Future<Map<String, Object?>> retireApp({
    required Future<void> Function() verifyCommandWork,
  }) async {
    await verify();
    final result = await _state._state.retireApp(
      _fence,
      _parent,
      'retirement',
      verifyPreparedInputs: () async {
        await verifyCommandWork();
        await _verifyFiles();
      },
    );
    await verify();
    return _retainedReport(result);
  }

  Future<Map<String, Object?>> observeRetiredApp() async {
    if (_state._state.appPath != '${_parent.path}/retirement/GaoVM.app' ||
        _state._state.appPath == _state._state.installationPath) {
      throw const FormatException('exact typed retired app required');
    }
    // The bound native cold lease revalidates the retirement intent/identity,
    // source-slot absence and both installed/retired process inventories.
    await verify();
    return _retainedReport({
      'source_app': _state._state.installationPath,
      'retired_app': _state._state.appPath,
      'journal_path': '${_parent.path}/retirement',
      'installed_candidate_published': false,
      'activation_authorized': false,
      'rollback_authorized': false,
    });
  }

  Map<String, Object?> _retainedReport(Map<String, Object?> result) => {
    ...result,
    'phase': 'uninstalled_data_retained',
    'uninstall_completed': true,
    'state_retained': true,
    'data_deleted': false,
    'committed': false,
    'preparation_path': path,
  };

  Future<void> _verifyFiles() async {
    if (_closed) throw StateError('uninstall preparation is closed');
    await ColdUpgradePreparation._verifyPrivate(_parent);
    await ColdUpgradePreparation._verifyPrivate(_root);
    _lock.verifyPathBinding();
    final lockFile = _parent.file(_lockName);
    try {
      final before = lockFile.stat();
      if (before.mode & 0xfff != 0x180 ||
          before.size != 0 ||
          before.linkCount != 1 ||
          (await lockFile.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('uninstall namespace lock changed');
      }
      await lockFile.verifyPathBinding();
      if (lockFile.stat() != before) {
        throw const FormatException('uninstall lock changed while reading');
      }
    } finally {
      lockFile.close();
    }
    await ColdUpgradePreparation._entries(_root, {'record.json'});
    await ColdUpgradePreparation._checkRecord(_root, 'record.json', _record);
    if (!ColdUpgradePreparation._equal(
          await _root.maintenanceIdentity(),
          _record['workspace_identity'],
        ) ||
        !ColdUpgradePreparation._equal(
          await ColdUpgradePreparation._identity(_state._state.path),
          _record['source_state_identity'],
        ) ||
        !ColdUpgradePreparation._equal(
          await ColdUpgradePreparation._identity(_state._state.appPath),
          _record['source_app_identity'],
        ) ||
        !ColdUpgradePreparation._equal(
          await _external(_state),
          _record['external_files'],
        )) {
      throw const FormatException(
        'uninstall source identity or external data changed',
      );
    }
    await _state._runtime?._verifyTree();
    if (!ColdUpgradePreparation._equal(
          _state._runtime?.toJson(),
          _record['runtime'],
        ) ||
        !ColdUpgradePreparation._equal(
          await _state._capturePersistent(),
          _record['state_manifest'],
        )) {
      throw const FormatException('retained uninstall data changed');
    }
    final app = await MaintenanceTree.open(Directory(_state._state.appPath));
    try {
      await app.verify(
        _record['app_manifest'] as Map<String, Object?>,
        nativeMetadata: true,
      );
    } finally {
      app.close();
    }
    await ColdUpgradePreparation._checkRecord(_root, 'record.json', _record);
    _lock.verifyPathBinding();
    await _root.verifyPathBinding();
  }

  static Future<Map<String, Object?>> _external(ColdStateSnapshot state) async {
    final files = <String, _HeldReference>{
      for (final held in [
        ...?state._references?._files.values,
        ...?state._assets?._files._files.values,
        ...state._legacy._files.values,
      ])
        held.file.path: held,
    };
    final paths = files.keys.toList()..sort();
    final result = <String, Object?>{};
    for (final path in paths) {
      final held = files[path]!;
      await held.parent.verifyPathBinding();
      final evidence = await _seal(held.file);
      if (JsonValue.fromJson(evidence) != held.evidence) {
        throw const ColdStateFailure('uninstall', 'external input changed');
      }
      result[path] = evidence;
    }
    return result;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _root.close();
    _lock.close();
  }
}
