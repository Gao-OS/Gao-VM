part of 'cold_catalog_inspection.dart';

Future<ColdRollbackStateRestoration> _openRollbackPair(
  OwnedImageDirectory work,
  String preparationName,
  MaintenanceStateFence original, {
  required Directory installationApp,
  required ({OwnedImageDirectory storage, String name}) retirement,
  required ({OwnedImageDirectory storage, String name})? publication,
  required String bundleIdentifier,
  required bool acceptHistoryRewind,
  required String oldVersion,
  required String newVersion,
  required String teamIdentifier,
  required int? sourceCatalogSchema,
  required ReleaseInspectionHost host,
  required MacOsOpenReferences? observer,
  required Future<DriverInventorySnapshot> Function(String)? inventory,
}) async {
  if (!acceptHistoryRewind || original.retiredForCommit) {
    throw const FormatException(
      'history rewind acceptance and active fence required',
    );
  }
  ColdUpgradePreparation._validateName(preparationName);
  if ({
        'rollback',
        '.rollback.partial',
        ColdRollbackPreparation._lockName,
      }.contains(preparationName) ||
      installationApp.path != installationApp.absolute.path ||
      !installationApp.path.endsWith('.app')) {
    throw const FormatException(
      'explicit fixed paired recovery selectors required',
    );
  }
  await original.verify();
  await ColdUpgradePreparation._verifyPrivate(work);
  final retained = '${work.path}/retained-current/state';
  final stagedApp = '${work.path}/rollback/app/payload.app';
  final stagedState = '${work.path}/rollback/state/payload';
  for (final path in {original.sourceStatePath, installationApp.path}) {
    if (ColdUpgradePreparation._overlap(work.path, path)) {
      throw const FormatException('paired recovery work overlaps installation');
    }
  }
  if (maintenancePathEntryExists('${work.path}/.rollback.partial') ||
      maintenancePathEntryExists(stagedApp) ||
      maintenancePathEntryExists(stagedState)) {
    throw const FormatException('fixed post-move paired layout required');
  }
  final upgradeLock = await work.tryAcquireMaintenanceLock(
    '.gaovm-upgrade.lock',
    create: false,
  );
  if (upgradeLock == null) throw StateError('original pair already owned');
  OwnedImageLock? rollbackLock;
  OwnedImageDirectory? upgrade, root;
  MaintenanceTree? currentTree, oldApp, oldState;
  ColdRollbackPreparation? prepared;
  _RollbackRecoveryNative? native;
  try {
    rollbackLock = await work.tryAcquireMaintenanceLock(
      ColdRollbackPreparation._lockName,
      create: false,
    );
    if (rollbackLock == null)
      throw StateError('rollback namespace already owned');
    upgrade = work.directory(preparationName);
    root = work.directory('rollback');
    await ColdUpgradePreparation._verifyPrivate(upgrade);
    await ColdUpgradePreparation._verifyPrivate(root);
    final sourceIntent = await ColdUpgradePreparation._readRecord(
      upgrade,
      'intent.json',
    );
    final checkpoint = upgrade.directory('prepared');
    late Map<String, Object?> sourceRecord;
    try {
      sourceRecord = await ColdUpgradePreparation._readRecord(
        checkpoint,
        'record.json',
      );
    } finally {
      checkpoint.close();
    }
    bool same(Object? a, Object? b) => ColdRollbackPreparation._same(a, b);
    final sourceState = original.sourceStatePath;
    if (sourceIntent.length != 13 ||
        sourceIntent['format'] != 'gaovm.cold-upgrade-intent.v1' ||
        sourceIntent['source_app'] != installationApp.path ||
        sourceIntent['source_state'] != sourceState ||
        sourceIntent['bundle_identifier'] != bundleIdentifier ||
        sourceIntent['old_version'] != oldVersion ||
        sourceIntent['new_version'] != newVersion ||
        sourceIntent['team_identifier'] != teamIdentifier ||
        sourceIntent['catalog_schema'] != sourceCatalogSchema ||
        sourceIntent['fence_path'] != original.path ||
        !same(
          sourceIntent['workspace_identity'],
          await upgrade.maintenanceIdentity(),
        ) ||
        sourceRecord.length != 13 ||
        sourceRecord['format'] != 'gaovm.cold-upgrade-preparation.v1' ||
        sourceRecord['phase'] != 'candidate_prepared' ||
        sourceRecord['intent_digest'] !=
            ColdRollbackPreparation._hash(sourceIntent) ||
        sourceRecord['catalog_schema'] != sourceCatalogSchema ||
        sourceRecord['ordinary_startup_fenced'] != true ||
        sourceRecord['installed_candidate_published'] != false ||
        sourceRecord['external_files_backed_up'] != false ||
        sourceRecord['rollback_authorized'] != false ||
        sourceRecord['original_release'] is! Map<String, Object?>) {
      throw const FormatException(
        'original pair differs from explicit recovery inputs',
      );
    }
    for (final (key, payload, format, source) in [
      (
        'original_app_receipt',
        'payload.app',
        'gaovm.tree-snapshot.v1',
        installationApp.path,
      ),
      (
        'original_state_receipt',
        'payload',
        'gaovm.cold-state-snapshot.v1',
        sourceState,
      ),
    ]) {
      final receipt = sourceRecord[key];
      if (receipt is! Map<String, Object?> ||
          receipt['payload_name'] != payload ||
          receipt['format'] != format ||
          receipt['source_path'] != source ||
          receipt['manifest'] is! Map<String, Object?> ||
          receipt['manifest_digest'] !=
              ColdRollbackPreparation._manifestHash(
                receipt['manifest'] as Map<String, Object?>,
              )) {
        throw const FormatException(
          'complete matching original pair receipts required',
        );
      }
    }
    final receipt = sourceRecord['original_state_receipt'] as Map;
    final boundary = receipt['boundary'];
    if (!same(receipt['omitted_paths'], ['run']) ||
        boundary is! Map ||
        boundary['format'] != 'gaovm.cold-state-boundary.v1' ||
        boundary['source_state'] != sourceState ||
        (boundary['catalog'] as Map?)?['schema_version'] !=
            sourceCatalogSchema) {
      throw const FormatException(
        'matching original cold-state boundary required',
      );
    }
    currentTree = await MaintenanceTree.open(Directory(retained));
    oldApp = await MaintenanceTree.open(
      Directory('${upgrade.path}/original-app/payload.app'),
    );
    oldState = await MaintenanceTree.open(
      Directory('${upgrade.path}/original-state/payload'),
    );
    final intent = await ColdUpgradePreparation._readRecord(
      root,
      'intent.json',
    );
    final expectedIntent = <String, Object?>{
      'format': 'gaovm.cold-rollback-intent.v1',
      'source_app': installationApp.path,
      'source_state': sourceState,
      'bundle_identifier': bundleIdentifier,
      'old_version': oldVersion,
      'new_version': newVersion,
      'team_identifier': teamIdentifier,
      'catalog_schema': sourceCatalogSchema,
      'fence_path': original.path,
      'workspace_identity': await root.maintenanceIdentity(),
      'source_state_identity': sourceIntent['source_state_identity'],
      'preparation_identity': sourceIntent['workspace_identity'],
      'preparation_intent_digest': ColdRollbackPreparation._hash(sourceIntent),
      'preparation_record_digest': ColdRollbackPreparation._hash(sourceRecord),
      'current_state_manifest': intent['current_state_manifest'],
      'history_rewind_accepted': true,
    };
    if (!same(intent, expectedIntent) ||
        intent['current_state_manifest'] is! Map<String, Object?>) {
      throw const FormatException('rollback intent differs from original pair');
    }
    final references =
        observer ??
        MacOsOpenReferences(
          command: (path, args) =>
              awaitColdCommandExit(() => runMaintenanceCommand(path, args)),
        );
    prepared = ColdRollbackPreparation._(
      null,
      original,
      work,
      upgrade,
      upgradeLock,
      rollbackLock,
      root,
      sourceIntent,
      sourceRecord,
      intent,
      currentTree,
      oldApp,
      oldState,
      references,
      recoveredSource: (
        state: sourceState,
        app: installationApp.path,
        bundle: bundleIdentifier,
      ),
    ).._cuttingOver = true;
    prepared._inspection = root.directory('inspection');
    final completed = root.directory('prepared');
    try {
      prepared._record = await ColdUpgradePreparation._readRecord(
        completed,
        'record.json',
      );
    } finally {
      completed.close();
    }
    final saved = prepared._record!;
    if (!same(saved, {
          'format': 'gaovm.cold-rollback-preparation.v1',
          'phase': 'rollback_prepared',
          'intent_digest': ColdRollbackPreparation._hash(intent),
          'catalog_schema': sourceCatalogSchema,
          'app_receipt': saved['app_receipt'],
          'state_receipt': saved['state_receipt'],
          'app_identity': saved['app_identity'],
          'state_identity': saved['state_identity'],
          'history_rewind_accepted': true,
          'ordinary_startup_fenced': true,
          'installed_pair_restored': false,
          'committed': false,
          'startup_allowed': false,
          'service_actions_performed': false,
          'external_files_backed_up': false,
        }) ||
        saved['app_identity'] is! Map<String, Object?> ||
        saved['state_identity'] is! Map<String, Object?>) {
      throw const FormatException(
        'complete sealed rollback preparation required',
      );
    }
    await prepared._openExternalFiles();
    native = await _RollbackRecoveryNative.open(
      retirement,
      publication,
      original,
      installationApp: installationApp.path,
      bundleIdentifier: bundleIdentifier,
      oldVersion: oldVersion,
      newVersion: newVersion,
      teamIdentifier: teamIdentifier,
      sourceCatalogSchema: sourceCatalogSchema,
      stateIdentity: sourceIntent['source_state_identity'],
      originalRelease: sourceRecord['original_release'] as Map<String, Object?>,
    );
    prepared._recoveryNative = native;
    final inputs = prepared;
    final nativeInputs = native;
    final restored = await ColdStateRestoration.openPair(
      work,
      'restored-old-state',
      stagedOldState: Directory(stagedState),
      oldApp: Directory(stagedApp),
      retainedApp: Directory(native.retiredAppPath),
      installationApp: installationApp,
      original: original,
      preservation: (storage: work, name: 'retained-current'),
      appRestoration: (storage: work, name: 'restored-old-app'),
      provenancePaths: native.paths,
      bundleIdentifier: bundleIdentifier,
      observePreparedInputs: inputs._verifySnapshotReferences,
      verifyPreparedInputs: (state, app) async {
        inputs._ownedRestoration = state;
        await inputs._verifyRestoredFiles(state, retained, app: app);
      },
      openAppHosts: (app) => MacOsColdStateHost.openRollbackObservers(
        app,
        releases: {
          stagedApp: sourceRecord['original_release'] as Map<String, Object?>,
          nativeInputs.retiredAppPath: nativeInputs.originalRelease,
          if (publication != null)
            installationApp.path: nativeInputs.candidateRelease!,
        },
        publicationPaths: nativeInputs.publicationPaths,
        host: host,
        observer: references,
        inventory: inventory,
      ),
    );
    inputs._ownedRestoration = restored;
    final result = ColdRollbackStateRestoration._(inputs, restored, retained)
      .._app = restored.restoredApp;
    await result.verify();
    inputs._consumed = true;
    return result;
  } catch (_) {
    if (prepared != null) {
      prepared.close();
    } else {
      native?.close();
      oldState?.close();
      oldApp?.close();
      currentTree?.close();
      root?.close();
      upgrade?.close();
      rollbackLock?.close();
      upgradeLock.close();
    }
    rethrow;
  }
}

/// Existing-only native provenance namespaces, not a normal retired host.
/// Their frozen contents are independently closed by the typed app proof.
final class _RollbackRecoveryNative {
  final _parents = <OwnedImageDirectory>[];
  final _locks = <(OwnedImageDirectory, String, OwnedImageLock)>[];
  final _roots = <OwnedImageDirectory>[];
  late String retiredAppPath;
  late Map<String, Object?> originalRelease;
  Map<String, Object?>? candidateRelease;
  final publicationPaths = <String>{};
  Set<String> get paths => _roots.map((root) => root.path).toSet();

  static Future<_RollbackRecoveryNative> open(
    ({OwnedImageDirectory storage, String name}) retirement,
    ({OwnedImageDirectory storage, String name})? publication,
    MaintenanceStateFence original, {
    required String installationApp,
    required String bundleIdentifier,
    required String oldVersion,
    required String newVersion,
    required String teamIdentifier,
    required int? sourceCatalogSchema,
    required Object? stateIdentity,
    required Map<String, Object?> originalRelease,
  }) async {
    final result = _RollbackRecoveryNative();
    bool same(Object? a, Object? b) => ColdRollbackPreparation._same(a, b);
    bool sameRelease(Map<String, Object?> a, Map<String, Object?> b) =>
        same({...a}..remove('app_path'), {...b}..remove('app_path'));
    try {
      Future<OwnedImageDirectory> read(
        ({OwnedImageDirectory storage, String name}) selector,
        String lockName,
      ) async {
        ColdUpgradePreparation._validateName(selector.name);
        await ColdUpgradePreparation._verifyPrivate(selector.storage);
        if (maintenancePathEntryExists(
          '${selector.storage.path}/.${selector.name}.partial',
        )) {
          throw const FormatException('incomplete native provenance retained');
        }
        final parent = await OwnedImageDirectory.open(
          Directory(selector.storage.path),
        );
        result._parents.add(parent);
        final lock = await parent.tryAcquireMaintenanceLock(
          lockName,
          create: false,
        );
        if (lock == null)
          throw StateError('native provenance namespace already owned');
        result._locks.add((parent, lockName, lock));
        final root = parent.directory(selector.name);
        result._roots.add(root);
        await ColdUpgradePreparation._verifyPrivate(root);
        return root;
      }

      final retired = await read(retirement, '.gaovm-app-retirement.lock');
      final intent = await ColdUpgradePreparation._readRecord(
        retired,
        'intent.json',
      );
      final release = intent['release'];
      if (intent.length != 14 ||
          intent['format'] != 'gaovm.app-retirement-intent.v1' ||
          intent['source_app'] != installationApp ||
          intent['source_state'] != original.sourceStatePath ||
          intent['fence_path'] != original.path ||
          intent['bundle_identifier'] != bundleIdentifier ||
          intent['version'] != oldVersion ||
          intent['team_identifier'] != teamIdentifier ||
          intent['catalog_schema'] != (sourceCatalogSchema ?? 0) ||
          !same(intent['state_identity'], stateIdentity) ||
          release is! Map<String, Object?> ||
          !sameRelease(release, originalRelease)) {
        throw const FormatException(
          'retirement provenance differs from original pair',
        );
      }
      result.retiredAppPath = '${retired.path}/GaoVM.app';
      result.originalRelease = release;
      if (publication != null) {
        final published = await read(
          publication,
          '.gaovm-candidate-publication.lock',
        );
        final intent = await ColdUpgradePreparation._readRecord(
          published,
          'intent.json',
        );
        final prepared = published.directory('prepared');
        late Map<String, Object?> record;
        try {
          record = await ColdUpgradePreparation._readRecord(
            prepared,
            'record.json',
          );
        } finally {
          prepared.close();
        }
        final candidateRelease = record['release'];
        if (intent.length != 16 ||
            intent['format'] != 'gaovm.candidate-publication-intent.v1' ||
            intent['source_app'] != installationApp ||
            intent['source_state'] != original.sourceStatePath ||
            intent['fence_path'] != original.path ||
            intent['bundle_identifier'] != bundleIdentifier ||
            intent['old_version'] != oldVersion ||
            intent['new_version'] != newVersion ||
            intent['team_identifier'] != teamIdentifier ||
            !same(intent['state_identity'], stateIdentity) ||
            record.length != 10 ||
            record['format'] != 'gaovm.candidate-publication-prepared.v1' ||
            record['phase'] != 'candidate_staged' ||
            record['intent_digest'] != ColdRollbackPreparation._hash(intent) ||
            candidateRelease is! Map<String, Object?> ||
            candidateRelease['app_path'] !=
                '${published.path}/candidate/payload.app' ||
            candidateRelease['bundle_identifier'] != bundleIdentifier ||
            candidateRelease['version'] != newVersion ||
            candidateRelease['team_identifier'] != teamIdentifier ||
            candidateRelease['required_catalog_schema'] !=
                intent['catalog_schema']) {
          throw const FormatException(
            'publication provenance differs from explicit inputs',
          );
        }
        result.candidateRelease = candidateRelease;
        result.publicationPaths.addAll({
          installationApp,
          '${published.path}/candidate/payload.app',
        });
      }
      await result.verify();
      return result;
    } catch (_) {
      result.close();
      rethrow;
    }
  }

  Future<void> verify() async {
    for (final parent in _parents) {
      await ColdUpgradePreparation._verifyPrivate(parent);
    }
    for (final (parent, name, lock) in _locks) {
      lock.verifyPathBinding();
      await ColdRollbackPreparation._checkLockFile(parent, name);
      lock.verifyPathBinding();
    }
    for (final root in _roots) {
      await ColdUpgradePreparation._verifyPrivate(root);
    }
  }

  void close() {
    for (final root in _roots) root.close();
    for (final (_, _, lock) in _locks) lock.close();
    for (final parent in _parents) parent.close();
  }
}
