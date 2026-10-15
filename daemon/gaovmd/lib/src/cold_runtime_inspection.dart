part of 'cold_catalog_inspection.dart';

/// Read-only runtime observations, not permission to omit or remove run/.
final class ColdRuntimeInspection {
  ColdRuntimeInspection._(this._catalog, this._tree, this._inventory)
    : _evidence = JsonObjectValue.fromJson({
        'format': 'gaovm.cold-runtime-inspection.v1',
        'source_state': _catalog.sourcePath,
        'run_present': _tree != null,
        'records': [
          for (final record in _tree?.records ?? <DriverRuntimeMetadata>[])
            record.toJson(),
        ],
        'entries': _tree?.evidence ?? <String, Object?>{},
        'run_omission_authorized': false,
      });
  final ColdCatalogInspection _catalog;
  final _ColdRuntimeTree? _tree;
  final Future<DriverInventorySnapshot> Function(String) _inventory;
  final JsonObjectValue _evidence;
  bool _closed = false;

  static Future<ColdRuntimeInspection> inspect(
    ColdCatalogInspection catalog, {
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) async {
    catalog.requireQuiescent();
    await catalog.verify();
    final tree = await _ColdRuntimeTree.read(catalog);
    try {
      final result = ColdRuntimeInspection._(
        catalog,
        tree,
        inventory ??
            (path) => MacOsDriverInventory(executablePath: path).snapshot(),
      );
      await result.verify();
      return result;
    } catch (_) {
      tree?.close();
      rethrow;
    }
  }

  Map<String, Object?> toJson() {
    if (_closed) throw StateError('runtime inspection is closed');
    return _evidence.toJson();
  }

  Future<void> verify() async {
    if (_closed) throw StateError('runtime inspection is closed');
    await _catalog.verify();
    await _verifyObservedRuntime();
    await _catalog.verify();
  }

  Future<void> _verifyObservedRuntime() async {
    if (_closed) throw StateError('runtime inspection is closed');
    await _verifyTree();
    final executables = {
      '${_catalog._state.appPath}/Contents/Helpers/gaovm-driver-vz',
      for (final record in _tree?.records ?? <DriverRuntimeMetadata>[])
        record.executable,
    }.toList()..sort();
    for (final executable in executables) {
      final observed = await _inventory(executable);
      if (observed.processes.isNotEmpty ||
          observed.unresolvedProcessIds.isNotEmpty) {
        throw const ColdStateFailure(
          'runtime_processes',
          'live or unresolved runtime processes remain',
        );
      }
    }
    await _verifyTree();
  }

  Future<void> _verifyTree() async {
    final tree = _tree;
    if (tree != null) await tree.verifyBindings();
    final current = await _ColdRuntimeTree.read(_catalog);
    try {
      if ((tree == null) != (current == null) ||
          (tree != null &&
              JsonValue.fromJson(tree.evidence) !=
                  JsonValue.fromJson(current!.evidence))) {
        throw const ColdStateFailure(
          'runtime_files',
          'runtime namespace changed',
        );
      }
      if (tree != null) await tree.verifyBindings();
    } finally {
      current?.close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _tree?.close();
  }
}

final class _ColdRuntimeTree {
  final directories = <String, OwnedImageDirectory>{};
  final files = <String, OwnedImageFile>{};
  final evidence = <String, Object?>{};
  final records = <DriverRuntimeMetadata>[];

  static Future<_ColdRuntimeTree?> read(ColdCatalogInspection catalog) async {
    final path = '${catalog.sourcePath}/run';
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory ||
        await Directory(path).resolveSymbolicLinks() != path) {
      throw const ColdStateFailure(
        'runtime_files',
        'canonical runtime directory required',
      );
    }
    final result = _ColdRuntimeTree();
    final bindings = {
      for (final vm
          in (catalog.toJson()['vms'] as List).cast<Map<String, Object?>>())
        vm['vm_id'] as String: vm['driver_generation'] as int,
    };
    var count = 0;
    Future<void> visit(
      OwnedImageDirectory directory,
      String relative, {
      VmId? vm,
      int? generation,
      bool marker = false,
    }) async {
      result.directories[relative] = directory;
      await directory.verifyPathBinding();
      final metadata = await directory.maintenanceMetadata();
      if (directory.mode & 0xc3f != 0 ||
          metadata['has_acl'] != false ||
          ++count > 4096) {
        throw const ColdStateFailure(
          'runtime_files',
          'unsafe or excessive runtime directories',
        );
      }
      result.evidence[relative] = {'kind': 'directory', 'metadata': metadata};
      final names = <String>[];
      await for (final entry in Directory(
        directory.path,
      ).list(followLinks: false)) {
        if (names.length + count >= 4096) {
          throw const ColdStateFailure(
            'runtime_files',
            'runtime namespace exceeds bounds',
          );
        }
        names.add(entry.path.substring(entry.path.lastIndexOf('/') + 1));
      }
      names.sort();
      for (final name in names) {
        final child = relative.isEmpty ? name : '$relative/$name';
        if (marker)
          throw const ColdStateFailure(
            'runtime_files',
            'runtime owner marker is not empty',
          );
        if ((relative.isEmpty &&
                (name == 'api.sock' || _coldApiSocket.hasMatch(name))) ||
            (generation != null &&
                (name == 'driver.sock' || name == 'guest.sock'))) {
          if (++count > 4096)
            throw const ColdStateFailure(
              'runtime_files',
              'runtime namespace exceeds bounds',
            );
          result.evidence[child] = await directory.maintenanceSocketMetadata(
            name,
          );
          continue;
        }
        if (relative.isEmpty) {
          final id = VmId(name);
          if (!bindings.containsKey(id.value)) {
            throw const ColdStateFailure(
              'runtime_files',
              'runtime VM has no catalog binding',
            );
          }
          await visit(directory.directory(name), child, vm: id);
        } else if (_coldRuntimeMarker.hasMatch(name)) {
          await visit(directory.directory(name), child, marker: true);
        } else if (generation == null) {
          final number = int.tryParse(name);
          if (number == null ||
              number < 1 ||
              '$number' != name ||
              number > bindings[vm!.value]!) {
            throw const ColdStateFailure(
              'runtime_files',
              'unknown runtime generation',
            );
          }
          await visit(
            directory.directory(name),
            child,
            vm: vm,
            generation: number,
          );
        } else if (name == 'metadata.json') {
          final file = directory.file(name);
          result.files[child] = file;
          if (++count > 4096 || file.size > 64 * 1024) {
            throw const ColdStateFailure(
              'runtime_files',
              'unsafe or excessive runtime files',
            );
          }
          final seal = await _seal(file);
          if ((seal['metadata'] as Map)['has_acl'] != false) {
            throw const ColdStateFailure(
              'runtime_files',
              'runtime metadata grants ACL access',
            );
          }
          result.evidence[child] = {'kind': 'file', ...seal};
        } else {
          throw const ColdStateFailure(
            'runtime_files',
            'unknown runtime entry',
          );
        }
      }
      if (generation != null) {
        final file = result.files['$relative/metadata.json'];
        if (file == null)
          throw const ColdStateFailure(
            'runtime_files',
            'runtime generation has no metadata',
          );
        final value = jsonDecode(
          utf8.decode(await file.readBounded(64 * 1024)),
        );
        if (value is! Map<String, Object?>)
          throw const FormatException('runtime metadata must be an object');
        final record = DriverRuntimeMetadata.fromJson(value);
        if (record.processIdentity case final identity?) {
          if (identity.uid != metadata['uid']) {
            throw const ColdStateFailure(
              'runtime_files',
              'runtime process UID contradicts owned state',
            );
          }
        }
        // Historical paths select read-only native observations only. They do
        // not authorize execution, signaling, trust or mutation at those paths.
        if (!_coldRuntimePath(record.executable)) {
          throw const ColdStateFailure(
            'runtime_files',
            'runtime executable path is not canonical',
          );
        }
        // Do not pass the record's own executable to requireBinding: that
        // API requires a separately trusted executable, unlike this census.
        if (record.correlation.vmId != vm ||
            record.correlation.driverGeneration != generation ||
            record.bundlePath !=
                '${catalog.sourcePath}/vms/${vm!.value}.gaovm' ||
            record.socketPath != '${directory.path}/driver.sock') {
          throw const ColdStateFailure(
            'runtime_files',
            'runtime metadata disagrees with catalog or derived paths',
          );
        }
        result.records.add(record);
      }
      await directory.verifyPathBinding();
      if (JsonValue.fromJson(await directory.maintenanceMetadata()) !=
          JsonValue.fromJson(metadata)) {
        throw const ColdStateFailure(
          'runtime_files',
          'runtime directory changed during inspection',
        );
      }
    }

    try {
      await visit(await OwnedImageDirectory.open(Directory(path)), '');
      return result;
    } catch (error) {
      result.close();
      if (error is FormatException)
        throw ColdStateFailure('runtime_files', error.message);
      rethrow;
    }
  }

  Future<void> verifyBindings() async {
    for (final directory in directories.values) {
      await directory.verifyPathBinding();
    }
    for (final file in files.values) {
      await file.verifyPathBinding();
    }
  }

  void close() {
    for (final file in files.values) file.close();
    for (final directory in directories.values.toList().reversed)
      directory.close();
  }
}

final _coldRuntimeMarker = RegExp(r'^\.gaovm-owner-[A-Za-z0-9_-]{32}$');
final _coldApiSocket = RegExp(r'^\.[gosq]\.[A-Za-z0-9_-]{1,64}$');
bool _coldRuntimePath(String path) =>
    path.startsWith('/') &&
    !path
        .substring(1)
        .split('/')
        .any((part) => part.isEmpty || part == '.' || part == '..');
