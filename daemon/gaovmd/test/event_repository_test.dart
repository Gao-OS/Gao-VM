import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'gaovmd-event-repository-',
    );
    databasePath = '${temporaryDirectory.path}/gaovm.db';
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'event delivery cannot claim or acknowledge command outbox rows',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteEventRepository(database);
      await database.transaction((connection) {
        connection.execute(
          '''INSERT INTO outbox(topic, key, payload_json, created_at,
        claimed_by, claim_expires_at) VALUES (?, ?, ?, ?, ?, ?)''',
          [
            'vm.commands',
            'command',
            '{}',
            '2026-01-01T00:00:00.000000Z',
            'worker',
            '2099-01-01T00:00:00.000000Z',
          ],
        );
      });
      expect(await repository.readUnpublishedOutbox(), isEmpty);
      expect(
        await repository.claimOutbox(
          owner: 'worker',
          lease: const Duration(seconds: 30),
        ),
        isEmpty,
      );
      expect(await repository.markOutboxPublished(1, owner: 'worker'), isFalse);
      expect(await repository.releaseOutbox(1, owner: 'worker'), isFalse);
    },
  );

  test('append persists an event and one unpublished outbox record', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteEventRepository(
      database,
      newEventId: () => EventId('evt_01J00000000000000000000000'),
      now: () => DateTime.utc(2026, 9, 4, 9),
    );

    final event = await repository.append(
      type: 'daemon.started',
      resourceType: ResourceType.system,
      payload: JsonObjectValue.fromJson(const {'version': '2'}),
    );

    expect(event.sequence, 1);
    expect(event.eventId.value, 'evt_01J00000000000000000000000');
    expect(await repository.get(event.eventId), event);
    expect(await repository.list(), [event]);
    final records = await repository.readUnpublishedOutbox();
    expect(records, hasLength(1));
    expect(records.single.topic, durableEventOutboxTopic);
    expect(records.single.key, event.eventId.value);
    expect(records.single.payload.toJson(), event.toJson());
    expect(records.single.publishedAt, isNull);
    expect(records.single.attempts, 0);
    database.close();
  });

  test(
    'cursor and resource correlation filters preserve sequence order',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final vmId = VmId('vm_01J00000000000000000000001');
      final operationId = OperationId('op_01J00000000000000000000001');
      final testRunId = TestRunId('tr_01J00000000000000000000001');
      await database.transaction((connection) {
        connection.execute(
          '''
          INSERT INTO vms(
            id, name, labels_json, revision, spec_generation,
            created_at, updated_at
          ) VALUES (?, ?, '{}', 1, 1, ?, ?)
        ''',
          [
            vmId.value,
            'primary',
            '2026-09-04T09:00:00.000000Z',
            '2026-09-04T09:00:00.000000Z',
          ],
        );
        connection.execute(
          '''
          INSERT INTO operations(
            id, type, resource_type, resource_id, state, request_id,
            cancellable, progress_json, request_json, created_at
          ) VALUES (?, 'test.run', 'test_run', ?, 'running', ?, 1, '{}',
                    '{}', ?)
        ''',
          [
            operationId.value,
            testRunId.value,
            'req_01J00000000000000000000001',
            '2026-09-04T09:00:00.000000Z',
          ],
        );
        connection.execute(
          '''
          INSERT INTO test_runs(
            id, state, spec_json, vm_id, operation_id,
            artifact_ids_json, created_at
          ) VALUES (?, 'running_steps', '{}', ?, ?, '[]', ?)
        ''',
          [
            testRunId.value,
            vmId.value,
            operationId.value,
            '2026-09-04T09:00:00.000000Z',
          ],
        );
      });
      final eventIds = [
        EventId('evt_01J00000000000000000000001'),
        EventId('evt_01J00000000000000000000002'),
        EventId('evt_01J00000000000000000000003'),
        EventId('evt_01J00000000000000000000004'),
      ].iterator;
      final repository = SqliteEventRepository(
        database,
        newEventId: () {
          eventIds.moveNext();
          return eventIds.current;
        },
        now: () => DateTime.utc(2026, 9, 4, 9),
      );

      final system = await repository.append(
        type: 'daemon.started',
        resourceType: ResourceType.system,
        payload: JsonObjectValue.empty,
      );
      final vm = await repository.append(
        type: 'vm.defined',
        resourceType: ResourceType.virtualMachine,
        resourceId: vmId,
        vmId: vmId,
        payload: JsonObjectValue.empty,
      );
      final operation = await repository.append(
        type: 'operation.observed',
        resourceType: ResourceType.operation,
        resourceId: operationId,
        vmId: vmId,
        operationId: operationId,
        payload: JsonObjectValue.empty,
      );
      final testRun = await repository.append(
        type: 'test_run.started',
        resourceType: ResourceType.testRun,
        resourceId: testRunId,
        vmId: vmId,
        operationId: operationId,
        testRunId: testRunId,
        payload: JsonObjectValue.empty,
      );

      expect(await repository.list(), [system, vm, operation, testRun]);
      expect(await repository.list(after: vm.sequence), [operation, testRun]);
      expect(await repository.list(resourceId: operationId), [operation]);
      expect(await repository.list(vmId: vmId), [vm, operation, testRun]);
      expect(await repository.list(operationId: operationId), [
        operation,
        testRun,
      ]);
      expect(await repository.list(testRunId: testRunId), [testRun]);
      database.close();
    },
  );

  test('only the active claim owner can publish an outbox record', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteEventRepository(
      database,
      newEventId: () => EventId('evt_01J00000000000000000000005'),
      now: () => DateTime.utc(2026, 9, 4, 9),
    );
    await repository.append(
      type: 'daemon.started',
      resourceType: ResourceType.system,
      payload: JsonObjectValue.empty,
    );
    final record = (await repository.claimOutbox(
      owner: 'dispatcher-a',
      lease: const Duration(minutes: 1),
    )).single;

    expect(record.claimedBy, 'dispatcher-a');
    expect(record.claimExpiresAt, DateTime.utc(2026, 9, 4, 9, 1));
    expect(
      await repository.markOutboxPublished(record.id, owner: 'dispatcher-b'),
      isFalse,
    );
    expect(
      await repository.markOutboxPublished(record.id, owner: 'dispatcher-a'),
      isTrue,
    );
    expect(
      await repository.markOutboxPublished(record.id, owner: 'dispatcher-a'),
      isFalse,
    );
    expect(await repository.readUnpublishedOutbox(), isEmpty);
    database.close();

    final reopened = await GaoVmDatabase.open(databasePath);
    expect(
      await SqliteEventRepository(reopened).readUnpublishedOutbox(),
      isEmpty,
    );
    reopened.close();
  });

  test(
    'released failures increment attempts and are reclaimed first',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final eventIds = [
        EventId('evt_01J00000000000000000000030'),
        EventId('evt_01J00000000000000000000031'),
        EventId('evt_01J00000000000000000000032'),
      ].iterator;
      final repository = SqliteEventRepository(
        database,
        newEventId: () {
          eventIds.moveNext();
          return eventIds.current;
        },
        now: () => DateTime.utc(2026, 9, 4, 9),
      );
      for (var index = 0; index < 3; index++) {
        await repository.append(
          type: 'daemon.heartbeat',
          resourceType: ResourceType.system,
          payload: JsonObjectValue.fromJson({'index': index}),
        );
      }
      final firstClaim = await repository.claimOutbox(
        owner: 'dispatcher-a',
        lease: const Duration(minutes: 1),
        limit: 2,
      );

      expect(
        await repository.releaseOutbox(
          firstClaim.first.id,
          owner: 'dispatcher-b',
        ),
        isFalse,
      );
      expect(
        await repository.releaseOutbox(
          firstClaim.last.id,
          owner: 'dispatcher-a',
        ),
        isTrue,
      );
      final retryClaim = await repository.claimOutbox(
        owner: 'dispatcher-b',
        lease: const Duration(minutes: 1),
        limit: 2,
      );

      expect(retryClaim.map((record) => record.id), [
        firstClaim.last.id,
        firstClaim.last.id + 1,
      ]);
      expect(retryClaim.first.attempts, 1);
      expect(retryClaim.last.attempts, 0);
      database.close();
    },
  );

  test('concurrent outbox claims are mutually exclusive', () async {
    final firstDatabase = await GaoVmDatabase.open(databasePath);
    final first = SqliteEventRepository(firstDatabase);
    for (var index = 0; index < 6; index++) {
      await first.append(
        type: 'daemon.heartbeat',
        resourceType: ResourceType.system,
        payload: JsonObjectValue.fromJson({'index': index}),
      );
    }
    final secondDatabase = await GaoVmDatabase.open(databasePath);
    final second = SqliteEventRepository(secondDatabase);

    final claims = await Future.wait([
      first.claimOutbox(
        owner: 'dispatcher-a',
        lease: const Duration(minutes: 1),
        limit: 4,
      ),
      second.claimOutbox(
        owner: 'dispatcher-b',
        lease: const Duration(minutes: 1),
        limit: 4,
      ),
    ]);

    final firstIds = claims.first.map((record) => record.id).toSet();
    final secondIds = claims.last.map((record) => record.id).toSet();
    expect(firstIds.intersection(secondIds), isEmpty);
    expect({...firstIds, ...secondIds}, hasLength(6));
    expect(
      claims.first.every((record) => record.claimedBy == 'dispatcher-a'),
      isTrue,
    );
    expect(
      claims.last.every((record) => record.claimedBy == 'dispatcher-b'),
      isTrue,
    );
    secondDatabase.close();
    firstDatabase.close();
  });

  test('expired claims are reclaimable and count as failed attempts', () async {
    final database = await GaoVmDatabase.open(databasePath);
    var currentTime = DateTime.utc(2026, 9, 4, 9);
    final repository = SqliteEventRepository(database, now: () => currentTime);
    await repository.append(
      type: 'daemon.started',
      resourceType: ResourceType.system,
      payload: JsonObjectValue.empty,
    );
    final first = (await repository.claimOutbox(
      owner: 'dispatcher-a',
      lease: const Duration(minutes: 1),
    )).single;

    currentTime = DateTime.utc(2026, 9, 4, 9, 0, 30);
    expect(
      await repository.claimOutbox(
        owner: 'dispatcher-b',
        lease: const Duration(minutes: 1),
      ),
      isEmpty,
    );
    currentTime = DateTime.utc(2026, 9, 4, 9, 1);
    final reclaimed = (await repository.claimOutbox(
      owner: 'dispatcher-b',
      lease: const Duration(minutes: 1),
    )).single;

    expect(reclaimed.id, first.id);
    expect(reclaimed.claimedBy, 'dispatcher-b');
    expect(reclaimed.attempts, 1);
    database.close();
  });

  test(
    'concurrent connections allocate unique strictly increasing sequences',
    () async {
      final databases = <GaoVmDatabase>[];
      for (var index = 0; index < 4; index++) {
        databases.add(await GaoVmDatabase.open(databasePath));
      }
      var nextId = 0;
      final repositories = [
        for (final database in databases)
          SqliteEventRepository(
            database,
            newEventId: () => EventId(
              'evt_01J0000000000000${(nextId++).toString().padLeft(10, '0')}',
            ),
            now: () => DateTime.utc(2026, 9, 4, 9),
          ),
      ];

      await Future.wait([
        for (var index = 0; index < 32; index++)
          repositories[index % repositories.length].append(
            type: 'daemon.heartbeat',
            resourceType: ResourceType.system,
            payload: JsonObjectValue.fromJson({'index': index}),
          ),
      ]);

      final events = await repositories.first.list();
      expect(events, hasLength(32));
      expect(events.map((event) => event.sequence), [
        for (var sequence = 1; sequence <= 32; sequence++) sequence,
      ]);
      expect(events.map((event) => event.eventId.value).toSet(), hasLength(32));
      expect(
        await repositories.first.readUnpublishedOutbox(limit: 1000),
        hasLength(32),
      );
      for (final database in databases) {
        database.close();
      }
    },
  );

  test('append joins and rolls back with an outer transaction', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteEventRepository(
      database,
      newEventId: () => EventId('evt_01J00000000000000000000006'),
      now: () => DateTime.utc(2026, 9, 4, 9),
    );

    await expectLater(
      () => database.transaction((_) async {
        await repository.append(
          type: 'daemon.started',
          resourceType: ResourceType.system,
          payload: JsonObjectValue.empty,
        );
        throw StateError('roll back the application unit of work');
      }),
      throwsStateError,
    );

    expect(await repository.list(), isEmpty);
    expect(await repository.readUnpublishedOutbox(), isEmpty);
    database.close();
  });

  test(
    'outbox collision rolls back the nested event while outer work continues',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final eventId = EventId('evt_01J00000000000000000000007');
      final repository = SqliteEventRepository(
        database,
        newEventId: () => eventId,
        now: () => DateTime.utc(2026, 9, 4, 9),
      );
      await database.transaction((connection) {
        connection.execute(
          'CREATE UNIQUE INDEX collision_probe ON outbox(topic, key)',
        );
        connection.execute(
          '''
            INSERT INTO outbox(topic, key, payload_json, created_at)
            VALUES (?, ?, '{}', ?)
          ''',
          [
            durableEventOutboxTopic,
            eventId.value,
            '2026-09-04T09:00:00.000000Z',
          ],
        );
        connection.execute('CREATE TABLE outer_probe(value TEXT NOT NULL)');
      });

      var collisionCaught = false;
      await database.transaction((connection) async {
        connection.execute('INSERT INTO outer_probe(value) VALUES (?)', [
          'before',
        ]);
        try {
          await repository.append(
            type: 'daemon.started',
            resourceType: ResourceType.system,
            payload: JsonObjectValue.empty,
          );
        } on SqliteException {
          collisionCaught = true;
        }
        connection.execute('INSERT INTO outer_probe(value) VALUES (?)', [
          'after',
        ]);
      });

      expect(collisionCaught, isTrue);
      expect(await repository.get(eventId), isNull);
      expect(
        await database.read(
          (connection) => connection
              .select('SELECT value FROM outer_probe ORDER BY rowid')
              .map((row) => row['value'])
              .toList(),
        ),
        ['before', 'after'],
      );
      database.close();
    },
  );

  test('resource events require matching typed correlation IDs', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteEventRepository(database);
    final vmId = VmId('vm_01J00000000000000000000020');
    final operationId = OperationId('op_01J00000000000000000000020');
    final otherOperationId = OperationId('op_01J00000000000000000000021');
    final testRunId = TestRunId('tr_01J00000000000000000000020');

    for (final append in <Future<Event> Function()>[
      () => repository.append(
        type: 'vm.observed',
        resourceType: ResourceType.virtualMachine,
        resourceId: vmId,
        payload: JsonObjectValue.empty,
      ),
      () => repository.append(
        type: 'operation.observed',
        resourceType: ResourceType.operation,
        resourceId: operationId,
        operationId: otherOperationId,
        payload: JsonObjectValue.empty,
      ),
      () => repository.append(
        type: 'test_run.observed',
        resourceType: ResourceType.testRun,
        resourceId: testRunId,
        payload: JsonObjectValue.empty,
      ),
    ]) {
      await expectLater(append, throwsArgumentError);
    }

    expect(await repository.list(), isEmpty);
    expect(await repository.readUnpublishedOutbox(), isEmpty);
    database.close();
  });

  test(
    'public event append cannot duplicate operation lifecycle events',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final operations = SqliteOperationRepository(
        database,
        newOperationId: () => OperationId('op_01J00000000000000000000022'),
        now: () => DateTime.utc(2026, 9, 4, 9),
      );
      final operation = await operations.create(
        type: 'vm.start',
        resourceType: ResourceType.virtualMachine,
        resourceId: VmId('vm_01J00000000000000000000022'),
        requestId: RequestId('req_01J00000000000000000000022'),
        cancellable: true,
        request: JsonObjectValue.empty,
      );
      final EventRepository events = SqliteEventRepository(database);

      for (final type in const [
        'operation.created',
        'operation.started',
        'operation.updated',
        'operation.completed',
      ]) {
        await expectLater(
          () => events.append(
            type: type,
            resourceType: ResourceType.operation,
            resourceId: operation.id,
            operationId: operation.id,
            payload: JsonObjectValue.fromJson(const {'state': 'contradictory'}),
          ),
          throwsArgumentError,
        );
      }

      expect(
        (await events.list(
          operationId: operation.id,
        )).map((event) => event.type),
        ['operation.created'],
      );
      database.close();
    },
  );
}
