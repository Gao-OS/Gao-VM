import 'package:gaovm_models/gaovm_models.dart';

import 'event_repository.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';

abstract interface class VmStateEffectAdapter {
  Future<void> persistVm(VmControllerState state);

  Future<void> persistRuntime(VmControllerState state);
}

abstract interface class VmEffectCancellationAdapter {
  Future<void> cancel(VmEffect effect, VmControllerState state);
}

abstract interface class VmLeaseEffectAdapter {
  Future<void> acquire(VmControllerState state, OperationId operationId);

  Future<void> release(VmControllerState state, OperationId? operationId);
}

abstract interface class VmDriverEffectAdapter {
  Future<void> spawn(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  );

  Future<void> connect(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  );

  Future<void> configure(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  );

  Future<void> start(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  );

  Future<void> stop(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  );

  Future<void> kill(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  );
}

abstract interface class VmManagedFileEffectAdapter {
  Future<void> remove(VmControllerState state, OperationId operationId);
}

final class RepositoryVmEffectRunner
    implements TransactionalVmEffectRunner, CancellableVmEffectRunner {
  RepositoryVmEffectRunner({
    required GaoVmDatabase database,
    required OperationRepository operations,
    required EventRepository events,
    required VmStateEffectAdapter persistence,
    required VmLeaseEffectAdapter leases,
    required VmDriverEffectAdapter drivers,
    required VmManagedFileEffectAdapter managedFiles,
    RequestId Function()? newRequestId,
  }) : _database = database,
       _operations = operations,
       _events = events,
       _persistence = persistence,
       _leases = leases,
       _drivers = drivers,
       _managedFiles = managedFiles,
       _newRequestId = newRequestId ?? RequestId.generate;

  final GaoVmDatabase _database;
  final OperationRepository _operations;
  final EventRepository _events;
  final VmStateEffectAdapter _persistence;
  final VmLeaseEffectAdapter _leases;
  final VmDriverEffectAdapter _drivers;
  final VmManagedFileEffectAdapter _managedFiles;
  final RequestId Function() _newRequestId;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (isDurable(effect)) {
      return (await runDurableBatch([effect], state)).single;
    }
    return _runOne(effect, state);
  }

  @override
  bool isDurable(VmEffect effect) =>
      effect is PersistVm ||
      effect is PersistRuntime ||
      effect is CreateRecoveryOperation ||
      effect is FailOperation ||
      effect is CompleteOperation ||
      effect is EmitEvent;

  @override
  Future<List<VmCommand?>> runDurableBatch(
    List<VmEffect> effects,
    VmControllerState state,
  ) => _database.transaction((_) async {
    final commands = <VmCommand?>[];
    for (final effect in effects) {
      if (!isDurable(effect)) {
        throw ArgumentError('non-durable effect in durable batch: $effect');
      }
      try {
        commands.add(await _runOne(effect, state));
      } catch (error, stackTrace) {
        throw VmEffectBatchException(effect, error, stackTrace);
      }
    }
    return commands;
  });

  Future<VmCommand?> _runOne(VmEffect effect, VmControllerState state) async {
    final operationId = effect.operationId;
    final driverGeneration = effect.driverGeneration;
    switch (effect) {
      case PersistVm():
        await _persistence.persistVm(state);
      case PersistRuntime():
        await _persistence.persistRuntime(state);
      case AcquireHostLease():
        await _leases.acquire(state, operationId!);
        return HostLeaseAcquired(operationId);
      case ReleaseHostLease():
        await _leases.release(state, operationId);
        return HostLeaseReleased(operationId);
      case SpawnDriver():
        await _drivers.spawn(state, operationId!, driverGeneration!);
        return DriverSpawned(
          operationId: operationId,
          driverGeneration: driverGeneration,
        );
      case ConnectDriver():
        await _drivers.connect(state, operationId!, driverGeneration!);
        return DriverHandshakeCompleted(
          operationId: operationId,
          driverGeneration: driverGeneration,
        );
      case ConfigureRuntime():
        await _drivers.configure(state, operationId!, driverGeneration!);
        return DriverCommandSucceeded(
          operationId: operationId,
          driverGeneration: driverGeneration,
          command: RuntimeCommandKind.configure,
        );
      case StartRuntime():
        await _drivers.start(state, operationId!, driverGeneration!);
        return DriverCommandSucceeded(
          operationId: operationId,
          driverGeneration: driverGeneration,
          command: RuntimeCommandKind.start,
        );
      case StopRuntime():
        await _drivers.stop(state, operationId!, driverGeneration!);
        return DriverCommandSucceeded(
          operationId: operationId,
          driverGeneration: driverGeneration,
          command: RuntimeCommandKind.stop,
        );
      case KillDriver():
        await _drivers.kill(state, operationId!, driverGeneration!);
        return DriverCommandSucceeded(
          operationId: operationId,
          driverGeneration: driverGeneration,
          command: RuntimeCommandKind.kill,
        );
      case ShutdownDriver():
        await _drivers.kill(state, operationId!, driverGeneration!);
        return ControllerDriverShutdownSucceeded(driverGeneration, operationId);
      case ShutdownLease():
        await _leases.release(state, operationId);
        return const ControllerLeaseShutdownSucceeded();
      case CreateRecoveryOperation(:final error):
        final operation = await _operations.createAndStart(
          type: 'vm.recovery',
          resourceType: ResourceType.virtualMachine,
          resourceId: effect.vmId,
          requestId: _newRequestId(),
          cancellable: false,
          request: JsonObjectValue.fromJson({
            'failed_driver_generation': driverGeneration,
            'error': error.toJson(),
          }),
        );
        return RecoveryOperationCreated(
          operationId: operation.id,
          failedDriverGeneration: driverGeneration!,
        );
      case RemoveManagedFiles():
        await _managedFiles.remove(state, operationId!);
        return ManagedFilesRemoved(operationId);
      case FailOperation(:final error):
        await _ensureRunning(operationId!);
        await _operations.fail(operationId, error: error);
      case CompleteOperation(:final cancelled):
        await _completeOperation(operationId!, cancelled: cancelled);
      case EmitEvent(:final type, :final payload):
        await _events.append(
          type: type,
          resourceType: ResourceType.virtualMachine,
          resourceId: effect.vmId,
          vmId: effect.vmId,
          operationId: operationId,
          payload: payload ?? JsonObjectValue.empty,
        );
      case ScheduleRetry() || CancelRetry() || ScheduleStableReset():
        throw StateError('timer effects must be handled by VmController');
    }
    return null;
  }

  @override
  Future<void> cancel(VmEffect effect, VmControllerState state) async {
    final adapter = switch (effect) {
      PersistVm() || PersistRuntime() => _persistence,
      AcquireHostLease() || ReleaseHostLease() || ShutdownLease() => _leases,
      SpawnDriver() ||
      ConnectDriver() ||
      ConfigureRuntime() ||
      StartRuntime() ||
      StopRuntime() ||
      KillDriver() ||
      ShutdownDriver() => _drivers,
      RemoveManagedFiles() => _managedFiles,
      _ => null,
    };
    if (adapter is VmEffectCancellationAdapter) {
      await adapter.cancel(effect, state);
    }
  }

  Future<void> _ensureRunning(OperationId operationId) async {
    final operation = await _operations.get(operationId);
    if (operation == null) throw OperationNotFoundException(operationId);
    if (operation.state == OperationState.pending) {
      await _operations.start(operationId);
    }
  }

  Future<void> _completeOperation(
    OperationId operationId, {
    required bool cancelled,
  }) async {
    final operation = await _operations.get(operationId);
    if (operation == null) throw OperationNotFoundException(operationId);
    if (operation.state == OperationState.succeeded && !cancelled ||
        operation.state == OperationState.cancelled && cancelled) {
      return;
    }
    if (cancelled) {
      await _operations.cancel(operationId);
      return;
    }
    await _ensureRunning(operationId);
    await _operations.succeed(operationId);
  }
}
