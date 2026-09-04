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

    expect(database.schemaVersion, 1);
    expect(database.appliedMigrationVersions, [1]);
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
    expect(database.schemaVersion, 1);
    expect(database.appliedMigrationVersions, [1]);
    database.close();
  });

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
      expect(database.schemaVersion, 1);
      expect(database.appliedMigrationVersions, [1]);
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
      expect(result.schemaVersion, 1);
      expect(result.migrations, [1]);
    }
  });
}
