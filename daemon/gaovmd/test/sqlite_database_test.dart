import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:gaovmd/gaovmd.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'gaovmd-sqlite-',
    );
    databasePath = '${temporaryDirectory.path}/gaovm.db';
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('bootstrap configures SQLite and applies the schema once', () async {
    var database = await GaoVmDatabase.open(databasePath);

    expect(database.schemaVersion, 7);
    expect(database.appliedMigrationVersions, [1, 2, 3, 4, 5, 6, 7]);
    expect(database.journalMode, 'wal');
    expect(database.foreignKeysEnabled, isTrue);
    expect(database.busyTimeout, const Duration(seconds: 5));
    expect(database.tableNames, containsAll(coreTableNames));
    await database.read((connection) {
      final indexSql =
          connection
                  .select(
                    "SELECT sql FROM sqlite_schema WHERE name = 'vms_active_created_idx'",
                  )
                  .single['sql']
              as String;
      expect(indexSql, contains('ON vms(created_at, id)'));
      expect(indexSql, contains('WHERE deleted_at IS NULL'));
      final appliedAt =
          connection
                  .select(
                    'SELECT applied_at FROM schema_migrations WHERE version = 1',
                  )
                  .single['applied_at']
              as String;
      expect(appliedAt, matches(RegExp(r'\.\d{6}Z$')));
    });
    database.close();

    database = await GaoVmDatabase.open(databasePath);
    expect(database.schemaVersion, 7);
    expect(database.appliedMigrationVersions, [1, 2, 3, 4, 5, 6, 7]);
    database.close();
  });

  test(
    'v5 adds an empty provisioning catalog without changing v4 data',
    () async {
      final legacy = sqlite3.open(databasePath);
      legacy.execute('''
        CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
        INSERT INTO schema_migrations VALUES(1, 'old'), (2, 'old'), (3, 'old'), (4, 'old');
        CREATE TABLE vms(id TEXT PRIMARY KEY);
        CREATE TABLE vm_specs(vm_id TEXT NOT NULL, generation INTEGER NOT NULL, PRIMARY KEY(vm_id, generation));
        CREATE TABLE operations(id TEXT PRIMARY KEY);
        INSERT INTO vms VALUES('retained');
        INSERT INTO vm_specs VALUES('retained', 7);
        INSERT INTO operations VALUES('operation');
      ''');
      legacy.userVersion = 4;
      legacy.dispose();
      final database = await GaoVmDatabase.open(databasePath);
      try {
        expect(database.schemaVersion, 7);
        expect(database.appliedMigrationVersions, [1, 2, 3, 4, 5, 6, 7]);
        await database.read((db) {
          expect(db.select('SELECT * FROM vm_provisioning'), isEmpty);
          expect(db.select('SELECT * FROM vm_specs').single['generation'], 7);
          for (final values in [
            ['retained', 'operation', 8],
            ['retained', 'missing', 7],
            ['missing', 'operation', 7],
          ]) {
            expect(
              () => db.execute('''
              INSERT INTO vm_provisioning(vm_id, operation_id, spec_generation, plan_json, created_at)
              VALUES (?, ?, ?, '{}', 'now')
            ''', values),
              throwsA(isA<SqliteException>()),
            );
          }
          db.execute(
            "INSERT INTO vm_provisioning(vm_id, operation_id, spec_generation, plan_json, created_at) VALUES('retained', 'operation', 7, '{}', 'now')",
          );
          expect(
            () => db.execute("DELETE FROM vm_specs WHERE vm_id = 'retained'"),
            throwsA(isA<SqliteException>()),
          );
          expect(db.select('SELECT * FROM vms').single['id'], 'retained');
        });
      } finally {
        database.close();
      }
    },
  );

  test(
    'v6 retains v5 pinned jobs and enforces complete immutable outcome fields',
    () async {
      final legacy = sqlite3.open(databasePath);
      legacy.execute('''
      CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
      INSERT INTO schema_migrations VALUES(1, 'old'), (2, 'old'), (3, 'old'), (4, 'old'), (5, 'old');
      CREATE TABLE vm_provisioning (
        vm_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE,
        spec_generation INTEGER NOT NULL, plan_json TEXT NOT NULL,
        cancellation_requested INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL
      );
      INSERT INTO vm_provisioning VALUES('vm', 'op', 7, '{"pinned":true}', 0, 'old');
    ''');
      legacy.userVersion = 5;
      legacy.dispose();
      final database = await GaoVmDatabase.open(databasePath);
      try {
        expect(database.schemaVersion, 7);
        await database.read((db) {
          final job = db.select('SELECT * FROM vm_provisioning').single;
          expect(job['plan_json'], '{"pinned":true}');
          expect(job['spec_generation'], 7);
          expect(job['completion_kind'], isNull);
          expect(job['manifest_digest'], isNull);
          expect(job['completed_at'], isNull);
          for (final assignment in [
            "completion_kind = 'succeeded'",
            "completed_at = 'now'",
            "manifest_digest = 'digest'",
            "completion_kind = 'failed', manifest_digest = 'digest', completed_at = 'now'",
            "completion_kind = 'unknown', completed_at = 'now'",
          ]) {
            expect(
              () => db.execute('UPDATE vm_provisioning SET $assignment'),
              throwsA(isA<SqliteException>()),
            );
          }
          db.execute(
            "UPDATE vm_provisioning SET completion_kind = 'failed', completed_at = 'now'",
          );
          expect(
            () =>
                db.execute("UPDATE vm_provisioning SET completed_at = 'later'"),
            throwsA(isA<SqliteException>()),
          );
          expect(
            () => db.execute(
              'UPDATE vm_provisioning SET cancellation_requested = 1',
            ),
            throwsA(isA<SqliteException>()),
          );
        });
      } finally {
        database.close();
      }
    },
  );

  test('v7 retains v6 jobs and enforces immutable cancellation linkage', () async {
    final legacy = sqlite3.open(databasePath);
    legacy.execute('''
        CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
        INSERT INTO schema_migrations VALUES(1, 'old'), (2, 'old'), (3, 'old'), (4, 'old'), (5, 'old'), (6, 'old');
        CREATE TABLE operations(id TEXT PRIMARY KEY);
        INSERT INTO operations VALUES('target'), ('completed'), ('action'), ('second-action'), ('other-action');
        CREATE TABLE vm_provisioning (
          vm_id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE,
          spec_generation INTEGER NOT NULL, plan_json TEXT NOT NULL,
          cancellation_requested INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL, completion_kind TEXT,
          manifest_digest TEXT, completed_at TEXT
        );
        INSERT INTO vm_provisioning VALUES
          ('pending-vm', 'target', 7, '{"pinned":true}', 1, 'old', NULL, NULL, NULL),
          ('completed-vm', 'completed', 8, '{"completed":true}', 0, 'old', 'succeeded', 'digest', 'done');
      ''');
    final retainedJobs = [
      for (final row in legacy.select(
        'SELECT * FROM vm_provisioning ORDER BY vm_id',
      ))
        Map<String, Object?>.from(row),
    ];
    legacy.userVersion = 6;
    legacy.dispose();

    var database = await GaoVmDatabase.open(databasePath);
    try {
      expect(database.schemaVersion, 7);
      expect(database.appliedMigrationVersions, [1, 2, 3, 4, 5, 6, 7]);
      await database.read((db) {
        expect(
          db.select('SELECT * FROM vm_provisioning ORDER BY vm_id'),
          retainedJobs,
        );
        expect(
          db.select('SELECT * FROM vm_provisioning_cancellations'),
          isEmpty,
        );
        for (final values in [
          [null, 'target'],
          ['missing-action', 'target'],
          ['action', 'missing-target'],
          ['action', 'other-action'],
        ]) {
          expect(
            () => db.execute(
              'INSERT INTO vm_provisioning_cancellations(action_id, target_id) VALUES (?, ?)',
              values,
            ),
            throwsA(isA<SqliteException>()),
          );
        }
        db.execute('''
            INSERT INTO vm_provisioning_cancellations(action_id, target_id)
            VALUES ('action', 'target'), ('second-action', 'target')
          ''');
        expect(
          () => db.execute('''
              INSERT INTO vm_provisioning_cancellations(action_id, target_id)
              VALUES ('action', 'completed')
            '''),
          throwsA(isA<SqliteException>()),
        );
        for (final statement in [
          "UPDATE vm_provisioning_cancellations SET action_id = 'other-action' WHERE action_id = 'action'",
          "UPDATE vm_provisioning_cancellations SET target_id = 'completed' WHERE action_id = 'action'",
          "DELETE FROM operations WHERE id = 'action'",
          "DELETE FROM vm_provisioning WHERE operation_id = 'target'",
        ]) {
          expect(() => db.execute(statement), throwsA(isA<SqliteException>()));
        }
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
      });
    } finally {
      database.close();
    }

    database = await GaoVmDatabase.open(databasePath);
    try {
      expect(database.appliedMigrationVersions, [1, 2, 3, 4, 5, 6, 7]);
      await database.read((db) {
        expect(
          db.select('SELECT * FROM vm_provisioning ORDER BY vm_id'),
          retainedJobs,
        );
        expect(
          db.select(
            'SELECT * FROM vm_provisioning_cancellations ORDER BY action_id',
          ),
          [
            {'action_id': 'action', 'target_id': 'target'},
            {'action_id': 'second-action', 'target_id': 'target'},
          ],
        );
      });
    } finally {
      database.close();
    }
  });

  test(
    'v4 preserves an existing v3 checkpoint with nullable compatibility fields',
    () async {
      final legacy = sqlite3.open(databasePath);
      legacy.execute('''
        CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
        INSERT INTO schema_migrations VALUES(1, 'old'), (2, 'old'), (3, 'old');
        CREATE TABLE vm_runtime(vm_id TEXT PRIMARY KEY, applied_intent_revision INTEGER, active_operation_id TEXT);
        INSERT INTO vm_runtime VALUES('existing', 7, 'active');
      ''');
      legacy.userVersion = 3;
      legacy.dispose();
      final database = await GaoVmDatabase.open(databasePath);
      try {
        expect(database.schemaVersion, 7);
        await database.read((db) {
          final row = db.select('SELECT * FROM vm_runtime').single;
          expect(row['applied_intent_revision'], 7);
          expect(row['active_operation_id'], 'active');
          expect(row['execution_desired_state'], isNull);
          expect(row['execution_spec_generation'], isNull);
        });
      } finally {
        database.close();
      }
    },
  );

  test(
    'v3 adds acceptance checkpoints without changing existing VM state',
    () async {
      final legacy = sqlite3.open(databasePath);
      legacy.execute('''
      CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
      INSERT INTO schema_migrations VALUES(1, '2026-09-07T00:00:00.000000Z'), (2, '2026-09-07T00:00:00.000000Z');
      CREATE TABLE vms(id TEXT PRIMARY KEY, revision INTEGER NOT NULL, spec_generation INTEGER NOT NULL);
      CREATE TABLE vm_runtime(vm_id TEXT PRIMARY KEY, desired_state TEXT NOT NULL, phase TEXT NOT NULL);
      INSERT INTO vms VALUES('existing-vm', 7, 3);
      INSERT INTO vm_runtime VALUES('existing-vm', 'running', 'starting');
    ''');
      legacy.userVersion = 2;
      legacy.dispose();
      final database = await GaoVmDatabase.open(databasePath);
      try {
        expect(database.schemaVersion, 7);
        expect(database.appliedMigrationVersions, [1, 2, 3, 4, 5, 6, 7]);
        await database.read((db) {
          final vm = db.select('SELECT * FROM vms').single;
          expect(vm['revision'], 7);
          expect(vm['spec_generation'], 3);
          expect(vm['intent_revision'], 0);
          final runtime = db.select('SELECT * FROM vm_runtime').single;
          expect(runtime['desired_state'], 'running');
          expect(runtime['phase'], 'starting');
          expect(runtime['applied_intent_revision'], 0);
          expect(runtime['active_operation_id'], isNull);
          expect(runtime['execution_desired_state'], isNull);
          expect(runtime['execution_spec_generation'], isNull);
          expect(
            () => db.execute(
              "UPDATE vm_runtime SET execution_desired_state = 'invalid'",
            ),
            throwsA(isA<SqliteException>()),
          );
          expect(
            () => db.execute(
              'UPDATE vm_runtime SET execution_spec_generation = 0',
            ),
            throwsA(isA<SqliteException>()),
          );
          expect(
            () => db.execute('UPDATE vms SET intent_revision = -1'),
            throwsA(isA<SqliteException>()),
          );
          expect(
            () => db.execute(
              'UPDATE vm_runtime SET applied_intent_revision = -1',
            ),
            throwsA(isA<SqliteException>()),
          );
        });
      } finally {
        database.close();
      }
    },
  );

  test(
    'migration preserves duplicate v1 outbox keys and adds claim fields',
    () async {
      final legacy = sqlite3.open(databasePath);
      legacy.execute('''
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      );
      INSERT INTO schema_migrations(version, applied_at)
      VALUES (1, '2026-09-04T09:00:00.000000Z');
      CREATE TABLE vms(id TEXT PRIMARY KEY);
      CREATE TABLE vm_runtime(vm_id TEXT PRIMARY KEY);
      CREATE TABLE outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        topic TEXT NOT NULL,
        key TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        published_at TEXT,
        attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0)
      );
      INSERT INTO outbox(topic, key, payload_json, created_at)
      VALUES
        ('events', 'duplicate', '{}', '2026-09-04T09:00:00.000000Z'),
        ('events', 'duplicate', '{}', '2026-09-04T09:00:00.000000Z');
    ''');
      legacy.userVersion = 1;
      legacy.dispose();

      final database = await GaoVmDatabase.open(databasePath);

      expect(database.schemaVersion, 7);
      expect(database.appliedMigrationVersions, [1, 2, 3, 4, 5, 6, 7]);
      await database.read((connection) {
        expect(
          connection
              .select(
                "SELECT COUNT(*) AS count FROM outbox WHERE key = 'duplicate'",
              )
              .single['count'],
          2,
        );
        final columns = {
          for (final row in connection.select('PRAGMA table_info(outbox)'))
            row['name'],
        };
        expect(columns, containsAll(['claimed_by', 'claim_expires_at']));
      });
      database.close();
    },
  );

  test('transaction rolls back every write when its action fails', () async {
    final database = await GaoVmDatabase.open(databasePath);

    await expectLater(
      () => database.transaction((connection) {
        connection.execute(
          'CREATE TABLE transaction_probe (value TEXT NOT NULL)',
        );
        connection.execute('INSERT INTO transaction_probe(value) VALUES (?)', [
          'uncommitted',
        ]);
        throw StateError('fail this transaction');
      }),
      throwsStateError,
    );

    expect(database.tableNames, isNot(contains('transaction_probe')));
    database.close();
  });

  test(
    'a caught nested transaction failure rolls back only its savepoint',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final originalError = StateError('original nested failure');

      await database.transaction((connection) async {
        connection.execute(
          'CREATE TABLE savepoint_probe (value TEXT NOT NULL)',
        );
        connection.execute('INSERT INTO savepoint_probe(value) VALUES (?)', [
          'outer-before',
        ]);
        try {
          await database.transaction((nested) {
            nested.execute('INSERT INTO savepoint_probe(value) VALUES (?)', [
              'inner-rolled-back',
            ]);
            throw originalError;
          });
        } on StateError catch (error) {
          expect(identical(error, originalError), isTrue);
          // The outer transaction deliberately continues.
        }
        await database.transaction(
          (nested) => nested.execute(
            'INSERT INTO savepoint_probe(value) VALUES (?)',
            ['outer-after'],
          ),
        );
      });

      expect(
        await database.read(
          (connection) => connection
              .select('SELECT value FROM savepoint_probe ORDER BY rowid')
              .map((row) => row['value'])
              .toList(),
        ),
        ['outer-before', 'outer-after'],
      );
      database.close();
    },
  );

  test('nested savepoints remain independent at multiple depths', () async {
    final database = await GaoVmDatabase.open(databasePath);

    await database.transaction((connection) async {
      connection.execute('CREATE TABLE nested_probe (value TEXT NOT NULL)');
      await database.transaction((nested) async {
        nested.execute('INSERT INTO nested_probe(value) VALUES (?)', [
          'middle-before',
        ]);
        try {
          await database.transaction((deepest) {
            deepest.execute('INSERT INTO nested_probe(value) VALUES (?)', [
              'deepest-rolled-back',
            ]);
            throw StateError('roll back the deepest savepoint');
          });
        } on StateError {
          // The middle savepoint deliberately continues.
        }
        nested.execute('INSERT INTO nested_probe(value) VALUES (?)', [
          'middle-after',
        ]);
      });
    });

    expect(
      await database.read(
        (connection) => connection
            .select('SELECT value FROM nested_probe ORDER BY rowid')
            .map((row) => row['value'])
            .toList(),
      ),
      ['middle-before', 'middle-after'],
    );
    database.close();
  });

  test(
    'overlapping sibling savepoints reject and roll back the outer transaction',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final firstEntered = Completer<void>();
      final releaseFirst = Completer<void>();
      var secondActionRan = false;

      await expectLater(
        () => database.transaction((connection) async {
          connection.execute(
            'CREATE TABLE sibling_probe (value TEXT NOT NULL)',
          );
          final first = database.transaction((nested) async {
            nested.execute('INSERT INTO sibling_probe(value) VALUES (?)', [
              'first',
            ]);
            firstEntered.complete();
            await releaseFirst.future;
          });
          await firstEntered.future;
          final second = database.transaction((nested) {
            secondActionRan = true;
            nested.execute('INSERT INTO sibling_probe(value) VALUES (?)', [
              'second',
            ]);
          });
          releaseFirst.complete();
          await Future.wait([first, second]);
        }),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('overlapping nested transaction'),
          ),
        ),
      );

      expect(database.tableNames, isNot(contains('sibling_probe')));
      expect(secondActionRan, isFalse);
      database.close();
    },
  );

  test('foreign key enforcement rejects orphaned repository rows', () async {
    final database = await GaoVmDatabase.open(databasePath);

    await expectLater(
      () => database.transaction(
        (connection) => connection.execute(
          '''
            INSERT INTO vm_specs(vm_id, generation, spec_json, created_at)
            VALUES (?, ?, ?, ?)
          ''',
          ['vm_01J00000000000000000000009', 1, '{}', '2026-09-04T09:00:00Z'],
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
    database.close();
  });

  test(
    'top-level transactions wait for async callbacks and serialize',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final secondDatabase = await GaoVmDatabase.open(databasePath);
      final releaseFirst = Completer<void>();
      final sequence = <String>[];

      final first = database.transaction((connection) async {
        sequence.add('first-start');
        connection.execute(
          'CREATE TABLE async_transaction_probe (value TEXT NOT NULL)',
        );
        await releaseFirst.future;
        connection.execute(
          'INSERT INTO async_transaction_probe(value) VALUES (?)',
          ['first'],
        );
        sequence.add('first-end');
      });
      await Future<void>.delayed(Duration.zero);

      var secondCompleted = false;
      final second = secondDatabase.transaction((connection) {
        connection.execute(
          'INSERT INTO async_transaction_probe(value) VALUES (?)',
          ['second'],
        );
        sequence.add('second');
        secondCompleted = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(secondCompleted, isFalse);
      releaseFirst.complete();
      await Future.wait([first, second]);
      expect(sequence, ['first-start', 'first-end', 'second']);
      secondDatabase.close();
      database.close();
    },
  );

  test('concurrent connections serialize first bootstrap', () async {
    final databases = await Future.wait([
      GaoVmDatabase.open(databasePath),
      GaoVmDatabase.open(databasePath),
    ]);

    for (final database in databases) {
      expect(database.schemaVersion, 7);
      expect(database.appliedMigrationVersions, [1, 2, 3, 4, 5, 6, 7]);
      database.close();
    }
  });

  test('simultaneous isolate first opens converge on one migration', () async {
    final results = await Future.wait([
      for (var index = 0; index < 8; index++)
        Isolate.run(() async {
          final database = await GaoVmDatabase.open(databasePath);
          final result = (
            schemaVersion: database.schemaVersion,
            migrations: database.appliedMigrationVersions,
          );
          database.close();
          return result;
        }),
    ]);

    for (final result in results) {
      expect(result.schemaVersion, 7);
      expect(result.migrations, [1, 2, 3, 4, 5, 6, 7]);
    }
  });
}
