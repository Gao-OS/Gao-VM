part of 'cold_catalog_inspection.dart';

/// Prepare independent old-app/whole-state copies under the original fence.
/// Does not open the current catalog, replace either installation slot, retire
/// the fence or start a service. The caller retains its current lease/fence/work.
final class ColdRollbackPreparation {
  ColdRollbackPreparation._(
    this._current,
    this._fence,
    this._work,
    this._upgrade,
    this._upgradeLock,
    this._lock,
    this._root,
    this._sourceIntent,
    this._sourceRecord,
    this._intent,
    this._currentTree,
    this._oldApp,
    this._oldState,
    this._observer,
  );

  static const _lockName = '.gaovm-cold-rollback.lock';
  final ColdStateLease _current;
  final MaintenanceStateFence _fence;
  final OwnedImageDirectory _work, _upgrade, _root;
  final OwnedImageLock _upgradeLock, _lock;
  final Map<String, Object?> _sourceIntent, _sourceRecord, _intent;
  final MaintenanceTree _currentTree, _oldApp, _oldState;
  final MacOsOpenReferences _observer;
  final _external = <String, _HeldReference>{};
  Map<String, Object?>? _record;
  String _completionName = 'prepared';
  MacOsColdStateHost? _stagedHost;
  ColdStateLease? _stagedLease;
  ColdCatalogInspection? _catalog;
  OwnedImageDirectory? _inspection;
  bool _closed = false, _busy = false;

  String get path => _root.path;
  String get appPath => '$path/app/payload.app';
  String get statePath => '$path/state/payload';

  Map<String, Object?> toJson() {
    if (_closed || _record == null) {
      throw StateError('complete rollback preparation required');
    }
    return JsonObjectValue.fromJson(_record!).toJson();
  }

  static Future<ColdRollbackPreparation> prepare(
    ColdStateLease current,
    MaintenanceStateFence fence,
    OwnedImageDirectory work,
    String preparationName, {
    required bool acceptHistoryRewind,
    required String oldVersion,
    required String newVersion,
    required String teamIdentifier,
    required int? sourceCatalogSchema,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) => _prepare(
    current,
    fence,
    work,
    preparationName,
    acceptHistoryRewind: acceptHistoryRewind,
    oldVersion: oldVersion,
    newVersion: newVersion,
    teamIdentifier: teamIdentifier,
    sourceCatalogSchema: sourceCatalogSchema,
    host: host,
    observer: observer,
    inventory: inventory,
  );

  /// Reopen only a complete fixed checkpoint. The caller supplies a new empty,
  /// private, disjoint inspection directory, not a path selected from a record.
  /// Reacquires real state ownership and never rewrites the sealed checkpoint.
  static Future<ColdRollbackPreparation> open(
    ColdStateLease current,
    MaintenanceStateFence fence,
    OwnedImageDirectory work,
    String preparationName,
    OwnedImageDirectory inspection, {
    required bool acceptHistoryRewind,
    required String oldVersion,
    required String newVersion,
    required String teamIdentifier,
    required int? sourceCatalogSchema,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) => _prepare(
    current,
    fence,
    work,
    preparationName,
    acceptHistoryRewind: acceptHistoryRewind,
    oldVersion: oldVersion,
    newVersion: newVersion,
    teamIdentifier: teamIdentifier,
    sourceCatalogSchema: sourceCatalogSchema,
    host: host,
    observer: observer,
    inventory: inventory,
    recoveryInspection: inspection,
  );

  static Future<ColdRollbackPreparation> _prepare(
    ColdStateLease current,
    MaintenanceStateFence fence,
    OwnedImageDirectory work,
    String preparationName, {
    required bool acceptHistoryRewind,
    required String oldVersion,
    required String newVersion,
    required String teamIdentifier,
    required int? sourceCatalogSchema,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
    OwnedImageDirectory? recoveryInspection,
  }) async {
    final reopening = recoveryInspection != null;
    if (!acceptHistoryRewind) {
      throw const FormatException(
        'explicit history rewind acceptance required',
      );
    }
    ColdUpgradePreparation._validateName(preparationName);
    if ({
      'rollback',
      '.rollback.partial',
      _lockName,
    }.contains(preparationName)) {
      throw const FormatException(
        'rollback and original pair must be disjoint',
      );
    }
    await current.verify();
    await ColdUpgradePreparation._verifyPrivate(work);
    for (final source in {
      current.path,
      current.appPath,
      current.installationPath,
    }) {
      if (ColdUpgradePreparation._overlap(work.path, source)) {
        throw const FormatException('rollback work overlaps original targets');
      }
    }
    if (fence.retiredForCommit) {
      throw const FormatException('active original startup fence required');
    }
    if (maintenancePathEntryExists('${work.path}/.rollback.partial') ||
        reopening != maintenancePathEntryExists('${work.path}/rollback')) {
      throw const FormatException(
        'explicit complete rollback checkpoint required',
      );
    }
    if (recoveryInspection != null) {
      await ColdUpgradePreparation._verifyPrivate(recoveryInspection);
      if (!await Directory(
            recoveryInspection.path,
          ).list(followLinks: false).isEmpty ||
          {
            work.path,
            current.path,
            current.appPath,
            current.installationPath,
          }.any(
            (path) =>
                ColdUpgradePreparation._overlap(recoveryInspection.path, path),
          )) {
        throw const FormatException(
          'new disjoint recovery inspection directory required',
        );
      }
    }
    final upgradeLock = await work.tryAcquireMaintenanceLock(
      '.gaovm-upgrade.lock',
      create: false,
    );
    if (upgradeLock == null) throw StateError('original pair already owned');
    OwnedImageLock? lock;
    OwnedImageDirectory? upgrade, root;
    MaintenanceTree? currentTree, oldApp, oldState;
    ColdRollbackPreparation? result;
    try {
      lock = await work.tryAcquireMaintenanceLock(
        _lockName,
        create: !reopening,
      );
      if (lock == null) throw StateError('rollback work already owned');
      upgrade = work.directory(preparationName);
      await ColdUpgradePreparation._verifyPrivate(upgrade);
      final intent = await ColdUpgradePreparation._readRecord(
        upgrade,
        'intent.json',
      );
      final prepared = upgrade.directory('prepared');
      late Map<String, Object?> record;
      try {
        await ColdUpgradePreparation._verifyPrivate(prepared);
        await ColdUpgradePreparation._entries(prepared, {'record.json'});
        record = await ColdUpgradePreparation._readRecord(
          prepared,
          'record.json',
        );
      } finally {
        prepared.close();
      }
      if (intent.length != 13 ||
          intent['format'] != 'gaovm.cold-upgrade-intent.v1' ||
          intent['source_app'] != current.installationPath ||
          intent['source_state'] != current.path ||
          intent['bundle_identifier'] != current.bundleIdentifier ||
          intent['old_version'] != oldVersion ||
          intent['new_version'] != newVersion ||
          intent['team_identifier'] != teamIdentifier ||
          intent['catalog_schema'] != sourceCatalogSchema ||
          intent['fence_path'] != fence.path ||
          !_same(
            intent['workspace_identity'],
            await upgrade.maintenanceIdentity(),
          ) ||
          !_same(
            intent['source_state_identity'],
            await ColdUpgradePreparation._identity(current.path),
          ) ||
          record.length != 13 ||
          record['format'] != 'gaovm.cold-upgrade-preparation.v1' ||
          record['phase'] != 'candidate_prepared' ||
          record['catalog_schema'] != sourceCatalogSchema ||
          record['intent_digest'] != _hash(intent) ||
          record['ordinary_startup_fenced'] != true ||
          record['installed_candidate_published'] != false ||
          record['external_files_backed_up'] != false ||
          record['rollback_authorized'] != false) {
        throw const FormatException(
          'original pair or explicit rollback inputs disagree',
        );
      }
      for (final entry in {
        'original_app_receipt': (
          'payload.app',
          'gaovm.tree-snapshot.v1',
          current.installationPath,
        ),
        'original_state_receipt': (
          'payload',
          'gaovm.cold-state-snapshot.v1',
          current.path,
        ),
      }.entries) {
        final receipt = record[entry.key];
        if (receipt is! Map<String, Object?> ||
            receipt['payload_name'] != entry.value.$1 ||
            receipt['format'] != entry.value.$2 ||
            receipt['source_path'] != entry.value.$3 ||
            receipt['manifest'] is! Map<String, Object?> ||
            receipt['manifest_digest'] !=
                _manifestHash(receipt['manifest'] as Map<String, Object?>)) {
          throw const FormatException(
            'complete original app and state receipts required',
          );
        }
      }
      final stateReceipt =
          record['original_state_receipt'] as Map<String, Object?>;
      final boundary = stateReceipt['boundary'];
      if (!_same(stateReceipt['omitted_paths'], ['run']) ||
          boundary is! Map<String, Object?> ||
          boundary['format'] != 'gaovm.cold-state-boundary.v1' ||
          boundary['source_state'] != current.path ||
          (boundary['catalog'] as Map?)?['schema_version'] !=
              sourceCatalogSchema) {
        throw const FormatException(
          'original complete cold-state boundary required',
        );
      }
      currentTree = await MaintenanceTree.open(Directory(current.path));
      oldApp = await MaintenanceTree.open(
        Directory('${upgrade.path}/original-app/payload.app'),
      );
      oldState = await MaintenanceTree.open(
        Directory('${upgrade.path}/original-state/payload'),
      );
      root = reopening
          ? work.directory('rollback')
          : work.createDirectory('rollback');
      final retainedIntent = reopening
          ? await ColdUpgradePreparation._readRecord(root, 'intent.json')
          : null;
      if (retainedIntent != null &&
          (retainedIntent.length != 16 ||
              retainedIntent['current_state_manifest']
                  is! Map<String, Object?>)) {
        throw const FormatException('unrecognized rollback intent');
      }
      final manifest = reopening
          ? retainedIntent!['current_state_manifest']
          : await currentTree.captureStateData(
              verifyBoundary: () async {
                await current.verify();
                return {'source_state': current.path};
              },
            );
      final rollbackIntent = <String, Object?>{
        'format': 'gaovm.cold-rollback-intent.v1',
        'source_app': current.installationPath,
        'source_state': current.path,
        'bundle_identifier': current.bundleIdentifier,
        'old_version': oldVersion,
        'new_version': newVersion,
        'team_identifier': teamIdentifier,
        'catalog_schema': sourceCatalogSchema,
        'fence_path': fence.path,
        'workspace_identity': await root.maintenanceIdentity(),
        'source_state_identity': intent['source_state_identity'],
        'preparation_identity': intent['workspace_identity'],
        'preparation_intent_digest': _hash(intent),
        'preparation_record_digest': _hash(record),
        'current_state_manifest': manifest,
        'history_rewind_accepted': true,
      };
      if (reopening) {
        if (!_same(rollbackIntent, retainedIntent)) {
          throw const FormatException(
            'rollback intent or explicit inputs changed',
          );
        }
      } else {
        await ColdUpgradePreparation._writeRecord(
          root,
          'intent.json',
          rollbackIntent,
        );
        await root.sync();
        final lockFile = work.file(_lockName);
        try {
          await lockFile.sync();
        } finally {
          lockFile.close();
        }
        await work.sync();
      }
      final references =
          observer ??
          MacOsOpenReferences(
            command: (path, args) =>
                awaitColdCommandExit(() => runMaintenanceCommand(path, args)),
          );
      result = ColdRollbackPreparation._(
        current,
        fence,
        work,
        upgrade,
        upgradeLock,
        lock,
        root,
        intent,
        record,
        rollbackIntent,
        currentTree,
        oldApp,
        oldState,
        references,
      );
      if (reopening) {
        final complete = maintenancePathEntryExists('${root.path}/prepared');
        if (complete ==
            maintenancePathEntryExists('${root.path}/.prepared.partial')) {
          throw const FormatException(
            'exactly one complete rollback checkpoint required',
          );
        }
        result._completionName = complete ? 'prepared' : '.prepared.partial';
        final prepared = root.directory(result._completionName);
        try {
          await ColdUpgradePreparation._verifyPrivate(prepared);
          await ColdUpgradePreparation._entries(prepared, {'record.json'});
          result._record = await ColdUpgradePreparation._readRecord(
            prepared,
            'record.json',
          );
        } finally {
          prepared.close();
        }
        final saved = result._record!;
        if (saved.length != 15 ||
            saved['format'] != 'gaovm.cold-rollback-preparation.v1' ||
            saved['phase'] != 'rollback_prepared' ||
            saved['intent_digest'] != _hash(rollbackIntent) ||
            saved['catalog_schema'] != sourceCatalogSchema ||
            saved['history_rewind_accepted'] != true ||
            saved['ordinary_startup_fenced'] != true ||
            saved['installed_pair_restored'] != false ||
            saved['committed'] != false ||
            saved['startup_allowed'] != false ||
            saved['service_actions_performed'] != false ||
            saved['external_files_backed_up'] != false) {
          throw const FormatException(
            'unrecognized complete rollback preparation',
          );
        }
        await result._verifyOutputFiles();
      }
      await result._openExternalFiles();
      await result._verifySources();
      final execution = OwnedColdInspection(host);
      final release = await inspectMacOsRelease(
        Directory(oldApp.path),
        bundleIdentifier: current.bundleIdentifier,
        version: oldVersion,
        teamIdentifier: teamIdentifier,
        catalogSchema: sourceCatalogSchema ?? 0,
        host: execution,
      );
      if (!_same(
        {...release}..remove('app_path'),
        {...record['original_release'] as Map<String, Object?>}
          ..remove('app_path'),
      )) {
        throw const FormatException('original app release evidence changed');
      }
      await result._verifySources();
      final appReceipt = reopening
          ? result._record!['app_receipt'] as Map<String, Object?>
          : await oldApp.snapshotTo(root, 'app');
      await result._verifySources();
      final restoredStateReceipt = reopening
          ? result._record!['state_receipt'] as Map<String, Object?>
          : await oldState.snapshotTo(root, 'state');
      result._inspection = reopening
          ? await OwnedImageDirectory.open(Directory(recoveryInspection.path))
          : root.createDirectory('inspection');
      result._stagedHost = await MacOsColdStateHost.open(
        Directory(result.appPath),
        bundleIdentifier: current.bundleIdentifier,
        version: oldVersion,
        teamIdentifier: teamIdentifier,
        catalogSchema: sourceCatalogSchema ?? 0,
        host: execution,
        observer: references,
        inventory: inventory,
      );
      result._stagedLease = await ColdStateLease.acquire(
        Directory(result.statePath),
        bundleIdentifier: current.bundleIdentifier,
        host: result._stagedHost!,
      );
      if (sourceCatalogSchema == null) {
        if (maintenancePathEntryExists('${result.statePath}/gaovm.db')) {
          throw const FormatException('unexpected original catalog');
        }
      } else {
        result._catalog = await ColdCatalogInspection.inspect(
          result._stagedLease!,
          result._inspection!,
        );
        result._catalog!.requireQuiescent();
        if (result._catalog!.schemaVersion != sourceCatalogSchema) {
          throw const FormatException(
            'original catalog schema differs from sealed pair',
          );
        }
      }
      final outputRecord = <String, Object?>{
        'format': 'gaovm.cold-rollback-preparation.v1',
        'phase': 'rollback_prepared',
        'intent_digest': _hash(rollbackIntent),
        'catalog_schema': result._catalog?.schemaVersion,
        'app_receipt': appReceipt,
        'state_receipt': restoredStateReceipt,
        'app_identity': await ColdUpgradePreparation._identity(result.appPath),
        'state_identity': await ColdUpgradePreparation._identity(
          result.statePath,
        ),
        'history_rewind_accepted': true,
        'ordinary_startup_fenced': true,
        'installed_pair_restored': false,
        'committed': false,
        'startup_allowed': false,
        'service_actions_performed': false,
        'external_files_backed_up': false,
      };
      if (reopening) {
        if (!_same(outputRecord, result._record)) {
          throw const FormatException('recovered rollback evidence changed');
        }
      } else {
        result._record = outputRecord;
        final checkpoint = root.createDirectory('.prepared.partial');
        try {
          await ColdUpgradePreparation._writeRecord(
            checkpoint,
            'record.json',
            outputRecord,
          );
          await checkpoint.sync();
        } finally {
          checkpoint.close();
        }
        await root.renameDirectoryNoReplace('.prepared.partial', 'prepared');
      }
      await result.verify();
      if (result._completionName == '.prepared.partial') {
        // The original owner, independent restored-state owner, native cold
        // context and complete read set were re-established above. JSON alone
        // never promotes a partial or authorizes a canonical state replacement.
        await root.renameDirectoryNoReplace('.prepared.partial', 'prepared');
        result._completionName = 'prepared';
        await result.verify();
      }
      return result;
    } catch (_) {
      if (result != null) {
        result.close();
      } else {
        oldState?.close();
        oldApp?.close();
        currentTree?.close();
        root?.close();
        upgrade?.close();
        lock?.close();
        upgradeLock.close();
      }
      rethrow;
    }
  }

  Future<void> _openExternalFiles() async {
    final boundary =
        (_sourceRecord['original_state_receipt'] as Map)['boundary'] as Map;
    final expected = <String, Map<String, Object?>>{};
    for (final key in ['external_files', 'legacy']) {
      final group = boundary[key];
      if (group == null) continue;
      if (group is! Map || group['files'] is! List) {
        throw const FormatException(
          'original external file evidence is incomplete',
        );
      }
      for (final value in group['files'] as List) {
        if (value is! Map ||
            value['path'] is! String ||
            value['evidence'] is! Map<String, Object?>) {
          throw const FormatException(
            'invalid original external file evidence',
          );
        }
        final path = value['path'] as String;
        if (path.startsWith('${_current.path}/')) continue;
        final file = File(path);
        final evidence = value['evidence'] as Map<String, Object?>;
        if (!file.isAbsolute ||
            file.absolute.path != path ||
            await file.resolveSymbolicLinks() != path ||
            expected.containsKey(path) &&
                JsonValue.fromJson(expected[path]) !=
                    JsonValue.fromJson(evidence)) {
          throw const FormatException(
            'canonical consistent original external file required',
          );
        }
        expected[path] = evidence;
        if (expected.length > 16384)
          throw const FormatException('too many external files');
      }
    }
    for (final entry in expected.entries) {
      final file = File(entry.key);
      final parent = await OwnedImageDirectory.open(file.parent);
      OwnedImageFile? held;
      try {
        if (parent.path != file.parent.path)
          throw const FormatException('external parent changed');
        held = parent.file(file.uri.pathSegments.last);
        if (JsonValue.fromJson(await _seal(held)) !=
                JsonValue.fromJson(entry.value) ||
            (entry.value['metadata'] as Map?)?['has_acl'] != false) {
          throw const FormatException('original external file changed');
        }
        _external[entry.key] = _HeldReference(parent, held, entry.value, []);
      } catch (_) {
        held?.close();
        parent.close();
        rethrow;
      }
    }
  }

  Future<void> _verifySources() async {
    await _current.verify();
    for (final tree in [_oldApp, _oldState]) {
      if ((await _observer.directory(
        Directory(tree.path),
      )).any((process) => process != pid)) {
        throw const ColdStateFailure(
          'rollback_snapshot_references',
          'other processes reference an original snapshot',
        );
      }
    }
    for (final held in _external.values) {
      if ((await _observer.file(
        File(held.file.path),
      )).any((process) => process != pid)) {
        throw const ColdStateFailure(
          'rollback_external_files',
          'other processes reference an original VM file',
        );
      }
    }
    await _current.verify();
    await _verifySourceFiles();
  }

  // Filesystem-only closure, after the last native observation of a pass.
  Future<void> _verifySourceFiles() async {
    if (_closed) throw StateError('rollback preparation is closed');
    await ColdUpgradePreparation._verifyPrivate(_work);
    await _verifyLock('.gaovm-upgrade.lock', _upgradeLock);
    await _verifyLock(_lockName, _lock);
    await ColdUpgradePreparation._verifyPrivate(_upgrade);
    if (!_same(
      await _upgrade.maintenanceIdentity(),
      _sourceIntent['workspace_identity'],
    )) {
      throw const FormatException('original preparation inode changed');
    }
    await ColdUpgradePreparation._entries(_upgrade, {
      'intent.json',
      'prepared',
      'original-app',
      'original-state',
      'candidate-app',
      '.gaovm-maintenance.lock',
    });
    await _checkLockFile(_upgrade, '.gaovm-maintenance.lock');
    await ColdUpgradePreparation._checkRecord(
      _upgrade,
      'intent.json',
      _sourceIntent,
    );
    final prepared = _upgrade.directory('prepared');
    try {
      await ColdUpgradePreparation._verifyPrivate(prepared);
      await ColdUpgradePreparation._entries(prepared, {'record.json'});
      await ColdUpgradePreparation._checkRecord(
        prepared,
        'record.json',
        _sourceRecord,
      );
    } finally {
      prepared.close();
    }
    for (final entry in {
      'original-app': 'original_app_receipt',
      'original-state': 'original_state_receipt',
    }.entries) {
      final wrapper = _upgrade.directory(entry.key);
      try {
        await ColdUpgradePreparation._verifyPrivate(wrapper);
        await MaintenanceTree.verifySnapshotContents(
          wrapper,
          _sourceRecord[entry.value] as Map<String, Object?>,
        );
      } finally {
        wrapper.close();
      }
    }
    final currentRoot = await OwnedImageDirectory.open(
      Directory(_current.path),
    );
    try {
      if (_fence.retiredForCommit)
        throw const FormatException('active original fence required');
      await _fence.verifyFor(
        currentRoot,
        bundleIdentifier: _current.bundleIdentifier,
        appPath: _current.installationPath,
      );
      if (!_same(
        await currentRoot.maintenanceIdentity(),
        _intent['source_state_identity'],
      )) {
        throw const FormatException('original state inode changed');
      }
    } finally {
      currentRoot.close();
    }
    for (final held in _external.values) {
      await held.parent.verifyPathBinding();
      if (JsonValue.fromJson(await _seal(held.file)) != held.evidence) {
        throw const FormatException(
          'original external file changed after observation',
        );
      }
    }
    final current = await _currentTree.captureStateData(
      verifyBoundary: () async => {'source_state': _current.path},
    );
    if (!_same(current, _intent['current_state_manifest'])) {
      throw const FormatException(
        'post-upgrade state changed during rollback preparation',
      );
    }
    await ColdUpgradePreparation._verifyPrivate(_root);
    if (!_same(
      await _root.maintenanceIdentity(),
      _intent['workspace_identity'],
    )) {
      throw const FormatException('rollback workspace inode changed');
    }
    await ColdUpgradePreparation._checkRecord(_root, 'intent.json', _intent);
  }

  Future<void> _verifyLock(String name, OwnedImageLock lock) async {
    lock.verifyPathBinding();
    await _checkLockFile(_work, name);
    lock.verifyPathBinding();
  }

  static Future<void> _checkLockFile(
    OwnedImageDirectory root,
    String name,
  ) async {
    final file = root.file(name);
    try {
      final before = file.stat();
      if (before.mode & 0xfff != 0x180 ||
          before.size != 0 ||
          before.linkCount != 1 ||
          (await file.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('rollback namespace lock changed');
      }
      await file.verifyPathBinding();
      if (file.stat() != before)
        throw const FormatException('rollback lock changed during observation');
    } finally {
      file.close();
    }
  }

  Future<void> verify() async {
    if (_closed || _busy || _record == null || _stagedLease == null) {
      throw StateError('complete available rollback preparation required');
    }
    _busy = true;
    try {
      await _verifySources();
      await ColdUpgradePreparation._noReferences(_observer, appPath);
      await _catalog?.verify();
      await _stagedLease!.verify();
      await _current.verify();
      // No native process/service observers after this full read-set closure.
      await _verifySourceFiles();
      await _catalog?._verifySourceFiles();
      await ColdUpgradePreparation._verifyPrivate(_inspection!);
      await _verifyOutputFiles();
    } finally {
      _busy = false;
    }
  }

  /// First cutover phase only: preserve the whole failed/current generation
  /// while retaining both persistent startup fences and the exact kernel owner.
  /// Consumes the caller's current lease on success. Does not install the old
  /// state/app pair, retire either fence or start a service.
  Future<PreservedColdState> preserveCurrentState() async {
    await verify();
    _busy = true;
    try {
      return await _current.preserveForRollback(
        _fence,
        _work,
        'retained-current',
        verifyPreparedInputs: () async {
          await _stagedLease!.verify();
          await _catalog?.verify();
          await _verifySources();
          await _catalog?._verifySourceFiles();
          await ColdUpgradePreparation._verifyPrivate(_inspection!);
          await _verifyOutputFiles();
        },
      );
    } finally {
      _busy = false;
    }
  }

  Future<void> _verifyOutputFiles() async {
    await ColdUpgradePreparation._entries(_root, {
      'intent.json',
      'app',
      'state',
      'inspection',
      _completionName,
      '.gaovm-maintenance.lock',
    });
    await _checkLockFile(_root, '.gaovm-maintenance.lock');
    for (final entry in {
      'app': 'app_receipt',
      'state': 'state_receipt',
    }.entries) {
      final wrapper = _root.directory(entry.key);
      try {
        await ColdUpgradePreparation._verifyPrivate(wrapper);
        final receipt = _record![entry.value];
        final original =
            _sourceRecord[entry.key == 'app'
                    ? 'original_app_receipt'
                    : 'original_state_receipt']
                as Map;
        if (receipt is! Map<String, Object?> ||
            receipt.length != 6 ||
            receipt['format'] != 'gaovm.tree-snapshot.v1' ||
            receipt['source_path'] !=
                (entry.key == 'app' ? _oldApp.path : _oldState.path) ||
            receipt['snapshot_path'] != '$path/${entry.key}' ||
            receipt['payload_name'] !=
                (entry.key == 'app' ? 'payload.app' : 'payload') ||
            receipt['manifest'] is! Map<String, Object?> ||
            receipt['manifest_digest'] !=
                _manifestHash(receipt['manifest'] as Map<String, Object?>) ||
            !_same(receipt['manifest'], original['manifest'])) {
          throw const FormatException(
            'restoration copy differs from complete old pair',
          );
        }
        await MaintenanceTree.verifySnapshotContents(wrapper, receipt);
      } finally {
        wrapper.close();
      }
    }
    final originalInspection = _root.directory('inspection');
    try {
      await ColdUpgradePreparation._verifyPrivate(originalInspection);
    } finally {
      originalInspection.close();
    }
    if (!_same(
          await ColdUpgradePreparation._identity(appPath),
          _record!['app_identity'],
        ) ||
        !_same(
          await ColdUpgradePreparation._identity(statePath),
          _record!['state_identity'],
        )) {
      throw const FormatException('restoration copy inode changed');
    }
    final prepared = _root.directory(_completionName);
    try {
      await ColdUpgradePreparation._verifyPrivate(prepared);
      await ColdUpgradePreparation._entries(prepared, {'record.json'});
      await ColdUpgradePreparation._checkRecord(
        prepared,
        'record.json',
        _record!,
      );
    } finally {
      prepared.close();
    }
    await _root.verifyPathBinding();
  }

  /// Releases readers and the independent staged-state owner, never outputs or
  /// the caller's current state ownership/fence. Pending verification must drain.
  void close() {
    if (_busy) throw StateError('rollback preparation verification is pending');
    if (_closed) return;
    _closed = true;
    _stagedLease?.close();
    _stagedHost?.close();
    _inspection?.close();
    for (final held in _external.values) {
      held.close();
    }
    _oldState.close();
    _oldApp.close();
    _currentTree.close();
    _root.close();
    _upgrade.close();
    _lock.close();
    _upgradeLock.close();
  }

  static bool _same(Object? a, Object? b) =>
      ColdUpgradePreparation._equal(a, b);
  static String _manifestHash(Map<String, Object?> value) =>
      'sha256:${sha256.convert(utf8.encode(jsonEncode(value)))}';
  static String _hash(Map<String, Object?> value) =>
      'sha256:${sha256.convert(ColdUpgradePreparation._encode(value))}';
}
