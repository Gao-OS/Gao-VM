part of 'macos_cold_state_host.dart';

/// A separately staged candidate, bound to one retired app and original state.
/// Only the staged inode may occupy the fixed installation slot. The immutable
/// record is not a commit receipt or authority to start a daemon/restore state.
final class _CandidatePublication {
  _CandidatePublication(
    this._retirement,
    this._parent,
    this._lock,
    this._root,
    this._intent,
    this._record,
  );

  static const _lockName = '.gaovm-candidate-publication.lock';
  final _AppRetirement _retirement;
  final OwnedImageDirectory _parent;
  final OwnedImageLock _lock;
  OwnedImageDirectory _root;
  final Map<String, Object?> _intent;
  Map<String, Object?> _record;
  bool _closed = false;
  String? _observedPath;
  String get _stagedPath => '${_root.path}/candidate/payload.app';
  Set<String> get candidatePaths => {_stagedPath, _retirement.sourceAppPath};
  String get candidatePath =>
      _observedPath ??
      (throw StateError('verify publication before observing candidate'));
  Map<String, Object?> get evidence => {
    'phase': candidatePath == _stagedPath
        ? 'candidate_staged'
        : 'candidate_published',
    'source_app': _retirement.sourceAppPath,
    'retired_app': '${_retirement._root.path}/GaoVM.app',
    'candidate_app': candidatePath,
    'journal_path': _root.path,
    'installed_candidate_published': candidatePath != _stagedPath,
    'activation_authorized': false,
    'rollback_authorized': false,
    'committed': false,
  };

  static Future<_CandidatePublication> open(
    _AppRetirement retirement,
    OwnedImageDirectory state,
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name, {
    required String version,
    required int catalogSchema,
    MaintenanceStateFence? preservedOriginal,
  }) async {
    _AppRetirement._validateName(name);
    await _AppRetirement._private(storage);
    for (final protected in [
      retirement.sourceAppPath,
      '${retirement._root.path}/GaoVM.app',
      retirement._root.path,
      state.path,
    ]) {
      if (_AppRetirement._overlap('${storage.path}/$name', protected) ||
          storage.path == protected ||
          storage.path.startsWith('$protected/')) {
        throw const FormatException(
          'publication recovery overlaps protected input',
        );
      }
    }
    if (maintenancePathEntryExists('${storage.path}/.$name.partial')) {
      throw const FormatException(
        'incomplete publication requires investigation',
      );
    }
    final parent = await OwnedImageDirectory.open(Directory(storage.path));
    OwnedImageDirectory? root;
    OwnedImageLock? lock;
    _CandidatePublication? publication;
    try {
      await storage.verifyPathBinding();
      if (!_AppRetirement._equal(
        await storage.maintenanceIdentity(),
        await parent.maintenanceIdentity(),
      )) {
        throw const FormatException('publication storage changed');
      }
      lock = await parent.tryAcquireMaintenanceLock(_lockName, create: false);
      if (lock == null) throw StateError('publication namespace already owned');
      root = parent.directory(name);
      await _AppRetirement._private(root);
      final intent = await _read(root, 'intent.json');
      final prepared = root.directory('prepared');
      late Map<String, Object?> record;
      try {
        await _AppRetirement._private(prepared);
        await _entries(prepared, {'record.json'});
        record = await _read(prepared, 'record.json');
      } finally {
        prepared.close();
      }
      final origin = preservedOriginal ?? fence;
      if (intent.length != 16 ||
          intent['format'] != 'gaovm.candidate-publication-intent.v1' ||
          intent['source_app'] != retirement.sourceAppPath ||
          intent['source_state'] != origin.sourceStatePath ||
          intent['source_state'] != retirement._intent['source_state'] ||
          intent['fence_path'] != origin.path ||
          intent['fence_path'] != retirement._intent['fence_path'] ||
          intent['bundle_identifier'] !=
              retirement._intent['bundle_identifier'] ||
          intent['old_version'] != retirement._intent['version'] ||
          intent['new_version'] != version ||
          intent['team_identifier'] != retirement._intent['team_identifier'] ||
          intent['catalog_schema'] != catalogSchema ||
          intent['catalog_schema'] is! int ||
          intent['candidate_manifest'] is! Map<String, Object?> ||
          intent['candidate_source'] is! String ||
          !(intent['candidate_source'] as String).startsWith('/') ||
          !(intent['candidate_source'] as String).endsWith('.app') ||
          !_AppRetirement._equal(
            intent['state_identity'],
            await state.maintenanceIdentity(),
          ) ||
          record.length != 10 ||
          record['format'] != 'gaovm.candidate-publication-prepared.v1' ||
          record['phase'] != 'candidate_staged' ||
          record['intent_digest'] !=
              'sha256:${sha256.convert(_AppRetirement._encode(intent))}' ||
          record['candidate_identity'] is! Map<String, Object?> ||
          record['candidate_wrapper_identity'] is! Map<String, Object?> ||
          record['receipt'] is! Map<String, Object?> ||
          record['release'] is! Map<String, Object?> ||
          record['probe_identity'] is! Map<String, Object?> ||
          record['probe_manifest'] is! Map<String, Object?> ||
          record['probe_evidence'] is! Map<String, Object?>) {
        throw const FormatException(
          'publication disagrees with explicit inputs',
        );
      }
      final receipt = record['receipt'] as Map<String, Object?>;
      if (receipt.length != 6 ||
          receipt['format'] != 'gaovm.tree-snapshot.v1' ||
          receipt['source_path'] != intent['candidate_source'] ||
          receipt['snapshot_path'] != '${root.path}/candidate' ||
          receipt['payload_name'] != 'payload.app' ||
          !_AppRetirement._equal(
            receipt['manifest'],
            intent['candidate_manifest'],
          ) ||
          receipt['manifest_digest'] !=
              'sha256:${sha256.convert(utf8.encode(jsonEncode(intent['candidate_manifest'])))}' ||
          (record['release'] as Map)['app_path'] !=
              '${root.path}/candidate/payload.app') {
        throw const FormatException('publication candidate receipt changed');
      }
      publication = _CandidatePublication(
        retirement,
        parent,
        lock,
        root,
        intent,
        record,
      );
      await publication.verify(); // Full bindings/bytes BEFORE any helper.
      return publication;
    } catch (_) {
      if (publication != null) {
        publication.close();
      } else {
        root?.close();
        lock?.close();
        parent.close();
      }
      rethrow;
    }
  }

  Future<void> validateNative(MacOsColdStateHost owner) async {
    await verify();
    final release = await _inspect(owner, candidatePath);
    if (!_AppRetirement._sameRelease(
      release,
      _record['release'] as Map<String, Object?>,
    )) {
      throw const FormatException(
        'recovered candidate release evidence changed',
      );
    }
    final probe = await _probe(
      owner,
      candidatePath,
      _record['probe_manifest'] as Map<String, Object?>,
    );
    if (!_AppRetirement._equal(probe, _record['probe_evidence'])) {
      throw const FormatException('recovered startup fence evidence changed');
    }
    await _AppRetirement._noReferences(owner._observer, candidatePath);
    await _AppRetirement._noReferences(owner._observer, '${_root.path}/probe');
    await verify();
  }

  static Future<_CandidatePublication> create(
    MacOsColdStateHost owner,
    ColdStateLease state,
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name,
    Directory candidate, {
    required String version,
    required int catalogSchema,
    required Map<String, Object?> manifest,
  }) async {
    _AppRetirement._validateName(name);
    final retirement = owner._retirement!;
    await _AppRetirement._private(storage);
    final executable = await File(
      Platform.resolvedExecutable,
    ).resolveSymbolicLinks();
    for (final protected in [
      state.path,
      owner.appPath,
      state.installationPath,
      retirement._root.path,
      candidate.path,
      executable,
    ]) {
      if (_AppRetirement._overlap('${storage.path}/$name', protected) ||
          _AppRetirement._overlap(
            '${storage.path}/.$name.partial',
            protected,
          ) ||
          storage.path == protected ||
          storage.path.startsWith('$protected/')) {
        throw const FormatException('publication overlaps protected input');
      }
    }
    if (_AppRetirement._overlap(executable, state.path) ||
        _AppRetirement._overlap(executable, state.installationPath) ||
        _AppRetirement._overlap(executable, owner.appPath)) {
      throw const FormatException('maintenance executable must remain outside');
    }
    final parent = await OwnedImageDirectory.open(Directory(storage.path));
    MaintenanceTree? source;
    OwnedImageDirectory? root;
    OwnedImageLock? lock;
    _CandidatePublication? publication;
    try {
      source = await MaintenanceTree.open(candidate);
      await storage.verifyPathBinding();
      if (!_AppRetirement._equal(
        await storage.maintenanceIdentity(),
        await parent.maintenanceIdentity(),
      )) {
        throw const FormatException('publication storage changed');
      }
      await source.verify(manifest, nativeMetadata: true);
      if (manifest.values.cast<Map>().any(
        (entry) => (entry['metadata'] as Map)['has_acl'] != false,
      )) {
        throw const FormatException(
          'candidate ACL grants require investigation',
        );
      }
      for (final target in [name, '.$name.partial']) {
        if (maintenancePathEntryExists('${parent.path}/$target')) {
          throw const FormatException('publication output already exists');
        }
      }
      lock = await parent.tryAcquireMaintenanceLock(_lockName);
      if (lock == null) throw StateError('publication namespace already owned');
      final lockFile = parent.file(_lockName);
      try {
        await lockFile.sync();
      } finally {
        lockFile.close();
      }
      await parent.sync();
      final stateRoot = await OwnedImageDirectory.open(Directory(state.path));
      late Map<String, Object?> stateIdentity;
      try {
        await fence.verifyFor(
          stateRoot,
          bundleIdentifier: state.bundleIdentifier,
          appPath: state.installationPath,
        );
        stateIdentity = await stateRoot.maintenanceIdentity();
      } finally {
        stateRoot.close();
      }
      root = parent.createDirectory('.$name.partial');
      final intent = <String, Object?>{
        'format': 'gaovm.candidate-publication-intent.v1',
        'source_app': state.installationPath,
        'source_state': state.path,
        'fence_path': fence.path,
        'bundle_identifier': state.bundleIdentifier,
        'old_version': retirement._intent['version'],
        'new_version': version,
        'team_identifier': retirement._intent['team_identifier'],
        'catalog_schema': catalogSchema,
        'old_retirement_digest': 'sha256:${sha256.convert(retirement._bytes)}',
        'old_workspace_identity': retirement._intent['workspace_identity'],
        'state_identity': stateIdentity,
        'source_parent_identity': retirement._intent['source_parent_identity'],
        'workspace_identity': await root.maintenanceIdentity(),
        'candidate_source': candidate.path,
        'candidate_manifest': manifest,
      };
      await _write(root, 'intent.json', intent);
      await root.sync();
      await parent.sync();
      // Publish the intent first. Probe paths (and their fence hashes) must not
      // change afterward; an intent-only workspace is retained, never promoted.
      await parent.renameDirectoryNoReplace('.$name.partial', name);
      root.close();
      root = parent.directory(name);
      publication = _CandidatePublication(
        retirement,
        parent,
        lock,
        root,
        intent,
        {},
      );
      final receipt = await source.snapshotTo(root, 'candidate');
      final wrapper = root.directory('candidate');
      late Map<String, Object?> wrapperIdentity;
      try {
        wrapperIdentity = await wrapper.maintenanceIdentity();
        await MaintenanceTree.verifySnapshotContents(wrapper, receipt);
      } finally {
        wrapper.close();
      }
      final staged = await MaintenanceTree.open(
        Directory(publication._stagedPath),
      );
      try {
        await staged.verify(manifest, nativeMetadata: true);
      } finally {
        staged.close();
      }
      final candidateIdentity = await _identity(publication._stagedPath);
      final release = await publication._inspect(
        owner,
        publication._stagedPath,
      );
      final probe = root.createDirectory('probe');
      late Map<String, Object?> probeManifest, probeIdentity;
      try {
        final probeState = probe.createDirectory('state');
        try {
          final canary = probeState.createFile('canary');
          try {
            final writer = await canary.openWrite();
            try {
              await writer.writeString('do not initialize this state\n');
              await writer.flush();
            } finally {
              await writer.close();
            }
          } finally {
            canary.close();
          }
          await probeState.sync();
        } finally {
          probeState.close();
        }
        final marker = probe.createDirectory(publication._probeMarkerName);
        try {
          await marker.sync();
        } finally {
          marker.close();
        }
        await probe.sync();
        await root.sync();
        final probeTree = await MaintenanceTree.open(Directory(probe.path));
        try {
          probeManifest = await probeTree.capture(nativeMetadata: true);
        } finally {
          probeTree.close();
        }
        probeIdentity = await probe.maintenanceIdentity();
      } finally {
        probe.close();
      }
      final probeEvidence = await publication._probe(
        owner,
        publication._stagedPath,
        probeManifest,
      );
      publication._record = {
        'format': 'gaovm.candidate-publication-prepared.v1',
        'phase': 'candidate_staged',
        'intent_digest':
            'sha256:${sha256.convert(_AppRetirement._encode(intent))}',
        'candidate_identity': candidateIdentity,
        'candidate_wrapper_identity': wrapperIdentity,
        'receipt': receipt,
        'release': release,
        'probe_identity': probeIdentity,
        'probe_manifest': probeManifest,
        'probe_evidence': probeEvidence,
      };
      final prepared = root.createDirectory('.prepared.partial');
      try {
        await _write(prepared, 'record.json', publication._record);
        await prepared.sync();
        await root.sync();
      } finally {
        prepared.close();
      }
      await root.renameDirectoryNoReplace('.prepared.partial', 'prepared');
      await source.verify(manifest, nativeMetadata: true);
      await publication.verify();
      return publication;
    } catch (_) {
      if (publication != null) {
        publication.close();
      } else {
        root?.close();
        lock?.close();
        parent.close();
      }
      rethrow;
    } finally {
      source?.close();
    }
  }

  String get _probeState => '${_root.path}/probe/state';
  String get _probeMarkerName =>
      '.gaovmd-maintenance-${sha256.convert(utf8.encode(_probeState))}';

  Future<Map<String, Object?>> _inspect(
    MacOsColdStateHost owner,
    String path,
  ) => inspectMacOsRelease(
    Directory(path),
    bundleIdentifier: _intent['bundle_identifier'] as String,
    version: _intent['new_version'] as String,
    teamIdentifier: _intent['team_identifier'] as String,
    catalogSchema: _intent['catalog_schema'] as int,
    host: _PublicationExecution(owner._host),
  );

  Future<Map<String, Object?>> _probe(
    MacOsColdStateHost owner,
    String path,
    Map<String, Object?> expected,
  ) async {
    final tree = await MaintenanceTree.open(Directory('${_root.path}/probe'));
    try {
      await tree.verify(expected, nativeMetadata: true);
      final marker = '${_root.path}/probe/$_probeMarkerName';
      final result = await _PublicationExecution(owner._host)
          .run('$path/Contents/MacOS/gaovmd', [
            '--state-dir',
            _probeState,
            '--socket-path',
            '$_probeState/run/gaovmd.sock',
            '--driver-bin',
            '$path/Contents/Helpers/gaovm-driver-vz',
            '--openapi-path',
            '$path/Contents/Resources/schemas/openapi/gaovm-v1.yaml',
          ]);
      await tree.verify(expected, nativeMetadata: true);
      if (result.exitCode != 1 ||
          result.stdout != '' ||
          result.stderr !=
              'gaovmd startup failed: maintenance recovery required for $_probeState; retained fence: $marker\n') {
        throw const FormatException(
          'candidate did not confirm ordinary startup fence refusal',
        );
      }
      return {
        'outcome': 'startup_refused',
        'exit_code': 1,
        'state_path': _probeState,
        'marker_path': marker,
        'daemon_digest':
            ((_intent['candidate_manifest'] as Map)['Contents/MacOS/gaovmd']
                as Map)['digest'],
      };
    } finally {
      tree.close();
    }
  }

  Future<void> publish(
    MacOsColdStateHost owner,
    ColdStateLease state,
    Future<void> Function() verifyPreparedInputs,
  ) async {
    final executable = await File(
      Platform.resolvedExecutable,
    ).resolveSymbolicLinks();
    for (final protected in [
      state.path,
      owner.appPath,
      _retirement.sourceAppPath,
      _root.path,
    ]) {
      if (_AppRetirement._overlap(executable, protected)) {
        throw const FormatException(
          'maintenance executable must remain outside',
        );
      }
    }
    await verify();
    final before = await _inspect(owner, candidatePath);
    if (!_AppRetirement._sameRelease(
      before,
      _record['release'] as Map<String, Object?>,
    )) {
      throw const FormatException('candidate release evidence changed');
    }
    // The first probe was durably recorded during preparation. Explicit reopen
    // re-probes before proceeding, and publication always probes the final path.
    await state.verify();
    await _AppRetirement._noReferences(owner._observer, candidatePath);
    await verifyPreparedInputs();
    await verify();
    if (candidatePath == _stagedPath) {
      final wrapper = _root.directory('candidate');
      MaintenanceTree? source;
      MaintenanceTree? moved;
      try {
        source = await MaintenanceTree.open(Directory(_stagedPath));
        moved = await source.moveForMaintenanceTo(
          wrapper,
          _retirement._sourceParent,
          Directory(
            _retirement.sourceAppPath,
          ).uri.pathSegments.where((s) => s.isNotEmpty).last,
        );
      } finally {
        moved?.close();
        source?.close();
        wrapper.close();
      }
    }
    await verify();
    // An explicit retry may be observing a rename whose earlier parent fsync
    // failed. Attempt both again; observed placement alone is not durability.
    final wrapper = _root.directory('candidate');
    Object? syncFailure;
    StackTrace? syncStack;
    try {
      for (final parent in [wrapper, _retirement._sourceParent]) {
        try {
          await parent.sync();
        } catch (error, stack) {
          syncFailure ??= error;
          syncStack ??= stack;
        }
      }
    } finally {
      wrapper.close();
    }
    if (syncFailure != null) Error.throwWithStackTrace(syncFailure, syncStack!);
    final after = await _inspect(owner, candidatePath);
    if (!_AppRetirement._sameRelease(
      after,
      _record['release'] as Map<String, Object?>,
    )) {
      throw const FormatException(
        'installed candidate release evidence changed',
      );
    }
    final probe = await _probe(
      owner,
      candidatePath,
      _record['probe_manifest'] as Map<String, Object?>,
    );
    if (!_AppRetirement._equal(probe, _record['probe_evidence'])) {
      throw const FormatException('candidate startup fence evidence changed');
    }
    await state.verify();
    // No native observers after this callback: it re-reads the complete original
    // persistent/external inputs and immutable preparation outputs.
    await verifyPreparedInputs();
    await verify();
  }

  Future<void> verify() async {
    if (_closed) throw StateError('publication is closed');
    await _AppRetirement._private(_parent);
    await _AppRetirement._private(_root);
    await _AppRetirement._appParent(_retirement._sourceParent);
    if (!_AppRetirement._equal(
          await _root.maintenanceIdentity(),
          _intent['workspace_identity'],
        ) ||
        !_AppRetirement._equal(
          await _retirement._sourceParent.maintenanceIdentity(),
          _intent['source_parent_identity'],
        ) ||
        _intent['old_retirement_digest'] !=
            'sha256:${sha256.convert(_retirement._bytes)}' ||
        !_AppRetirement._equal(
          _intent['old_workspace_identity'],
          _retirement._intent['workspace_identity'],
        )) {
      throw const FormatException('publication namespace identity changed');
    }
    _lock.verifyPathBinding();
    await _lockFile(_parent, _lockName);
    await _entries(_root, {
      'intent.json',
      'candidate',
      'probe',
      'prepared',
      '.gaovm-maintenance.lock',
    });
    await _check(_root, 'intent.json', _intent);
    await _lockFile(_root, '.gaovm-maintenance.lock');
    final prepared = _root.directory('prepared');
    try {
      await _AppRetirement._private(prepared);
      await _entries(prepared, {'record.json'});
      await _check(prepared, 'record.json', _record);
    } finally {
      prepared.close();
    }
    final staged = maintenancePathEntryExists(_stagedPath);
    final installed = maintenancePathEntryExists(_retirement.sourceAppPath);
    if (staged == installed) {
      throw const FormatException(
        'exactly one fixed candidate location required',
      );
    }
    final path = staged ? _stagedPath : _retirement.sourceAppPath;
    if (!_AppRetirement._equal(
      await _identity(path),
      _record['candidate_identity'],
    )) {
      throw const FormatException('candidate inode changed');
    }
    final tree = await MaintenanceTree.open(Directory(path));
    try {
      await tree.verify(
        _intent['candidate_manifest'] as Map<String, Object?>,
        nativeMetadata: true,
      );
    } finally {
      tree.close();
    }
    final wrapper = _root.directory('candidate');
    try {
      await _AppRetirement._private(wrapper);
      if (!_AppRetirement._equal(
        await wrapper.maintenanceIdentity(),
        _record['candidate_wrapper_identity'],
      )) {
        throw const FormatException('candidate wrapper identity changed');
      }
      await _entries(wrapper, {'receipt.json', if (staged) 'payload.app'});
      await _check(
        wrapper,
        'receipt.json',
        _record['receipt'] as Map<String, Object?>,
      );
    } finally {
      wrapper.close();
    }
    final probe = _root.directory('probe');
    try {
      await _AppRetirement._private(probe);
      if (!_AppRetirement._equal(
        await probe.maintenanceIdentity(),
        _record['probe_identity'],
      )) {
        throw const FormatException('probe identity changed');
      }
      final probeTree = await MaintenanceTree.open(Directory(probe.path));
      try {
        await probeTree.verify(
          _record['probe_manifest'] as Map<String, Object?>,
          nativeMetadata: true,
        );
      } finally {
        probeTree.close();
      }
    } finally {
      probe.close();
    }
    await _check(_root, 'intent.json', _intent);
    _lock.verifyPathBinding();
    await _root.verifyPathBinding();
    _observedPath = path;
  }

  static Future<Map<String, Object?>> _identity(String path) async {
    final root = await OwnedImageDirectory.open(Directory(path));
    try {
      if (root.path != path)
        throw const FormatException('candidate path changed');
      await root.verifyPathBinding();
      return await root.maintenanceIdentity();
    } finally {
      root.close();
    }
  }

  static Future<void> _entries(
    OwnedImageDirectory root,
    Set<String> expected,
  ) async {
    await root.verifyPathBinding();
    final names = await Directory(root.path)
        .list(followLinks: false)
        .take(expected.length + 1)
        .map((entry) => entry.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toList();
    if (names.length != expected.length ||
        !names.toSet().containsAll(expected)) {
      throw const FormatException('publication entries changed');
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
        throw const FormatException('publication lock changed');
      }
      await file.verifyPathBinding();
      if (file.stat() != stat)
        throw const FormatException('publication lock changed while reading');
    } finally {
      file.close();
    }
  }

  static Future<void> _write(
    OwnedImageDirectory root,
    String name,
    Map<String, Object?> record,
  ) async {
    final file = root.createFile(name);
    try {
      final writer = await file.openWrite();
      try {
        await writer.writeFrom(_AppRetirement._encode(record));
        await writer.flush();
      } finally {
        await writer.close();
      }
      await file.seal();
    } finally {
      file.close();
    }
  }

  static Future<void> _check(
    OwnedImageDirectory root,
    String name,
    Map<String, Object?> record,
  ) async {
    if (!_AppRetirement._equal(await _read(root, name), record)) {
      throw const FormatException('publication record changed');
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
          stat.size > _AppRetirement._limit ||
          stat.linkCount != 1 ||
          (await file.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('unsafe publication record');
      }
      final bytes = await file.readBounded(_AppRetirement._limit);
      await file.verifyPathBinding();
      if (file.stat() != stat)
        throw const FormatException('publication record changed while reading');
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, Object?> ||
          utf8.decode(bytes) != '${jsonEncode(value)}\n') {
        throw const FormatException('unrecognized publication record encoding');
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
    try {
      _lock.close();
    } finally {
      _parent.close();
    }
  }
}

/// Publication cannot unwind readers/locks while one of its native commands
/// may still be running. A command deadline is an error, not process exit.
final class _PublicationExecution implements ReleaseInspectionHost {
  const _PublicationExecution(this.delegate);
  final ReleaseInspectionHost delegate;
  @override
  bool get canExecuteArm64 => delegate.canExecuteArm64;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    List<int>? input,
  }) async {
    try {
      return await delegate.run(executable, arguments, input: input);
    } on MaintenanceCommandFailure catch (failure) {
      if (!failure.exitConfirmed && failure.ownedExit != null) {
        await failure.ownedExit;
        throw MaintenanceCommandFailure(
          failure.reason,
          failure.pid,
          exitConfirmed: true,
        );
      }
      rethrow;
    }
  }
}
