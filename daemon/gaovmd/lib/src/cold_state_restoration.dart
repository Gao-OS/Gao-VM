part of 'cold_state_lease.dart';

/// A fenced old-state installation, NOT a restored app/state pair or a startup
/// permit. Both source leases are consumed only on success. Forward callers keep
/// borrowed hosts and the original fence open; recovery consumes its new hosts.
final class ColdStateRestoration {
  ColdStateRestoration._(
    this._old,
    this._current,
    this._storage,
    this._lock,
    this._root,
    this._sourceParent,
    this._targetParent,
    this._intent,
    this._apps,
  );

  static const _lockName = '.gaovm-state-restoration.lock';
  final ColdStateLease _old;
  final PreservedColdState _current;
  final OwnedImageDirectory _storage, _root, _sourceParent, _targetParent;
  final OwnedImageLock _lock;
  final Map<String, Object?> _intent;
  final Map<String, MaintenanceTree?> _apps;
  final _recoveredHosts = <MacOsColdStateHost>[];
  OwnedImageDirectory? _state;
  Map<String, Object?>? _record;
  String? _completionName;
  bool _busy = false, _closed = false, _ownsStates = false;
  bool _recovering = false;

  String get path => _intent['target_state'] as String;
  Map<String, Object?> toJson() {
    if (_closed ||
        _recovering ||
        _record == null ||
        _completionName != 'completed') {
      throw StateError('complete available state restoration required');
    }
    return jsonDecode(jsonEncode(_record)) as Map<String, Object?>;
  }

  /// Reopen only the explicitly selected post-move checkpoint. The complete
  /// filesystem read set precedes both real state owners and any host callback. Returned
  /// native hosts are consumed and closed by this context, including on failure;
  /// callbacks must drain their work and not retain/close the borrowed proof or
  /// retained fence. [verifyPreparedInputs] rechecks the matching old pair and
  /// external inputs using filesystem checks only, after native observations and
  /// before completing the fixed phase. This proof never grants ordinary startup.
  static Future<ColdStateRestoration> open(
    OwnedImageDirectory storage,
    String name, {
    required Directory stagedOldState,
    required Directory oldApp,
    required Directory retainedApp,
    required Directory installationApp,
    required MaintenanceStateFence original,
    required ({OwnedImageDirectory storage, String name}) preservation,
    required String bundleIdentifier,
    required Future<void> Function() verifyPreparedInputs,
    required Future<ColdStateHost> Function(ColdStateRestoration) openOldHost,
    required Future<ColdStateHost> Function(
      ColdStateRestoration,
      MaintenanceStateFence,
    )
    openCurrentHost,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name) ||
        name.endsWith('.partial') ||
        original.retiredForCommit ||
        stagedOldState.path != stagedOldState.absolute.path ||
        maintenancePathEntryExists(stagedOldState.path)) {
      throw const FormatException('fixed post-move state restoration required');
    }
    await original.verify();
    await PreservedColdState._private(storage);
    final target = original.sourceStatePath;
    final output = '${storage.path}/$name';
    final retainedPath =
        '${preservation.storage.path}/${preservation.name}/state';
    final protected = {
      stagedOldState.path,
      target,
      retainedPath,
      oldApp.path,
      retainedApp.path,
      installationApp.path,
    };
    final executable = await File(
      Platform.resolvedExecutable,
    ).resolveSymbolicLinks();
    final script = Platform.script.scheme == 'file'
        ? await File.fromUri(Platform.script).resolveSymbolicLinks()
        : null;
    for (final input in protected) {
      if (!input.startsWith('/') ||
          storage.path == input ||
          storage.path.startsWith('$input/') ||
          PreservedColdState._overlap(output, input) ||
          PreservedColdState._inside(executable, input) ||
          script != null && PreservedColdState._inside(script, input)) {
        throw const FormatException(
          'recovery overlaps protected input or code',
        );
      }
    }
    if (PreservedColdState._inside(executable, output) ||
        script != null && PreservedColdState._inside(script, output)) {
      throw const FormatException('recovery executable must remain outside');
    }
    final ownedStorage = await OwnedImageDirectory.open(
      Directory(storage.path),
    );
    OwnedImageDirectory? root, sourceParent, targetParent, state;
    OwnedImageLock? lock;
    PreservedColdState? current;
    DaemonOwnership? oldOwner, currentOwner;
    ColdStateRestoration? result;
    final apps = <String, MaintenanceTree?>{};
    try {
      lock = await ownedStorage.tryAcquireMaintenanceLock(
        _lockName,
        create: false,
      );
      if (lock == null) throw StateError('restoration namespace already owned');
      await PreservedColdState._lockFile(ownedStorage, _lockName);
      root = ownedStorage.directory(name);
      await PreservedColdState._private(root);
      final intent = await PreservedColdState._read(root, 'intent.json');
      final expectedApps = {
        oldApp.path,
        retainedApp.path,
        installationApp.path,
      };
      final appEvidence = intent['apps'];
      if (intent.length != 14 ||
          intent['format'] != 'gaovm.cold-state-restoration-intent.v1' ||
          intent['source_state'] != stagedOldState.path ||
          intent['target_state'] != target ||
          intent['bundle_identifier'] != bundleIdentifier ||
          intent['retained_state'] != retainedPath ||
          intent['state_manifest'] is! Map<String, Object?> ||
          appEvidence is! Map<String, Object?> ||
          appEvidence.length != expectedApps.length ||
          !appEvidence.keys.toSet().containsAll(expectedApps) ||
          appEvidence[oldApp.path] == null ||
          appEvidence[retainedApp.path] == null) {
        throw const FormatException(
          'restoration intent or explicit inputs changed',
        );
      }
      sourceParent = await OwnedImageDirectory.open(stagedOldState.parent);
      targetParent = await OwnedImageDirectory.open(Directory(target).parent);
      if (sourceParent.path != stagedOldState.parent.path ||
          targetParent.path != Directory(target).parent.path) {
        throw const FormatException('canonical recovery parents required');
      }
      await _parent(sourceParent);
      await _parent(targetParent);
      state = await OwnedImageDirectory.open(Directory(target));
      if (state.path != target)
        throw const FormatException('canonical restored state required');
      current = await PreservedColdState._readForRestoration(
        original,
        preservation.storage,
        preservation.name,
        bundleIdentifier: bundleIdentifier,
        installationPath: installationApp.path,
      );
      for (final entry in appEvidence.entries) {
        if (entry.value == null) {
          apps[entry.key] = null;
        } else {
          final evidence = entry.value;
          if (evidence is! Map<String, Object?> ||
              evidence.length != 2 ||
              evidence['identity'] is! Map<String, Object?> ||
              evidence['manifest'] is! Map<String, Object?>) {
            throw const FormatException('complete app binding required');
          }
          apps[entry.key] = await MaintenanceTree.open(Directory(entry.key));
        }
      }
      final old = ColdStateLease._unowned(state, bundleIdentifier, oldApp.path);
      final hasComplete = maintenancePathEntryExists('${root.path}/completed');
      final hasPartial = maintenancePathEntryExists(
        '${root.path}/.completed.partial',
      );
      if (hasComplete && hasPartial) {
        throw const FormatException('ambiguous state restoration completion');
      }
      final completionName = hasComplete
          ? 'completed'
          : hasPartial
          ? '.completed.partial'
          : null;
      result =
          ColdStateRestoration._(
              old,
              current,
              ownedStorage,
              lock,
              root,
              sourceParent,
              targetParent,
              intent,
              apps,
            )
            .._state = state
            .._completionName = completionName
            .._recovering = true;
      result._record = result._completedRecord;
      // No helper or lock creation before the complete, independently bound
      // restored/retained/app/fence/parent/journal proof closes successfully.
      await result._verifyFiles(moved: true);
      oldOwner = await DaemonOwnership.tryAcquireForRestoration(state, result);
      if (oldOwner == null)
        throw const ColdStateFailure(
          'ownership',
          'restored state already owned',
        );
      currentOwner = await DaemonOwnership.tryAcquireForRestoration(
        current._state!,
        result,
      );
      if (currentOwner == null)
        throw const ColdStateFailure(
          'ownership',
          'retained state already owned',
        );
      old._ownership = oldOwner;
      current._source._ownership = currentOwner;
      Future<ColdStateHost> loadHost(
        Future<ColdStateHost> Function() open,
        String app,
        String installation,
      ) async {
        final host = await open();
        if (host is MacOsColdStateHost) result!._recoveredHosts.add(host);
        final actualInstallation = host is MacOsColdStateHost
            ? host.installationPath
            : host.appPath;
        if (host.appPath != app ||
            actualInstallation != installation ||
            host is MacOsColdStateHost && host.isValidatingCandidate) {
          throw const FormatException(
            'recovered host disagrees with explicit app selectors',
          );
        }
        await result!._verifyFiles(moved: true);
        return host;
      }

      old._host = await loadHost(
        () => openOldHost(result!),
        oldApp.path,
        oldApp.path,
      );
      current._source._host = await loadHost(
        () => openCurrentHost(result!, current!._destination),
        retainedApp.path,
        installationApp.path,
      );
      result._recovering = false;
      await result.verify();
      await verifyPreparedInputs();
      await result._verifyFiles(moved: true);
      if (completionName != 'completed') {
        if (completionName == null) {
          final partial = root.createDirectory('.completed.partial');
          try {
            await PreservedColdState._write(
              partial,
              'record.json',
              result._record!,
            );
            await partial.sync();
          } finally {
            partial.close();
          }
        }
        await root.renameDirectoryNoReplace('.completed.partial', 'completed');
        result._completionName = 'completed';
        await result.verify();
        await verifyPreparedInputs();
        await result._verifyFiles(moved: true);
      }
      result._ownsStates = true;
      return result;
    } catch (_) {
      currentOwner?.close();
      oldOwner?.close();
      current?._closeResources();
      if (result != null) {
        result._closeUntransferred();
      } else {
        for (final app in apps.values) app?.close();
        state?.close();
        sourceParent?.close();
        targetParent?.close();
        root?.close();
        lock?.close();
        ownedStorage.close();
      }
      rethrow;
    }
  }

  static Future<ColdStateRestoration> _create(
    ColdStateLease old,
    PreservedColdState current,
    OwnedImageDirectory storage,
    String name,
    Future<void> Function() verifyPreparedInputs,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(name) ||
        name.endsWith('.partial')) {
      throw const FormatException(
        'fixed unused state restoration child required',
      );
    }
    await old.verify();
    await current._verifyHeld();
    await PreservedColdState._private(storage);
    final target = current._original.sourceStatePath;
    final output = '${storage.path}/$name';
    final protected = {
      old.path,
      current.path,
      target,
      old.appPath,
      old.installationPath,
      current._source.appPath,
      current._source.installationPath,
    };
    final executable = await File(
      Platform.resolvedExecutable,
    ).resolveSymbolicLinks();
    final script = Platform.script.scheme == 'file'
        ? await File.fromUri(Platform.script).resolveSymbolicLinks()
        : null;
    for (final input in protected) {
      if (storage.path == input ||
          storage.path.startsWith('$input/') ||
          PreservedColdState._overlap(output, input) ||
          PreservedColdState._inside(executable, input) ||
          script != null && PreservedColdState._inside(script, input)) {
        throw const FormatException(
          'restoration overlaps protected input or running code',
        );
      }
    }
    if (maintenancePathEntryExists(target) ||
        maintenancePathEntryExists(output) ||
        PreservedColdState._inside(executable, output) ||
        script != null && PreservedColdState._inside(script, output)) {
      throw const FormatException(
        'unused fixed restoration destinations required',
      );
    }
    final ownedStorage = await OwnedImageDirectory.open(
      Directory(storage.path),
    );
    OwnedImageDirectory? root, sourceParent, targetParent;
    OwnedImageLock? lock;
    final apps = <String, MaintenanceTree?>{};
    ColdStateRestoration? result;
    try {
      lock = await ownedStorage.tryAcquireMaintenanceLock(_lockName);
      if (lock == null)
        throw StateError('state restoration namespace already owned');
      await PreservedColdState._lockFile(ownedStorage, _lockName);
      sourceParent = await OwnedImageDirectory.open(Directory(old.path).parent);
      targetParent = await OwnedImageDirectory.open(Directory(target).parent);
      await _parent(sourceParent);
      await _parent(targetParent);
      root = ownedStorage.createDirectory(name);
      final tree = await MaintenanceTree.open(Directory(old.path));
      late Map<String, Object?> stateManifest;
      try {
        stateManifest = await tree.capture(nativeMetadata: true);
      } finally {
        tree.close();
      }
      final appEvidence = <String, Object?>{};
      for (final app in {
        old.appPath,
        old.installationPath,
        current._source.appPath,
        current._source.installationPath,
      }) {
        if (!maintenancePathEntryExists(app)) {
          apps[app] = null;
          appEvidence[app] = null;
        } else {
          final reader = await MaintenanceTree.open(Directory(app));
          apps[app] = reader;
          final directory = await OwnedImageDirectory.open(Directory(app));
          try {
            appEvidence[app] = {
              'identity': await directory.maintenanceIdentity(),
              'manifest': await reader.capture(nativeMetadata: true),
            };
          } finally {
            directory.close();
          }
        }
      }
      final intent = <String, Object?>{
        'format': 'gaovm.cold-state-restoration-intent.v1',
        'source_state': old.path,
        'target_state': target,
        'bundle_identifier': old.bundleIdentifier,
        'state_identity': await old._root.maintenanceIdentity(),
        'state_manifest': stateManifest,
        'retained_state': current.path,
        'preservation_intent_digest': current.toJson()['intent_digest'],
        'original_fence': await PreservedColdState._fenceEvidence(
          current._original,
        ),
        'retained_fence': await PreservedColdState._fenceEvidence(
          current._destination,
        ),
        'workspace_identity': await root.maintenanceIdentity(),
        'source_parent_identity': await sourceParent.maintenanceIdentity(),
        'target_parent_identity': await targetParent.maintenanceIdentity(),
        'apps': appEvidence,
      };
      result = ColdStateRestoration._(
        old,
        current,
        ownedStorage,
        lock,
        root,
        sourceParent,
        targetParent,
        intent,
        apps,
      );
      // Even a post-rename failure retains both original owners and all newly
      // opened resources until the original future and explicit close settle.
      old._pendingRestoration = result;
      await PreservedColdState._write(root, 'intent.json', intent);
      final prepared = root.createDirectory('.prepared.partial');
      try {
        await PreservedColdState._write(
          prepared,
          'record.json',
          result._preparedRecord,
        );
        await prepared.sync();
      } finally {
        prepared.close();
      }
      await root.renameDirectoryNoReplace('.prepared.partial', 'prepared');
      final namespace = ownedStorage.file(_lockName);
      try {
        await namespace.sync();
      } finally {
        namespace.close();
      }
      await ownedStorage.sync();
      await old.verify();
      await current._verifyHeld();
      await verifyPreparedInputs();
      // No native callbacks after the complete pre-move read-set closure.
      await result._verifyFiles(moved: false);
      result._state = await old._root.moveForMaintenanceTo(
        sourceParent,
        targetParent,
        Directory(
          target,
        ).uri.pathSegments.where((part) => part.isNotEmpty).last,
      );
      await old._ownership.rebindAfterRestorationMove(result._state!, result);
      result._record = result._completedRecord;
      final completed = root.createDirectory('.completed.partial');
      try {
        await PreservedColdState._write(
          completed,
          'record.json',
          result._record!,
        );
        await completed.sync();
      } finally {
        completed.close();
      }
      await root.renameDirectoryNoReplace('.completed.partial', 'completed');
      result._completionName = 'completed';
      await result.verify();
      old._closed = true;
      old._pendingRestoration = null;
      current._closed = true;
      result._ownsStates = true;
      return result;
    } catch (_) {
      if (result == null) {
        for (final app in apps.values) {
          app?.close();
        }
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
    'format': 'gaovm.cold-state-restoration-prepared.v1',
    'phase': 'old_state_ready',
    'intent_digest': PreservedColdState._hash(_intent),
    'startup_allowed': false,
  };
  Map<String, Object?> get _completedRecord => {
    'format': 'gaovm.cold-state-restoration-completed.v1',
    'phase': 'old_state_restored',
    'intent_digest': PreservedColdState._hash(_intent),
    'source_state': _intent['source_state'],
    'target_state': path,
    'retained_state': _current.path,
    'state_identity': _intent['state_identity'],
    'canonical_state_restored': true,
    'installed_pair_restored': false,
    'committed': false,
    'startup_allowed': false,
    'service_actions_performed': false,
  };

  /// Typed, filesystem-only admission for the already held old-state owner.
  /// Not an ordinary-startup route, raw lock getter or arbitrary callback.
  Future<void> verifyFor(OwnedImageDirectory state) =>
      _verifyAdmission(state, retained: false);

  /// Recovery may reacquire only either of this proof's two exact state inodes.
  /// This filesystem proof does not assert ownership or ordinary admission.
  Future<void> verifyOwnershipFor(OwnedImageDirectory state) =>
      _verifyAdmission(state, retained: state.path == _current.path);

  /// Native retirement recovery must borrow the same original/retained fences;
  /// the original occupied slot is admitted only by the complete typed proof.
  Future<void> verifyRetainedFor(
    OwnedImageDirectory state,
    MaintenanceStateFence original,
    MaintenanceStateFence retained,
  ) {
    if (!identical(original, _current._original) ||
        !identical(retained, _current._destination)) {
      throw const FormatException('exact restoration fences required');
    }
    // The full admission proof already checks relocated provenance and both
    // exact borrowed fences. Keep its pending-close guard through the last read.
    return _verifyAdmission(state, retained: true);
  }

  Future<void> _verifyAdmission(
    OwnedImageDirectory state, {
    required bool retained,
  }) async {
    if (_closed || _busy) {
      throw StateError('restored state admission is unavailable');
    }
    _busy = true;
    try {
      if (_state == null ||
          state.path != (retained ? _current.path : path) ||
          !PreservedColdState._same(
            await state.maintenanceIdentity(),
            retained
                ? _current._intent['state_identity']
                : _intent['state_identity'],
          )) {
        throw const FormatException('exact restored state admission required');
      }
      await _verifyFiles(moved: true);
    } finally {
      _busy = false;
    }
  }

  Future<void> _verifyInstalledBinding() async {
    if (_closed ||
        _state == null ||
        _state!.path != path ||
        path != _current._original.sourceStatePath ||
        maintenancePathEntryExists(_intent['source_state'] as String) ||
        !PreservedColdState._same(
          await _state!.maintenanceIdentity(),
          _intent['state_identity'],
        )) {
      throw const FormatException('restored state inode or placement changed');
    }
    await _state!.verifyPathBinding();
    await _targetParent.verifyPathBinding();
  }

  Future<void> _verifyFiles({required bool moved}) async {
    await PreservedColdState._private(_storage);
    _lock.verifyPathBinding();
    await PreservedColdState._lockFile(_storage, _lockName);
    await PreservedColdState._private(_root);
    await _parent(_sourceParent);
    await _parent(_targetParent);
    for (final pair in [
      (_root, 'workspace_identity'),
      (_sourceParent, 'source_parent_identity'),
      (_targetParent, 'target_parent_identity'),
    ]) {
      if (!PreservedColdState._same(
        await pair.$1.maintenanceIdentity(),
        _intent[pair.$2],
      )) {
        throw const FormatException(
          'state restoration namespace identity changed',
        );
      }
    }
    await PreservedColdState._entries(_root, {
      'intent.json',
      'prepared',
      if (_completionName != null) _completionName!,
    });
    await PreservedColdState._check(_root, 'intent.json', _intent);
    final prepared = _root.directory('prepared');
    try {
      await PreservedColdState._private(prepared);
      await PreservedColdState._entries(prepared, {'record.json'});
      await PreservedColdState._check(prepared, 'record.json', _preparedRecord);
    } finally {
      prepared.close();
    }
    await _current._verifyFiles(moved: true, restoration: moved ? this : null);
    if (_intent['preservation_intent_digest'] !=
            PreservedColdState._hash(_current._intent) ||
        !PreservedColdState._same(
          await PreservedColdState._fenceEvidence(_current._original),
          _intent['original_fence'],
        ) ||
        !PreservedColdState._same(
          await PreservedColdState._fenceEvidence(_current._destination),
          _intent['retained_fence'],
        )) {
      throw const FormatException('preservation provenance changed');
    }
    final actual = moved ? _state! : _old._root;
    if (moved) {
      await _verifyInstalledBinding();
    } else if (maintenancePathEntryExists(path) ||
        actual.path != _intent['source_state']) {
      throw const FormatException('original restoration slots changed');
    }
    await PreservedColdState._private(actual);
    if (!PreservedColdState._same(
      await actual.maintenanceIdentity(),
      _intent['state_identity'],
    )) {
      throw const FormatException('old-state inode changed');
    }
    final tree = await MaintenanceTree.open(Directory(actual.path));
    try {
      await tree.verify(
        _intent['state_manifest'] as Map<String, Object?>,
        nativeMetadata: true,
      );
    } finally {
      tree.close();
    }
    for (final app in _apps.entries) {
      final evidence = (_intent['apps'] as Map)[app.key];
      if (app.value == null) {
        if (evidence != null || maintenancePathEntryExists(app.key)) {
          throw const FormatException('original app slot became occupied');
        }
      } else {
        final directory = await OwnedImageDirectory.open(Directory(app.key));
        try {
          if (!PreservedColdState._same(
            await directory.maintenanceIdentity(),
            (evidence as Map)['identity'],
          )) {
            throw const FormatException('restoration app inode changed');
          }
          await app.value!.verify(
            evidence['manifest'] as Map<String, Object?>,
            nativeMetadata: true,
          );
        } finally {
          directory.close();
        }
      }
    }
    if (_completionName != null) {
      final completed = _root.directory(_completionName!);
      try {
        await PreservedColdState._private(completed);
        await PreservedColdState._entries(completed, {'record.json'});
        await PreservedColdState._check(completed, 'record.json', _record!);
      } finally {
        completed.close();
      }
    }
    _lock.verifyPathBinding();
  }

  Future<void> verify() async {
    if (_closed || _busy || _recovering || _state == null || _record == null) {
      throw StateError('complete available restored state required');
    }
    _busy = true;
    try {
      await _old._ownership.verify();
      await _old._verifyService();
      for (final driver in [false, true]) {
        final inventory = await _old._host.inventory(driver: driver);
        if (inventory.processes.isNotEmpty ||
            inventory.unresolvedProcessIds.isNotEmpty) {
          throw const ColdStateFailure(
            'restored_processes',
            'live or unresolved processes remain',
          );
        }
      }
      if ((await _old._host.stateReferences(
        Directory(path),
      )).any((other) => other != pid)) {
        throw const ColdStateFailure(
          'restored_references',
          'other processes remain',
        );
      }
      await _old._verifyService();
      await _current._verifyHeld(restoration: this);
      await _old._ownership.verify();
      // Independently close both states, all app placements and the journal
      // after the last native callback, not only before the filesystem move.
      await _verifyFiles(moved: true);
    } finally {
      _busy = false;
    }
  }

  static Future<void> _parent(OwnedImageDirectory directory) async {
    await directory.verifyPathBinding();
    if (directory.mode & 0xe12 != 0 ||
        (await directory.maintenanceMetadata())['has_acl'] != false ||
        await Directory(directory.path).resolveSymbolicLinks() !=
            directory.path) {
      throw const FormatException(
        'canonical owned restoration parent required',
      );
    }
  }

  void _closeUntransferred() {
    if (_closed) return;
    _closed = true;
    for (final host in _recoveredHosts) host.close();
    _state?.close();
    for (final app in _apps.values) {
      app?.close();
    }
    _sourceParent.close();
    _targetParent.close();
    _root.close();
    _lock.close();
    _storage.close();
  }

  void close() {
    if (_busy) throw StateError('state restoration verification is pending');
    if (_closed) return;
    if (!_ownsStates)
      throw StateError('restoration belongs to the original leases');
    _old._ownership.close();
    _old._root.close();
    _old._ownedRetiredHost?.close();
    _current._source._ownership.close();
    _current._source._root.close();
    _current._source._ownedRetiredHost?.close();
    _current._closeResources();
    _closeUntransferred();
  }
}
