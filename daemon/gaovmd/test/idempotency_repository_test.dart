import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/idempotency_repository.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteIdempotencyRepository repository;
  late DateTime now;
  var calls = 0;
  final body = utf8.encode('{"force":false}');
  final envelope = JsonObjectValue.fromJson({
    'status': 202,
    'operation_id': 'op_01J00000000000000000000000',
    'resource_id': 'vm_01J00000000000000000000000',
  });

  Future<IdempotencyResponse> action() async {
    calls++;
    return IdempotencyResponse(envelope);
  }

  Future<IdempotencyResult> execute({
    String scope = 'POST /v1/vms/vm_01J00000000000000000000000/start',
    List<int>? requestBody,
    Future<IdempotencyResponse> Function()? run,
  }) => repository.execute(
    scope: scope,
    key: 'retry-key',
    requestBody: requestBody ?? body,
    action: run ?? action,
  );

  Future<IdempotencyResult?> lookup({
    String scope = 'POST /v1/vms/vm_01J00000000000000000000000/start',
    String key = 'retry-key',
    List<int>? requestBody,
  }) => repository.lookup(
    scope: scope,
    key: key,
    requestBody: requestBody ?? body,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gaovm-idempotency-');
    database = await GaoVmDatabase.open('${directory.path}/db.sqlite');
    now = DateTime.utc(2026, 9, 7);
    calls = 0;
    repository = SqliteIdempotencyRepository(
      database,
      retention: const Duration(hours: 1),
      now: () => now,
    );
  });

  tearDown(() async {
    database.close();
    await directory.delete(recursive: true);
  });

  test('lookup misses do not reserve or mutate a request', () async {
    expect(
      await repository.lookup(
        scope: 'missing',
        key: 'retry-key',
        requestBody: body,
      ),
      isNull,
    );
    await database.read((connection) {
      expect(connection.select('SELECT * FROM idempotency_keys'), isEmpty);
    });
    expect((await execute(scope: 'missing')).replayed, isFalse);
    expect(calls, 1);
  });

  test(
    'lookup replays a frozen response without extending retention',
    () async {
      await execute();
      final stored = await database.read(
        (db) => Map<String, Object?>.from(
          db.select('SELECT * FROM idempotency_keys').single,
        ),
      );
      now = now.add(const Duration(minutes: 59));
      final replay = (await lookup())!;
      expect(replay.replayed, isTrue);
      expect(replay.response.toJson(), envelope.toJson());
      final exported = replay.response.toJson();
      expect(() => exported['status'] = 500, throwsUnsupportedError);
      expect(replay.response.toJson(), envelope.toJson());
      expect((await lookup())!.response.toJson(), envelope.toJson());
      expect(await lookup(scope: 'another-target'), isNull);
      expect(await lookup(key: 'another-key'), isNull);
      await database.read((db) {
        expect(db.select('SELECT * FROM idempotency_keys').single, stored);
      });
      expect(calls, 1);
    },
  );

  test(
    'lookup rejects different exact bytes until completed response expires',
    () async {
      await execute();
      await expectLater(
        lookup(requestBody: utf8.encode('{ "force":false}')),
        throwsA(isA<IdempotencyConflictException>()),
      );
      now = now.add(const Duration(hours: 1) - const Duration(microseconds: 1));
      expect((await lookup())!.replayed, isTrue);
      now = now.add(const Duration(microseconds: 1));
      expect(await lookup(), isNull);
      expect(await lookup(requestBody: [0]), isNull);
      await database.read((db) {
        expect(db.select('SELECT * FROM idempotency_keys'), hasLength(1));
      });
      expect(await repository.cleanupExpired(), 1);
      expect(calls, 1);
    },
  );

  test(
    'lookup observes unfinished caller work even after its reservation expires',
    () async {
      await execute(
        run: () async {
          for (final elapsed in [Duration.zero, const Duration(hours: 2)]) {
            now = now.add(elapsed);
            await expectLater(
              lookup(),
              throwsA(isA<IdempotencyInProgressException>()),
            );
            await expectLater(
              lookup(requestBody: [0]),
              throwsA(isA<IdempotencyConflictException>()),
            );
          }
          return action();
        },
      );
      expect((await lookup())!.replayed, isTrue);
      expect(calls, 1);
    },
  );

  test('lookup validates scope key and byte bounds without mutation', () async {
    expect(() => lookup(scope: ''), throwsArgumentError);
    expect(() => lookup(key: ''), throwsArgumentError);
    expect(() => lookup(key: 'x' * 256), throwsArgumentError);
    expect(() => lookup(requestBody: [-1]), throwsArgumentError);
    expect(() => lookup(requestBody: [256]), throwsArgumentError);
    expect(await lookup(key: 'x' * 255, requestBody: [0, 255]), isNull);
    await database.read((db) {
      expect(db.select('SELECT * FROM idempotency_keys'), isEmpty);
    });
  });

  test(
    'replays persisted resource and operation after database reopen',
    () async {
      expect((await execute()).replayed, isFalse);
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/db.sqlite');
      repository = SqliteIdempotencyRepository(
        database,
        retention: const Duration(hours: 1),
        now: () => now,
      );
      final retry = await execute();
      expect(retry.replayed, isTrue);
      expect(retry.response.toJson(), envelope.toJson());
      expect(calls, 1);
    },
  );

  test(
    'different bytes conflict, including whitespace and list order',
    () async {
      await execute();
      await expectLater(
        execute(requestBody: utf8.encode('{ "force":false}')),
        throwsA(
          isA<IdempotencyConflictException>().having(
            (error) => error.code,
            'code',
            'IDEMPOTENCY_CONFLICT',
          ),
        ),
      );
      expect(
        SqliteIdempotencyRepository.requestHash(utf8.encode('[1,2]')),
        isNot(SqliteIdempotencyRepository.requestHash(utf8.encode('[2,1]'))),
      );
      expect(calls, 1);
    },
  );

  test('same key for different action targets has independent scope', () async {
    await execute();
    await execute(scope: 'POST /v1/vms/another/start');
    await execute(scope: 'POST /v1/vms/another/stop');
    expect(calls, 3);
  });

  test('concurrent requests wait for commit then replay once', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = execute(
      run: () async {
        entered.complete();
        await release.future;
        return action();
      },
    );
    await entered.future;
    final second = execute();
    release.complete();
    expect((await first).replayed, isFalse);
    expect((await second).replayed, isTrue);
    expect(calls, 1);
  });

  test('nested retry observes in-progress and cannot execute again', () async {
    await execute(
      run: () async {
        await expectLater(
          execute(),
          throwsA(isA<IdempotencyInProgressException>()),
        );
        await expectLater(
          execute(requestBody: [0]),
          throwsA(isA<IdempotencyConflictException>()),
        );
        return action();
      },
    );
    expect(calls, 1);
  });

  test('separate database connections reuse one accepted operation', () async {
    final otherDatabase = await GaoVmDatabase.open(
      '${directory.path}/db.sqlite',
    );
    final other = SqliteIdempotencyRepository(
      otherDatabase,
      retention: const Duration(hours: 1),
      now: () => now,
    );
    final operations = SqliteOperationRepository(database);
    final entered = Completer<void>();
    final release = Completer<void>();
    try {
      final first = execute(
        run: () async {
          final operation = await operations.create(
            type: 'vm.start',
            resourceType: ResourceType.virtualMachine,
            resourceId: VmId('vm_01J00000000000000000000000'),
            requestId: RequestId.generate(),
            cancellable: true,
            request: JsonObjectValue.fromJson({}),
          );
          entered.complete();
          await release.future;
          return IdempotencyResponse(
            JsonObjectValue.fromJson({
              'operation_id': operation.id.value,
              'resource_id': operation.resourceId.value,
            }),
          );
        },
      );
      await entered.future;
      final second = other.execute(
        scope: 'POST /v1/vms/vm_01J00000000000000000000000/start',
        key: 'retry-key',
        requestBody: body,
        action: () async => throw StateError('must not execute twice'),
      );
      release.complete();
      final accepted = await first;
      final replay = await second;
      expect(replay.replayed, isTrue);
      expect(replay.response.toJson(), accepted.response.toJson());
      await otherDatabase.read((connection) {
        for (final table in [
          'operations',
          'events',
          'outbox',
          'idempotency_keys',
        ]) {
          expect(connection.select('SELECT * FROM $table'), hasLength(1));
        }
      });
    } finally {
      otherDatabase.close();
    }
  });

  test('action failure rolls back operation, events, outbox and key', () async {
    final operations = SqliteOperationRepository(database);
    await expectLater(
      execute(
        run: () async {
          await operations.create(
            type: 'vm.start',
            resourceType: ResourceType.virtualMachine,
            resourceId: VmId('vm_01J00000000000000000000000'),
            requestId: RequestId.generate(),
            cancellable: true,
            request: JsonObjectValue.fromJson({}),
          );
          throw StateError('abort');
        },
      ),
      throwsStateError,
    );
    await database.read((connection) {
      for (final table in [
        'operations',
        'events',
        'outbox',
        'idempotency_keys',
      ]) {
        expect(connection.select('SELECT * FROM $table'), isEmpty);
      }
    });
    expect((await execute()).replayed, isFalse);
  });

  test(
    'caller transaction rollback also removes completed reservation',
    () async {
      await expectLater(
        database.transaction((_) async {
          await execute();
          throw StateError('caller rollback');
        }),
        throwsStateError,
      );
      expect((await execute()).replayed, isFalse);
      expect(calls, 2);
    },
  );

  test('replay lasts until exact expiry, then permits a new request', () async {
    await execute();
    now = now.add(const Duration(hours: 1) - const Duration(microseconds: 1));
    expect((await execute()).replayed, isTrue);
    expect(await repository.cleanupExpired(), 0);
    now = now.add(const Duration(microseconds: 1));
    expect((await execute(requestBody: [1])).replayed, isFalse);
    expect(calls, 2);
  });

  test(
    'cleanup removes expired completed keys but retains unfinished rows',
    () async {
      await execute();
      await database.transaction((connection) {
        connection.execute(
          '''INSERT INTO idempotency_keys
        (scope,key,request_hash,created_at,expires_at) VALUES(?,?,?,?,?)''',
          [
            'pending',
            'retry-key',
            SqliteIdempotencyRepository.requestHash(body),
            '2020-01-01T00:00:00.000000Z',
            '2020-01-01T01:00:00.000000Z',
          ],
        );
      });
      now = now.add(const Duration(hours: 1));
      expect(await repository.cleanupExpired(), 1);
      await expectLater(
        execute(scope: 'pending'),
        throwsA(isA<IdempotencyInProgressException>()),
      );
      expect(calls, 1);
    },
  );

  test(
    'retention starts at completed acceptance and retry never extends it',
    () async {
      await execute(
        run: () async {
          now = now.add(const Duration(minutes: 10));
          return action();
        },
      );
      now = now.add(const Duration(minutes: 59));
      expect((await execute()).replayed, isTrue);
      now = now.add(const Duration(minutes: 1));
      expect(await repository.cleanupExpired(), 1);
    },
  );

  test(
    'validates retention, keys, scope and raw bytes before writing',
    () async {
      expect(
        () => SqliteIdempotencyRepository(database, retention: Duration.zero),
        throwsArgumentError,
      );
      expect(() => execute(scope: ''), throwsArgumentError);
      expect(() => execute(requestBody: [-1]), throwsArgumentError);
      expect(
        () => repository.execute(
          scope: 'x',
          key: 'x' * 256,
          requestBody: [],
          action: action,
        ),
        throwsArgumentError,
      );
      await database.read((connection) {
        expect(connection.select('SELECT * FROM idempotency_keys'), isEmpty);
      });
    },
  );
}
