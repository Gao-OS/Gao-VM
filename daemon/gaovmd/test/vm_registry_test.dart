import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  test('lease-loss notification never activates a cold catalog VM', () async {
    final repository = _MemoryVmRepository([_vm(_vm1)]);
    final registry = VmRegistry(
      repository: repository,
      operations: _MemoryOperationRepository(),
      effectRunner: _RegistryRunner(),
    );
    final error = OperationError(
      code: ErrorCode.hostResourceExhausted,
      message: 'lease lost',
      retryable: true,
      details: JsonObjectValue.empty,
    );
    await registry.handleHostLeaseLost(_vm1, 1, _operation1, 1, error);
    await registry.handleHostLeaseLost(_vm1, 1, null, null, error);
    expect(registry.activeCount, 0);
    await registry.shutdown();
  });
  test(
    'a moved checkpoint is retried but a stable recovery error is surfaced',
    () async {
      final repository = _MemoryVmRepository([_vm(_vm1)])
        ..releaseGets.complete();
      final entered = Completer<void>();
      final release = Completer<bool>();
      final failure = StateError('checkpoint mismatch');
      final recovery = _ObservedRecovery()
        ..check = (_) {
          if (!entered.isCompleted) {
            entered.complete();
            return release.future;
          }
          return Future.error(failure);
        };
      final registry = VmRegistry(
        repository: repository,
        operations: _MemoryOperationRepository(),
        effectRunner: _RegistryRunner(),
        recovery: recovery,
      );
      try {
        final controller = (await registry.get(_vm1))!;
        final pending = registry.reconcileVm(_vm1);
        await entered.future;
        await controller.submit(
          const SpecUpdated(
            specGeneration: 2,
            restartPolicy: RestartPolicy.never,
            restartRequired: false,
          ),
        );
        release.completeError(failure);
        await pending;
        await expectLater(registry.reconcileVm(_vm1), throwsA(same(failure)));
        expect(recovery.checks, 2);
      } finally {
        if (!release.isCompleted) release.complete(false);
        await registry.shutdown();
      }
    },
  );

  test('tick retires a completed deletion omitted from the catalog', () async {
    final repository = _MemoryVmRepository([_vm(_vm1)])..releaseGets.complete();
    final registry = VmRegistry(
      repository: repository,
      operations: _MemoryOperationRepository(),
      effectRunner: _RegistryRunner(),
    );
    final controller = (await registry.get(_vm1))!;
    await controller.submit(DeleteRequested(_operation1));
    expect(controller.state.phase, VmPhase.deleted);
    expect(registry.activeCount, 1);
    repository._virtualMachines.remove(_vm1);
    try {
      await registry.reconcileTick(onError: (_, error, _) => fail('$error'));
      await registry.reconcileVm(_vm1);
      expect(registry.activeCount, 0);
      expect(controller.isAccepting, isFalse);
    } finally {
      await registry.shutdown();
    }
  });

  test('recovery guard waits for the existing effect lane to settle', () async {
    final repository = _MemoryVmRepository([_vm(_vm1)])..releaseGets.complete();
    final recovery = _ObservedRecovery();
    final runner = _PausedAcquisitionRunner();
    final registry = VmRegistry(
      repository: repository,
      operations: _MemoryOperationRepository(),
      effectRunner: runner,
      recovery: recovery,
    );
    final controller = (await registry.get(_vm1))!;
    final start = controller.submit(StartRequested(_operation1));
    await runner.entered.future;
    try {
      await registry.reconcileTick(onError: (_, error, _) => fail('$error'));
      expect(recovery.checks, 0);
      await registry.shutdown().timeout(const Duration(seconds: 1));
      await start;
      expect(recovery.checks, 0);
    } finally {
      if (!runner.release.isCompleted) runner.release.complete();
      await registry.shutdown();
    }
  });

  test(
    'ticks skip provisioning and isolate per-VM activation failures',
    () async {
      final repository = _MemoryVmRepository([
        _vm(_vm1),
        _vm(_vm2),
        _vm(VmId.generate(), phase: VmPhase.provisioning),
      ])..releaseGets.complete();
      final failure = StateError('damaged operation history');
      final operations = _FailingOperationRepository(_vm1, failure);
      final registry = VmRegistry(
        repository: repository,
        operations: operations,
        effectRunner: _RegistryRunner(),
      );
      final reported = Completer<VmId>();
      try {
        await registry.reconcileTick(
          onError: (id, error, _) {
            expect(error, same(failure));
            reported.complete(id);
          },
        );
        expect(await reported.future, _vm1);
        await registry.reconcileVm(_vm2);
        expect(registry.activeCount, 1);
        expect(registry.activeControllers.single.state.vmId, _vm2);
      } finally {
        await registry.shutdown();
      }
    },
  );

  test(
    'a catalog tick completing after shutdown cannot activate controllers',
    () async {
      final release = Completer<void>();
      final repository = _MemoryVmRepository([
        _vm(_vm1),
      ], listGate: release.future)..releaseGets.complete();
      final registry = VmRegistry(
        repository: repository,
        operations: _MemoryOperationRepository(),
        effectRunner: _RegistryRunner(),
      );
      final tick = registry.reconcileTick(
        onError: (_, error, _) => fail('$error'),
      );
      final rejected = expectLater(
        tick,
        throwsA(isA<VmRegistryClosedException>()),
      );
      await repository.listStarted.future;
      final closing = registry.shutdown();
      release.complete();
      await closing;
      await rejected;
      expect(registry.activeCount, 0);
    },
  );

  test('safety ticks coalesce a slow VM without blocking another VM', () async {
    final repository = _MemoryVmRepository([
      _vm(_vm1, desiredState: DesiredState.running),
      _vm(_vm2),
    ])..releaseGets.complete();
    final operations = _MemoryOperationRepository();
    await operations.createVmOperation(_vm1, 'vm.start');
    final runner = _PausedAcquisitionRunner();
    final registry = VmRegistry(
      repository: repository,
      operations: operations,
      effectRunner: runner,
    );
    final errors = <Object>[];
    try {
      await registry.reconcileTick(onError: (_, error, _) => errors.add(error));
      await runner.entered.future;
      final slow = registry.reconcileVm(_vm1);
      await registry.reconcileVm(_vm2).timeout(const Duration(seconds: 1));
      await registry.reconcileTick(onError: (_, error, _) => errors.add(error));
      expect(registry.reconcileVm(_vm1), same(slow));
      await registry.reconcileVm(_vm2).timeout(const Duration(seconds: 1));
      expect(registry.activeCount, 2);
      expect(errors, isEmpty);
      final closing = registry.shutdown();
      await closing.timeout(const Duration(seconds: 1));
      await slow;
      expect(runner.cancelled, isTrue);
      expect(registry.activeCount, 0);
    } finally {
      if (!runner.release.isCompleted) runner.release.complete();
      await registry.shutdown();
    }
  });

  test(
    'lazy activation is singleton-safe under concurrent get races',
    () async {
      final repository = _MemoryVmRepository([_vm(_vm1)]);
      final registry = VmRegistry(
        repository: repository,
        operations: _MemoryOperationRepository(),
        effectRunner: _RegistryRunner(),
      );

      final gets = List.generate(20, (_) => registry.get(_vm1));
      await Future<void>.delayed(Duration.zero);
      expect(repository.getCalls, 1);
      repository.releaseGets.complete();
      final controllers = await Future.wait(gets);

      expect(
        controllers.every((value) => identical(value, controllers.first)),
        isTrue,
      );
      expect(registry.activeCount, 1);
      await registry.shutdown();
    },
  );

  test('startup loads the catalog and reconciles every VM', () async {
    final repository = _MemoryVmRepository([
      _vm(_vm1, desiredState: DesiredState.running, phase: VmPhase.running),
      _vm(_vm2),
    ])..releaseGets.complete();
    final runner = _RegistryRunner();
    final registry = VmRegistry(
      repository: repository,
      operations: _MemoryOperationRepository(),
      effectRunner: runner,
    );

    final controllers = await registry.reconcileOnStartup();

    expect(controllers, hasLength(2));
    expect(registry.activeCount, 2);
    final recovering = await registry.get(_vm1);
    expect(recovering?.state.currentOperation?.kind, VmOperationKind.recovery);
    expect(runner.effects[_vm1], contains('CreateRecoveryOperation'));
    expect((await registry.get(_vm2))?.state.phase, VmPhase.defined);
    await registry.shutdown();
  });

  test('completed deletion shuts down and removes its controller', () async {
    final repository = _MemoryVmRepository([_vm(_vm1)])..releaseGets.complete();
    final registry = VmRegistry(
      repository: repository,
      operations: _MemoryOperationRepository(),
      effectRunner: _RegistryRunner(),
    );
    final controller = await registry.get(_vm1);

    final state = await registry.dispatch(_vm1, DeleteRequested(_operation1));

    expect(state.deletionState, VmDeletionState.deleted);
    expect(controller?.isAccepting, isFalse);
    expect(controller?.isIdle, isTrue);
    expect(registry.activeCount, 0);
    await registry.shutdown();
  });

  test('shutdown aborts startup reconciliation after catalog load', () async {
    final listGate = Completer<void>();
    final repository = _MemoryVmRepository([
      _vm(_vm1),
    ], listGate: listGate.future)..releaseGets.complete();
    final registry = VmRegistry(
      repository: repository,
      operations: _MemoryOperationRepository(),
      effectRunner: _RegistryRunner(),
    );
    final reconcile = registry.reconcileOnStartup();
    await repository.listStarted.future;

    final shutdown = registry.shutdown();
    final concurrentShutdown = registry.shutdown();
    expect(identical(shutdown, concurrentShutdown), isTrue);
    listGate.complete();

    await expectLater(reconcile, throwsA(isA<VmRegistryClosedException>()));
    await shutdown;
    await concurrentShutdown;
    expect(registry.activeCount, 0);
  });

  test(
    'shutdown waits an activation and prevents post-close controller creation',
    () async {
      final repository = _MemoryVmRepository([_vm(_vm1)]);
      final registry = VmRegistry(
        repository: repository,
        operations: _MemoryOperationRepository(),
        effectRunner: _RegistryRunner(),
      );
      final activation = registry.get(_vm1);
      await Future<void>.delayed(Duration.zero);

      final shutdown = registry.shutdown();
      repository.releaseGets.complete();

      await expectLater(activation, throwsA(isA<VmRegistryClosedException>()));
      await shutdown;
      expect(registry.activeCount, 0);
    },
  );

  test(
    'shutdown cancels effects while startup reconciliation waits for idle',
    () async {
      final repository = _MemoryVmRepository([
        _vm(_vm1, desiredState: DesiredState.running),
      ])..releaseGets.complete();
      final operations = _MemoryOperationRepository();
      await operations.createVmOperation(_vm1, 'vm.start');
      final runner = _PausedAcquisitionRunner();
      final registry = VmRegistry(
        repository: repository,
        operations: operations,
        effectRunner: runner,
      );
      final reconcile = registry.reconcileOnStartup();
      await runner.entered.future;
      try {
        await registry.shutdown().timeout(const Duration(seconds: 1));
        await reconcile;
        expect(runner.cancelled, isTrue);
        expect(registry.activeCount, 0);
      } finally {
        if (!runner.release.isCompleted) runner.release.complete();
        await registry.shutdown();
        await reconcile;
      }
    },
  );

  test(
    'shutdown drains a rejected reconcile waiting for an active effect',
    () async {
      final repository = _MemoryVmRepository([_vm(_vm1)])
        ..releaseGets.complete();
      final runner = _PausedAcquisitionRunner();
      final registry = VmRegistry(
        repository: repository,
        operations: _MemoryOperationRepository(),
        effectRunner: runner,
      );
      final controller = (await registry.get(_vm1))!;
      final start = controller.submit(StartRequested(_operation1));
      await runner.entered.future;
      final reconcile = registry.reconcileOnStartup();
      await Future<void>.delayed(Duration.zero);
      final rejection = expectLater(
        reconcile,
        throwsA(isA<VmRegistryClosedException>()),
      );
      await registry.shutdown().timeout(const Duration(seconds: 1));
      await rejection;
      await start;
      expect(registry.activeCount, 0);
    },
  );

  test(
    'failed shutdown keeps its controller for a successful cleanup retry',
    () async {
      final repository = _MemoryVmRepository([_vm(_vm1)])
        ..releaseGets.complete();
      final runner = _PausedAcquisitionRunner()..failCleanup = true;
      final registry = VmRegistry(
        repository: repository,
        operations: _MemoryOperationRepository(),
        effectRunner: runner,
      );
      final controller = (await registry.get(_vm1))!;
      final start = controller.submit(StartRequested(_operation1));
      await runner.entered.future;
      await expectLater(
        registry.shutdown(),
        throwsA(isA<VmControllerShutdownException>()),
      );
      await start;
      expect(registry.activeCount, 1);
      expect(controller.isAccepting, isFalse);
      runner.failCleanup = false;
      await registry.shutdown();
      expect(registry.activeCount, 0);
      expect(controller.state.leaseState, VmLeaseState.none);
    },
  );

  test(
    'startup restores one operation and terminalizes superseded orphans',
    () async {
      final repository = _MemoryVmRepository([
        _vm(_vm1, desiredState: DesiredState.running, phase: VmPhase.running),
      ])..releaseGets.complete();
      final operations = _MemoryOperationRepository();
      final first = await operations.createVmOperation(_vm1, 'vm.start');
      final second = await operations.createVmOperation(_vm1, 'vm.restart');
      final registry = VmRegistry(
        repository: repository,
        operations: operations,
        effectRunner: _RegistryRunner(operations),
      );

      await registry.reconcileOnStartup();
      final controller = await registry.get(_vm1);

      expect(controller?.state.currentOperation?.id, second.id);
      expect((await operations.get(first.id))?.state, OperationState.failed);
      expect((await operations.get(second.id))?.state, OperationState.running);
      await registry.shutdown();
    },
  );

  test(
    'deleting VM without an operation creates recovery delete and finishes it',
    () async {
      final repository = _MemoryVmRepository([
        _vm(_vm1, phase: VmPhase.deleting),
      ])..releaseGets.complete();
      final operations = _MemoryOperationRepository();
      final registry = VmRegistry(
        repository: repository,
        operations: operations,
        effectRunner: _RegistryRunner(operations),
        newRequestId: () => RequestId('req_01J00000000000000000000000'),
      );

      await registry.reconcileOnStartup();

      final recoveryDeletes = (await operations.list()).where(
        (operation) => operation.type == 'vm.delete.recovery',
      );
      expect(recoveryDeletes, hasLength(1));
      expect(recoveryDeletes.single.state, OperationState.succeeded);
      expect(registry.activeCount, 0);
      await registry.shutdown();
    },
  );

  test(
    'startup restores unfinished stop and normalizes transient stopped VM',
    () async {
      final repository = _MemoryVmRepository([
        _vm(_vm1, phase: VmPhase.stopping),
        _vm(_vm2, phase: VmPhase.starting),
      ])..releaseGets.complete();
      final operations = _MemoryOperationRepository();
      final stop = await operations.createVmOperation(_vm1, 'vm.stop');
      final registry = VmRegistry(
        repository: repository,
        operations: operations,
        effectRunner: _RegistryRunner(operations),
      );

      await registry.reconcileOnStartup();

      expect((await operations.get(stop.id))?.state, OperationState.succeeded);
      expect((await registry.get(_vm1))?.state.phase, VmPhase.stopped);
      expect((await registry.get(_vm2))?.state.phase, VmPhase.stopped);
      await registry.shutdown();
    },
  );

  test(
    'rolled-back delete completion stays active and is compensated failed',
    () async {
      final repository = _MemoryVmRepository([_vm(_vm1)])
        ..releaseGets.complete();
      final runner = _RollbackDeleteRunner();
      final registry = VmRegistry(
        repository: repository,
        operations: _MemoryOperationRepository(),
        effectRunner: runner,
      );

      final state = await registry.dispatch(_vm1, DeleteRequested(_operation1));

      expect(state.deletionState, VmDeletionState.deleting);
      expect(state.phase, VmPhase.failed);
      expect(state.currentOperation?.state, OperationState.failed);
      expect(runner.batches.last, contains('FailOperation'));
      expect(registry.activeCount, 1);
      expect((await registry.get(_vm1))?.isAccepting, isTrue);
      await registry.shutdown();
    },
  );
}

final class _RegistryRunner implements VmEffectRunner {
  _RegistryRunner([this.operations]);

  final _MemoryOperationRepository? operations;
  final effects = <VmId, List<String>>{};

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    effects
        .putIfAbsent(effect.vmId, () => [])
        .add(effect.runtimeType.toString());
    if (effect is CreateRecoveryOperation) {
      return RecoveryOperationCreated(
        operationId: effect.vmId == _vm1 ? _operation1 : _operation2,
        failedDriverGeneration: effect.driverGeneration!,
      );
    }
    if (effect is RemoveManagedFiles) {
      return ManagedFilesRemoved(effect.operationId!);
    }
    if (effect is CompleteOperation && operations != null) {
      await operations!.succeed(effect.operationId!);
    }
    if (effect is FailOperation && operations != null) {
      await operations!.fail(effect.operationId!, error: effect.error);
    }
    return null;
  }
}

final class _PausedAcquisitionRunner
    implements VmEffectRunner, CancellableVmEffectRunner {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool cancelled = false;
  bool failCleanup = false;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is AcquireHostLease) {
      entered.complete();
      await release.future;
    }
    if (effect is ShutdownLease) {
      if (failCleanup) throw StateError('lease cleanup failed');
      return const ControllerLeaseShutdownSucceeded();
    }
    return null;
  }

  @override
  Future<void> cancel(VmEffect effect, VmControllerState state) async {
    if (effect is AcquireHostLease) {
      cancelled = true;
      if (!release.isCompleted) release.complete();
    }
  }
}

final class _RollbackDeleteRunner implements TransactionalVmEffectRunner {
  final batches = <List<String>>[];

  @override
  bool isDurable(VmEffect effect) =>
      effect is PersistVm ||
      effect is PersistRuntime ||
      effect is CompleteOperation ||
      effect is FailOperation ||
      effect is EmitEvent;

  @override
  Future<List<VmCommand?>> runDurableBatch(
    List<VmEffect> effects,
    VmControllerState state,
  ) async {
    batches.add(
      effects.map((effect) => effect.runtimeType.toString()).toList(),
    );
    if (effects.any((effect) => effect is CompleteOperation)) {
      throw VmEffectBatchException(
        effects.last,
        StateError('delete completion transaction rolled back'),
        StackTrace.current,
      );
    }
    return List<VmCommand?>.filled(effects.length, null);
  }

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is RemoveManagedFiles) {
      return ManagedFilesRemoved(effect.operationId!);
    }
    return null;
  }
}

final class _MemoryVmRepository implements VmRepository {
  _MemoryVmRepository(Iterable<VirtualMachine> virtualMachines, {this.listGate})
    : _virtualMachines = {
        for (final virtualMachine in virtualMachines)
          virtualMachine.metadata.id: virtualMachine,
      };

  final Map<VmId, VirtualMachine> _virtualMachines;
  final Future<void>? listGate;
  final releaseGets = Completer<void>();
  final listStarted = Completer<void>();
  var getCalls = 0;

  @override
  Future<VirtualMachine?> get(VmId id, {bool includeDeleted = false}) async {
    getCalls++;
    await releaseGets.future;
    return _virtualMachines[id];
  }

  @override
  Future<List<VirtualMachine>> list({
    bool includeDeleted = false,
    LabelSelector? labelSelector,
  }) async {
    if (!listStarted.isCompleted) listStarted.complete();
    await listGate;
    return List<VirtualMachine>.unmodifiable(_virtualMachines.values);
  }

  @override
  Future<VirtualMachine> create({
    required String name,
    Map<String, String> labels = const {},
    required VmSpec spec,
  }) => throw UnimplementedError();

  @override
  Future<VirtualMachine> markDeleting(
    VmId id, {
    required int expectedRevision,
  }) => throw UnimplementedError();

  @override
  Future<VirtualMachine> patch(
    VmId id, {
    required int expectedRevision,
    String? name,
    Map<String, String>? labels,
    VmSpecPatch? spec,
  }) => throw UnimplementedError();

  @override
  Future<VirtualMachine> tombstone(VmId id, {required int expectedRevision}) =>
      throw UnimplementedError();

  @override
  Future<VirtualMachine> updateSpec(
    VmId id, {
    required int expectedRevision,
    required VmSpec spec,
  }) => throw UnimplementedError();
}

final class _ObservedRecovery implements VmIntentRecoveryRepository {
  int checks = 0;
  Future<bool> Function(VmControllerState)? check;
  @override
  Future<VmIntentRecoverySnapshot?> restore(VmId id) async => null;
  @override
  Future<bool> hasUnpublishedCommands(VmId id) async => false;
  @override
  Future<bool> shouldDeferReconciliation(VmControllerState state) async {
    checks++;
    return check == null ? false : await check!(state);
  }
}

final class _FailingOperationRepository extends _MemoryOperationRepository {
  _FailingOperationRepository(this.vmId, this.error);
  final VmId vmId;
  final Object error;
  @override
  Future<List<Operation>> list({
    ResourceType? resourceType,
    ResourceId? resourceId,
    OperationState? state,
  }) {
    if (resourceId == vmId) return Future.error(error);
    return super.list(
      resourceType: resourceType,
      resourceId: resourceId,
      state: state,
    );
  }
}

class _MemoryOperationRepository implements OperationRepository {
  final operations = <OperationId, Operation>{};
  var _sequence = 0;

  Future<Operation> createVmOperation(VmId vmId, String type) async {
    final operation = await create(
      type: type,
      resourceType: ResourceType.virtualMachine,
      resourceId: vmId,
      requestId: RequestId('req_01J00000000000000000000000'),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    return start(operation.id);
  }

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
  }) async {
    final suffix = (_sequence++).toString().padLeft(2, '0');
    final id = OperationId('op_01J000000000000000000000$suffix');
    final operation = Operation(
      id: id,
      type: type,
      resourceType: resourceType,
      resourceId: resourceId,
      state: OperationState.pending,
      requestId: requestId,
      cancellable: cancellable,
      request: request,
      createdAt: DateTime.utc(2026, 9, 4, 9),
    );
    operations[id] = operation;
    return operation;
  }

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
  Future<Operation?> get(OperationId id) async => operations[id];

  @override
  Future<List<Operation>> list({
    ResourceType? resourceType,
    ResourceId? resourceId,
    OperationState? state,
  }) async => operations.values
      .where(
        (operation) =>
            (resourceType == null || operation.resourceType == resourceType) &&
            (resourceId == null || operation.resourceId == resourceId) &&
            (state == null || operation.state == state),
      )
      .toList();

  @override
  Future<Operation> start(
    OperationId id, {
    OperationProgress? progress,
  }) async => _replace(id, OperationState.running);

  @override
  Future<Operation> succeed(OperationId id, {JsonObjectValue? result}) async =>
      _replace(id, OperationState.succeeded);

  @override
  Future<Operation> fail(
    OperationId id, {
    required OperationError error,
  }) async => _replace(id, OperationState.failed, error: error);

  @override
  Future<Operation> cancel(OperationId id) async =>
      _replace(id, OperationState.cancelled);

  @override
  Future<Operation> setCancellable(
    OperationId id, {
    required bool cancellable,
  }) async => operations[id]!;

  Operation _replace(
    OperationId id,
    OperationState state, {
    OperationError? error,
  }) {
    final current = operations[id]!;
    final terminal = const {
      OperationState.succeeded,
      OperationState.failed,
      OperationState.cancelled,
    }.contains(state);
    final operation = Operation(
      id: current.id,
      type: current.type,
      resourceType: current.resourceType,
      resourceId: current.resourceId,
      state: state,
      requestId: current.requestId,
      cancellable: !terminal && current.cancellable,
      request: current.request,
      error: error,
      createdAt: current.createdAt,
      startedAt: state == OperationState.running
          ? DateTime.utc(2026, 9, 4, 9, 1)
          : current.startedAt,
      completedAt: terminal ? DateTime.utc(2026, 9, 4, 9, 2) : null,
    );
    operations[id] = operation;
    return operation;
  }
}

VirtualMachine _vm(
  VmId id, {
  DesiredState desiredState = DesiredState.stopped,
  VmPhase phase = VmPhase.defined,
}) {
  final timestamp = DateTime.utc(2026, 9, 4, 9);
  return VirtualMachine(
    metadata: VmMetadata(
      id: id,
      name: id.value,
      revision: 1,
      createdAt: timestamp,
      updatedAt: timestamp,
    ),
    spec: _spec,
    status: VmStatus(
      desiredState: desiredState,
      phase: phase,
      specGeneration: 1,
      observedGeneration: phase == VmPhase.running ? 1 : 0,
      driverGeneration: phase == VmPhase.running ? 1 : 0,
      guestAgent: GuestAgentState.disabled,
      lastTransitionAt: timestamp,
    ),
  );
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 2147483648,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [SharedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.onFailure,
);

final _vm1 = VmId('vm_01J00000000000000000000000');
final _vm2 = VmId('vm_01J00000000000000000000001');
final _operation1 = OperationId('op_01J00000000000000000000000');
final _operation2 = OperationId('op_01J00000000000000000000001');
