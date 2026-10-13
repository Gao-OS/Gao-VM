import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late VmController controller;
  late RepositoryVmEffectRunner runner;
  late _DriverBoundary driver;
  late SqliteOperationRepository operations;
  late SqliteVmCommandRepository commands;
  var controllerReady = false;

  setUp(() async {
    controllerReady = false;
    driver = _DriverBoundary();
    directory = await Directory.systemTemp.createTemp('vm-display-execution-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    final vm = await SqliteVmRepository(
      database,
    ).create(name: 'display', spec: _spec);
    operations = SqliteOperationRepository(database);
    commands = SqliteVmCommandRepository(database);
    final started = await operations.createAndStart(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: vm.metadata.id,
      requestId: RequestId.generate(),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    await operations.succeed(started.id);
    final state =
        VmControllerState.initial(
          vmId: vm.metadata.id,
          specGeneration: 1,
          restartPolicy: RestartPolicy.never,
        ).copyWith(
          desiredState: DesiredState.running,
          phase: VmPhase.running,
          observedGeneration: 1,
          driverGeneration: 1,
          activeDriverGeneration: 1,
          activeSpecGeneration: 1,
          driverOperationId: started.id,
          leaseState: VmLeaseState.held,
        );
    final persistence = SqliteVmStateEffectAdapter(database);
    await persistence.persistVm(state);
    await persistence.persistRuntime(state);
    final host = _HostBoundary();
    runner = RepositoryVmEffectRunner(
      database: database,
      operations: operations,
      events: SqliteEventRepository(database),
      persistence: persistence,
      leases: host,
      drivers: driver,
      managedFiles: host,
    );
    controller = VmController(initialState: state, effectRunner: runner);
    controllerReady = true;
  });

  tearDown(() async {
    final gate = driver.gate;
    if (gate != null && !gate.isCompleted) gate.complete();
    if (controllerReady) await controller.shutdown();
    database.close();
    await directory.delete(recursive: true);
  });

  Future<OperationAcceptance> accept(VmLifecycleAction action) =>
      controller.accept(
        SqliteVmLifecycleAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 1),
          command: VmLifecycleCommand(
            vmId: controller.state.vmId,
            action: action,
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
          ),
        ),
      );
  Future<VmCommandClaim> deliver() async {
    final claim = (await commands.claim(
      owner: 'display',
      lease: const Duration(seconds: 30),
    )).single;
    expect(
      await controller.adopt(
        SqliteVmIntentAdoption(
          database: database,
          record: claim.record,
          effectRunner: runner,
        ),
      ),
      VmIntentAdoptionDisposition.adopted,
    );
    expect(await commands.acknowledge(claim), isTrue);
    return claim;
  }

  test(
    'opening a running VM display commits the correlated result without changing runtime',
    () async {
      final originalDriverOperation = controller.state.driverOperationId;
      final accepted = await accept(VmLifecycleAction.openDisplay);
      await deliver();
      await controller.waitUntilIdle();
      final operation = (await operations.get(accepted.operationId))!;
      expect(operation.state, OperationState.succeeded);
      expect(operation.result?.toJson()['state'], 'open');
      expect(operation.result?.toJson()['driver_generation'], 1);
      expect(driver.displayCalls, ['open']);
      expect(driver.kills, 0);
      expect(controller.state.phase, VmPhase.running);
      expect(controller.state.desiredState, DesiredState.running);
      expect(controller.state.driverOperationId, originalDriverOperation);
      final display = await SqliteVmDisplayRepository(
        database,
      ).get(controller.state.vmId);
      expect(display.state, VmDisplayState.open);
      expect(display.observedAt, isNotNull);
    },
  );

  test(
    'cancelling a display action never stops its VM or accepts a late success',
    () async {
      final accepted = await accept(VmLifecycleAction.openDisplay);
      // Exercise the defensive internal callback with an eligible checkpoint;
      // public display operations intentionally advertise cancellable=false.
      await operations.setCancellable(accepted.operationId, cancellable: true);
      await operations.start(accepted.operationId);
      // A checkpoint with no currently awaited SDK call, as after interruption.
      // Test the public reducer and real durable runner, not private controller IO.
      final checkpoint = controller.state.copyWith(
        appliedIntentRevision: controller.acceptedIntentRevision,
        currentOperation: VmControllerOperation(
          id: accepted.operationId,
          kind: VmOperationKind.openDisplay,
          state: OperationState.running,
        ),
      );
      final cancelled = reduce(
        checkpoint,
        OperationCancelled(accepted.operationId),
      );
      expect(cancelled.state.desiredState, DesiredState.running);
      expect(cancelled.state.phase, VmPhase.running);
      expect(cancelled.effects.whereType<StopRuntime>(), isEmpty);
      expect(cancelled.effects.whereType<KillDriver>(), isEmpty);
      await runner.runDurableBatch(cancelled.effects, cancelled.state);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.cancelled,
      );
      final late = reduce(
        cancelled.state,
        DisplayCommandSucceeded(
          operationId: accepted.operationId,
          driverGeneration: 1,
          state: VmDisplayState.open,
          occurredAt: DateTime.now().toUtc(),
        ),
      );
      expect(late.effects, isEmpty);
      expect(driver.stops, 0);
      expect(driver.kills, 0);
    },
  );

  test(
    'interrupted display reconciliation fails the display without starting a VM under its ID',
    () async {
      final accepted = await accept(VmLifecycleAction.openDisplay);
      await operations.start(accepted.operationId);
      final checkpoint = controller.state.copyWith(
        appliedIntentRevision: controller.acceptedIntentRevision,
        clearActiveDriverGeneration: true,
        clearActiveSpecGeneration: true,
        leaseState: VmLeaseState.none,
        currentOperation: VmControllerOperation(
          id: accepted.operationId,
          kind: VmOperationKind.openDisplay,
          state: OperationState.running,
        ),
      );
      final reconciled = reduce(checkpoint, const ReconcileRequested());
      expect(reconciled.effects.whereType<AcquireHostLease>(), isEmpty);
      expect(reconciled.effects.whereType<ChangeDisplay>(), isEmpty);
      expect(reconciled.state.desiredState, DesiredState.running);
      await runner.runDurableBatch(reconciled.effects, reconciled.state);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.failed,
      );
      final recovery = reduce(reconciled.state, const ReconcileRequested());
      expect(
        recovery.effects.whereType<CreateRecoveryOperation>(),
        hasLength(1),
      );
      expect(recovery.effects.whereType<AcquireHostLease>(), isEmpty);
    },
  );

  test(
    'driver exit fails an in-flight display and creates a distinct runtime recovery operation',
    () async {
      final accepted = await accept(VmLifecycleAction.openDisplay);
      await operations.start(accepted.operationId);
      final checkpoint = controller.state.copyWith(
        appliedIntentRevision: controller.acceptedIntentRevision,
        restartPolicy: RestartPolicy.always,
        currentOperation: VmControllerOperation(
          id: accepted.operationId,
          kind: VmOperationKind.openDisplay,
          state: OperationState.running,
        ),
      );
      final exited = reduce(
        checkpoint,
        DriverExited(
          operationId: checkpoint.driverOperationId!,
          driverGeneration: 1,
          cleanShutdown: false,
          occurredAt: DateTime.now().toUtc(),
        ),
      );
      expect(
        exited.effects.whereType<FailOperation>().single.operationId,
        accepted.operationId,
      );
      expect(exited.effects.whereType<CreateRecoveryOperation>(), hasLength(1));
      expect(exited.state.desiredState, DesiredState.running);
      final replies = await runner.runDurableBatch(
        exited.effects.where(runner.isDurable).toList(),
        exited.state,
      );
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.failed,
      );
      final recovery = replies.whereType<RecoveryOperationCreated>().single;
      expect(recovery.operationId, isNot(accepted.operationId));
      final adopted = reduce(exited.state, recovery);
      expect(adopted.state.currentOperation!.kind, VmOperationKind.recovery);
      expect(adopted.state.currentOperation!.id, recovery.operationId);
      await runner.runDurableBatch(
        adopted.effects.where(runner.isDurable).toList(),
        adopted.state,
      );
      final restored = await SqliteVmIntentRecoveryRepository(
        database,
      ).restore(checkpoint.vmId);
      expect(
        restored!.executionState.currentOperation!.kind,
        VmOperationKind.recovery,
      );
      expect(
        restored.executionState.currentOperation!.id,
        recovery.operationId,
      );
    },
  );

  test(
    'open then repeated close remain ordered, durable, and never stop the VM',
    () async {
      driver.gate = Completer<void>();
      final opened = await accept(VmLifecycleAction.openDisplay);
      await deliver();
      await driver.entered.future;
      final closed = await accept(VmLifecycleAction.closeDisplay);
      final delivery = deliver();
      expect(
        (await operations.get(closed.operationId))!.state,
        OperationState.pending,
      );
      expect(driver.displayCalls, ['open']);
      driver.gate!.complete();
      await delivery;
      await controller.waitUntilIdle();
      final again = await accept(VmLifecycleAction.closeDisplay);
      await deliver();
      await controller.waitUntilIdle();
      expect(driver.displayCalls, ['open', 'close', 'close']);
      for (final acceptance in [opened, closed, again]) {
        expect(
          (await operations.get(acceptance.operationId))!.state,
          OperationState.succeeded,
        );
      }
      final status = await SqliteVmDisplayRepository(
        database,
      ).get(controller.state.vmId);
      expect(status.state, VmDisplayState.closed);
      expect(controller.state.desiredState, DesiredState.running);
      expect(controller.state.phase, VmPhase.running);
      expect(driver.stops, 0);
      expect(driver.kills, 0);
    },
  );

  test(
    'manual close updates the observation while retired generations cannot overwrite it',
    () async {
      final opened = await accept(VmLifecycleAction.openDisplay);
      await deliver();
      await controller.waitUntilIdle();
      final now = DateTime.now().toUtc().add(const Duration(seconds: 1));
      await controller.submit(
        DisplayObserved(
          driverGeneration: 1,
          state: VmDisplayState.closed,
          occurredAt: now,
        ),
      );
      expect(controller.state.displayState, VmDisplayState.closed);
      expect(
        (await operations.get(opened.operationId))!.result!.toJson()['state'],
        'open',
      );
      await controller.submit(
        DisplayObserved(
          driverGeneration: 2,
          state: VmDisplayState.open,
          occurredAt: now,
        ),
      );
      expect(controller.state.displayState, VmDisplayState.closed);
      final retired = controller.state.copyWith(
        driverGeneration: 2,
        activeDriverGeneration: 2,
      );
      expect(
        reduce(
          retired,
          DisplayObserved(
            driverGeneration: 1,
            state: VmDisplayState.open,
            occurredAt: now,
          ),
        ).effects,
        isEmpty,
      );
      expect(
        reduce(
          retired,
          DisplayCommandSucceeded(
            operationId: opened.operationId,
            driverGeneration: 1,
            state: VmDisplayState.open,
            occurredAt: now,
          ),
        ).effects,
        isEmpty,
      );
      expect(
        (await SqliteVmDisplayRepository(
          database,
        ).get(controller.state.vmId)).state,
        VmDisplayState.closed,
      );
      expect(controller.state.phase, VmPhase.running);
    },
  );

  test(
    'completion rollback never publishes display success or stops the runtime',
    () async {
      await database.transaction((db) async {
        db.execute(
          """CREATE TRIGGER reject_display_success BEFORE UPDATE OF state ON operations
          WHEN NEW.type = 'vm.open_display' AND NEW.state = 'succeeded'
          BEGIN SELECT RAISE(ABORT, 'injected display completion failure'); END""",
        );
      });
      final accepted = await accept(VmLifecycleAction.openDisplay);
      await deliver();
      await controller.waitUntilIdle();
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.failed,
      );
      expect(controller.state.desiredState, DesiredState.running);
      expect(controller.state.phase, VmPhase.running);
      expect(
        (await SqliteVmDisplayRepository(
          database,
        ).get(controller.state.vmId)).state,
        VmDisplayState.unknown,
      );
      await database.read((db) {
        expect(
          db.select(
            "SELECT id FROM events WHERE operation_id = ? AND type = 'vm.display_state_changed'",
            [accepted.operationId.value],
          ),
          isEmpty,
        );
      });
      expect(driver.stops, 0);
      expect(driver.kills, 0);
    },
  );

  test(
    'manual display observation rollback never stops a VM or rewrites a succeeded operation',
    () async {
      final accepted = await accept(VmLifecycleAction.openDisplay);
      await deliver();
      await controller.waitUntilIdle();
      await database.transaction((db) async {
        db.execute(
          """CREATE TRIGGER reject_manual_close BEFORE UPDATE OF display_state ON vm_runtime
          WHEN NEW.display_state = 'closed'
          BEGIN SELECT RAISE(ABORT, 'injected display observation failure'); END""",
        );
      });
      await controller.submit(
        DisplayObserved(
          driverGeneration: 1,
          state: VmDisplayState.closed,
          occurredAt: DateTime.now().toUtc().add(const Duration(seconds: 1)),
        ),
      );
      expect(controller.state.desiredState, DesiredState.running);
      expect(controller.state.phase, VmPhase.running);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
      expect(
        (await SqliteVmDisplayRepository(
          database,
        ).get(controller.state.vmId)).state,
        VmDisplayState.open,
      );
      expect(driver.stops, 0);
      expect(driver.kills, 0);
    },
  );

  test('cold restore rejects a driver owner belonging to another VM', () async {
    await accept(VmLifecycleAction.openDisplay);
    await deliver();
    await controller.waitUntilIdle();
    final peer = await SqliteVmRepository(
      database,
    ).create(name: 'peer', spec: _spec);
    final foreign = await operations.createAndStart(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: peer.metadata.id,
      requestId: RequestId.generate(),
      cancellable: false,
      request: JsonObjectValue.empty,
    );
    await operations.succeed(foreign.id);
    await database.transaction((db) {
      db.execute(
        'UPDATE vm_runtime SET driver_operation_id = ? WHERE vm_id = ?',
        [foreign.id.value, controller.state.vmId.value],
      );
    });
    await expectLater(
      SqliteVmIntentRecoveryRepository(database).restore(controller.state.vmId),
      throwsStateError,
    );
    expect(controller.state.phase, VmPhase.running);
    expect(driver.stops, 0);
    expect(driver.kills, 0);
  });

  test(
    'a display boundary failure fails only its operation, not its VM',
    () async {
      driver.error = VmEffectException(
        OperationError(
          code: ErrorCode.driverUnhealthy,
          message: 'display unavailable',
          retryable: false,
          details: JsonObjectValue.empty,
        ),
      );
      final accepted = await accept(VmLifecycleAction.openDisplay);
      await deliver();
      await controller.waitUntilIdle();
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.failed,
      );
      expect(controller.state.phase, VmPhase.running);
      expect(controller.state.desiredState, DesiredState.running);
      expect(driver.stops, 0);
      expect(driver.kills, 0);
    },
  );
}

// The VM/runtime and host SDK boundaries only; controller, persistence,
// acceptance, adoption and operation completion are the real implementations.
final class _DriverBoundary
    implements VmDriverEffectAdapter, VmDisplayEffectAdapter {
  final displayCalls = <String>[];
  int kills = 0;
  int stops = 0;
  final entered = Completer<void>();
  Completer<void>? gate;
  Exception? error;
  @override
  Future<VmDisplayState> setDisplay(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration, {
    required bool open,
  }) async {
    displayCalls.add(open ? 'open' : 'close');
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    if (error case final failure?) throw failure;
    return open ? VmDisplayState.open : VmDisplayState.closed;
  }

  @override
  Future<void> kill(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {
    kills++;
  }

  @override
  Future<void> stop(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {
    stops++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected runtime mutation: ${invocation.memberName}');
}

final class _HostBoundary
    implements VmLeaseEffectAdapter, VmManagedFileEffectAdapter {
  @override
  Future<void> release(
    VmControllerState state,
    OperationId? operationId,
  ) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected host mutation: ${invocation.memberName}');
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/external/root.raw'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: true, width: 1280, height: 800),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
