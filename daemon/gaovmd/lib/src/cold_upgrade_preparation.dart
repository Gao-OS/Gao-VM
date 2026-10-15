part of 'cold_catalog_inspection.dart';

/// A fenced, durable preparation checkpoint, NOT installed app publication.
/// Borrows the original cold snapshot, fence and storage. Closing retains all
/// output and the fence; it only releases this object's readers/namespace lock.
final class ColdUpgradePreparation {
  ColdUpgradePreparation._(
    this._state,
    this._fence,
    this._parent,
    this._lock,
    this._root,
    this._originalApp,
    this._intent,
    this._record,
    this._host,
    this._observer,
  );

  static const _lockName = '.gaovm-upgrade.lock';
  static const _recordLimit = 64 * 1024 * 1024;
  final ColdStateSnapshot _state;
  final MaintenanceStateFence _fence;
  final OwnedImageDirectory _parent;
  final OwnedImageLock _lock;
  OwnedImageDirectory _root;
  MaintenanceTree _originalApp;
  final Map<String, Object?> _intent;
  final Map<String, Object?> _record;
  final ReleaseInspectionHost _host;
  final MacOsOpenReferences _observer;
  bool _closed = false;
  String get path => _root.path;

  Map<String, Object?> toJson() =>
      (jsonDecode(jsonEncode(_record)) as Map).cast<String, Object?>();

  /// Reopens only a completed preparation in the operator's explicit storage.
  /// Paths in records are provenance, never authority to select a target.
  static Future<ColdUpgradePreparation> open(
    ColdStateSnapshot state,
    MaintenanceStateFence fence,
    OwnedImageDirectory parent,
    String name, {
    required String oldVersion,
    required String newVersion,
    required String teamIdentifier,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
  }) async {
    _validateName(name);
    await state.verify();
    await _verifyFence(state, fence);
    await _verifyPrivate(parent);
    for (final source in [
      state._state.path,
      state._state.appPath,
      state._inspectionPath,
    ]) {
      if (parent.path == source ||
          parent.path.startsWith('$source/') ||
          _overlap('${parent.path}/$name', source)) {
        throw const FormatException('upgrade recovery storage overlaps inputs');
      }
    }
    if (maintenancePathEntryExists('${parent.path}/.$name.partial')) {
      throw const FormatException(
        'incomplete preparation requires investigation',
      );
    }
    final lock = await parent.tryAcquireMaintenanceLock(
      _lockName,
      create: false,
    );
    if (lock == null) throw StateError('upgrade storage already has an owner');
    OwnedImageDirectory? root;
    MaintenanceTree? original;
    ColdUpgradePreparation? result;
    try {
      root = parent.directory(name);
      await _verifyPrivate(root);
      final intent = await _readRecord(root, 'intent.json');
      final checkpoint = root.directory('prepared');
      late Map<String, Object?> record;
      try {
        await _verifyPrivate(checkpoint);
        await _entries(checkpoint, {'record.json'});
        record = await _readRecord(checkpoint, 'record.json');
      } finally {
        checkpoint.close();
      }
      if (intent.length != 13 ||
          intent['format'] != 'gaovm.cold-upgrade-intent.v1' ||
          intent['source_app'] != state._state.installationPath ||
          intent['source_state'] != state._state.path ||
          intent['bundle_identifier'] != state._state.bundleIdentifier ||
          intent['old_version'] != oldVersion ||
          intent['new_version'] != newVersion ||
          intent['team_identifier'] != teamIdentifier ||
          intent['catalog_schema'] != state._catalog?.schemaVersion ||
          intent['fence_path'] != fence.path ||
          intent['candidate_source'] is! String ||
          !(intent['candidate_source'] as String).startsWith('/') ||
          !(intent['candidate_source'] as String).endsWith('.app') ||
          record.length != 13 ||
          record['format'] != 'gaovm.cold-upgrade-preparation.v1' ||
          record['phase'] != 'candidate_prepared' ||
          record['catalog_schema'] != state._catalog?.schemaVersion ||
          record['intent_digest'] !=
              'sha256:${sha256.convert(_encode(intent))}' ||
          record['ordinary_startup_fenced'] != true ||
          record['installed_candidate_published'] != false ||
          record['external_files_backed_up'] != false ||
          record['rollback_authorized'] != false ||
          !_equal(
            await root.maintenanceIdentity(),
            intent['workspace_identity'],
          ) ||
          !_equal(
            await _identity(state._state.appPath),
            intent['source_app_identity'],
          ) ||
          !_equal(
            await _identity(state._state.path),
            intent['source_state_identity'],
          )) {
        throw const FormatException(
          'unrecognized preparation or explicit inputs disagree',
        );
      }
      for (final entry in {
        'original_app_receipt': (
          'payload.app',
          'gaovm.tree-snapshot.v1',
          intent['source_app'],
        ),
        'original_state_receipt': (
          'payload',
          'gaovm.cold-state-snapshot.v1',
          intent['source_state'],
        ),
        'candidate_app_receipt': (
          'payload.app',
          'gaovm.tree-snapshot.v1',
          intent['candidate_source'],
        ),
      }.entries) {
        final receipt = record[entry.key];
        if (receipt is! Map<String, Object?> ||
            receipt['payload_name'] != entry.value.$1 ||
            receipt['format'] != entry.value.$2 ||
            receipt['source_path'] != entry.value.$3 ||
            receipt['manifest'] is! Map<String, Object?>) {
          throw const FormatException('unrecognized preparation snapshot');
        }
      }
      original = await MaintenanceTree.open(Directory(state._state.appPath));
      result = ColdUpgradePreparation._(
        state,
        fence,
        parent,
        lock,
        root,
        original,
        intent,
        record,
        host,
        observer ?? MacOsOpenReferences(),
      );
      await result.verify();
      return result;
    } catch (_) {
      if (result != null) {
        result.close();
      } else {
        root?.close();
        original?.close();
        lock.close();
      }
      rethrow;
    }
  }

  static Future<ColdUpgradePreparation> create(
    ColdStateSnapshot state,
    MaintenanceStateFence fence,
    OwnedImageDirectory parent,
    String name, {
    required Directory candidateApp,
    required String oldVersion,
    required String newVersion,
    required String teamIdentifier,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
  }) async {
    _validateName(name);
    await state.verify();
    await _verifyFence(state, fence);
    await _verifyPrivate(parent);
    final destination = '${parent.path}/$name';
    final stagingName = '.$name.partial';
    final stagingPath = '${parent.path}/$stagingName';
    final sourcePaths = [
      state._state.path,
      state._state.appPath,
      state._inspectionPath,
      candidateApp.path,
    ];
    for (var i = 0; i < sourcePaths.length; i++) {
      for (var j = i + 1; j < sourcePaths.length; j++) {
        if (_overlap(sourcePaths[i], sourcePaths[j])) {
          throw const FormatException('upgrade preparation inputs overlap');
        }
      }
      if (parent.path == sourcePaths[i] ||
          parent.path.startsWith('${sourcePaths[i]}/') ||
          _overlap(destination, sourcePaths[i]) ||
          _overlap(stagingPath, sourcePaths[i])) {
        throw const FormatException('upgrade storage overlaps inputs');
      }
    }
    for (final target in [destination, stagingPath]) {
      if (maintenancePathEntryExists(target)) {
        throw const FormatException('upgrade output already exists');
      }
    }
    final lock = await parent.tryAcquireMaintenanceLock(_lockName);
    if (lock == null) throw StateError('upgrade storage already has an owner');
    MaintenanceTree? original;
    MaintenanceTree? candidate;
    OwnedImageDirectory? staging;
    ColdUpgradePreparation? result;
    try {
      final schema = state._catalog?.schemaVersion;
      final namespaceFile = parent.file(_lockName);
      try {
        await namespaceFile.sync();
      } finally {
        namespaceFile.close();
      }
      Future<Map<String, Object?>> inspect(Directory app, String version) =>
          inspectMacOsRelease(
            app,
            bundleIdentifier: state._state.bundleIdentifier,
            version: version,
            teamIdentifier: teamIdentifier,
            catalogSchema: schema ?? 0,
            host: host,
          );
      final oldRelease = await inspect(
        Directory(state._state.appPath),
        oldVersion,
      );
      final candidateRelease = await inspect(candidateApp, newVersion);
      original = await MaintenanceTree.open(Directory(state._state.appPath));
      candidate = await MaintenanceTree.open(candidateApp);
      await original.verify(oldRelease['tree'] as Map<String, Object?>);
      await candidate.verify(candidateRelease['tree'] as Map<String, Object?>);
      final oldManifest = await original.capture(nativeMetadata: true);
      final candidateManifest = await candidate.capture(nativeMetadata: true);
      for (final manifest in [oldManifest, candidateManifest]) {
        if (manifest.values.cast<Map>().any(
          (entry) => (entry['metadata'] as Map)['has_acl'] != false,
        )) {
          throw const FormatException('app ACL grants require investigation');
        }
      }
      final stateManifest = await state._capture();
      final oldTree = original, candidateTree = candidate;
      final references = observer ?? MacOsOpenReferences();
      Future<void> verifySources() async {
        await state.verify();
        await _verifyFence(state, fence);
        await _noReferences(references, oldTree.path);
        await _noReferences(references, candidateTree.path);
        // No external native callbacks after these complete source reads.
        await oldTree.verify(oldManifest, nativeMetadata: true);
        await candidateTree.verify(candidateManifest, nativeMetadata: true);
        if (!_equal(await state._capturePersistent(), stateManifest)) {
          throw const FormatException('upgrade source state changed');
        }
      }

      await verifySources();
      var requiredBytes = 1024 * 1024;
      for (final manifest in [oldManifest, candidateManifest, stateManifest]) {
        requiredBytes += utf8.encode(jsonEncode(manifest)).length * 4;
        for (final entry in manifest.values.cast<Map>()) {
          requiredBytes += ((entry['size'] as int?) ?? 0) + 4096;
          for (final value
              in ((entry['metadata'] as Map)['xattrs'] as Map).values
                  .cast<Map>()) {
            requiredBytes += value['size'] as int;
          }
        }
      }
      if (await parent.availableBytes() < requiredBytes) {
        throw const FormatException('insufficient upgrade preparation space');
      }
      await _verifyPrivate(parent);
      lock.verifyPathBinding();
      staging = parent.createDirectory(stagingName);
      final intent = <String, Object?>{
        'format': 'gaovm.cold-upgrade-intent.v1',
        'source_app': oldTree.path,
        'source_state': state._state.path,
        'candidate_source': candidateTree.path,
        'bundle_identifier': state._state.bundleIdentifier,
        'old_version': oldVersion,
        'new_version': newVersion,
        'team_identifier': teamIdentifier,
        'catalog_schema': schema,
        'fence_path': fence.path,
        'workspace_identity': await staging.maintenanceIdentity(),
        'source_app_identity': await _identity(oldTree.path),
        'source_state_identity': await _identity(state._state.path),
      };
      // Intent reaches stable storage before any snapshot copy starts.
      await _writeRecord(staging, 'intent.json', intent);
      await staging.sync();
      await parent.sync();
      final oldReceipt = await oldTree.snapshotTo(staging, 'original-app');
      await verifySources();
      final stateReceipt = await state.snapshotTo(staging, 'original-state');
      final candidateReceipt = await candidateTree.snapshotTo(
        staging,
        'candidate-app',
      );
      await verifySources();
      final stagedRelease = await inspect(
        Directory('${staging.path}/candidate-app/payload.app'),
        newVersion,
      );
      final record = <String, Object?>{
        'format': 'gaovm.cold-upgrade-preparation.v1',
        'phase': 'candidate_prepared',
        'catalog_schema': schema,
        'intent_digest': 'sha256:${sha256.convert(_encode(intent))}',
        'original_release': oldRelease,
        'candidate_release': stagedRelease,
        'original_app_receipt': oldReceipt,
        'original_state_receipt': stateReceipt,
        'candidate_app_receipt': candidateReceipt,
        'ordinary_startup_fenced': true,
        'installed_candidate_published': false,
        'external_files_backed_up': false,
        'rollback_authorized': false,
      };
      final checkpoint = staging.createDirectory('.prepared.partial');
      try {
        await _writeRecord(checkpoint, 'record.json', record);
        await checkpoint.sync();
      } finally {
        checkpoint.close();
      }
      await staging.renameDirectoryNoReplace('.prepared.partial', 'prepared');
      result = ColdUpgradePreparation._(
        state,
        fence,
        parent,
        lock,
        staging,
        original,
        intent,
        record,
        host,
        references,
      );
      staging = null;
      original = null;
      await result.verify();
      await _verifyPrivate(parent);
      lock.verifyPathBinding();
      await parent.renameDirectoryNoReplace(stagingName, name);
      final published = parent.directory(name);
      result._root.close();
      result._root = published;
      await result.verify();
      return result;
    } catch (error) {
      if (result != null) {
        result.close();
      } else {
        original?.close();
        staging?.close();
        lock.close();
      }
      if (maintenancePathEntryExists(stagingPath) ||
          maintenancePathEntryExists(destination)) {
        throw MaintenanceSnapshotFailure(stagingPath, destination, error);
      }
      rethrow;
    } finally {
      candidate?.close();
    }
  }

  Future<void> verify() async {
    if (_closed) throw StateError('upgrade preparation is closed');
    await _verifyNamespace();
    await _verifyOutput();
    await _state.verify();
    await _verifyFence(_state, _fence);
    for (final entry in [
      (_state._state.appPath, _intent['old_version'] as String),
      ('$path/candidate-app/payload.app', _intent['new_version'] as String),
    ]) {
      final release = await inspectMacOsRelease(
        Directory(entry.$1),
        bundleIdentifier: _state._state.bundleIdentifier,
        version: entry.$2,
        teamIdentifier: _intent['team_identifier'] as String,
        catalogSchema: _state._catalog?.schemaVersion ?? 0,
        host: _host,
      );
      final expected =
          _record[entry.$1 == _state._state.appPath
              ? 'original_release'
              : 'candidate_release'];
      final observed = {...release}..remove('app_path');
      if (expected is! Map<String, Object?> ||
          !_equal(observed, {...expected}..remove('app_path'))) {
        throw const FormatException('preparation release evidence changed');
      }
      await _noReferences(_observer, entry.$1);
    }
    await _state.verify();
    await _verifyFence(_state, _fence);
    // Run after the LAST native callback: known-file checks do not cover unknown
    // source data and cannot substitute for these full native/content manifests.
    await _originalApp.verify(
      (_record['original_app_receipt'] as Map)['manifest']
          as Map<String, Object?>,
      nativeMetadata: true,
    );
    if (!_equal(
          await _state._capturePersistent(),
          (_record['original_state_receipt'] as Map)['manifest'],
        ) ||
        !_equal(
          await _identity(_state._state.appPath),
          _intent['source_app_identity'],
        ) ||
        !_equal(
          await _identity(_state._state.path),
          _intent['source_state_identity'],
        )) {
      throw const FormatException('upgrade original inputs changed');
    }
    await _verifyOutput();
    await _verifyNamespace();
  }

  /// Controlled migration may change catalog bytes and add managed assets, but
  /// cannot rewrite pre-existing non-catalog files or the retained old pair.
  /// This deliberately does not call the pre-migration catalog verifier.
  Future<void> verifyRetainedValidationInputs() async {
    if (_closed) throw StateError('upgrade preparation is closed');
    await _state._state.verify();
    await _verifyFence(_state, _fence);
    await _verifyOutput();
    await _verifyNamespace();
    await _originalApp.verify(
      (_record['original_app_receipt'] as Map)['manifest']
          as Map<String, Object?>,
      nativeMetadata: true,
    );
    if (!_equal(
          await _identity(_state._state.path),
          _intent['source_state_identity'],
        ) ||
        !_equal(
          await _identity(_state._state.appPath),
          _intent['source_app_identity'],
        )) {
      throw const FormatException('validation original inode changed');
    }
    for (final held in <_HeldReference>{
      ...?_state._references?._files.values,
      ..._state._legacy._files.values,
    }) {
      if (held.file.path.startsWith('${_state._state.path}/')) continue;
      if ((await _observer.file(
            File(held.file.path),
          )).any((process) => process != pid) ||
          JsonValue.fromJson(await _seal(held.file)) != held.evidence) {
        throw const FormatException(
          'validation changed an original external file',
        );
      }
      await held.parent.verifyPathBinding();
    }
    final before =
        (_record['original_state_receipt'] as Map)['manifest'] as Map;
    final after = await _state._capturePersistent();
    for (final entry in before.entries) {
      if (const {
        'gaovm.db',
        'gaovm.db-wal',
        'gaovm.db-shm',
      }.contains(entry.key))
        continue;
      final original = Map<String, Object?>.from(entry.value as Map);
      final currentValue = after[entry.key];
      if (currentValue is! Map<String, Object?>)
        throw const FormatException('validation removed original state data');
      final current = Map<String, Object?>.from(currentValue);
      if (const {'', 'images', 'vms', 'artifacts'}.contains(entry.key) &&
          original['kind'] == 'directory') {
        for (final value in [original, current]) {
          value['metadata'] = Map<String, Object?>.from(
            value['metadata'] as Map,
          )..remove('modified');
        }
      }
      if (!_equal(original, current))
        throw const FormatException(
          'validation changed original non-catalog data',
        );
    }
    await _verifyOutput();
    await _verifyNamespace();
  }

  /// Full post-validation state is retained independently, not substituted for
  /// the pre-upgrade rollback snapshot. All native observers settle before the
  /// final filesystem-only source/receipt comparison.
  Future<Map<String, Object?>> retainValidatedState(
    OwnedImageDirectory inspection,
    OwnedImageDirectory storage, {
    required MacOsOpenReferences observer,
    required Future<DriverInventorySnapshot> Function(String) inventory,
  }) async {
    await verifyRetainedValidationInputs();
    final post = await ColdStateSnapshot.prepare(
      _state._state,
      inspection,
      observer: observer,
      inventory: inventory,
    );
    try {
      final receipt = await post.snapshotTo(storage, 'validated-state');
      await post.verify();
      await verifyRetainedValidationInputs();
      final retained = storage.directory('validated-state');
      try {
        await MaintenanceTree.verifySnapshotContents(retained, receipt);
      } finally {
        retained.close();
      }
      if (!_equal(await post._capturePersistent(), receipt['manifest'])) {
        throw const FormatException(
          'validated state changed after native observations',
        );
      }
      return receipt;
    } finally {
      post.close();
    }
  }

  /// Retire only the exact prepared original app while the existing state lease
  /// keeps its kernel ownership. The immutable checkpoint and candidate copies
  /// stay put. The returned observation is not candidate publication or commit.
  Future<Map<String, Object?>> retireOriginalApp(
    OwnedImageDirectory storage,
    String name,
  ) async {
    await verify();
    for (final protected in [path, _state._inspectionPath]) {
      for (final target in [
        '${storage.path}/$name',
        '${storage.path}/.$name.partial',
      ]) {
        if (_overlap(target, protected) ||
            storage.path == protected ||
            storage.path.startsWith('$protected/')) {
          throw const FormatException('app retirement overlaps preparation');
        }
      }
    }
    final result = await _state._state.retireApp(
      _fence,
      storage,
      name,
      verifyPreparedInputs: _verifyPreparedFiles,
    );
    final moved = await MaintenanceTree.open(Directory(_state._state.appPath));
    _originalApp.close();
    _originalApp = moved;
    await verify();
    return result;
  }

  /// Publish a second, independent copy, never the immutable candidate snapshot.
  /// The caller keeps this preparation, original-state owner and fence alive.
  /// The observation remains uncommitted and startup stays fenced.
  Future<Map<String, Object?>> publishCandidate(
    OwnedImageDirectory storage,
    String name,
  ) async {
    await verify();
    for (final protected in [path, _state._inspectionPath]) {
      for (final target in [
        '${storage.path}/$name',
        '${storage.path}/.$name.partial',
      ]) {
        if (_overlap(target, protected) ||
            storage.path == protected ||
            storage.path.startsWith('$protected/')) {
          throw const FormatException(
            'candidate publication overlaps preparation',
          );
        }
      }
    }
    final result = await _state._state.publishCandidate(
      _fence,
      storage,
      name,
      Directory('$path/candidate-app/payload.app'),
      version: _intent['new_version'] as String,
      catalogSchema: _state._catalog?.schemaVersion ?? 0,
      candidateManifest:
          (_record['candidate_app_receipt'] as Map)['manifest']
              as Map<String, Object?>,
      verifyPreparedInputs: _verifyPreparedFiles,
    );
    await verify();
    return result;
  }

  Future<void> _verifyPreparedFiles() async {
    // Filesystem-only reads after the LAST native observer. External inputs are
    // not part of the state snapshot. Do not call legacy._verifyInputs: its
    // context invokes native observers after dependencies have been read.
    final files = <_HeldReference>{
      ...?_state._references?._files.values,
      ...?_state._assets?._files._files.values,
      ..._state._legacy._files.values,
    };
    for (final held in files) {
      await held.parent.verifyPathBinding();
      if (JsonValue.fromJson(await _seal(held.file)) != held.evidence) {
        throw const ColdStateFailure(
          'app_maintenance',
          'external input changed',
        );
      }
    }
    await _state._runtime?._verifyTree();
    if (!_equal(
      await _state._capturePersistent(),
      (_record['original_state_receipt'] as Map)['manifest'],
    )) {
      throw const FormatException(
        'prepared state changed before app maintenance',
      );
    }
    await _originalApp.verify(
      (_record['original_app_receipt'] as Map)['manifest']
          as Map<String, Object?>,
      nativeMetadata: true,
    );
    await _verifyOutput();
    await _verifyNamespace();
  }

  Future<void> _verifyNamespace() async {
    await _verifyPrivate(_parent);
    _lock.verifyPathBinding();
    final file = _parent.file(_lockName);
    try {
      final stat = file.stat();
      if (stat.mode & 0xfff != 0x180 ||
          stat.size != 0 ||
          stat.linkCount != 1 ||
          (await file.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('upgrade namespace lock changed');
      }
      await file.verifyPathBinding();
      if (file.stat() != stat)
        throw const FormatException(
          'upgrade namespace lock changed during inspection',
        );
    } finally {
      file.close();
    }
    _lock.verifyPathBinding();
  }

  Future<void> _verifyOutput() async {
    await _verifyPrivate(_root);
    if (!_equal(
      await _root.maintenanceIdentity(),
      _intent['workspace_identity'],
    )) {
      throw const FormatException('upgrade workspace identity changed');
    }
    await _entries(_root, {
      'intent.json',
      'prepared',
      'original-app',
      'original-state',
      'candidate-app',
      '.gaovm-maintenance.lock',
    });
    await _checkRecord(_root, 'intent.json', _intent);
    final checkpoint = _root.directory('prepared');
    try {
      await _verifyPrivate(checkpoint);
      await _entries(checkpoint, {'record.json'});
      await _checkRecord(checkpoint, 'record.json', _record);
    } finally {
      checkpoint.close();
    }
    final storageLock = _root.file('.gaovm-maintenance.lock');
    try {
      await storageLock.verifyPathBinding();
      final stat = storageLock.stat();
      if (stat.mode & 0xfff != 0x180 ||
          stat.size != 0 ||
          stat.linkCount != 1 ||
          (await storageLock.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('upgrade snapshot lock changed');
      }
    } finally {
      storageLock.close();
    }
    for (final entry in {
      'original-app': 'original_app_receipt',
      'original-state': 'original_state_receipt',
      'candidate-app': 'candidate_app_receipt',
    }.entries) {
      final wrapper = _root.directory(entry.key);
      try {
        await _verifyPrivate(wrapper);
        await MaintenanceTree.verifySnapshotContents(
          wrapper,
          _record[entry.value] as Map<String, Object?>,
        );
      } finally {
        wrapper.close();
      }
    }
    await _root.verifyPathBinding();
  }

  static void _validateName(String name) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name) ||
        name.endsWith('.partial')) {
      throw ArgumentError.value(name, 'name');
    }
  }

  static bool _overlap(String a, String b) =>
      a == b || a.startsWith('$b/') || b.startsWith('$a/');
  static bool _equal(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
  static List<int> _encode(Map<String, Object?> value) {
    final bytes = utf8.encode('${jsonEncode(value)}\n');
    if (bytes.length > _recordLimit)
      throw const FormatException('upgrade record exceeds bound');
    return bytes;
  }

  static Future<void> _verifyPrivate(OwnedImageDirectory root) async {
    await root.verifyPathBinding();
    if (await Directory(root.path).resolveSymbolicLinks() != root.path ||
        root.mode & 0xfff != 0x1c0 ||
        (await root.maintenanceMetadata())['has_acl'] != false) {
      throw const FormatException('private canonical upgrade storage required');
    }
  }

  static Future<Map<String, Object?>> _identity(String path) async {
    final root = await OwnedImageDirectory.open(Directory(path));
    try {
      if (root.path != path)
        throw const FormatException('upgrade source path changed');
      await root.verifyPathBinding();
      return await root.maintenanceIdentity();
    } finally {
      root.close();
    }
  }

  static Future<void> _verifyFence(
    ColdStateSnapshot state,
    MaintenanceStateFence fence,
  ) async {
    final root = await OwnedImageDirectory.open(Directory(state._state.path));
    try {
      await fence.verifyFor(
        root,
        bundleIdentifier: state._state.bundleIdentifier,
        appPath: state._state.installationPath,
      );
    } finally {
      root.close();
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

  static Future<void> _entries(
    OwnedImageDirectory root,
    Set<String> expected,
  ) async {
    final entries = await Directory(root.path)
        .list(followLinks: false)
        .take(expected.length + 1)
        .map((entry) => entry.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toList();
    if (entries.length != expected.length ||
        !entries.toSet().containsAll(expected)) {
      throw const FormatException('upgrade checkpoint entries changed');
    }
  }

  static Future<void> _writeRecord(
    OwnedImageDirectory root,
    String name,
    Map<String, Object?> value,
  ) async {
    final bytes = _encode(value);
    final record = root.createFile(name);
    try {
      final writer = await record.openWrite();
      try {
        await writer.writeFrom(bytes);
        await writer.flush();
      } finally {
        await writer.close();
      }
      await record.seal();
    } finally {
      record.close();
    }
  }

  static Future<void> _checkRecord(
    OwnedImageDirectory root,
    String name,
    Map<String, Object?> expected,
  ) async {
    final file = root.file(name);
    try {
      final stat = file.stat();
      if (stat.size > _recordLimit ||
          stat.mode & 0xfff != 0x100 ||
          stat.linkCount != 1 ||
          (await file.maintenanceMetadata())['has_acl'] != false ||
          sha256.convert(await file.readBounded(_recordLimit)).toString() !=
              sha256.convert(_encode(expected)).toString()) {
        throw const FormatException('upgrade record changed');
      }
      await file.verifyPathBinding();
      if (file.stat() != stat)
        throw const FormatException('upgrade record changed while reading');
    } finally {
      file.close();
    }
  }

  static Future<Map<String, Object?>> _readRecord(
    OwnedImageDirectory root,
    String name,
  ) async {
    final file = root.file(name);
    try {
      final stat = file.stat();
      if (stat.size > _recordLimit ||
          stat.mode & 0xfff != 0x100 ||
          stat.linkCount != 1 ||
          (await file.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('unsafe upgrade record');
      }
      final bytes = await file.readBounded(_recordLimit);
      await file.verifyPathBinding();
      if (file.stat() != stat)
        throw const FormatException('upgrade record changed while reading');
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, Object?> ||
          utf8.decode(bytes) != '${jsonEncode(value)}\n') {
        throw const FormatException('unrecognized upgrade record encoding');
      }
      return value;
    } finally {
      file.close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _root.close();
    _originalApp.close();
    _lock.close();
  }
}
