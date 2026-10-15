import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'cold_state_lease.dart';
import 'driver_runtime_metadata.dart';
import 'image_filesystem.dart';
import 'image_manifest.dart';
import 'macos_driver_inventory.dart';
import 'macos_open_references.dart';
import 'maintenance_tree.dart';
import 'vm_bundle_manifest.dart';
import 'vm_provisioning_plan.dart';

part 'cold_file_references.dart';
part 'cold_legacy_inspection.dart';
part 'cold_managed_assets.dart';
part 'cold_runtime_inspection.dart';
part 'cold_state_snapshot.dart';

/// Facts from a private catalog copy, not a full cold/upgrade certificate.
/// Never pass the inspection copy to a restore operation: SQLite may change its
/// database/sidecars; it contains neither complete state nor external VM files.
final class ColdCatalogInspection {
  ColdCatalogInspection._(
    this._state,
    Map<String, Object?> evidence,
    this._managedImages,
    this._managedVms,
    this._legacyMigration,
  ) : schemaVersion = evidence['schema_version'] as int,
      _quiescent = (evidence['blockers'] as List).isEmpty,
      _evidence = JsonObjectValue.fromJson(evidence);
  final JsonObjectValue _evidence;
  final ColdStateLease _state;
  final List<Image> _managedImages;
  final List<_ColdManagedVm> _managedVms;
  final _ColdLegacyMigration? _legacyMigration;
  final bool _quiescent;
  final int schemaVersion;
  String get sourcePath => _state.path;
  List<Map<String, Object?>> get blockers =>
      (toJson()['blockers'] as List).cast<Map<String, Object?>>();
  List<Map<String, Object?>> get fileReferences =>
      (toJson()['file_references'] as List).cast<Map<String, Object?>>();

  void requireQuiescent() {
    if (!_quiescent) {
      throw const ColdStateFailure('catalog', 'durable work remains');
    }
  }

  Map<String, Object?> toJson() => _evidence.toJson();

  /// Reuse only with the original held lease, never an imported JSON receipt.
  /// This verifies catalog evidence, not all state entries or external files.
  Future<void> verify() async {
    await _state.verify();
    final source = await OwnedImageDirectory.open(Directory(sourcePath));
    final expected = toJson()['source_files'] as Map<String, Object?>;
    try {
      await _noRollbackJournal(source);
      for (final name in ['gaovm.db', 'gaovm.db-wal', 'gaovm.db-shm']) {
        final file = source.fileOrNull(name);
        try {
          if ((file != null) != expected.containsKey(name) ||
              (file != null &&
                  JsonValue.fromJson(await _seal(file)) !=
                      JsonValue.fromJson(expected[name]))) {
            throw const ColdStateFailure(
              'catalog_copy',
              'source catalog changed',
            );
          }
        } finally {
          file?.close();
        }
      }
      await source.verifyPathBinding();
      await _state.verify();
    } finally {
      source.close();
    }
  }

  /// The caller supplies a new, empty, private inspection directory. Remaining
  /// output is retained; SQLite may change its own copies. The acquired state
  /// lease is never closed here. SQLite never opens the original catalog.
  static Future<ColdCatalogInspection> inspect(
    ColdStateLease state,
    OwnedImageDirectory inspection,
  ) async {
    await state.verify();
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
        !await Directory(inspection.path).list(followLinks: false).isEmpty) {
      throw const ColdStateFailure(
        'catalog_copy',
        'inspection directory must be empty, private and disjoint',
      );
    }
    final source = await OwnedImageDirectory.open(Directory(state.path));
    final inputs = <String, OwnedImageFile>{};
    try {
      await _noRollbackJournal(source);
      inputs['gaovm.db'] = source.file('gaovm.db');
      for (final name in ['gaovm.db-wal', 'gaovm.db-shm']) {
        final file = source.fileOrNull(name);
        if (file != null) inputs[name] = file;
      }
      final seals = <String, Object?>{};
      for (final entry in inputs.entries) {
        seals[entry.key] = await _seal(entry.value);
      }
      await _checkWalLayout(inputs);
      for (final entry in inputs.entries) {
        await entry.value.copyForMaintenance(inspection, entry.key);
        final copy = inspection.file(entry.key);
        try {
          if (jsonEncode(await _seal(copy)) != jsonEncode(seals[entry.key])) {
            throw const ColdStateFailure('catalog_copy', 'copy changed');
          }
        } finally {
          copy.close();
        }
      }
      await inspection.sync();
      await inspection.verifyPathBinding();
      // SQLite may need to initialize/recover WAL shared memory even for reads.
      // Permit that only in this disposable copy, then prohibit SQL writes.
      final database = sqlite3.open(
        '${inspection.path}/gaovm.db',
        mode: OpenMode.readWrite,
      );
      late Map<String, Object?> catalog;
      late List<Image> images;
      late List<_ColdManagedVm> vms;
      late _ColdLegacyMigration? legacy;
      try {
        await inspection.verifyPathBinding();
        database.execute('PRAGMA query_only = ON');
        database.execute('PRAGMA trusted_schema = OFF');
        catalog = _read(database);
        images = _readManagedImages(database);
        vms = _readManagedVms(database);
        legacy = _readLegacyMigration(database);
      } finally {
        database.dispose();
      }
      for (final entry in inputs.entries) {
        if (jsonEncode(await _seal(entry.value)) !=
            jsonEncode(seals[entry.key])) {
          throw const ColdStateFailure('catalog_copy', 'source changed');
        }
      }
      for (final name in ['gaovm.db-wal', 'gaovm.db-shm']) {
        final current = source.fileOrNull(name);
        try {
          if ((current != null) != inputs.containsKey(name)) {
            throw const ColdStateFailure('catalog_copy', 'sidecars changed');
          }
        } finally {
          current?.close();
        }
      }
      await source.verifyPathBinding();
      await inspection.verifyPathBinding();
      await _noRollbackJournal(source);
      await state.verify();
      return ColdCatalogInspection._(
        state,
        {
          'format': 'gaovm.cold-catalog-inspection.v1',
          'source_state': state.path,
          'inspection_path': inspection.path,
          'source_files': Map<String, Object?>.unmodifiable(seals),
          ...catalog,
        },
        images,
        vms,
        legacy,
      );
    } finally {
      for (final file in inputs.values) {
        file.close();
      }
      source.close();
    }
  }

  static Map<String, Object?> _read(Database database) {
    final version = database.userVersion;
    // A daemon migration bump must not silently extend this reader's policy.
    // The current-catalog integration test forces an explicit reader review.
    if (version < 0 || version > 21) {
      throw const ColdStateFailure('catalog', 'unsupported catalog schema');
    }
    final tables = {
      for (final entry in _introducedTables.entries)
        if (entry.value <= version) entry.key,
    };
    final actual = database.select(
      "SELECT name, type, sql FROM sqlite_schema WHERE type IN ('table', 'view') "
      "AND name NOT LIKE 'sqlite_%'",
    );
    if (version == 0 &&
        actual.any((row) => row['name'] == 'schema_migrations')) {
      tables.add('schema_migrations');
    }
    if (actual.length != tables.length ||
        actual.any(
          (row) =>
              !tables.contains(row['name']) ||
              row['type'] != 'table' ||
              !RegExp(
                r'^CREATE TABLE\b',
                caseSensitive: false,
              ).hasMatch(row['sql'] as String),
        )) {
      throw const ColdStateFailure(
        'catalog',
        'unknown or missing catalog tables',
      );
    }
    final migrations = tables.contains('schema_migrations')
        ? database.select(
            'SELECT version FROM schema_migrations ORDER BY version LIMIT 22',
          )
        : const <Row>[];
    if (migrations.length != version ||
        migrations.indexed.any(
          (entry) => entry.$2['version'] != entry.$1 + 1,
        )) {
      throw const ColdStateFailure(
        'catalog',
        'migration ledger does not match schema',
      );
    }
    if (database.select('PRAGMA integrity_check(1)').single.values.single !=
            'ok' ||
        database
            .select('SELECT 1 FROM pragma_foreign_key_check() LIMIT 1')
            .isNotEmpty) {
      throw const ColdStateFailure('catalog', 'catalog integrity failed');
    }
    if (version == 0) {
      return {
        'schema_version': 0,
        'blockers': [
          {
            'table': 'schema_migrations',
            'count': 1,
            'ids': ['uninitialized'],
          },
        ],
        'vms': <Object?>[],
        'file_references': <Object?>[],
        'counts': <String, Object?>{},
        'unpublished_outbox': 0,
        'event_cursor': 0,
      };
    }
    final blockers = <Map<String, Object?>>[];
    _blockers(
      database,
      blockers,
      'operations',
      "state NOT IN ('succeeded', 'failed', 'cancelled') OR completed_at IS NULL",
      'id',
    );
    for (final (table, condition, identity) in [
      ('outbox', "published_at IS NULL AND topic <> 'events'", 'id'),
      if (version >= 5)
        (
          'vm_provisioning',
          version >= 6
              ? 'completion_kind IS NULL OR completed_at IS NULL'
              : '1',
          'vm_id',
        ),
      if (version >= 8)
        ('legacy_vm_migrations', 'completed_at IS NULL', 'migration_key'),
      (
        'test_runs',
        "state NOT IN ('succeeded', 'failed', 'cancelled') OR completed_at IS NULL",
        'id',
      ),
      (
        'test_steps',
        "state = 'running' OR state NOT IN ('pending', 'running', 'succeeded', 'failed', 'cancelled', 'skipped')",
        "test_run_id || ':' || step_index",
      ),
      if (version >= 17)
        ('guest_exec_jobs', 'completed_at IS NULL', 'operation_id'),
      if (version >= 14)
        ('test_run_collection', 'completed_at IS NULL', 'test_run_id'),
      if (version >= 14)
        (
          'test_run_collection_items',
          "state = 'pending'",
          "test_run_id || ':' || kind",
        ),
      if (version >= 20)
        (
          'test_run_step_artifacts',
          "state = 'pending'",
          "test_run_id || ':' || step_index || ':' || kind",
        ),
      if (version >= 20)
        (
          'guest_diagnostic_attempts',
          'completed_at IS NULL',
          "operation_id || ':' || method",
        ),
      // Even an expired row can retain a generation/cleanup hold. Physical exit
      // and a clock comparison never authorize deleting or ignoring that owner.
      ('resource_leases', '1', "resource_type || ':' || resource_id"),
    ]) {
      _blockers(database, blockers, table, condition, identity);
    }
    final intentGap = version >= 3
        ? ' OR applied_intent_revision <> (SELECT v.intent_revision FROM vms v WHERE v.id = vm_id)'
        : '';
    final runningExecution = version >= 4
        ? " OR execution_desired_state = 'running'"
        : '';
    _blockers(
      database,
      blockers,
      'vm_runtime',
      "desired_state <> 'stopped' OR phase NOT IN ('defined', 'stopped', 'failed', 'deleted')$intentGap$runningExecution",
      'vm_id',
    );
    _blockers(
      database,
      blockers,
      'vms',
      'deleting_at IS NOT NULL AND deleted_at IS NULL',
      'id',
    );
    final vms = <Map<String, Object?>>[];
    final references = <Map<String, Object?>>[];
    final count =
        database.select('SELECT COUNT(*) AS count FROM vms').single['count']
            as int;
    if (count > 16384)
      throw const ColdStateFailure('catalog', 'VM evidence exceeds bounds');
    final executionColumn = version >= 4
        ? 'r.execution_spec_generation, r.execution_desired_state'
        : 'NULL AS execution_spec_generation, NULL AS execution_desired_state';
    final rows = database.select('''
      SELECT v.id, v.spec_generation, v.deleted_at, r.desired_state, r.phase,
        r.observed_generation, r.driver_generation, $executionColumn
      FROM vms v JOIN vm_runtime r ON r.vm_id = v.id ORDER BY v.id
    ''');
    if (rows.length != count ||
        rows.map((row) => row['id']).toSet().length != count) {
      throw const ColdStateFailure(
        'catalog',
        'missing or duplicate VM runtime binding',
      );
    }
    for (final row in rows) {
      final id = VmId(row['id'] as String).value;
      final generation = row['spec_generation'] as int;
      final observed = row['observed_generation'] as int;
      final driver = row['driver_generation'] as int;
      final execution = row['execution_spec_generation'] as int?;
      final executionDesired = row['execution_desired_state'];
      parseVmPhase(row['phase'] as String);
      if (generation < 1 ||
          observed < 0 ||
          observed > generation ||
          driver < 0 ||
          ((execution == null) != (executionDesired == null)) ||
          (executionDesired != null &&
              !['stopped', 'running'].contains(executionDesired)) ||
          (execution != null && (execution < 1 || execution > generation)) ||
          !['stopped', 'running'].contains(row['desired_state'])) {
        throw const ColdStateFailure(
          'catalog',
          'invalid VM generations or intent',
        );
      }
      final deleted = row['deleted_at'] != null;
      vms.add({
        'vm_id': id,
        'spec_generation': generation,
        'observed_generation': observed,
        'driver_generation': driver,
        'desired_state': row['desired_state'],
        'phase': row['phase'],
        'deleted': deleted,
      });
      final generations = {
        generation,
        if (observed > 0) observed,
        if (execution != null) execution,
      }.toList()..sort();
      for (final specGeneration in generations) {
        final specs = database.select(
          '''
          SELECT spec_json FROM vm_specs WHERE vm_id = ? AND generation = ?
            AND length(CAST(spec_json AS BLOB)) <= 1048576 LIMIT 2
        ''',
          [id, specGeneration],
        );
        if (specs.length != 1) {
          throw const ColdStateFailure(
            'catalog',
            'missing, oversized or duplicate VM spec',
          );
        }
        final spec = VmSpec.fromJson(
          jsonDecode(specs.single['spec_json'] as String),
        );
        if (deleted) continue;
        for (final disk in spec.disks) {
          if (disk.source case ExternalDiskSource(:final path)) {
            references.add({
              'vm_id': id,
              'spec_generation': specGeneration,
              'kind': 'disk',
              'device_id': disk.id,
              'path': path,
              'writable': disk.writable,
            });
          }
        }
        if (spec.boot case EfiBoot(
          variableStore: EfiVariableStore.external,
          :final variableStorePath,
        )) {
          references.add({
            'vm_id': id,
            'spec_generation': specGeneration,
            'kind': 'efi',
            'path': variableStorePath,
            'writable': true,
          });
        }
        if (references.length > 16384) {
          throw const ColdStateFailure(
            'catalog',
            'file reference evidence exceeds bounds',
          );
        }
      }
    }
    return {
      'schema_version': version,
      'blockers': blockers,
      'vms': vms,
      'file_references': references,
      'counts': {
        for (final table in tables)
          table: database
              .select('SELECT COUNT(*) AS count FROM $table')
              .single['count'],
      },
      // Committed events awaiting replay are not active mutating workers.
      'unpublished_outbox': database
          .select(
            'SELECT COUNT(*) AS count FROM outbox WHERE published_at IS NULL',
          )
          .single['count'],
      'event_cursor': database
          .select('SELECT COALESCE(MAX(sequence), 0) AS cursor FROM events')
          .single['cursor'],
    };
  }
}

// Additive table history from GaoVmDatabase's migrations. An unknown table at a
// known version may own work/files this reader cannot account for: refuse it.
const _introducedTables = {
  'schema_migrations': 1,
  'vms': 1,
  'vm_specs': 1,
  'vm_runtime': 1,
  'images': 1,
  'operations': 1,
  'events': 1,
  'test_runs': 1,
  'test_steps': 1,
  'artifacts': 1,
  'resource_leases': 1,
  'idempotency_keys': 1,
  'outbox': 1,
  'vm_provisioning': 5,
  'vm_provisioning_cancellations': 7,
  'legacy_vm_migrations': 8,
  'artifact_payloads': 10,
  'test_run_vm_provisioning': 12,
  'test_run_vm_start': 13,
  'test_run_collection': 14,
  'test_run_collection_items': 14,
  'test_run_vm_cleanup': 15,
  'guest_exec_jobs': 17,
  'guest_exec_cancellations': 17,
  'guest_artifact_receipts': 18,
  'guest_artifact_mappings': 18,
  'test_run_step_execs': 19,
  'test_run_step_artifacts': 20,
  'guest_diagnostic_attempts': 20,
};

void _blockers(
  Database database,
  List<Map<String, Object?>> result,
  String table,
  String condition,
  String identity,
) {
  final count =
      database
              .select('SELECT COUNT(*) AS count FROM $table WHERE $condition')
              .single['count']
          as int;
  if (count == 0) return;
  result.add({
    'table': table,
    'count': count,
    'ids': [
      for (final row in database.select(
        'SELECT $identity AS identity FROM $table WHERE $condition '
        'ORDER BY identity LIMIT 32',
      ))
        row['identity'],
    ],
  });
}

Future<Map<String, Object?>> _seal(OwnedImageFile file) async {
  final before = file.stat();
  final metadata = await file.maintenanceMetadata();
  if (before.linkCount != 1 || before.mode & 0xc12 != 0) {
    throw const ColdStateFailure('file_evidence', 'unsafe owned file');
  }
  final digest = 'sha256:${await sha256.bind(file.openRead()).first}';
  await file.verifyPathBinding();
  if (file.stat() != before ||
      jsonEncode(await file.maintenanceMetadata()) != jsonEncode(metadata)) {
    throw const ColdStateFailure('file_evidence', 'owned file changed');
  }
  return {'size': before.size, 'digest': digest, 'metadata': metadata};
}

Future<void> _noRollbackJournal(OwnedImageDirectory source) async {
  if (await FileSystemEntity.type(
        '${source.path}/gaovm.db-journal',
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound) {
    throw const ColdStateFailure(
      'catalog_copy',
      'rollback journal requires separate recovery',
    );
  }
}

// Do not let SQLite discard an obviously damaged WAL and then certify an older
// main-file view as idle. Frame visibility/checksums still belong to SQLite;
// stale frames from a previous WAL reset are legitimate, not new transactions.
Future<void> _checkWalLayout(Map<String, OwnedImageFile> files) async {
  final wal = files['gaovm.db-wal'];
  if (wal == null) return;
  final size = wal.stat().size;
  if (size == 0) return;
  final bytes = await _prefix(wal);
  if (bytes.lengthInBytes < 32) {
    throw const ColdStateFailure('catalog_copy', 'incomplete WAL header');
  }
  final magic = bytes.getUint32(0);
  final page = bytes.getUint32(8);
  if ((magic != 0x377f0682 && magic != 0x377f0683) ||
      bytes.getUint32(4) != 3007000 ||
      page < 512 ||
      page > 65536 ||
      page & (page - 1) != 0 ||
      (size - 32) % (24 + page) != 0) {
    throw const ColdStateFailure(
      'catalog_copy',
      'unsupported or incomplete WAL layout',
    );
  }
  final order = magic == 0x377f0682 ? Endian.little : Endian.big;
  var first = 0;
  var second = 0;
  for (var offset = 0; offset < 24; offset += 8) {
    first = (first + bytes.getUint32(offset, order) + second) & 0xffffffff;
    second = (second + bytes.getUint32(offset + 4, order) + first) & 0xffffffff;
  }
  if (first != bytes.getUint32(24) || second != bytes.getUint32(28)) {
    throw const ColdStateFailure('catalog_copy', 'WAL header checksum failed');
  }
  final database = await _prefix(files['gaovm.db']!);
  if (database.lengthInBytes < 18 ||
      (database.getUint16(16) == 1 ? 65536 : database.getUint16(16)) != page) {
    throw const ColdStateFailure(
      'catalog_copy',
      'WAL and database page sizes disagree',
    );
  }
}

Future<ByteData> _prefix(OwnedImageFile file) async {
  // One bounded descriptor read; await-for cancellation closes the reader.
  await for (final chunk in file.openRead()) {
    return ByteData.sublistView(Uint8List.fromList(chunk));
  }
  return ByteData(0);
}
