import 'dart:io';

import 'package:gaovmd/src/sqlite_database.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('validation reads the actual catalog but cannot write it', () async {
    final temporary = await Directory.systemTemp.createTemp('gvm-read-only-');
    final path = '${temporary.path}/gaovm.db';
    GaoVmDatabase? reader;
    try {
      final writer = await GaoVmDatabase.open(path);
      try {
        await writer.transaction((db) {
          db.execute('CREATE TABLE validation_probe (value TEXT NOT NULL)');
          db.execute('INSERT INTO validation_probe VALUES (?)', ['retained']);
        });
      } finally {
        writer.close();
      }
      final before = await File(path).readAsBytes();
      reader = await GaoVmDatabase.openReadOnly(
        path,
        busyTimeout: Duration.zero,
      );
      expect(reader.isReadOnly, isTrue);
      expect(reader.schemaVersion, GaoVmDatabase.latestSchemaVersion);
      expect(reader.foreignKeysEnabled, isTrue);
      expect(reader.busyTimeout, Duration.zero);
      expect(
        await reader.read(
          (db) =>
              db.select('SELECT value FROM validation_probe').single['value'],
        ),
        'retained',
      );
      // The safety boundary is native READONLY, not a reversible query_only flag.
      await reader.read((db) => db.execute('PRAGMA query_only = OFF'));
      await expectLater(
        reader.read(
          (db) => db.execute("UPDATE validation_probe SET value = 'changed'"),
        ),
        throwsA(
          isA<SqliteException>().having(
            (e) => e.resultCode,
            'SQLite result',
            SqlError.SQLITE_READONLY,
          ),
        ),
      );
      var invoked = false;
      expect(
        () => reader!.transaction((_) {
          invoked = true;
        }),
        throwsStateError,
      );
      expect(invoked, isFalse);
      expect(
        await reader.read(
          (db) =>
              db.select('SELECT value FROM validation_probe').single['value'],
        ),
        'retained',
      );
      reader.close();
      reader = null;
      expect(await File(path).readAsBytes(), orderedEquals(before));
    } finally {
      reader?.close();
      await temporary.delete(recursive: true);
    }
  });

  test('read-only validation cannot create a missing catalog', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'gvm-read-missing-',
    );
    final path = '${temporary.path}/missing.db';
    try {
      await expectLater(
        GaoVmDatabase.openReadOnly(path),
        throwsA(isA<SqliteException>()),
      );
      expect(await temporary.list().toList(), isEmpty);
    } finally {
      await temporary.delete(recursive: true);
    }
  });

  for (final version in [0, 20, 22]) {
    test(
      'read-only validation refuses schema $version without migrating it',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'gvm-read-schema-',
        );
        final path = '${temporary.path}/catalog.db';
        try {
          final fixture = sqlite3.open(path);
          try {
            fixture.execute('CREATE TABLE retained_data (value TEXT)');
            fixture.execute("INSERT INTO retained_data VALUES ('unchanged')");
            fixture.userVersion = version;
          } finally {
            fixture.dispose();
          }
          final before = await File(path).readAsBytes();
          await expectLater(GaoVmDatabase.openReadOnly(path), throwsStateError);
          expect(await File(path).readAsBytes(), orderedEquals(before));
        } finally {
          await temporary.delete(recursive: true);
        }
      },
    );
  }

  for (final alteration in [
    'DELETE FROM schema_migrations WHERE version = 1',
    'UPDATE schema_migrations SET version = 99 WHERE version = 21',
    'DROP TABLE events',
  ]) {
    test(
      'read-only validation refuses an incomplete current catalog: $alteration',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'gvm-read-ledger-',
        );
        final path = '${temporary.path}/catalog.db';
        try {
          (await GaoVmDatabase.open(path)).close();
          final fixture = sqlite3.open(path);
          try {
            fixture.execute(alteration);
          } finally {
            fixture.dispose();
          }
          final before = await File(path).readAsBytes();
          await expectLater(GaoVmDatabase.openReadOnly(path), throwsStateError);
          expect(await File(path).readAsBytes(), orderedEquals(before));
          // Failed validation releases its SQLite connection; it is not a repair.
          final retained = sqlite3.open(path, mode: OpenMode.readOnly);
          try {
            expect(retained.userVersion, GaoVmDatabase.latestSchemaVersion);
          } finally {
            retained.dispose();
          }
        } finally {
          await temporary.delete(recursive: true);
        }
      },
    );
  }

  for (final path in ['', ':memory:']) {
    test('read-only validation requires an existing file: $path', () async {
      await expectLater(GaoVmDatabase.openReadOnly(path), throwsArgumentError);
    });
  }
}
