part of 'cold_catalog_inspection.dart';

/// Recovery of a complete sealed validation checkpoint, not migration replay,
/// activation, commit or rollback. Borrows the work directory and held fence.
/// Imported records cannot grant an original-state owner or a cold boundary.
final class ColdValidationCheckpoint {
  ColdValidationCheckpoint._(
    this._root,
    this._lock,
    this._fence,
    this._intent,
    this._record,
    this._completionName,
  );
  final OwnedImageDirectory _root;
  final OwnedImageLock _lock;
  final MaintenanceStateFence _fence;
  final Map<String, Object?> _intent, _record;
  String _completionName;
  ColdStateSnapshot? _current;
  ColdUpgradePreparation? _prepared;
  final _external = <String, _HeldReference>{};
  bool _closed = false;

  /// Read only the operator's fixed children, before any native helper runs.
  /// Unknown/partial snapshots and older intents without inode binding refuse.
  static Future<ColdValidationCheckpoint> open(
    OwnedImageDirectory work,
    MaintenanceStateFence fence, {
    required String appPath,
    required String statePath,
    required String bundleIdentifier,
    required String oldVersion,
    required String newVersion,
    required String teamIdentifier,
    required int sourceCatalogSchema,
  }) async {
    final root = work.directory('validation');
    OwnedImageLock? lock;
    try {
      await ColdUpgradePreparation._verifyPrivate(root);
      final names = await Directory(root.path)
          .list(followLinks: false)
          .take(6)
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toSet();
      final completion = names.contains('completed')
          ? 'completed'
          : '.completed.partial';
      await ColdUpgradePreparation._entries(root, {
        'intent.json',
        'validated-state',
        '.gaovm-maintenance.lock',
        completion,
      });
      lock = await root.tryAcquireMaintenanceLock(
        '.gaovm-maintenance.lock',
        create: false,
      );
      if (lock == null) throw StateError('validation snapshot already owned');
      final intent = await ColdUpgradePreparation._readRecord(
        root,
        'intent.json',
      );
      final checkpoint = root.directory(completion);
      late Map<String, Object?> record;
      try {
        await ColdUpgradePreparation._verifyPrivate(checkpoint);
        await ColdUpgradePreparation._entries(checkpoint, {'record.json'});
        record = await ColdUpgradePreparation._readRecord(
          checkpoint,
          'record.json',
        );
      } finally {
        checkpoint.close();
      }
      if (intent.length != 12 ||
          intent['format'] != 'gaovm.candidate-validation-intent.v2' ||
          !_same(
            intent['workspace_identity'],
            await root.maintenanceIdentity(),
          ) ||
          intent['source_app'] != appPath ||
          intent['source_state'] != statePath ||
          intent['bundle_identifier'] != bundleIdentifier ||
          intent['old_version'] != oldVersion ||
          intent['new_version'] != newVersion ||
          intent['team_identifier'] != teamIdentifier ||
          (intent['source_catalog_schema'] != null &&
              intent['source_catalog_schema'] is! int) ||
          (intent['source_catalog_schema'] ?? 0) != sourceCatalogSchema ||
          intent['fence_path'] != fence.path ||
          intent['publication'] is! Map<String, Object?> ||
          !_digest(intent['preparation_digest']) ||
          record.length != 21 ||
          record['format'] != 'gaovm.cold-validation-command.v1' ||
          record['phase'] != 'candidate_validated' ||
          record['source_app'] != appPath ||
          record['source_state'] != statePath ||
          record['validation_path'] != root.path ||
          record['fence_path'] != fence.path ||
          record['intent_digest'] != _hash(intent) ||
          record['applied_catalog_schema'] !=
              GaoVmDatabase.latestSchemaVersion ||
          record['ordinary_ready'] != false ||
          record['background_workers_started'] != false ||
          record['driver_sessions_started'] != false ||
          record['ordinary_startup_fenced'] != true ||
          record['activation_authorized'] != false ||
          record['rollback_authorized'] != false ||
          record['committed'] != false ||
          !_digest(record['read_only_state_digest']) ||
          !_digest(record['closed_session_state_digest']) ||
          record['catalog_identity'] is! Map<String, Object?> ||
          record['public_capabilities'] is! Map<String, Object?> ||
          record['public_doctor'] is! Map<String, Object?> ||
          record['validated_state'] is! Map<String, Object?>) {
        throw const FormatException(
          'unrecognized sealed validation checkpoint or explicit inputs disagree',
        );
      }
      PublicCapabilities.fromJson(
        record['public_capabilities'] as Map<String, Object?>,
      );
      if (!DoctorResult.fromJson(
        record['public_doctor'] as Map<String, Object?>,
      ).healthy) {
        throw const FormatException(
          'validation checkpoint did not verify public doctor',
        );
      }
      final result = ColdValidationCheckpoint._(
        root,
        lock,
        fence,
        intent,
        record,
        completion,
      );
      await result._verifyRecords();
      return result;
    } catch (_) {
      lock?.close();
      root.close();
      rethrow;
    }
  }

  /// Re-establish the current complete cold state and original rollback pair.
  /// Only a fully sealed completion can be published from its fixed partial slot.
  Future<Map<String, Object?>> recover(
    ColdStateSnapshot current,
    OwnedImageDirectory work,
    MacOsColdStateHost host, {
    required ReleaseInspectionHost inspectionHost,
    required MacOsOpenReferences observer,
  }) async {
    if (_closed || _current != null)
      throw StateError('validation recovery is unavailable');
    _current = current;
    if (current._state.path != _intent['source_state'] ||
        current._state.installationPath != _intent['source_app'] ||
        current._state.appPath != host.appPath ||
        host.isValidatingCandidate ||
        host.publicationEvidence['phase'] != 'candidate_published' ||
        current.observedCatalogSchema != _record['applied_catalog_schema']) {
      throw const FormatException(
        'recovery requires the original cold owner and published candidate',
      );
    }
    final publication = Map<String, Object?>.from(
      _intent['publication'] as Map,
    );
    final process = publication.remove('executing_process');
    if (process is! Map ||
        process.length != 5 ||
        process['pid'] is! int ||
        (process['pid'] as int) <= 0 ||
        process['uid'] is! int ||
        process['pid_version'] is! int ||
        (process['pid_version'] as int) < 0 ||
        process['started_at_microseconds'] is! int ||
        process['executable_path'] !=
            '${_intent['source_app']}/Contents/MacOS/gaovmd' ||
        !_same(publication, host.publicationBindingEvidence)) {
      throw const FormatException('validation publication binding changed');
    }
    _prepared = await ColdUpgradePreparation._open(
      current,
      _fence,
      work,
      'preparation',
      oldVersion: _intent['old_version'] as String,
      newVersion: _intent['new_version'] as String,
      teamIdentifier: _intent['team_identifier'] as String,
      sourceCatalogSchema: _intent['source_catalog_schema'] as int?,
      retainedValidation: true,
      host: inspectionHost,
      observer: observer,
    );
    if ('sha256:${sha256.convert(utf8.encode(jsonEncode(_prepared!.toJson())))}' !=
        _intent['preparation_digest']) {
      throw const FormatException('validation preparation binding changed');
    }
    await _openOriginalExternalFiles();
    await _verify(current, observer);
    final promoted = _completionName == '.completed.partial';
    if (promoted) {
      await _root.renameDirectoryNoReplace('.completed.partial', 'completed');
      _completionName = 'completed';
      await _root.sync();
      await _verify(current, observer);
    }
    return {
      ...jsonDecode(jsonEncode(_record)) as Map<String, Object?>,
      'format': 'gaovm.cold-validation-recovery-command.v1',
      'phase': 'candidate_validation_recovered',
      'completion_checkpoint_promoted': promoted,
      'validation_record_digest': _hash(_record),
      'public_api_rerun': false,
      'state_unchanged': true,
    };
  }

  Future<void> _verify(
    ColdStateSnapshot current,
    MacOsOpenReferences observer,
  ) async {
    if (_closed) throw StateError('validation checkpoint is closed');
    await _prepared!.verifyRetainedValidationInputs();
    await current.verify();
    for (final held in _external.values) {
      if ((await observer.file(
        File(held.file.path),
      )).any((process) => process != pid)) {
        throw const FormatException(
          'other processes reference original external files',
        );
      }
    }
    await current._state.verify();
    // No native observation callbacks after here: close the entire read set.
    await _prepared!._verifyOutput();
    await _prepared!._verifyNamespace();
    await _prepared!._originalApp.verify(
      (_prepared!._record['original_app_receipt'] as Map)['manifest']
          as Map<String, Object?>,
      nativeMetadata: true,
    );
    for (final held in _external.values) {
      await held.parent.verifyPathBinding();
      if (JsonValue.fromJson(await _seal(held.file)) != held.evidence) {
        throw const FormatException(
          'original external file changed after validation',
        );
      }
    }
    await _verifyRecords();
    final receipt = _record['validated_state'] as Map<String, Object?>;
    if (!_same(await current._capturePersistent(), receipt['manifest'])) {
      throw const FormatException(
        'persistent state changed after validated checkpoint',
      );
    }
    _verifyCatalogIdentity(current);
  }

  Future<void> _verifyRecords() async {
    await ColdUpgradePreparation._verifyPrivate(_root);
    if (!_same(
      await _root.maintenanceIdentity(),
      _intent['workspace_identity'],
    )) {
      throw const FormatException('validation workspace identity changed');
    }
    _lock.verifyPathBinding();
    final lockFile = _root.file('.gaovm-maintenance.lock');
    try {
      final stat = lockFile.stat();
      if (stat.mode & 0xfff != 0x180 ||
          stat.size != 0 ||
          stat.linkCount != 1 ||
          (await lockFile.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException('validation snapshot lock changed');
      }
      await lockFile.verifyPathBinding();
    } finally {
      lockFile.close();
    }
    await ColdUpgradePreparation._entries(_root, {
      'intent.json',
      'validated-state',
      '.gaovm-maintenance.lock',
      _completionName,
    });
    await ColdUpgradePreparation._checkRecord(_root, 'intent.json', _intent);
    final completed = _root.directory(_completionName);
    try {
      await ColdUpgradePreparation._verifyPrivate(completed);
      await ColdUpgradePreparation._entries(completed, {'record.json'});
      await ColdUpgradePreparation._checkRecord(
        completed,
        'record.json',
        _record,
      );
    } finally {
      completed.close();
    }
    final receipt = _record['validated_state'] as Map<String, Object?>;
    if (receipt['format'] != 'gaovm.cold-state-snapshot.v1' ||
        receipt['source_path'] != _intent['source_state'] ||
        receipt['snapshot_path'] != '${_root.path}/validated-state' ||
        receipt['payload_name'] != 'payload' ||
        !_same(receipt['omitted_paths'], ['run']) ||
        receipt['manifest'] is! Map<String, Object?> ||
        receipt['manifest_digest'] != _record['closed_session_state_digest'] ||
        receipt['manifest_digest'] !=
            'sha256:${sha256.convert(utf8.encode(jsonEncode(receipt['manifest'])))}') {
      throw const FormatException('validated state receipt changed');
    }
    final snapshot = _root.directory('validated-state');
    try {
      await ColdUpgradePreparation._verifyPrivate(snapshot);
      await MaintenanceTree.verifySnapshotContents(snapshot, receipt);
    } finally {
      snapshot.close();
    }
    _lock.verifyPathBinding();
  }

  Future<void> _openOriginalExternalFiles() async {
    final boundary =
        (_prepared!._record['original_state_receipt'] as Map)['boundary'];
    if (boundary is! Map ||
        boundary['source_state'] != _intent['source_state']) {
      throw const FormatException('original cold state boundary changed');
    }
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
            'original external file evidence is invalid',
          );
        }
        final path = value['path'] as String;
        if (path.startsWith('${_intent['source_state']}/')) continue;
        final file = File(path);
        if (!file.isAbsolute ||
            file.absolute.path != path ||
            await file.resolveSymbolicLinks() != path) {
          throw const FormatException(
            'canonical original external file required',
          );
        }
        final evidence = value['evidence'] as Map<String, Object?>;
        if (expected.containsKey(path) && !_same(expected[path], evidence)) {
          throw const FormatException('conflicting original external evidence');
        }
        expected[path] = evidence;
        if (expected.length > 16384)
          throw const FormatException('too many original external files');
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
        if (!_same(await _seal(held), entry.value)) {
          throw const FormatException(
            'original external file changed after validation',
          );
        }
        _external[entry.key] = _HeldReference(parent, held, entry.value, []);
      } catch (_) {
        held?.close();
        parent.close();
        rethrow;
      }
    }
  }

  void _verifyCatalogIdentity(ColdStateSnapshot current) {
    final database = sqlite3.open(
      '${current._inspectionPath}/gaovm.db',
      mode: OpenMode.readOnly,
    );
    try {
      final identity = <String, Object?>{
        for (final entry in const {
          'vm_ids': 'vms',
          'image_ids': 'images',
          'operation_ids': 'operations',
          'test_run_ids': 'test_runs',
          'artifact_ids': 'artifacts',
        }.entries)
          entry.key: database
              .select('SELECT id FROM ${entry.value} ORDER BY id')
              .map((row) => row['id'] as String)
              .toList(),
        'event_cursor': database
            .select('SELECT COALESCE(MAX(sequence), 0) AS cursor FROM events')
            .single['cursor'],
        'idempotency_count': database
            .select('SELECT COUNT(*) AS count FROM idempotency_keys')
            .single['count'],
      };
      if (!_same(identity, _record['catalog_identity'])) {
        throw const FormatException('validated catalog identity changed');
      }
    } finally {
      database.dispose();
    }
  }

  static bool _digest(Object? value) =>
      value is String && RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(value);
  static String _hash(Map<String, Object?> value) =>
      'sha256:${sha256.convert(utf8.encode('${jsonEncode(value)}\n'))}';
  static bool _same(Object? a, Object? b) =>
      JsonValue.fromJson(a) == JsonValue.fromJson(b);

  void close() {
    if (_closed) return;
    _closed = true;
    for (final held in _external.values) held.close();
    _prepared?.close();
    _lock.close();
    _root.close();
  }
}
