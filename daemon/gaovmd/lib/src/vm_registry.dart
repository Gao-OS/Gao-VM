import 'package:gaovm_models/gaovm_models.dart';

import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'operation_repository.dart';
import 'vm_repository.dart';
import 'vm_intent_recovery_repository.dart';

final class VmRegistryClosedException implements Exception {
  const VmRegistryClosedException();

  @override
  String toString() => 'VM registry is shutting down';
}

final class VmRegistry {
  VmRegistry({
    required VmRepository repository,
    required OperationRepository operations,
    required VmEffectRunner effectRunner,
    VmIntentRecoveryRepository? recovery,
    VmTimerScheduler Function()? timerSchedulerFactory,
    RequestId Function()? newRequestId,
  }) : _repository = repository,
       _operations = operations,
       _effectRunner = effectRunner,
       _recovery = recovery,
       _timerSchedulerFactory =
           timerSchedulerFactory ?? (() => const DartVmTimerScheduler()),
       _newRequestId = newRequestId ?? RequestId.generate;

  final VmRepository _repository;
  final OperationRepository _operations;
  final VmEffectRunner _effectRunner;
  final VmIntentRecoveryRepository? _recovery;
  final VmTimerScheduler Function() _timerSchedulerFactory;
  final RequestId Function() _newRequestId;
  final Map<VmId, VmController> _controllers = {};
  final Map<VmId, Future<VmController?>> _activations = {};
  final Map<VmId, Future<void>> _retirements = {};
  Future<List<VmController>>? _reconcileFuture;
  Future<void>? _shutdownFuture;
  bool _accepting = true;

  int get activeCount => _controllers.length;
  Iterable<VmController> get activeControllers =>
      List<VmController>.unmodifiable(_controllers.values);

  Future<VmController?> get(VmId vmId) {
    if (!_accepting) {
      return Future<VmController?>.error(const VmRegistryClosedException());
    }
    final active = _controllers[vmId];
    if (active != null && active.isAccepting) return Future.value(active);
    final retirement = _retirements[vmId];
    if (retirement != null) {
      return retirement.then((_) => get(vmId));
    }
    final pending = _activations[vmId];
    if (pending != null) return pending;

    late Future<VmController?> activation;
    activation = _loadAndActivate(vmId).whenComplete(() {
      if (identical(_activations[vmId], activation)) {
        _activations.remove(vmId);
      }
    });
    _activations[vmId] = activation;
    return activation;
  }

  Future<List<VmController>> reconcileOnStartup() {
    _requireAccepting();
    return _reconcileFuture ??= _reconcileOnStartup().whenComplete(() {
      _reconcileFuture = null;
    });
  }

  Future<List<VmController>> _reconcileOnStartup() async {
    final virtualMachines = await _repository.list();
    _requireAccepting();
    final controllers = await Future.wait(virtualMachines.map(_activateLoaded));
    _requireAccepting();
    await Future.wait(
      controllers.map((controller) async {
        if (await _recovery?.hasUnpublishedCommands(controller.state.vmId) ??
            false)
          return;
        await controller.submit(const ReconcileRequested());
        await controller.waitUntilIdle();
        if (_isDurablyDeleted(controller.state)) {
          await _retire(controller.state.vmId, controller);
        }
      }),
    );
    return List<VmController>.unmodifiable(controllers);
  }

  Future<VmControllerState> dispatch(VmId vmId, VmCommand command) async {
    final controller = await get(vmId);
    if (controller == null) throw VmNotFoundException(vmId);
    await controller.submit(command);
    await controller.waitUntilIdle();
    final state = controller.state;
    if (_isDurablyDeleted(state)) {
      await _retire(vmId, controller);
    }
    return state;
  }

  Future<void> shutdown() {
    final pending = _shutdownFuture;
    if (pending != null) return pending;
    late Future<void> attempt;
    attempt = _shutdown().whenComplete(() {
      if (identical(_shutdownFuture, attempt)) _shutdownFuture = null;
    });
    _shutdownFuture = attempt;
    return attempt;
  }

  Future<void> _shutdown() async {
    if (!_accepting && _controllers.isEmpty && _activations.isEmpty) return;
    _accepting = false;
    final reconcile = _reconcileFuture;
    if (reconcile != null) {
      try {
        await reconcile;
      } on VmRegistryClosedException {
        // Closing intentionally aborts startup activation.
      }
    }
    final activations = List<Future<VmController?>>.of(_activations.values);
    if (activations.isNotEmpty) {
      try {
        await Future.wait(activations);
      } on VmRegistryClosedException {
        // Closing intentionally aborts lazy activation.
      }
    }
    await Future.wait(
      List<VmController>.of(
        _controllers.values,
      ).map((controller) => controller.shutdown()),
    );
    _controllers.clear();
  }

  Future<VmController?> _loadAndActivate(VmId vmId) async {
    final virtualMachine = await _repository.get(vmId);
    if (virtualMachine == null) return null;
    _requireAccepting();
    return _restoreAndCreate(virtualMachine);
  }

  Future<VmController> _activateLoaded(VirtualMachine virtualMachine) async {
    final vmId = virtualMachine.metadata.id;
    final active = _controllers[vmId];
    if (active != null) return active;
    final pending = _activations[vmId];
    if (pending != null) {
      final controller = await pending;
      if (controller == null) throw VmNotFoundException(vmId);
      return controller;
    }
    _requireAccepting();
    return _restoreAndCreate(virtualMachine);
  }

  Future<VmController> _restoreAndCreate(VirtualMachine vm) async {
    final recovered = await _recovery?.restore(vm.metadata.id);
    if (recovered == null) return _createController(await _restoreState(vm));
    _requireAccepting();
    return _createController(
      recovered.executionState,
      acceptedIntentRevision: recovered.acceptedIntentRevision,
    );
  }

  VmController _createController(
    VmControllerState initialState, {
    int? acceptedIntentRevision,
  }) {
    _requireAccepting();
    final vmId = initialState.vmId;
    final active = _controllers[vmId];
    if (active != null) return active;
    final controller = VmController(
      initialState: initialState,
      initialAcceptedIntentRevision: acceptedIntentRevision,
      effectRunner: _effectRunner,
      timerScheduler: _timerSchedulerFactory(),
    );
    _controllers[vmId] = controller;
    return controller;
  }

  Future<void> _retire(VmId vmId, VmController controller) {
    final pending = _retirements[vmId];
    if (pending != null) return pending;
    late Future<void> retirement;
    retirement = controller
        .shutdown()
        .then((_) {
          if (identical(_controllers[vmId], controller)) {
            _controllers.remove(vmId);
          }
        })
        .whenComplete(() {
          if (identical(_retirements[vmId], retirement)) {
            _retirements.remove(vmId);
          }
        });
    _retirements[vmId] = retirement;
    return retirement;
  }

  Future<VmControllerState> _restoreState(VirtualMachine virtualMachine) async {
    final vmId = virtualMachine.metadata.id;
    final unfinished =
        (await _operations.list(
              resourceType: ResourceType.virtualMachine,
              resourceId: vmId,
            ))
            .where(
              (operation) =>
                  operation.state == OperationState.pending ||
                  operation.state == OperationState.running,
            )
            .toList();
    VmControllerOperation? selected;
    Operation? selectedRecord;
    final deleting = virtualMachine.status.phase == VmPhase.deleting;
    final desiredRunning =
        virtualMachine.status.desiredState == DesiredState.running;
    for (final operation in unfinished.reversed) {
      final kind = _operationKind(operation.type);
      final eligible =
          kind != null &&
          (deleting
              ? kind == VmOperationKind.delete
              : desiredRunning
              ? const {
                  VmOperationKind.start,
                  VmOperationKind.restart,
                  VmOperationKind.recovery,
                }.contains(kind)
              : kind == VmOperationKind.stop || kind == VmOperationKind.kill);
      if (selectedRecord == null && eligible) {
        selectedRecord = operation;
        selected = VmControllerOperation(
          id: operation.id,
          kind: kind,
          state: OperationState.running,
        );
      } else {
        await _failOrphan(operation);
      }
    }
    if (deleting && selectedRecord == null) {
      selectedRecord = await _operations.createAndStart(
        type: 'vm.delete.recovery',
        resourceType: ResourceType.virtualMachine,
        resourceId: vmId,
        requestId: _newRequestId(),
        cancellable: false,
        request: JsonObjectValue.fromJson(const {'recovery': true}),
      );
      selected = VmControllerOperation(
        id: selectedRecord.id,
        kind: VmOperationKind.delete,
        state: OperationState.running,
      );
    } else if (selectedRecord?.state == OperationState.pending) {
      selectedRecord = await _operations.start(selectedRecord!.id);
    }
    final status = virtualMachine.status;
    final deletionState = switch (status.phase) {
      VmPhase.deleted => VmDeletionState.deleted,
      VmPhase.deleting => VmDeletionState.deleting,
      _ => VmDeletionState.active,
    };
    return VmControllerState.initial(
      vmId: vmId,
      specGeneration: status.specGeneration,
      restartPolicy: virtualMachine.spec.restartPolicy,
    ).copyWith(
      desiredState: status.desiredState,
      phase: status.phase,
      observedGeneration: status.observedGeneration,
      restartRequired: status.restartRequired,
      driverGeneration: status.driverGeneration,
      deletionState: deletionState,
      currentOperation: selected,
      driverOperationId: selected?.id,
      lastError: status.lastError,
    );
  }

  Future<void> _failOrphan(Operation operation) async {
    if (operation.state == OperationState.pending) {
      await _operations.start(operation.id);
    }
    await _operations.fail(
      operation.id,
      error: OperationError(
        code: ErrorCode.vmOperationConflict,
        message: 'operation superseded during daemon reconciliation',
        retryable: false,
        details: JsonObjectValue.empty,
      ),
    );
  }

  void _requireAccepting() {
    if (!_accepting) throw const VmRegistryClosedException();
  }
}

bool _isDurablyDeleted(VmControllerState state) =>
    state.deletionState == VmDeletionState.deleted &&
    state.phase == VmPhase.deleted &&
    state.currentOperation?.kind == VmOperationKind.delete &&
    state.currentOperation?.state == OperationState.succeeded;

VmOperationKind? _operationKind(String type) {
  if (type.contains('delete')) return VmOperationKind.delete;
  if (type.contains('restart')) return VmOperationKind.restart;
  if (type.contains('recovery')) return VmOperationKind.recovery;
  if (type.contains('start')) return VmOperationKind.start;
  if (type.contains('stop')) return VmOperationKind.stop;
  if (type.contains('kill')) return VmOperationKind.kill;
  return null;
}
