part of 'cold_catalog_inspection.dart';

const _legacyInputNames = [
  'config.json',
  'pending_config.json',
  'desired_state.json',
  'daemon_state.json',
];
const _legacyTreeNames = ['legacy-v1-backup', '.legacy-v1-backup-stage'];

/// Legacy inputs and active file dependencies, not migration or backup authority.
/// The original lease stays caller-owned, including on failure. Completed
/// migration inputs are history; their old external paths are not live specs.
final class ColdLegacyInspection {
  ColdLegacyInspection._(
    this._state,
    this._catalog,
    this._root,
    this._observer,
    this._files,
    this._trees,
    this._evidence,
  );
  final ColdStateLease _state;
  final ColdCatalogInspection? _catalog;
  final OwnedImageDirectory _root;
  final MacOsOpenReferences _observer;
  final Map<String, _HeldReference> _files;
  final Map<String, ({MaintenanceTree tree, Map<String, Object?> manifest})>
  _trees;
  final JsonObjectValue _evidence;
  bool _closed = false;

  static Future<ColdLegacyInspection> inspect(
    ColdStateLease state, {
    ColdCatalogInspection? catalog,
    MacOsOpenReferences? observer,
  }) async {
    await _context(state, catalog);
    final root = await OwnedImageDirectory.open(Directory(state.path));
    final files = <String, _HeldReference>{};
    final trees =
        <String, ({MaintenanceTree tree, Map<String, Object?> manifest})>{};
    try {
      final inputs = await _inputs(root);
      for (final name in _legacyTreeNames) {
        final path = '${root.path}/$name';
        if (await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          continue;
        }
        final tree = await MaintenanceTree.open(Directory(path));
        try {
          final manifest = await tree.capture(nativeMetadata: true);
          if (((manifest[''] as Map)['mode'] as int) != 0x1c0 ||
              manifest.values.any(
                (entry) =>
                    ((entry as Map)['metadata'] as Map)['has_acl'] != false,
              )) {
            throw const ColdStateFailure(
              'legacy_inputs',
              'private legacy tree without ACL grants required',
            );
          }
          trees[name] = (tree: tree, manifest: manifest);
        } catch (_) {
          tree.close();
          rethrow;
        }
      }
      final backup = trees['legacy-v1-backup'];
      final backupManifest = backup == null
          ? null
          : await _backup(root, backup.manifest);
      final record = catalog?._legacyMigration;
      final completed = record?.completed ?? false;
      if (record != null &&
          (backupManifest == null ||
              backupManifest['digest'] != record.backupDigest)) {
        throw const ColdStateFailure(
          'legacy_inputs',
          'catalog migration backup is missing or mismatched',
        );
      }
      String? selected;
      if (!completed) {
        if (backupManifest != null &&
            JsonValue.fromJson(backupManifest['files']) !=
                JsonValue.fromJson(_fileDigests(inputs))) {
          throw const ColdStateFailure(
            'legacy_inputs',
            'pending migration originals differ from published backup',
          );
        }
        if (_legacyInputNames.any(inputs.containsKey)) {
          selected = inputs.containsKey('pending_config.json')
              ? 'pending_config.json'
              : inputs.containsKey('config.json')
              ? 'config.json'
              : null;
          if (selected == null) {
            throw const ColdStateFailure(
              'legacy_inputs',
              'legacy state has no selected configuration',
            );
          }
          final config = await _objectAt(root, selected);
          final boot = config['boot'];
          final disk = config['disk'];
          if (boot is! Map || disk is! Map) {
            throw const ColdStateFailure(
              'legacy_inputs',
              'selected legacy file dependencies cannot be identified',
            );
          }
          final paths = {
            'kernel': boot['kernelPath'],
            if (boot['initrdPath'] != null) 'initrd': boot['initrdPath'],
            'disk': disk['path'],
          };
          for (final entry in paths.entries) {
            final path = entry.value;
            if (path is! String ||
                !File(path).isAbsolute ||
                await File(path).resolveSymbolicLinks() != path) {
              throw const ColdStateFailure(
                'legacy_inputs',
                'canonical legacy file path required',
              );
            }
            var held = files[path];
            if (held == null) {
              final parent = await OwnedImageDirectory.open(File(path).parent);
              try {
                if (parent.path != File(path).parent.path) {
                  throw const ColdStateFailure(
                    'legacy_inputs',
                    'parent changed',
                  );
                }
                final file = parent.file(File(path).uri.pathSegments.last);
                try {
                  final seal = await _seal(file);
                  if (seal['size'] == 0 ||
                      (seal['metadata'] as Map)['has_acl'] != false) {
                    throw const ColdStateFailure(
                      'legacy_inputs',
                      'nonempty legacy dependency without ACL grants required',
                    );
                  }
                  held = _HeldReference(parent, file, seal, []);
                  files[path] = held;
                } catch (_) {
                  file.close();
                  rethrow;
                }
              } catch (_) {
                parent.close();
                rethrow;
              }
            }
            held.bindings.add({
              'kind': 'legacy_${entry.key}',
              'config': selected,
              'writable': entry.key == 'disk',
            });
            if (backupManifest != null && entry.key != 'disk') {
              final expected =
                  (backupManifest['boot_sources'] as Map)[entry.key];
              final actual = held.evidence.toJson();
              if (expected is! Map ||
                  expected['path'] != path ||
                  expected['digest'] != actual['digest'] ||
                  expected['size_bytes'] != actual['size']) {
                throw const ColdStateFailure(
                  'legacy_inputs',
                  'pending legacy boot source differs from backup',
                );
              }
            }
          }
          if (backupManifest != null &&
              ((backupManifest['boot_sources'] as Map).keys.toSet().difference(
                paths.keys.toSet(),
              )).isNotEmpty) {
            throw const ColdStateFailure(
              'legacy_inputs',
              'unexpected pending legacy boot source',
            );
          }
        }
      }
      final result = ColdLegacyInspection._(
        state,
        catalog,
        root,
        observer ?? MacOsOpenReferences(),
        files,
        trees,
        JsonObjectValue.fromJson({
          'format': 'gaovm.cold-legacy-inspection.v1',
          'source_state': state.path,
          'mode': completed
              ? 'completed'
              : selected == null
              ? 'absent'
              : 'pending',
          'selected_config': selected,
          'migration_vm_id': record?.vmId,
          'backup_digest': backupManifest?['digest'],
          'inputs': inputs,
          'trees': {
            for (final entry in trees.entries) entry.key: entry.value.manifest,
          },
          'snapshot_authorized': false,
        }),
      );
      await result.verify();
      return result;
    } catch (_) {
      for (final file in files.values) {
        file.close();
      }
      for (final tree in trees.values) {
        tree.tree.close();
      }
      root.close();
      rethrow;
    }
  }

  static Future<void> _context(
    ColdStateLease state,
    ColdCatalogInspection? catalog,
  ) async {
    await state.verify();
    if (catalog != null) {
      if (!identical(catalog._state, state)) {
        throw const ColdStateFailure(
          'legacy_inputs',
          'original catalog lease required',
        );
      }
      catalog.requireQuiescent();
      await catalog.verify();
    } else {
      for (final name in [
        'gaovm.db',
        'gaovm.db-wal',
        'gaovm.db-shm',
        'gaovm.db-journal',
      ]) {
        if (await FileSystemEntity.type(
              '${state.path}/$name',
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          throw const ColdStateFailure(
            'legacy_inputs',
            'catalog inspection required',
          );
        }
      }
    }
  }

  Future<void> _verifyInputs() async {
    await _context(_state, _catalog);
    if (JsonValue.fromJson(await _inputs(_root)) != _evidence['inputs']) {
      throw const ColdStateFailure('legacy_inputs', 'legacy inputs changed');
    }
    for (final name in _legacyTreeNames) {
      final tree = _trees[name];
      if (tree == null) {
        if (await FileSystemEntity.type(
              '${_root.path}/$name',
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          throw const ColdStateFailure('legacy_inputs', 'legacy tree appeared');
        }
      } else {
        await tree.tree.verify(tree.manifest, nativeMetadata: true);
      }
    }
    await _root.verifyPathBinding();
  }

  Future<void> verify() async {
    if (_closed) throw StateError('legacy inspection is closed');
    await _verifyInputs();
    for (final held in _files.values) {
      await held.parent.verifyPathBinding();
      if (JsonValue.fromJson(await _seal(held.file)) != held.evidence) {
        throw const ColdStateFailure(
          'legacy_inputs',
          'legacy dependency changed',
        );
      }
      final processes = await _observer.file(File(held.file.path));
      if (processes.any((process) => process != pid)) {
        throw const ColdStateFailure(
          'legacy_inputs',
          'other process references legacy file',
        );
      }
      if (JsonValue.fromJson(await _seal(held.file)) != held.evidence) {
        throw const ColdStateFailure(
          'legacy_inputs',
          'legacy file changed during observation',
        );
      }
    }
    await _verifyInputs();
    await _context(_state, _catalog);
  }

  Map<String, Object?> toJson() {
    if (_closed) throw StateError('legacy inspection is closed');
    return {
      ..._evidence.toJson(),
      'files': [
        for (final path in _files.keys.toList()..sort())
          {
            'path': path,
            'backed_up': false,
            'evidence': _files[path]!.evidence.toJson(),
            'bindings': [
              for (final binding in _files[path]!.bindings)
                Map<String, Object?>.of(binding),
            ],
          },
      ],
    };
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final file in _files.values) {
      file.close();
    }
    for (final tree in _trees.values) {
      tree.tree.close();
    }
    _root.close();
  }

  static Future<Map<String, Object?>> _inputs(OwnedImageDirectory root) async {
    final result = <String, Object?>{};
    for (final name in [..._legacyInputNames, '.legacy-v1-migration.lock']) {
      final file = root.fileOrNull(name);
      if (file == null) continue;
      try {
        final seal = await _seal(file);
        if ((seal['metadata'] as Map)['has_acl'] != false) {
          throw const ColdStateFailure(
            'legacy_inputs',
            'legacy input has ACL grants',
          );
        }
        result[name] = seal;
      } finally {
        file.close();
      }
    }
    await root.verifyPathBinding();
    return result;
  }

  static Map<String, Object?> _fileDigests(Map<String, Object?> files) {
    final result = <String, Object?>{};
    for (final name in _legacyInputNames) {
      final file = files[name];
      if (file == null) {
        result[name] = null;
        continue;
      }
      final entry = file as Map;
      if ((entry.containsKey('kind') && entry['kind'] != 'file') ||
          (entry['size'] as int) > 1024 * 1024) {
        throw const ColdStateFailure(
          'legacy_inputs',
          'invalid legacy backup input',
        );
      }
      result[name] = {
        'sha256': (entry['digest'] as String).substring(7),
        'size_bytes': entry['size'],
      };
    }
    return result;
  }

  static Future<Map<String, Object?>> _backup(
    OwnedImageDirectory root,
    Map<String, Object?> tree,
  ) async {
    final marker = tree['.gaovm-legacy-backup-owner'];
    if (marker is! Map ||
        marker['kind'] != 'directory' ||
        tree.keys.any(
          (path) => path.startsWith('.gaovm-legacy-backup-owner/'),
        )) {
      throw const ColdStateFailure(
        'legacy_inputs',
        'legacy backup owner marker required',
      );
    }
    final directory = root.directory('legacy-v1-backup');
    try {
      final manifest = await _objectAt(directory, 'manifest.json');
      final sources = manifest['boot_sources'];
      if (sources is! Map ||
          !sources.containsKey('kernel') ||
          sources.keys.any((key) => key != 'kernel' && key != 'initrd')) {
        throw const ColdStateFailure(
          'legacy_inputs',
          'invalid legacy boot manifest',
        );
      }
      for (final source in sources.values) {
        if (source is! Map ||
            source.length != 3 ||
            source['path'] is! String ||
            !File(source['path'] as String).isAbsolute ||
            source['digest'] is! String ||
            !RegExp(
              r'^sha256:[0-9a-f]{64}$',
            ).hasMatch(source['digest'] as String) ||
            source['size_bytes'] is! int ||
            (source['size_bytes'] as int) <= 0) {
          throw const ColdStateFailure(
            'legacy_inputs',
            'invalid legacy boot source',
          );
        }
      }
      final unsigned = {
        'migration_version': 1,
        'boot_sources': sources,
        'files': _fileDigests(tree),
      };
      // Frozen migration v1 hashes the saved bytes, not decoded legacy JSON.
      if (JsonValue.fromJson(manifest) !=
          JsonValue.fromJson({
            ...unsigned,
            'digest': contentDigest(unsigned),
          })) {
        throw const ColdStateFailure(
          'legacy_inputs',
          'legacy backup manifest mismatch',
        );
      }
      return manifest;
    } finally {
      directory.close();
    }
  }

  static Future<Map<String, Object?>> _objectAt(
    OwnedImageDirectory parent,
    String name,
  ) async {
    final file = parent.file(name);
    try {
      final object = jsonDecode(
        utf8.decode(await file.readBounded(1024 * 1024)),
      );
      if (object is! Map)
        throw const ColdStateFailure(
          'legacy_inputs',
          'legacy JSON object required',
        );
      await file.verifyPathBinding();
      return Map<String, Object?>.from(object);
    } finally {
      file.close();
    }
  }
}

final class _ColdLegacyMigration {
  const _ColdLegacyMigration(this.vmId, this.backupDigest, this.completed);
  final String vmId;
  final String backupDigest;
  final bool completed;
}

_ColdLegacyMigration? _readLegacyMigration(Database database) {
  if (database.userVersion < 8) return null;
  final rows = database.select(
    'SELECT migration_key, vm_id, backup_digest, completed_at '
    'FROM legacy_vm_migrations LIMIT 2',
  );
  if (rows.isEmpty) return null;
  final row = rows.first;
  if (rows.length != 1 ||
      row['migration_key'] != 'legacy-single-vm-v1' ||
      row['backup_digest'] is! String ||
      !RegExp(
        r'^sha256:[0-9a-f]{64}$',
      ).hasMatch(row['backup_digest'] as String)) {
    throw const ColdStateFailure(
      'legacy_inputs',
      'unsupported legacy migration record',
    );
  }
  final vmId = VmId(row['vm_id'] as String).value;
  return _ColdLegacyMigration(
    vmId,
    row['backup_digest'] as String,
    row['completed_at'] != null,
  );
}
