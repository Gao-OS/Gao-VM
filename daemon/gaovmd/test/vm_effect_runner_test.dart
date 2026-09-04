import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late GaoVmDatabase database;
  late SqliteOperationRepository operations;
  late SqliteEventRepository events;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'gaovmd-vm-effect-runner-',
    );
    database = await GaoVmDatabase.open('${temporaryDirectory.path}/gaovm.db');
    await database.transaction(
      (connection) => connection.execute(
        '''
          INSERT INTO vms(
            id, name, labels_json, revision, spec_generation,
            created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          _vmId.value,
          'primary',
          '{}',
          1,
          1,
          '2026-09-04T09:00:00.000000Z',
          '2026-09-04T09:00:00.000000Z',
        ],
      ),
    );
    operations = SqliteOperationRepository(
      database,
      newOperationId: () => _recoveryOperationId,
      now: () => DateTime.utc(2026, 9, 4, 9),
    );
    events = SqliteEventRepository(database);
  });

  tearDown(() async {
    database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'recovery creation is durable and returns a correlated command',
    () async {
      final runner = _runner(database, operations, events);
      final state = _state().copyWith(
        desiredState: DesiredState.running,
        driverGeneration: 4,
        pendingRecoveryGeneration: 4,
        pendingRecoveryError: _driverError,
        retryState: VmRetryState(
          attempts: 1,
          scheduledDelay: const Duration(seconds: 1),
        ),
      );

      final command = await runner.run(
        CreateRecoveryOperation(
          vmId: _vmId,
          operationId: null,
          driverGeneration: 4,
          error: _driverError,
        ),
        state,
      );

      expect(
        command,
        isA<RecoveryOperationCreated>()
            .having(
              (value) => value.operationId,
              'operationId',
              _recoveryOperationId,
            )
            .having((value) => value.failedDriverGeneration, 'generation', 4),
      );
      final operation = await operations.get(_recoveryOperationId);
      expect(operation?.type, 'vm.recovery');
      expect(operation?.state, OperationState.running);
      expect(operation?.resourceId, _vmId);
      expect(operation?.request.toJson(), {
        'error': _driverError.toJson(),
        'failed_driver_generation': 4,
      });
    },
  );

  test('operation and event effects use committed repositories', () async {
    final operation = await operations.create(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: _vmId,
      requestId: _requestId,
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    await operations.start(operation.id);
    final runner = _runner(database, operations, events);

    await runner.run(
      EmitEvent(
        vmId: _vmId,
        operationId: operation.id,
        type: 'vm.test_event',
        payload: JsonObjectValue.fromJson(const {'value': 1}),
      ),
      _state(),
    );
    await runner.run(
      FailOperation(
        vmId: _vmId,
        operationId: operation.id,
        error: _driverError,
      ),
      _state(),
    );

    expect((await operations.get(operation.id))?.state, OperationState.failed);
    final durableEvents = await events.list(vmId: _vmId);
    expect(
      durableEvents.where((event) => event.type == 'vm.test_event'),
      hasLength(1),
    );
  });

  test('adapter successes return every correlated lifecycle command', () async {
    final runner = _runner(database, operations, events);
    final state = _state();
    final effects = <VmEffect>[
      AcquireHostLease(vmId: _vmId, operationId: _recoveryOperationId),
      ReleaseHostLease(vmId: _vmId, operationId: null),
      MarkHostLeaseRunning(
        vmId: _vmId,
        operationId: _recoveryOperationId,
        driverGeneration: 3,
      ),
      SpawnDriver(
        vmId: _vmId,
        operationId: _recoveryOperationId,
        driverGeneration: 3,
      ),
      ConnectDriver(
        vmId: _vmId,
        operationId: _recoveryOperationId,
        driverGeneration: 3,
      ),
      ConfigureRuntime(
        vmId: _vmId,
        operationId: _recoveryOperationId,
        driverGeneration: 3,
      ),
      StartRuntime(
        vmId: _vmId,
        operationId: _recoveryOperationId,
        driverGeneration: 3,
      ),
      StopRuntime(
        vmId: _vmId,
        operationId: _recoveryOperationId,
        driverGeneration: 3,
      ),
      KillDriver(
        vmId: _vmId,
        operationId: _recoveryOperationId,
        driverGeneration: 3,
      ),
      RemoveManagedFiles(vmId: _vmId, operationId: _recoveryOperationId),
    ];

    final commands = <VmCommand?>[];
    for (final effect in effects) {
      commands.add(await runner.run(effect, state));
    }

    expect(commands[0], isA<HostLeaseAcquired>());
    expect(commands[1], isA<HostLeaseReleased>());
    expect(commands[2], isNull);
    expect(commands[3], isA<DriverSpawned>());
    expect(commands[4], isA<DriverHandshakeCompleted>());
    expect(commands.sublist(5, 9), everyElement(isA<DriverCommandSucceeded>()));
    expect(commands[9], isA<ManagedFilesRemoved>());
  });

  test(
    'recovery repository failures re-enter and fail reconciliation',
    () async {
      await operations.create(
        type: 'vm.existing',
        resourceType: ResourceType.virtualMachine,
        resourceId: _vmId,
        requestId: _requestId,
        cancellable: false,
        request: JsonObjectValue.empty,
      );
      final controller = VmController(
        initialState: _state().copyWith(
          desiredState: DesiredState.running,
          phase: VmPhase.running,
        ),
        effectRunner: _runner(database, operations, events),
      );

      await controller.submit(const ReconcileRequested());
      await controller.waitUntilIdle();

      expect(controller.state.desiredState, DesiredState.stopped);
      expect(controller.state.phase, VmPhase.failed);
      expect(controller.state.pendingRecoveryGeneration, isNull);
      expect(controller.state.lastError?.code, ErrorCode.internalError);
      await controller.shutdown();
    },
  );

  test('durable effect batch rolls back every repository write', () async {
    final operation = await operations.create(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: _vmId,
      requestId: _requestId,
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    await operations.start(operation.id);
    await operations.succeed(operation.id);
    final runner = _runner(database, operations, events);

    await expectLater(
      runner.runDurableBatch([
        EmitEvent(
          vmId: _vmId,
          operationId: operation.id,
          type: 'vm.rollback_probe',
        ),
        FailOperation(
          vmId: _vmId,
          operationId: operation.id,
          error: _driverError,
        ),
      ], _state()),
      throwsA(isA<VmEffectBatchException>()),
    );

    expect(
      (await events.list(
        vmId: _vmId,
      )).where((event) => event.type == 'vm.rollback_probe'),
      isEmpty,
    );
    expect(
      (await operations.get(operation.id))?.state,
      OperationState.succeeded,
    );
  });

  test('recovery create and start roll back as one transaction', () async {
    final failing = _FailingStartOperationRepository(operations);
    final runner = _runner(database, failing, events);

    await expectLater(
      runner.run(
        CreateRecoveryOperation(
          vmId: _vmId,
          operationId: null,
          driverGeneration: 7,
          error: _driverError,
        ),
        _state(),
      ),
      throwsA(isA<VmEffectBatchException>()),
    );

    expect(
      (await operations.list()).where(
        (operation) => operation.type == 'vm.recovery',
      ),
      isEmpty,
    );
  });
}

RepositoryVmEffectRunner _runner(
  GaoVmDatabase database,
  OperationRepository operations,
  EventRepository events,
) => RepositoryVmEffectRunner(
  database: database,
  operations: operations,
  events: events,
  persistence: _NoopPersistence(),
  leases: _NoopLeases(),
  drivers: _NoopDrivers(),
  managedFiles: _NoopManagedFiles(),
  newRequestId: () => _requestId,
);

final class _NoopPersistence implements VmStateEffectAdapter {
  @override
  Future<void> persistRuntime(VmControllerState state) async {}

  @override
  Future<void> persistVm(VmControllerState state) async {}
}

final class _NoopLeases implements VmLeaseEffectAdapter {
  @override
  Future<void> acquire(
    VmControllerState state,
    OperationId operationId,
  ) async {}

  @override
  Future<void> markRunning(
    VmControllerState state,
    OperationId operationId,
  ) async {}

  @override
  Future<void> release(
    VmControllerState state,
    OperationId? operationId,
  ) async {}
}

final class _NoopDrivers implements VmDriverEffectAdapter {
  @override
  Future<void> configure(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}

  @override
  Future<void> connect(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}

  @override
  Future<void> kill(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}

  @override
  Future<void> spawn(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}

  @override
  Future<void> start(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}

  @override
  Future<void> stop(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}
}

final class _NoopManagedFiles implements VmManagedFileEffectAdapter {
  @override
  Future<void> remove(VmControllerState state, OperationId operationId) async {}
}

final class _FailingStartOperationRepository implements OperationRepository {
  const _FailingStartOperationRepository(this.delegate);

  final OperationRepository delegate;

  @override
  Future<Operation> create({
    required String type,
    required ResourceType resourceType,
    required ResourceId resourceId,
    required RequestId requestId,
    String? idempotencyKey,
    required bool cancellable,
    required JsonObjectValue request,
    DateTime? deadlineAt,
  }) => delegate.create(
    type: type,
    resourceType: resourceType,
    resourceId: resourceId,
    requestId: requestId,
    idempotencyKey: idempotencyKey,
    cancellable: cancellable,
    request: request,
    deadlineAt: deadlineAt,
  );

  @override
  Future<Operation> createAndStart({
    required String type,
    required ResourceType resourceType,
    required ResourceId resourceId,
    required RequestId requestId,
    String? idempotencyKey,
    required bool cancellable,
    required JsonObjectValue request,
    DateTime? deadlineAt,
  }) async {
    final operation = await create(
      type: type,
      resourceType: resourceType,
      resourceId: resourceId,
      requestId: requestId,
      idempotencyKey: idempotencyKey,
      cancellable: cancellable,
      request: request,
      deadlineAt: deadlineAt,
    );
    return start(operation.id);
  }

  @override
  Future<Operation> start(OperationId id, {OperationProgress? progress}) =>
      Future.error(StateError('start failed'));

  @override
  Future<Operation?> get(OperationId id) => delegate.get(id);

  @override
  Future<List<Operation>> list({
    ResourceType? resourceType,
    ResourceId? resourceId,
    OperationState? state,
  }) => delegate.list(
    resourceType: resourceType,
    resourceId: resourceId,
    state: state,
  );

  @override
  Future<Operation> succeed(OperationId id, {JsonObjectValue? result}) =>
      delegate.succeed(id, result: result);

  @override
  Future<Operation> fail(OperationId id, {required OperationError error}) =>
      delegate.fail(id, error: error);

  @override
  Future<Operation> cancel(OperationId id) => delegate.cancel(id);

  @override
  Future<Operation> setCancellable(
    OperationId id, {
    required bool cancellable,
  }) => delegate.setCancellable(id, cancellable: cancellable);
}

VmControllerState _state() => VmControllerState.initial(
  vmId: _vmId,
  specGeneration: 1,
  restartPolicy: RestartPolicy.onFailure,
);

final _vmId = VmId('vm_01J00000000000000000000000');
final _recoveryOperationId = OperationId('op_01J00000000000000000000000');
final _requestId = RequestId('req_01J00000000000000000000000');
final _driverError = OperationError(
  code: ErrorCode.driverUnhealthy,
  message: 'driver failed',
  retryable: true,
  details: JsonObjectValue.empty,
);
