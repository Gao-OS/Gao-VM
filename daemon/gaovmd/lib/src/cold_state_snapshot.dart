part of 'cold_catalog_inspection.dart';

/// Complete state-copy preparation, not paired app publication or rollback.
/// Owns its readers, never the caller's original state lease or scratch files.
final class ColdStateSnapshot {
  ColdStateSnapshot._(
    this._state,
    this._catalog,
    this._assets,
    this._references,
    this._legacy,
    this._runtime,
    this._tree,
    this._inspectionPath,
  );
  final ColdStateLease _state;
  final ColdCatalogInspection? _catalog;
  final ColdManagedAssets? _assets;
  final ColdFileReferences? _references;
  final ColdLegacyInspection _legacy;
  final ColdRuntimeInspection? _runtime;
  final MaintenanceTree _tree;
  final String _inspectionPath;
  bool _closed = false;

  /// Independently inspected source schema; null means no source catalog.
  /// Zero used for release bootstrap compatibility must not be reported as this.
  int? get observedCatalogSchema => _catalog?.schemaVersion;

  static Future<ColdStateSnapshot> prepare(
    ColdStateLease state,
    OwnedImageDirectory inspection, {
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) async {
    await state.verify();
    ColdCatalogInspection? catalog;
    ColdManagedAssets? assets;
    ColdFileReferences? references;
    ColdLegacyInspection? legacy;
    ColdRuntimeInspection? runtime;
    MaintenanceTree? tree;
    try {
      if (await FileSystemEntity.type(
            '${state.path}/gaovm.db',
            followLinks: false,
          ) ==
          FileSystemEntityType.notFound) {
        await inspection.verifyPathBinding();
        final metadata = await inspection.maintenanceMetadata();
        if (inspection.mode & 0xfff != 0x1c0 ||
            metadata['has_acl'] != false ||
            [state.path, state.appPath].any(
              (path) =>
                  inspection.path == path ||
                  inspection.path.startsWith('$path/') ||
                  path.startsWith('${inspection.path}/'),
            ) ||
            !await Directory(
              inspection.path,
            ).list(followLinks: false).isEmpty) {
          throw const ColdStateFailure(
            'state_snapshot',
            'private unused disjoint inspection directory required',
          );
        }
        await _noLegacyRuntime(state);
      } else {
        catalog = await ColdCatalogInspection.inspect(state, inspection);
        catalog.requireQuiescent();
        assets = await ColdManagedAssets.inspect(catalog, observer: observer);
        references = await ColdFileReferences.inspect(
          catalog,
          observer: observer,
        );
        runtime = await ColdRuntimeInspection.inspect(
          catalog,
          inventory: inventory,
        );
      }
      legacy = await ColdLegacyInspection.inspect(
        state,
        catalog: catalog,
        observer: observer,
      );
      tree = await MaintenanceTree.open(Directory(state.path));
      final result = ColdStateSnapshot._(
        state,
        catalog,
        assets,
        references,
        legacy,
        runtime,
        tree,
        inspection.path,
      );
      await result.verify();
      return result;
    } catch (_) {
      tree?.close();
      runtime?.close();
      legacy?.close();
      references?.close();
      assets?.close();
      rethrow;
    }
  }

  Future<void> verify() async {
    if (_closed) throw StateError('state snapshot preparation is closed');
    await _state.verify();
    await _catalog?._verifySourceFiles();
    _catalog?.requireQuiescent();
    if (_catalog == null) await _noLegacyRuntime(_state);
    // Each constituent belongs to this same held lease/catalog. Do not recurse
    // through its standalone native-context wrapper at every dependency edge.
    await _runtime?._verifyObservedRuntime();
    await _assets?._verifyObservedAssets();
    await _references?._verifyObservedFiles();
    await _legacy._verifyObservedLegacy();
    await _runtime?._verifyObservedRuntime();
    await _catalog?._verifySourceFiles();
    if (_catalog == null) await _noLegacyRuntime(_state);
    await _state.verify();
    // The last native observer may have changed an earlier dependency. Re-read
    // every constituent using filesystem-only checks; no result is memoized.
    await _runtime?._verifyTree();
    await _assets?._verifyPersistentAssets();
    await _references?._verifyPersistentFiles();
    await _legacy._verifyPersistentLegacy();
    await _catalog?._verifySourceFiles();
    if (_catalog == null) await _noLegacyRuntime(_state);
  }

  static Future<void> _noLegacyRuntime(ColdStateLease state) async {
    if (await FileSystemEntity.type('${state.path}/run', followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ColdStateFailure(
        'state_snapshot',
        'pre-catalog runtime requires independent investigation',
      );
    }
  }

  Future<Map<String, Object?>> snapshotTo(
    OwnedImageDirectory parent,
    String name,
  ) async {
    await verify();
    for (final protected in [_state.appPath, _inspectionPath]) {
      for (final target in [
        '${parent.path}/$name',
        '${parent.path}/.$name.partial',
      ]) {
        if (target == protected ||
            target.startsWith('$protected/') ||
            protected.startsWith('$target/')) {
          throw const ColdStateFailure(
            'state_snapshot',
            'snapshot overlaps app or inspection',
          );
        }
      }
      if (parent.path == protected || parent.path.startsWith('$protected/')) {
        throw const ColdStateFailure(
          'state_snapshot',
          'snapshot storage overlaps app or inspection',
        );
      }
    }
    return _tree.snapshotStateDataTo(parent, name, verifyBoundary: _boundary);
  }

  Future<Map<String, Object?>> _capture() =>
      _tree.captureStateData(verifyBoundary: _boundary);

  // Run last in each coordinator verification pass, after native observations.
  // Filesystem-only source read, not a cold permit or replacement-tree fence.
  Future<Map<String, Object?>> _capturePersistent() => _tree.captureStateData(
    verifyBoundary: () async {
      if (_closed) throw StateError('state snapshot preparation is closed');
      return {'source_state': _state.path};
    },
  );

  Future<Map<String, Object?>> _boundary() async {
    await verify();
    return {
      'format': 'gaovm.cold-state-boundary.v1',
      'source_state': _state.path,
      'owning_app': _state.appPath,
      'catalog': _catalog?.toJson(),
      'managed_assets': _assets?.toJson(),
      'external_files': _references?.toJson(),
      'legacy': _legacy.toJson(),
      'runtime': _runtime?.toJson(),
      'pre_catalog_run_absent': _catalog == null,
      'paired_app_snapshot': false,
      'external_files_backed_up': false,
      'candidate_publication_authorized': false,
      'replacement_startup_fenced': false,
    };
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _tree.close();
    _runtime?.close();
    _legacy.close();
    _references?.close();
    _assets?.close();
  }
}
