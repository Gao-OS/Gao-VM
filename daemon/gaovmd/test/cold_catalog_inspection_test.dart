import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/cold_catalog_inspection.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/daemon_ownership.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory state;
  late OwnedImageDirectory scratch;
  late ColdStateLease lease;
  late _Host host;
  var retainInputs = false;

  setUp(() async {
    retainInputs = false;
    temporary = Directory(
      await (await Directory.systemTemp.createTemp(
        'gvm-catalog-inspection-',
      )).resolveSymbolicLinks(),
    );
    imageFileMode(temporary.path, 0x1c0);
    state = await Directory('${temporary.path}/state').create();
    imageFileMode(state.path, 0x1c0);
    final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    database.close();
    imageFileMode('${state.path}/gaovm.db', 0x180);
    final output = await Directory('${temporary.path}/inspection').create();
    imageFileMode(output.path, 0x1c0);
    scratch = await OwnedImageDirectory.open(output);
    host = _Host();
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: 'org.gaovm.tests.Catalog',
      host: host,
    );
  });
  tearDown(() async {
    lease.close();
    scratch.close();
    if (retainInputs)
      throw StateError(
        'retaining inputs for unconfirmed child: ${temporary.path}',
      );
    await temporary.delete(recursive: true);
  });

  test(
    'catalog inspection opens only a copy and keeps state ownership',
    () async {
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        final inspection = await ColdCatalogInspection.inspect(lease, scratch);
        expect(inspection.schemaVersion, GaoVmDatabase.latestSchemaVersion);
        expect(inspection.blockers, isEmpty);
        inspection.requireQuiescent();
        expect(inspection.toJson()['source_state'], state.path);
        expect(inspection.toJson()['inspection_path'], scratch.path);
        expect(inspection.toJson()['vms'], isEmpty);
        expect(inspection.fileReferences, isEmpty);
        expect(
          (inspection.toJson()['counts'] as Map).keys.toSet(),
          coreTableNames,
        );
        await source.verify(before, nativeMetadata: true);
        final copy = sqlite3.open(
          '${scratch.path}/gaovm.db',
          mode: OpenMode.readOnly,
        );
        try {
          expect(copy.userVersion, GaoVmDatabase.latestSchemaVersion);
        } finally {
          copy.dispose();
        }
        final root = await OwnedImageDirectory.open(state);
        try {
          expect(await DaemonOwnership.tryAcquire(root), isNull);
        } finally {
          root.close();
        }
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'pending Operations prevent quiescence without deleting history',
    () async {
      final database = sqlite3.open('${state.path}/gaovm.db');
      late String active;
      try {
        active = _operation(database, state: 'pending');
        _operation(database, state: 'failed');
      } finally {
        database.dispose();
      }
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        final inspection = await ColdCatalogInspection.inspect(lease, scratch);
        expect(inspection.blockers, [
          {
            'table': 'operations',
            'count': 1,
            'ids': [active],
          },
        ]);
        expect(
          inspection.requireQuiescent,
          throwsA(
            isA<ColdStateFailure>().having((e) => e.stage, 'stage', 'catalog'),
          ),
        );
        await source.verify(before, nativeMetadata: true);
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'stopped catalog keeps VM identity and external disk/EFI bindings',
    () async {
      final diskPath = '${temporary.path}/operator.raw';
      final efiPath = '${temporary.path}/operator.efi';
      final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
      late VirtualMachine vm;
      try {
        vm = await SqliteVmRepository(
          database,
        ).create(name: 'retained-definition', spec: _spec(diskPath, efiPath));
      } finally {
        database.close();
      }
      final inspection = await ColdCatalogInspection.inspect(lease, scratch);
      inspection.requireQuiescent();
      expect((inspection.toJson()['vms'] as List).single, {
        'vm_id': vm.metadata.id.value,
        'spec_generation': 1,
        'observed_generation': 0,
        'driver_generation': 0,
        'desired_state': 'stopped',
        'phase': 'defined',
        'deleted': false,
      });
      expect(inspection.fileReferences, [
        {
          'vm_id': vm.metadata.id.value,
          'spec_generation': 1,
          'kind': 'disk',
          'device_id': 'root',
          'path': diskPath,
          'writable': true,
        },
        {
          'vm_id': vm.metadata.id.value,
          'spec_generation': 1,
          'kind': 'efi',
          'path': efiPath,
          'writable': true,
        },
      ]);
    },
    skip: !Platform.isMacOS,
  );
  for (final table in [
    'vm_runtime',
    'vm_provisioning',
    'legacy_vm_migrations',
    'test_runs',
    'guest_exec_jobs',
    'test_run_collection',
    'test_run_collection_items',
    'test_run_step_artifacts',
    'guest_diagnostic_attempts',
    'resource_leases',
  ]) {
    test('$table retains and reports unfinished work', () async {
      final fixture = await _workFixture(state);
      final database = sqlite3.open('${state.path}/gaovm.db');
      try {
        final vm = fixture.vm;
        final op = fixture.operation;
        final run = fixture.run;
        switch (table) {
          case 'vm_runtime':
            database.execute(
              "UPDATE vm_runtime SET desired_state = 'running', phase = 'failed'",
            );
          case 'vm_provisioning':
            database.execute(
              '''
              INSERT INTO vm_provisioning(vm_id, operation_id, spec_generation, plan_json, created_at)
              VALUES (?, ?, 1, ?, ?)
            ''',
              [
                vm,
                op,
                jsonEncode({
                  'plan_version': 1,
                  'vm_id': vm,
                  'operation_id': op,
                  'spec_generation': 1,
                  'spec_digest': 'sha256:${'a' * 64}',
                  'disks': [
                    {
                      'id': 'root',
                      'writable': true,
                      'source': {
                        'type': 'external',
                        'path': '${temporary.path}/operator.raw',
                      },
                    },
                  ],
                  'kernel': null,
                  'initrd': null,
                }),
                _now,
              ],
            );
          case 'legacy_vm_migrations':
            database.execute(
              '''
              INSERT INTO legacy_vm_migrations(migration_key, vm_id, operation_id, backup_digest, desired_state)
              VALUES ('legacy-single-vm-v1', ?, ?, ?, 'stopped')
            ''',
              [vm, op, 'sha256:${'a' * 64}'],
            );
          case 'test_runs':
            database.execute(
              "UPDATE test_runs SET state = 'collecting', completed_at = NULL",
            );
          case 'guest_exec_jobs':
            database.execute(
              '''
              INSERT INTO guest_exec_jobs(operation_id, vm_id, driver_generation, spec_generation,
                applied_intent_revision, created_at) VALUES (?, ?, 1, 1, 0, ?)
            ''',
              [op, vm, _now],
            );
          case 'test_run_collection':
          case 'test_run_collection_items':
            database.execute(
              '''
              INSERT INTO test_run_collection(test_run_id, snapshot_json, retention_until, completed_at)
              VALUES (?, '{}', ?, ?)
            ''',
              [run, _now, table == 'test_run_collection' ? null : _now],
            );
            if (table == 'test_run_collection_items') {
              database.execute(
                '''
                INSERT INTO test_run_collection_items(test_run_id, kind, artifact_id, state)
                VALUES (?, 'driver', ?, 'pending')
              ''',
                [run, ArtifactId.generate().value],
              );
            }
          case 'test_run_step_artifacts':
            database.execute(
              '''
              INSERT INTO test_run_step_artifacts(test_run_id, step_index, kind, artifact_id, source_json, state)
              VALUES (?, 0, 'stdout', ?, '{}', 'pending')
            ''',
              [run, ArtifactId.generate().value],
            );
          case 'guest_diagnostic_attempts':
            database.execute(
              '''
              INSERT INTO guest_diagnostic_attempts(operation_id, method, attempt_id, vm_id,
                driver_generation, control_epoch_id, request_json, started_at, deadline_at)
              VALUES (?, 'system.info', 'test-attempt', ?, 1, 'test-epoch', '{}', ?, ?)
            ''',
              [op, vm, _now, _now],
            );
          case 'resource_leases':
            // Expiry alone cannot release an unknown owner or cleanup hold.
            database.execute(
              '''
              INSERT INTO resource_leases(resource_type, resource_id, owner_id, lease_json, acquired_at, expires_at)
              VALUES ('unknown-owner-kind', ?, 'old-owner', '{}', ?, '2000-01-01T00:00:00Z')
            ''',
              [vm, _now],
            );
        }
      } finally {
        database.dispose();
      }
      final inspection = await ColdCatalogInspection.inspect(lease, scratch);
      expect(inspection.blockers.map((e) => e['table']), [table]);
      expect(inspection.blockers.single['count'], 1);
      expect(inspection.requireQuiescent, throwsA(isA<ColdStateFailure>()));
      await lease.verify();
    }, skip: !Platform.isMacOS);
  }
  for (final version in [1, 20]) {
    test(
      'schema $version is inspected without migrating its source',
      () async {
        await _workFixture(state);
        final database = sqlite3.open('${state.path}/gaovm.db');
        try {
          _historicalFixture(database, version);
        } finally {
          database.dispose();
        }
        final source = await MaintenanceTree.open(state);
        try {
          final before = await source.capture(nativeMetadata: true);
          final inspection = await ColdCatalogInspection.inspect(
            lease,
            scratch,
          );
          expect(inspection.schemaVersion, version);
          inspection.requireQuiescent();
          expect((inspection.toJson()['vms'] as List).length, 1);
          await source.verify(before, nativeMetadata: true);
        } finally {
          source.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  for (final damage in [
    'newer',
    'missing-ledger',
    'unknown-table',
    'missing-table',
  ]) {
    test(
      '$damage never produces a quiescent catalog certificate',
      () async {
        final database = sqlite3.open('${state.path}/gaovm.db');
        try {
          switch (damage) {
            case 'newer':
              database.userVersion = GaoVmDatabase.latestSchemaVersion + 1;
            case 'missing-ledger':
              database.execute(
                'DELETE FROM schema_migrations WHERE version = 3',
              );
            case 'unknown-table':
              database.execute('CREATE TABLE future_jobs(id TEXT, state TEXT)');
            case 'missing-table':
              database.execute('DROP TABLE resource_leases');
          }
        } finally {
          database.dispose();
        }
        await expectLater(
          ColdCatalogInspection.inspect(lease, scratch),
          throwsA(isA<ColdStateFailure>()),
        );
        expect(await File('${scratch.path}/gaovm.db').exists(), isTrue);
        await lease.verify();
      },
      skip: !Platform.isMacOS,
    );
  }
  for (final topic in [
    'events',
    'vm.commands',
    'vm.provisioning',
    'images.work',
    'future.work',
  ]) {
    test(
      'unpublished $topic is classified without consuming its row',
      () async {
        final database = sqlite3.open('${state.path}/gaovm.db');
        try {
          database.execute(
            '''
          INSERT INTO outbox(topic, key, payload_json, created_at) VALUES (?, 'test-key', '{}', ?)
        ''',
            [topic, _now],
          );
        } finally {
          database.dispose();
        }
        final inspection = await ColdCatalogInspection.inspect(lease, scratch);
        expect(inspection.toJson()['unpublished_outbox'], 1);
        if (topic == 'events') {
          inspection.requireQuiescent();
        } else {
          expect(inspection.blockers.single['table'], 'outbox');
          expect(inspection.requireQuiescent, throwsA(isA<ColdStateFailure>()));
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'an unapplied intent is not hidden by stopped runtime status',
    () async {
      await _workFixture(state);
      final database = sqlite3.open('${state.path}/gaovm.db');
      try {
        database.execute('UPDATE vms SET intent_revision = 1');
      } finally {
        database.dispose();
      }
      final inspection = await ColdCatalogInspection.inspect(lease, scratch);
      expect(inspection.blockers.single['table'], 'vm_runtime');
      expect(inspection.requireQuiescent, throwsA(isA<ColdStateFailure>()));
    },
    skip: !Platform.isMacOS,
  );
  test(
    'revalidation rejects changed original catalog and retains its lock',
    () async {
      final inspection = await ColdCatalogInspection.inspect(lease, scratch);
      await inspection.verify();
      final database = sqlite3.open('${state.path}/gaovm.db');
      try {
        _operation(database, state: 'pending');
      } finally {
        database.dispose();
      }
      await expectLater(inspection.verify(), throwsA(isA<ColdStateFailure>()));
      final root = await OwnedImageDirectory.open(state);
      try {
        expect(await DaemonOwnership.tryAcquire(root), isNull);
      } finally {
        root.close();
      }
    },
    skip: !Platform.isMacOS,
  );
  test(
    'committed WAL data is inspected without checkpointing original sidecars',
    () async {
      final operation = OperationId.generate().value;
      try {
        final result = await runMaintenanceCommand('/usr/bin/sqlite3', [
          '${state.path}/gaovm.db',
          'PRAGMA wal_autocheckpoint=0;',
          '.filectrl persist_wal 1',
          '.dbconfig no_ckpt_on_close on',
          "INSERT INTO operations(id,type,resource_type,resource_id,state,request_id,cancellable,progress_json,request_json,created_at) "
              "VALUES ('$operation','vm.start','vm','${VmId.generate().value}','pending','${RequestId.generate().value}',0,'{}','{}','$_now');",
        ]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
      } on MaintenanceCommandFailure catch (error) {
        if (!error.exitConfirmed) retainInputs = true;
        rethrow;
      }
      for (final name in ['gaovm.db-wal', 'gaovm.db-shm']) {
        expect(await File('${state.path}/$name').length(), greaterThan(0));
        imageFileMode('${state.path}/$name', 0x180);
      }
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        final inspection = await ColdCatalogInspection.inspect(lease, scratch);
        expect(inspection.blockers.single['ids'], [operation]);
        expect((inspection.toJson()['source_files'] as Map).keys.toSet(), {
          'gaovm.db',
          'gaovm.db-wal',
          'gaovm.db-shm',
        });
        await inspection.verify();
        await source.verify(before, nativeMetadata: true);
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unpaired execution checkpoint is not treated as a valid binding',
    () async {
      await _workFixture(state);
      final database = sqlite3.open('${state.path}/gaovm.db');
      try {
        database.execute('UPDATE vm_runtime SET execution_spec_generation = 1');
      } finally {
        database.dispose();
      }
      await expectLater(
        ColdCatalogInspection.inspect(lease, scratch),
        throwsA(isA<ColdStateFailure>()),
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unknown rollback journal is retained without opening or repairing it',
    () async {
      final journal = await File(
        '${state.path}/gaovm.db-journal',
      ).writeAsString('retained recovery bytes');
      imageFileMode(journal.path, 0x180);
      await expectLater(
        ColdCatalogInspection.inspect(lease, scratch),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(await journal.readAsString(), 'retained recovery bytes');
      expect(await Directory(scratch.path).list().isEmpty, isTrue);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'copy destinations cannot overwrite unknown inspection entries',
    () async {
      final unknown = await File(
        '${scratch.path}/retain-me',
      ).writeAsString('retain');
      await expectLater(
        ColdCatalogInspection.inspect(lease, scratch),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(await unknown.readAsString(), 'retain');
      expect(await File('${scratch.path}/gaovm.db').exists(), isFalse);
    },
    skip: !Platform.isMacOS,
  );

  test('inspection output cannot be nested under state', () async {
    final root = await OwnedImageDirectory.open(state);
    final nested = root.createDirectory('inspection');
    try {
      await expectLater(
        ColdCatalogInspection.inspect(lease, nested),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(await Directory(nested.path).list().isEmpty, isTrue);
    } finally {
      nested.close();
      root.close();
    }
  }, skip: !Platform.isMacOS);

  test(
    'blocker samples are bounded while total work remains exact',
    () async {
      final database = sqlite3.open('${state.path}/gaovm.db');
      try {
        for (var i = 0; i < 40; i++) {
          _operation(database, state: 'pending');
        }
      } finally {
        database.dispose();
      }
      final inspection = await ColdCatalogInspection.inspect(lease, scratch);
      expect(inspection.blockers.single['count'], 40);
      expect((inspection.blockers.single['ids'] as List).length, 32);
      inspection.blockers.clear();
      expect(inspection.requireQuiescent, throwsA(isA<ColdStateFailure>()));
    },
    skip: !Platform.isMacOS,
  );
  test(
    'current, observed and execution specs all contribute live file bindings',
    () async {
      final fixture = await _workFixture(state);
      final database = sqlite3.open('${state.path}/gaovm.db');
      try {
        for (final generation in [2, 3]) {
          database.execute(
            '''
          INSERT INTO vm_specs(vm_id, generation, spec_json, created_at) VALUES (?, ?, ?, ?)
        ''',
            [
              fixture.vm,
              generation,
              jsonEncode(
                _spec(
                  '${temporary.path}/disk-$generation',
                  '${temporary.path}/efi-$generation',
                ).toJson(),
              ),
              _now,
            ],
          );
        }
        database.execute('UPDATE vms SET spec_generation = 3');
        database.execute(
          "UPDATE vm_runtime SET execution_spec_generation = 2, execution_desired_state = 'stopped'",
        );
      } finally {
        database.dispose();
      }
      final inspection = await ColdCatalogInspection.inspect(lease, scratch);
      inspection.requireQuiescent();
      expect(
        inspection.fileReferences
            .map((entry) => entry['spec_generation'])
            .toSet(),
        {1, 2, 3},
      );
      expect(inspection.fileReferences.length, 6);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'an uninitialized catalog is observed but cannot authorize upgrade preparation',
    () async {
      final database = sqlite3.open('${state.path}/gaovm.db');
      try {
        for (final table in coreTableNames) {
          database.execute('DROP TABLE $table');
        }
        database.userVersion = 0;
      } finally {
        database.dispose();
      }
      final inspection = await ColdCatalogInspection.inspect(lease, scratch);
      expect(inspection.schemaVersion, 0);
      expect(inspection.requireQuiescent, throwsA(isA<ColdStateFailure>()));
    },
    skip: !Platform.isMacOS,
  );
  for (final damage in ['garbage', 'checksum', 'partial-frame']) {
    test(
      '$damage WAL is refused instead of silently inspecting an older DB view',
      () async {
        final bytes = Uint8List(
          damage == 'garbage'
              ? 9
              : damage == 'checksum'
              ? 32
              : 33,
        );
        if (damage != 'garbage') {
          final header = ByteData.sublistView(bytes);
          header.setUint32(0, 0x377f0682);
          header.setUint32(4, 3007000);
          header.setUint32(8, 4096);
          if (damage == 'partial-frame') {
            var first = 0;
            var second = 0;
            for (var offset = 0; offset < 24; offset += 8) {
              first =
                  (first + header.getUint32(offset, Endian.little) + second) &
                  0xffffffff;
              second =
                  (second +
                      header.getUint32(offset + 4, Endian.little) +
                      first) &
                  0xffffffff;
            }
            header.setUint32(24, first);
            header.setUint32(28, second);
          }
        }
        final wal = await File(
          '${state.path}/gaovm.db-wal',
        ).writeAsBytes(bytes);
        imageFileMode(wal.path, 0x180);
        await expectLater(
          ColdCatalogInspection.inspect(lease, scratch),
          throwsA(isA<ColdStateFailure>()),
        );
        expect(await wal.readAsBytes(), bytes);
      },
      skip: !Platform.isMacOS,
    );
  }
  test(
    'running execution checkpoint blocks preparation even when public intent is stopped',
    () async {
      await _workFixture(state);
      final database = sqlite3.open('${state.path}/gaovm.db');
      try {
        database.execute(
          "UPDATE vm_runtime SET execution_desired_state = 'running', execution_spec_generation = 1",
        );
      } finally {
        database.dispose();
      }
      final inspection = await ColdCatalogInspection.inspect(lease, scratch);
      expect(inspection.blockers.single['table'], 'vm_runtime');
      expect(inspection.requireQuiescent, throwsA(isA<ColdStateFailure>()));
    },
    skip: !Platform.isMacOS,
  );
}

const _now = '2026-10-15T00:00:00.000Z';

void _historicalFixture(Database database, int version) {
  if (version == 1) {
    const original = {
      'schema_migrations',
      'vms',
      'vm_specs',
      'vm_runtime',
      'images',
      'operations',
      'events',
      'test_runs',
      'test_steps',
      'artifacts',
      'resource_leases',
      'idempotency_keys',
      'outbox',
    };
    for (final table in coreTableNames.difference(original)) {
      database.execute('DROP TABLE $table');
    }
    database.execute('DROP INDEX outbox_claimable_idx');
    for (final column in ['claimed_by', 'claim_expires_at']) {
      database.execute('ALTER TABLE outbox DROP COLUMN $column');
    }
    database.execute('ALTER TABLE vms DROP COLUMN intent_revision');
    for (final column in [
      'execution_desired_state',
      'execution_spec_generation',
      'applied_intent_revision',
      'active_operation_id',
    ]) {
      database.execute('ALTER TABLE vm_runtime DROP COLUMN $column');
    }
  }
  for (final column in [
    'driver_operation_id',
    'display_state',
    'display_observed_at',
  ]) {
    database.execute('ALTER TABLE vm_runtime DROP COLUMN $column');
  }
  database.execute('DELETE FROM schema_migrations WHERE version > ?', [
    version,
  ]);
  database.userVersion = version;
}

VmSpec _spec(String disk, String efi) => VmSpec(
  cpu: 1,
  memoryBytes: 268435456,
  boot: EfiBoot(
    variableStore: EfiVariableStore.external,
    variableStorePath: efi,
  ),
  disks: [VmDisk(id: 'root', source: ExternalDiskSource(disk), writable: true)],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);

Future<({String vm, String operation, String run})> _workFixture(
  Directory state,
) async {
  final catalog = await GaoVmDatabase.open('${state.path}/gaovm.db');
  late VirtualMachine vm;
  try {
    vm = await SqliteVmRepository(catalog).create(
      name: 'retained-failed-run',
      spec: _spec(
        '${state.parent.path}/operator.raw',
        '${state.parent.path}/operator.efi',
      ),
    );
  } finally {
    catalog.close();
  }
  final database = sqlite3.open('${state.path}/gaovm.db');
  try {
    final id = vm.metadata.id.value;
    database.execute(
      "UPDATE vm_runtime SET phase = 'stopped', driver_generation = 1, observed_generation = 1",
    );
    final operation = _operation(database, state: 'failed', vmId: id);
    final run = TestRunId.generate().value;
    final request = TestStepRequest(argv: ['true'], timeoutSeconds: 1);
    final spec = TestRunSpec(
      source: TemplateVmTestRunSource(vm.metadata.id),
      wait: VmWaitSpec(
        condition: WaitCondition.guestAgentReady,
        timeoutSeconds: 1,
      ),
      steps: [request],
      cleanup: CleanupPolicy.retain,
      retainOnFailure: true,
    );
    database.execute(
      '''
      INSERT INTO test_runs(id, state, spec_json, vm_id, operation_id, artifact_ids_json, created_at, completed_at)
      VALUES (?, 'failed', ?, ?, ?, '[]', ?, ?)
    ''',
      [run, jsonEncode(spec.toJson()), id, operation, _now, _now],
    );
    database.execute(
      '''
      INSERT INTO test_steps(test_run_id, step_index, state, request_json, started_at, completed_at)
      VALUES (?, 0, 'failed', ?, ?, ?)
    ''',
      [run, jsonEncode(request.toJson()), _now, _now],
    );
    return (vm: id, operation: operation, run: run);
  } finally {
    database.dispose();
  }
}

String _operation(Database database, {required String state, String? vmId}) {
  final id = OperationId.generate().value;
  database.execute(
    '''
    INSERT INTO operations(id, type, resource_type, resource_id, state,
      request_id, cancellable, progress_json, request_json, created_at, completed_at)
    VALUES (?, 'vm.start', 'vm', ?, ?, ?, 0, '{}', '{}', ?, ?)
  ''',
    [
      id,
      vmId ?? VmId.generate().value,
      state,
      RequestId.generate().value,
      _now,
      ['succeeded', 'failed', 'cancelled'].contains(state) ? _now : null,
    ],
  );
  return id;
}

final class _Host implements ColdStateHost {
  @override
  String get appPath => '/test-only/GaoVM.app';
  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async =>
      DriverInventorySnapshot(processes: [], unresolvedProcessIds: []);
  @override
  Future<Set<int>> stateReferences(Directory state) async => {pid};
  @override
  Future<ProcessResult> serviceStatus() async => ProcessResult(
    pid,
    0,
    jsonEncode({
      'action': 'status',
      'bundle_identifier': 'org.gaovm.tests.Catalog',
      'plist_name': 'gaovmd.plist',
      'authorization_state': 'notRegistered',
      'native_status': 0,
      'outcome': 'observed',
      'error_code': null,
    }),
    '',
  );
}
