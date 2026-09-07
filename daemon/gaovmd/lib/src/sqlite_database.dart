import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'persistence_timestamp.dart';

const coreTableNames = <String>{
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

const _latestSchemaVersion = 2;
final _transactionContextKey = Object();
final _savepointScopeKey = Object();
final _transactionGates = <String, _AsyncGate>{};
var _memoryDatabaseSequence = 0;

final class GaoVmDatabase {
  GaoVmDatabase._(this._database, this._transactionGate);

  static Future<GaoVmDatabase> open(
    String path, {
    Duration busyTimeout = const Duration(seconds: 5),
  }) async {
    if (busyTimeout.isNegative) {
      throw ArgumentError.value(
        busyTimeout,
        'busyTimeout',
        'must not be negative',
      );
    }

    final isMemory = path == ':memory:';
    final databaseKey = isMemory
        ? 'memory:${_memoryDatabaseSequence++}'
        : File(path).absolute.path;
    final transactionGate = _transactionGates.putIfAbsent(
      databaseKey,
      _AsyncGate.new,
    );
    // This in-isolate gate is for normal repository work only. Bootstrap
    // exclusion is owned by SQLite's BEGIN EXCLUSIVE below.
    Database? database;
    try {
      database = sqlite3.open(path);
      final wrapper = GaoVmDatabase._(database, transactionGate);
      wrapper._setBusyTimeout(busyTimeout);
      wrapper._migrateExclusively();
      await wrapper._enableWal();
      wrapper._database.execute('PRAGMA foreign_keys = ON');
      return wrapper;
    } catch (_) {
      database?.dispose();
      rethrow;
    }
  }

  final Database _database;
  final _AsyncGate _transactionGate;
  bool _closed = false;

  /// True when this caller already owns a transaction on this catalog, even
  /// through another connection sharing its gate. Filesystem publication must
  /// not mistake a nested savepoint for an independently committed transaction.
  bool get hasActiveCallerTransaction {
    final context = Zone.current[_transactionContextKey];
    return context is _TransactionContext &&
        context.active &&
        identical(context.gate, _transactionGate);
  }

  int get schemaVersion => _database.userVersion;

  String get journalMode =>
      _database.select('PRAGMA journal_mode').single.values.single as String;

  bool get foreignKeysEnabled =>
      (_database.select('PRAGMA foreign_keys').single.values.single as int) ==
      1;

  Duration get busyTimeout => Duration(
    milliseconds:
        _database.select('PRAGMA busy_timeout').single.values.single as int,
  );

  List<int> get appliedMigrationVersions => [
    for (final row in _database.select(
      'SELECT version FROM schema_migrations ORDER BY version',
    ))
      row['version'] as int,
  ];

  Set<String> get tableNames => {
    for (final row in _database.select(
      "SELECT name FROM sqlite_schema WHERE type = 'table'",
    ))
      row['name'] as String,
  };

  Future<T> read<T>(FutureOr<T> Function(Database database) action) {
    final context = Zone.current[_transactionContextKey];
    if (context is _TransactionContext && context.active) {
      if (identical(context.database, this)) {
        return Future<T>.sync(() => action(_database));
      }
      if (identical(context.gate, _transactionGate)) {
        throw StateError(
          'a transaction cannot use another connection to the same database',
        );
      }
    }
    return _transactionGate.run(() => action(_database));
  }

  Future<T> transaction<T>(FutureOr<T> Function(Database database) action) {
    final context = Zone.current[_transactionContextKey];
    if (context is _TransactionContext && context.active) {
      if (identical(context.database, this)) {
        return context.runSavepoint(action, _database);
      }
      if (identical(context.gate, _transactionGate)) {
        throw StateError(
          'a transaction cannot use another connection to the same database',
        );
      }
    }

    final newContext = _TransactionContext(this, _transactionGate);
    return _transactionGate.run(
      () => runZoned(() async {
        _database.execute('BEGIN IMMEDIATE');
        try {
          final result = await action(_database);
          _database.execute('COMMIT');
          return result;
        } catch (_) {
          _database.execute('ROLLBACK');
          rethrow;
        } finally {
          newContext.active = false;
        }
      }, zoneValues: {_transactionContextKey: newContext}),
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _database.dispose();
  }

  void _setBusyTimeout(Duration busyTimeout) {
    _database.execute('PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}');
  }

  void _migrateExclusively() {
    _database.execute('BEGIN EXCLUSIVE');
    try {
      _database.execute('''
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          applied_at TEXT NOT NULL
        )
      ''');
      var currentVersion = _database.userVersion;
      if (currentVersion > _latestSchemaVersion) {
        throw StateError(
          'database schema version $currentVersion is newer than supported '
          'version $_latestSchemaVersion',
        );
      }

      for (final migration in _migrations) {
        if (migration.version <= currentVersion) continue;
        _database.execute(migration.sql);
        _database.execute(
          '''
            INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            VALUES (?, ?)
          ''',
          [migration.version, formatPersistenceTimestamp(DateTime.now())],
        );
        _database.userVersion = migration.version;
        currentVersion = migration.version;
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> _enableWal() async {
    for (var attempt = 0; ; attempt++) {
      try {
        final mode =
            _database.select('PRAGMA journal_mode = WAL').single.values.single
                as String;
        if (mode == 'wal') return;
        if (attempt >= 4) {
          throw StateError('SQLite refused WAL journal mode: $mode');
        }
      } on SqliteException catch (error) {
        final retryable =
            error.resultCode == SqlError.SQLITE_BUSY ||
            error.resultCode == SqlError.SQLITE_LOCKED;
        if (!retryable || attempt >= 4) rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 25 * (attempt + 1)));
    }
  }
}

final class _Migration {
  const _Migration(this.version, this.sql);

  final int version;
  final String sql;
}

const _migrations = <_Migration>[
  _Migration(1, '''
    CREATE TABLE IF NOT EXISTS vms (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      labels_json TEXT NOT NULL,
      revision INTEGER NOT NULL CHECK (revision >= 1),
      spec_generation INTEGER NOT NULL CHECK (spec_generation >= 1),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      deleting_at TEXT,
      deleted_at TEXT
    );

    CREATE INDEX IF NOT EXISTS vms_active_updated_idx
      ON vms(deleted_at, updated_at, id);

    CREATE INDEX IF NOT EXISTS vms_active_created_idx
      ON vms(created_at, id) WHERE deleted_at IS NULL;

    CREATE TABLE IF NOT EXISTS vm_specs (
      vm_id TEXT NOT NULL REFERENCES vms(id) ON DELETE CASCADE,
      generation INTEGER NOT NULL CHECK (generation >= 1),
      spec_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY (vm_id, generation)
    );

    CREATE TABLE IF NOT EXISTS vm_runtime (
      vm_id TEXT PRIMARY KEY REFERENCES vms(id) ON DELETE CASCADE,
      desired_state TEXT NOT NULL CHECK (desired_state IN ('stopped', 'running')),
      phase TEXT NOT NULL,
      observed_generation INTEGER NOT NULL CHECK (observed_generation >= 0),
      driver_generation INTEGER NOT NULL CHECK (driver_generation >= 0),
      guest_agent TEXT NOT NULL,
      restart_required INTEGER NOT NULL DEFAULT 0 CHECK (restart_required IN (0, 1)),
      last_transition_at TEXT NOT NULL,
      last_error_json TEXT
    );

    CREATE TABLE IF NOT EXISTS images (
      id TEXT PRIMARY KEY,
      digest TEXT NOT NULL UNIQUE,
      type TEXT NOT NULL,
      architecture TEXT NOT NULL,
      guest_profile TEXT,
      version TEXT,
      build_id TEXT,
      channel TEXT,
      labels_json TEXT NOT NULL,
      manifest_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      deleted_at TEXT
    );

    CREATE TABLE IF NOT EXISTS operations (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      resource_type TEXT NOT NULL,
      resource_id TEXT NOT NULL,
      state TEXT NOT NULL,
      request_id TEXT NOT NULL,
      idempotency_key TEXT,
      cancellable INTEGER NOT NULL CHECK (cancellable IN (0, 1)),
      progress_json TEXT NOT NULL,
      request_json TEXT NOT NULL,
      result_json TEXT,
      error_json TEXT,
      created_at TEXT NOT NULL,
      started_at TEXT,
      completed_at TEXT,
      deadline_at TEXT
    );

    CREATE INDEX IF NOT EXISTS operations_resource_idx
      ON operations(resource_type, resource_id, created_at);

    CREATE TABLE IF NOT EXISTS events (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      id TEXT NOT NULL UNIQUE,
      type TEXT NOT NULL,
      resource_type TEXT NOT NULL,
      resource_id TEXT,
      vm_id TEXT REFERENCES vms(id),
      operation_id TEXT REFERENCES operations(id),
      test_run_id TEXT REFERENCES test_runs(id),
      payload_json TEXT NOT NULL,
      occurred_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS test_runs (
      id TEXT PRIMARY KEY,
      state TEXT NOT NULL,
      spec_json TEXT NOT NULL,
      vm_id TEXT REFERENCES vms(id),
      operation_id TEXT NOT NULL REFERENCES operations(id),
      cleanup_decision TEXT,
      result_json TEXT,
      error_json TEXT,
      artifact_ids_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      completed_at TEXT
    );

    CREATE TABLE IF NOT EXISTS test_steps (
      test_run_id TEXT NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
      step_index INTEGER NOT NULL CHECK (step_index >= 0),
      state TEXT NOT NULL,
      request_json TEXT NOT NULL,
      result_json TEXT,
      error_json TEXT,
      started_at TEXT,
      completed_at TEXT,
      PRIMARY KEY (test_run_id, step_index)
    );

    CREATE TABLE IF NOT EXISTS artifacts (
      id TEXT PRIMARY KEY,
      vm_id TEXT REFERENCES vms(id),
      operation_id TEXT REFERENCES operations(id),
      test_run_id TEXT REFERENCES test_runs(id),
      kind TEXT NOT NULL,
      content_type TEXT NOT NULL,
      size_bytes INTEGER NOT NULL CHECK (size_bytes >= 0),
      digest TEXT NOT NULL,
      download_url TEXT NOT NULL,
      retention_until TEXT,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS resource_leases (
      resource_type TEXT NOT NULL,
      resource_id TEXT NOT NULL,
      owner_id TEXT NOT NULL,
      lease_json TEXT NOT NULL,
      acquired_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      PRIMARY KEY (resource_type, resource_id)
    );

    CREATE INDEX IF NOT EXISTS resource_leases_expiry_idx
      ON resource_leases(expires_at);

    CREATE TABLE IF NOT EXISTS idempotency_keys (
      scope TEXT NOT NULL,
      key TEXT NOT NULL,
      request_hash TEXT NOT NULL,
      resource_type TEXT,
      resource_id TEXT,
      response_json TEXT,
      created_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      PRIMARY KEY (scope, key)
    );

    CREATE INDEX IF NOT EXISTS idempotency_keys_expiry_idx
      ON idempotency_keys(expires_at);

    CREATE TABLE IF NOT EXISTS outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      topic TEXT NOT NULL,
      key TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      published_at TEXT,
      attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0)
    );

    CREATE INDEX IF NOT EXISTS outbox_unpublished_idx
      ON outbox(published_at, id);
  '''),
  _Migration(2, '''
    ALTER TABLE outbox ADD COLUMN claimed_by TEXT;
    ALTER TABLE outbox ADD COLUMN claim_expires_at TEXT;

    CREATE INDEX IF NOT EXISTS outbox_claimable_idx
      ON outbox(published_at, claim_expires_at, id);
  '''),
];

final class _TransactionContext {
  _TransactionContext(this.database, this.gate);

  final GaoVmDatabase database;
  final _AsyncGate gate;
  bool active = true;
  var _savepointSequence = 0;
  final _activeSavepointParents = <Object?>{};

  Future<T> runSavepoint<T>(
    FutureOr<T> Function(Database database) action,
    Database connection,
  ) async {
    final parentScope = Zone.current[_savepointScopeKey];
    if (!_activeSavepointParents.add(parentScope)) {
      throw StateError(
        'overlapping nested transaction in the same savepoint scope',
      );
    }
    final scope = _savepointSequence++;
    final name = 'gaovm_savepoint_$scope';
    var savepointCreated = false;
    try {
      connection.execute('SAVEPOINT $name');
      savepointCreated = true;
      final result = await runZoned(
        () => Future<T>.sync(() => action(connection)),
        zoneValues: {_savepointScopeKey: scope},
      );
      connection.execute('RELEASE SAVEPOINT $name');
      return result;
    } catch (error, stackTrace) {
      if (savepointCreated) {
        try {
          connection.execute('ROLLBACK TO SAVEPOINT $name');
        } catch (_) {
          // Preserve the original transaction error.
        }
        try {
          connection.execute('RELEASE SAVEPOINT $name');
        } catch (_) {
          // Preserve the original transaction error.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _activeSavepointParents.remove(parentScope);
    }
  }
}

final class _AsyncGate {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(FutureOr<T> Function() action) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }
}
