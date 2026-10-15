part of 'cold_catalog_inspection.dart';

/// Held byte/metadata/path evidence for the live catalog's external disk and EFI
/// consumers. No backup, restore authority or lasting external writer fence.
final class ColdFileReferences {
  ColdFileReferences._(this._catalog, this._observer, this._files);
  final ColdCatalogInspection _catalog;
  final MacOsOpenReferences _observer;
  final Map<String, _HeldReference> _files;
  bool _closed = false;

  static Future<ColdFileReferences> inspect(
    ColdCatalogInspection catalog, {
    MacOsOpenReferences? observer,
  }) async {
    catalog.requireQuiescent();
    await catalog.verify();
    final files = <String, _HeldReference>{};
    try {
      for (final binding in catalog.fileReferences) {
        final path = binding['path'] as String;
        final existing = files[path];
        if (existing != null) {
          existing.bindings.add(binding);
          continue;
        }
        final file = File(path);
        if (!file.isAbsolute ||
            file.absolute.path != path ||
            await file.resolveSymbolicLinks() != path) {
          throw const ColdStateFailure(
            'file_references',
            'canonical file path required',
          );
        }
        final parent = await OwnedImageDirectory.open(file.parent);
        try {
          if (parent.path != file.parent.path) {
            throw const ColdStateFailure(
              'file_references',
              'parent path changed',
            );
          }
          final source = parent.file(file.uri.pathSegments.last);
          try {
            final evidence = await _seal(source);
            if (evidence['size'] == 0 ||
                (evidence['metadata'] as Map)['has_acl'] != false) {
              // Same-UID native observation cannot account for ACL-granted
              // writers from other users. Retain and refuse, never strip ACLs.
              throw const ColdStateFailure(
                'file_references',
                'nonempty file without ACL grants required',
              );
            }
            files[path] = _HeldReference(parent, source, evidence, [binding]);
          } catch (_) {
            source.close();
            rethrow;
          }
        } catch (_) {
          parent.close();
          rethrow;
        }
      }
      final result = ColdFileReferences._(
        catalog,
        observer ?? MacOsOpenReferences(),
        files,
      );
      await result.verify();
      return result;
    } catch (_) {
      for (final file in files.values) {
        file.close();
      }
      rethrow;
    }
  }

  /// Failure retains the held descriptors and the caller's original state
  /// lease until their explicit close. No process or original file is changed.
  Future<void> verify() async {
    if (_closed) throw StateError('file reference inspection is closed');
    await _catalog.verify();
    for (final held in _files.values) {
      await held.parent.verifyPathBinding();
      if (JsonValue.fromJson(await _seal(held.file)) != held.evidence) {
        throw const ColdStateFailure(
          'file_references',
          'referenced file changed',
        );
      }
      final processes = await _observer.file(File(held.file.path));
      if (processes.any((process) => process != pid)) {
        throw const ColdStateFailure(
          'file_references',
          'other processes reference a VM file',
        );
      }
      await held.parent.verifyPathBinding();
      if (JsonValue.fromJson(await _seal(held.file)) != held.evidence) {
        throw const ColdStateFailure(
          'file_references',
          'referenced file changed during observation',
        );
      }
    }
    await _catalog.verify();
  }

  Map<String, Object?> toJson() {
    if (_closed) throw StateError('file reference inspection is closed');
    final paths = _files.keys.toList()..sort();
    return {
      'format': 'gaovm.cold-file-references.v1',
      'source_state': _catalog.sourcePath,
      'files': [
        for (final path in paths)
          {
            'path': path,
            'location': path.startsWith('${_catalog.sourcePath}/')
                ? 'state'
                : 'external',
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
  }
}

final class _HeldReference {
  _HeldReference(
    this.parent,
    this.file,
    Map<String, Object?> evidence,
    this.bindings,
  ) : evidence = JsonObjectValue.fromJson(evidence);
  final OwnedImageDirectory parent;
  final OwnedImageFile file;
  final JsonObjectValue evidence;
  final List<Map<String, Object?>> bindings;
  void close() {
    file.close();
    parent.close();
  }
}
