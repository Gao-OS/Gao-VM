import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'gaovmd-operation-repository-',
    );
    databasePath = '${temporaryDirectory.path}/gaovm.db';
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('create/list/get persist the complete pending operation', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteOperationRepository(
      database,
      newOperationId: () => OperationId('op_01J00000000000000000000000'),
      now: () => DateTime.utc(2026, 9, 4, 9),
    );
    final vmId = VmId('vm_01J00000000000000000000000');

    final operation = await repository.create(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: vmId,
      requestId: RequestId('req_01J00000000000000000000000'),
      idempotencyKey: 'start-primary',
      cancellable: true,
      request: JsonObjectValue.fromJson(const {'force': false}),
      deadlineAt: DateTime.utc(2026, 9, 4, 9, 5),
    );

    expect(operation.id.value, 'op_01J00000000000000000000000');
    expect(operation.state, OperationState.pending);
    expect(operation.resourceId, vmId);
    expect(operation.request.toJson(), {'force': false});
    expect(operation.deadlineAt, DateTime.utc(2026, 9, 4, 9, 5));
    expect(await repository.list(), [operation]);
    expect(await repository.get(operation.id), operation);
    expect(
      await repository.get(OperationId('op_01J00000000000000000000001')),
      isNull,
    );
    database.close();
  });

  test('a pending operation runs and succeeds with its result', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final times = [
      DateTime.utc(2026, 9, 4, 9),
      DateTime.utc(2026, 9, 4, 9, 1),
      DateTime.utc(2026, 9, 4, 9, 2),
    ].iterator;
    final eventIds = [
      EventId('evt_01J00000000000000000000002'),
      EventId('evt_01J00000000000000000000003'),
      EventId('evt_01J00000000000000000000004'),
    ].iterator;
    final repository = SqliteOperationRepository(
      database,
      newOperationId: () => OperationId('op_01J00000000000000000000002'),
      newEventId: () {
        eventIds.moveNext();
        return eventIds.current;
      },
      now: () {
        times.moveNext();
        return times.current;
      },
    );
    await database.transaction(
      (connection) => connection.execute(
        '''
          INSERT INTO vms(
            id, name, labels_json, revision, spec_generation,
            created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          'vm_01J00000000000000000000000',
          'primary',
          '{}',
          1,
          1,
          '2026-09-04T09:00:00.000000Z',
          '2026-09-04T09:00:00.000000Z',
        ],
      ),
    );
    final created = await repository.create(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: VmId('vm_01J00000000000000000000000'),
      requestId: RequestId('req_01J00000000000000000000000'),
      cancellable: true,
      request: JsonObjectValue.empty,
    );

    final running = await repository.start(
      created.id,
      progress: OperationProgress(percent: 20, step: 'driver'),
    );
    expect(running.state, OperationState.running);
    expect(running.startedAt, DateTime.utc(2026, 9, 4, 9, 1));
    expect(running.progress, OperationProgress(percent: 20, step: 'driver'));

    final succeeded = await repository.succeed(
      created.id,
      result: JsonObjectValue.fromJson(const {'phase': 'running'}),
    );
    expect(succeeded.state, OperationState.succeeded);
    expect(succeeded.cancellable, isFalse);
    expect(succeeded.result?.toJson(), {'phase': 'running'});
    expect(succeeded.error, isNull);
    expect(succeeded.completedAt, DateTime.utc(2026, 9, 4, 9, 2));
    expect(await repository.get(created.id), succeeded);
    final eventRepository = SqliteEventRepository(database);
    final completionEvents = await eventRepository.list(
      operationId: created.id,
    );
    expect(completionEvents.map((event) => event.type), [
      'operation.created',
      'operation.started',
      'operation.completed',
    ]);
    final completion = completionEvents.last;
    expect(completion.resourceType, ResourceType.operation);
    expect(completion.resourceId, created.id);
    expect(completion.vmId, created.resourceId);
    expect(completion.payload.toJson(), {
      'state': 'succeeded',
      'cancellable': false,
      'progress': {'percent': 20, 'step': 'driver'},
      'result': {'phase': 'running'},
      'error': null,
    });
    expect(await eventRepository.readUnpublishedOutbox(), hasLength(3));
    database.close();
  });

  test('a running operation fails with its structured error', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteOperationRepository(
      database,
      newOperationId: () => OperationId('op_01J00000000000000000000003'),
      now: () => DateTime.utc(2026, 9, 4, 9),
    );
    final created = await repository.create(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: VmId('vm_01J00000000000000000000000'),
      requestId: RequestId('req_01J00000000000000000000000'),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    await repository.start(created.id);
    final failure = OperationError(
      code: ErrorCode.driverStartFailed,
      message: 'driver exited',
      retryable: true,
      details: JsonObjectValue.fromJson(const {'exit_code': 1}),
    );

    final failed = await repository.fail(created.id, error: failure);

    expect(failed.state, OperationState.failed);
    expect(failed.cancellable, isFalse);
    expect(failed.result, isNull);
    expect(failed.error, failure);
    expect(failed.completedAt, DateTime.utc(2026, 9, 4, 9));
    database.close();
  });

  test('cancel enforces and persists the current cancellability', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteOperationRepository(
      database,
      newOperationId: () => OperationId('op_01J00000000000000000000004'),
      now: () => DateTime.utc(2026, 9, 4, 9),
    );
    final created = await repository.create(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: VmId('vm_01J00000000000000000000000'),
      requestId: RequestId('req_01J00000000000000000000000'),
      cancellable: false,
      request: JsonObjectValue.empty,
    );
    await repository.start(created.id);

    await expectLater(
      () => repository.cancel(created.id),
      throwsA(isA<OperationNotCancellableException>()),
    );
    final cancellable = await repository.setCancellable(
      created.id,
      cancellable: true,
    );
    expect(cancellable.cancellable, isTrue);

    final cancelled = await repository.cancel(created.id);
    expect(cancelled.state, OperationState.cancelled);
    expect(cancelled.cancellable, isFalse);
    expect(cancelled.completedAt, DateTime.utc(2026, 9, 4, 9));
    final events = SqliteEventRepository(database);
    expect(
      (await events.list(operationId: created.id)).map((event) => event.type),
      [
        'operation.created',
        'operation.started',
        'operation.updated',
        'operation.completed',
      ],
    );
    expect(await events.readUnpublishedOutbox(), hasLength(4));
    database.close();
  });

  test('transition matrix rejects skipped and terminal mutations', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final repository = SqliteOperationRepository(
      database,
      newOperationId: () => OperationId('op_01J00000000000000000000005'),
      now: () => DateTime.utc(2026, 9, 4, 9),
    );
    final pending = await repository.create(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: VmId('vm_01J00000000000000000000000'),
      requestId: RequestId('req_01J00000000000000000000000'),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    final error = OperationError(
      code: ErrorCode.driverStartFailed,
      message: 'failed',
      retryable: false,
      details: JsonObjectValue.empty,
    );

    await expectLater(
      () => repository.succeed(pending.id),
      throwsA(isA<InvalidOperationTransitionException>()),
    );
    await expectLater(
      () => repository.fail(pending.id, error: error),
      throwsA(isA<InvalidOperationTransitionException>()),
    );
    final terminal = await repository.cancel(pending.id);

    for (final mutation in <Future<Operation> Function()>[
      () => repository.start(pending.id),
      () => repository.succeed(pending.id),
      () => repository.fail(pending.id, error: error),
      () => repository.cancel(pending.id),
      () => repository.setCancellable(pending.id, cancellable: false),
    ]) {
      await expectLater(
        mutation,
        throwsA(isA<InvalidOperationTransitionException>()),
      );
    }
    expect(await repository.get(pending.id), terminal);
    final events = SqliteEventRepository(database);
    expect(
      (await events.list(operationId: pending.id)).map((event) => event.type),
      ['operation.created', 'operation.completed'],
    );
    expect(await events.readUnpublishedOutbox(), hasLength(2));
    database.close();
  });

  test(
    'create and its durable event roll back with an outer transaction',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final operationId = OperationId('op_01J00000000000000000000013');
      final repository = SqliteOperationRepository(
        database,
        newOperationId: () => operationId,
        now: () => DateTime.utc(2026, 9, 4, 9),
      );

      await expectLater(
        () => database.transaction((_) async {
          await repository.create(
            type: 'vm.start',
            resourceType: ResourceType.virtualMachine,
            resourceId: VmId('vm_01J00000000000000000000000'),
            requestId: RequestId('req_01J00000000000000000000000'),
            cancellable: true,
            request: JsonObjectValue.empty,
          );
          throw StateError('roll back the application unit of work');
        }),
        throwsStateError,
      );

      expect(await repository.get(operationId), isNull);
      final events = SqliteEventRepository(database);
      expect(await events.list(operationId: operationId), isEmpty);
      expect(await events.readUnpublishedOutbox(), isEmpty);
      database.close();
    },
  );

  test(
    'outer rollback removes operation completion, event, and outbox together',
    () async {
      final database = await GaoVmDatabase.open(databasePath);
      final repository = SqliteOperationRepository(
        database,
        newOperationId: () => OperationId('op_01J00000000000000000000006'),
        now: () => DateTime.utc(2026, 9, 4, 9),
      );
      final created = await repository.create(
        type: 'vm.start',
        resourceType: ResourceType.virtualMachine,
        resourceId: VmId('vm_01J00000000000000000000000'),
        requestId: RequestId('req_01J00000000000000000000000'),
        cancellable: true,
        request: JsonObjectValue.empty,
      );
      final running = await repository.start(created.id);
      final events = SqliteEventRepository(database);
      final beforeEvents = await events.list(operationId: created.id);
      final beforeOutbox = await events.readUnpublishedOutbox();

      await expectLater(
        () => database.transaction((_) async {
          await repository.succeed(created.id);
          throw StateError('roll back the application unit of work');
        }),
        throwsStateError,
      );

      expect(await repository.get(created.id), running);
      expect(await events.list(operationId: created.id), beforeEvents);
      expect(
        (await events.readUnpublishedOutbox()).map((record) => record.key),
        beforeOutbox.map((record) => record.key),
      );
      database.close();
    },
  );

  test('operation, completion event, and outbox survive reopen', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final eventIds = [
      EventId('evt_01J00000000000000000000007'),
      EventId('evt_01J00000000000000000000008'),
      EventId('evt_01J00000000000000000000009'),
    ].iterator;
    final repository = SqliteOperationRepository(
      database,
      newOperationId: () => OperationId('op_01J00000000000000000000007'),
      newEventId: () {
        eventIds.moveNext();
        return eventIds.current;
      },
      now: () => DateTime.utc(2026, 9, 4, 9),
    );
    final created = await repository.create(
      type: 'vm.stop',
      resourceType: ResourceType.virtualMachine,
      resourceId: VmId('vm_01J00000000000000000000000'),
      requestId: RequestId('req_01J00000000000000000000000'),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    await repository.start(created.id);
    final completed = await repository.succeed(created.id);
    database.close();

    final reopened = await GaoVmDatabase.open(databasePath);
    expect(
      await SqliteOperationRepository(reopened).get(created.id),
      completed,
    );
    final events = SqliteEventRepository(reopened);
    expect(await events.list(operationId: created.id), hasLength(3));
    expect(await events.readUnpublishedOutbox(), hasLength(3));
    reopened.close();
  });

  test('list filters operations with stable creation ordering', () async {
    final database = await GaoVmDatabase.open(databasePath);
    final ids = [
      OperationId('op_01J00000000000000000000010'),
      OperationId('op_01J00000000000000000000011'),
      OperationId('op_01J00000000000000000000012'),
    ].iterator;
    final repository = SqliteOperationRepository(
      database,
      newOperationId: () {
        ids.moveNext();
        return ids.current;
      },
      now: () => DateTime.utc(2026, 9, 4, 9),
    );
    final vmId = VmId('vm_01J00000000000000000000000');
    final first = await repository.create(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: vmId,
      requestId: RequestId('req_01J00000000000000000000000'),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    final second = await repository.create(
      type: 'vm.stop',
      resourceType: ResourceType.virtualMachine,
      resourceId: vmId,
      requestId: RequestId('req_01J00000000000000000000001'),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    final image = await repository.create(
      type: 'image.import',
      resourceType: ResourceType.image,
      resourceId: ImageId('img_01J00000000000000000000000'),
      requestId: RequestId('req_01J00000000000000000000002'),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    final running = await repository.start(second.id);

    expect(await repository.list(resourceType: ResourceType.virtualMachine), [
      first,
      running,
    ]);
    expect(await repository.list(resourceId: vmId), [first, running]);
    expect(await repository.list(state: OperationState.running), [running]);
    expect(await repository.list(resourceType: ResourceType.image), [image]);
    database.close();
  });
}
