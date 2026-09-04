import 'package:gaovm_models/gaovm_models.dart';

enum VmLeaseState { none, acquiring, held, releasing }

enum VmDeletionState { active, deleting, removingFiles, deleted }

enum VmOperationKind { start, stop, restart, recovery, delete }

final class VmControllerOperation {
  const VmControllerOperation({
    required this.id,
    required this.kind,
    required this.state,
  });

  final OperationId id;
  final VmOperationKind kind;
  final OperationState state;

  bool get isTerminal => switch (state) {
    OperationState.succeeded ||
    OperationState.failed ||
    OperationState.cancelled => true,
    OperationState.pending || OperationState.running => false,
  };

  VmControllerOperation copyWith({OperationState? state}) =>
      VmControllerOperation(id: id, kind: kind, state: state ?? this.state);
}

final class VmRetryState {
  VmRetryState({
    this.attempts = 0,
    this.maxAttempts = 5,
    this.scheduledDelay,
    this.stableResetGeneration,
    Iterable<DateTime> failureTimes = const [],
  }) : failureTimes = List<DateTime>.unmodifiable(failureTimes),
       assert(attempts >= 0),
       assert(maxAttempts > 0),
       assert(attempts <= maxAttempts);

  final int attempts;
  final int maxAttempts;
  final Duration? scheduledDelay;
  final int? stableResetGeneration;
  final List<DateTime> failureTimes;

  bool get retryScheduled => scheduledDelay != null;
}

final class VmControllerState {
  const VmControllerState({
    required this.vmId,
    required this.desiredState,
    required this.phase,
    required this.specGeneration,
    required this.observedGeneration,
    required this.restartRequired,
    required this.driverGeneration,
    required this.activeDriverGeneration,
    required this.activeSpecGeneration,
    required this.driverOperationId,
    required this.restartPolicy,
    required this.currentOperation,
    required this.retryState,
    required this.deletionState,
    required this.leaseState,
    required this.pendingRecoveryGeneration,
    required this.pendingRecoveryError,
    this.lastError,
  });

  factory VmControllerState.initial({
    required VmId vmId,
    required int specGeneration,
    required RestartPolicy restartPolicy,
    int maxRestartAttempts = 5,
  }) => VmControllerState(
    vmId: vmId,
    desiredState: DesiredState.stopped,
    phase: VmPhase.stopped,
    specGeneration: specGeneration,
    observedGeneration: 0,
    restartRequired: false,
    driverGeneration: 0,
    activeDriverGeneration: null,
    activeSpecGeneration: null,
    driverOperationId: null,
    restartPolicy: restartPolicy,
    currentOperation: null,
    retryState: VmRetryState(maxAttempts: maxRestartAttempts),
    deletionState: VmDeletionState.active,
    leaseState: VmLeaseState.none,
    pendingRecoveryGeneration: null,
    pendingRecoveryError: null,
  );

  final VmId vmId;
  final DesiredState desiredState;
  final VmPhase phase;
  final int specGeneration;
  final int observedGeneration;
  final bool restartRequired;
  final int driverGeneration;
  final int? activeDriverGeneration;
  final int? activeSpecGeneration;
  final OperationId? driverOperationId;
  final RestartPolicy restartPolicy;
  final VmControllerOperation? currentOperation;
  final VmRetryState retryState;
  final VmDeletionState deletionState;
  final VmLeaseState leaseState;
  final int? pendingRecoveryGeneration;
  final OperationError? pendingRecoveryError;
  final OperationError? lastError;

  VmControllerState copyWith({
    DesiredState? desiredState,
    VmPhase? phase,
    int? specGeneration,
    int? observedGeneration,
    bool? restartRequired,
    int? driverGeneration,
    int? activeDriverGeneration,
    bool clearActiveDriverGeneration = false,
    int? activeSpecGeneration,
    bool clearActiveSpecGeneration = false,
    OperationId? driverOperationId,
    bool clearDriverOperationId = false,
    RestartPolicy? restartPolicy,
    VmControllerOperation? currentOperation,
    bool clearCurrentOperation = false,
    VmRetryState? retryState,
    VmDeletionState? deletionState,
    VmLeaseState? leaseState,
    int? pendingRecoveryGeneration,
    bool clearPendingRecoveryGeneration = false,
    OperationError? pendingRecoveryError,
    bool clearPendingRecoveryError = false,
    OperationError? lastError,
    bool clearLastError = false,
  }) => VmControllerState(
    vmId: vmId,
    desiredState: desiredState ?? this.desiredState,
    phase: phase ?? this.phase,
    specGeneration: specGeneration ?? this.specGeneration,
    observedGeneration: observedGeneration ?? this.observedGeneration,
    restartRequired: restartRequired ?? this.restartRequired,
    driverGeneration: driverGeneration ?? this.driverGeneration,
    activeDriverGeneration: clearActiveDriverGeneration
        ? null
        : activeDriverGeneration ?? this.activeDriverGeneration,
    activeSpecGeneration: clearActiveSpecGeneration
        ? null
        : activeSpecGeneration ?? this.activeSpecGeneration,
    driverOperationId: clearDriverOperationId
        ? null
        : driverOperationId ?? this.driverOperationId,
    restartPolicy: restartPolicy ?? this.restartPolicy,
    currentOperation: clearCurrentOperation
        ? null
        : currentOperation ?? this.currentOperation,
    retryState: retryState ?? this.retryState,
    deletionState: deletionState ?? this.deletionState,
    leaseState: leaseState ?? this.leaseState,
    pendingRecoveryGeneration: clearPendingRecoveryGeneration
        ? null
        : pendingRecoveryGeneration ?? this.pendingRecoveryGeneration,
    pendingRecoveryError: clearPendingRecoveryError
        ? null
        : pendingRecoveryError ?? this.pendingRecoveryError,
    lastError: clearLastError ? null : lastError ?? this.lastError,
  );
}

sealed class VmCommand {
  const VmCommand();
}

final class StartRequested extends VmCommand {
  const StartRequested(this.operationId);

  final OperationId operationId;
}

final class StopRequested extends VmCommand {
  const StopRequested(this.operationId);

  final OperationId operationId;
}

final class RestartRequested extends VmCommand {
  const RestartRequested(this.operationId);

  final OperationId operationId;
}

final class DeleteRequested extends VmCommand {
  const DeleteRequested(this.operationId);

  final OperationId operationId;
}

final class SpecUpdated extends VmCommand {
  const SpecUpdated({
    required this.specGeneration,
    required this.restartPolicy,
    required this.restartRequired,
  });

  final int specGeneration;
  final RestartPolicy restartPolicy;
  final bool restartRequired;
}

final class ReconcileRequested extends VmCommand {
  const ReconcileRequested();
}

final class HostLeaseAcquired extends VmCommand {
  const HostLeaseAcquired(this.operationId);

  final OperationId operationId;
}

final class HostLeaseReleased extends VmCommand {
  const HostLeaseReleased(this.operationId);

  final OperationId operationId;
}

final class HostLeaseReleaseFailed extends VmCommand {
  const HostLeaseReleaseFailed(this.operationId, this.error);

  final OperationId operationId;
  final OperationError error;
}

final class HostLeaseFailed extends VmCommand {
  const HostLeaseFailed({required this.operationId, required this.error});

  final OperationId operationId;
  final OperationError error;
}

final class DriverSpawned extends VmCommand {
  const DriverSpawned({
    required this.operationId,
    required this.driverGeneration,
  });

  final OperationId operationId;
  final int driverGeneration;
}

final class DriverSpawnFailed extends VmCommand {
  const DriverSpawnFailed({
    required this.operationId,
    required this.driverGeneration,
    required this.error,
    this.occurredAt,
  });

  final OperationId operationId;
  final int driverGeneration;
  final OperationError error;
  final DateTime? occurredAt;
}

final class DriverHandshakeCompleted extends VmCommand {
  const DriverHandshakeCompleted({
    required this.operationId,
    required this.driverGeneration,
  });

  final OperationId operationId;
  final int driverGeneration;
}

final class DriverHandshakeFailed extends VmCommand {
  const DriverHandshakeFailed({
    required this.operationId,
    required this.driverGeneration,
    required this.error,
    this.occurredAt,
  });

  final OperationId operationId;
  final int driverGeneration;
  final OperationError error;
  final DateTime? occurredAt;
}

final class RecoveryOperationCreated extends VmCommand {
  const RecoveryOperationCreated({
    required this.operationId,
    required this.failedDriverGeneration,
  });

  final OperationId operationId;
  final int failedDriverGeneration;
}

final class StableWindowElapsed extends VmCommand {
  const StableWindowElapsed({
    required this.operationId,
    required this.driverGeneration,
  });

  final OperationId operationId;
  final int driverGeneration;
}

final class ManagedFilesRemoved extends VmCommand {
  const ManagedFilesRemoved(this.operationId);

  final OperationId operationId;
}

final class ManagedFilesRemovalFailed extends VmCommand {
  const ManagedFilesRemovalFailed(this.operationId, this.error);

  final OperationId operationId;
  final OperationError error;
}

enum RuntimeCommandKind { configure, start, stop, kill }

final class DriverCommandSucceeded extends VmCommand {
  const DriverCommandSucceeded({
    required this.operationId,
    required this.driverGeneration,
    required this.command,
  });

  final OperationId operationId;
  final int driverGeneration;
  final RuntimeCommandKind command;
}

final class DriverCommandFailed extends VmCommand {
  const DriverCommandFailed({
    required this.operationId,
    required this.driverGeneration,
    required this.command,
    required this.error,
  });

  final OperationId operationId;
  final int driverGeneration;
  final RuntimeCommandKind command;
  final OperationError error;
}

final class VmStateChanged extends VmCommand {
  const VmStateChanged({
    required this.operationId,
    required this.driverGeneration,
    required this.phase,
  });

  final OperationId operationId;
  final int driverGeneration;
  final VmPhase phase;
}

final class DriverExited extends VmCommand {
  const DriverExited({
    required this.operationId,
    required this.driverGeneration,
    required this.cleanShutdown,
    this.error,
    this.occurredAt,
  });

  final OperationId operationId;
  final int driverGeneration;
  final bool cleanShutdown;
  final OperationError? error;
  final DateTime? occurredAt;
}

final class DriverChannelClosed extends VmCommand {
  const DriverChannelClosed({
    required this.operationId,
    required this.driverGeneration,
    required this.error,
    this.occurredAt,
  });

  final OperationId operationId;
  final int driverGeneration;
  final OperationError error;
  final DateTime? occurredAt;
}

final class HeartbeatMissed extends VmCommand {
  const HeartbeatMissed({
    required this.operationId,
    required this.driverGeneration,
  });

  final OperationId operationId;
  final int driverGeneration;
}

final class RetryTimerFired extends VmCommand {
  const RetryTimerFired({
    required this.operationId,
    required this.driverGeneration,
  });

  final OperationId operationId;
  final int driverGeneration;
}

final class OperationCancelled extends VmCommand {
  const OperationCancelled(this.operationId);

  final OperationId operationId;
}

sealed class VmEffect {
  const VmEffect({
    required this.vmId,
    required this.operationId,
    this.driverGeneration,
  });

  final VmId vmId;
  final OperationId? operationId;
  final int? driverGeneration;
}

final class PersistVm extends VmEffect {
  const PersistVm({required super.vmId, required super.operationId});
}

final class AcquireHostLease extends VmEffect {
  const AcquireHostLease({required super.vmId, required super.operationId});
}

final class PersistRuntime extends VmEffect {
  const PersistRuntime({
    required super.vmId,
    required super.operationId,
    required super.driverGeneration,
  });
}

final class SpawnDriver extends VmEffect {
  const SpawnDriver({
    required super.vmId,
    required super.operationId,
    required super.driverGeneration,
  });
}

final class ConnectDriver extends VmEffect {
  const ConnectDriver({
    required super.vmId,
    required super.operationId,
    required super.driverGeneration,
  });
}

final class ConfigureRuntime extends VmEffect {
  const ConfigureRuntime({
    required super.vmId,
    required super.operationId,
    required super.driverGeneration,
  });
}

final class StartRuntime extends VmEffect {
  const StartRuntime({
    required super.vmId,
    required super.operationId,
    required super.driverGeneration,
  });
}

final class KillDriver extends VmEffect {
  const KillDriver({
    required super.vmId,
    required super.operationId,
    required super.driverGeneration,
  });
}

final class StopRuntime extends VmEffect {
  const StopRuntime({
    required super.vmId,
    required super.operationId,
    required super.driverGeneration,
  });
}

final class ReleaseHostLease extends VmEffect {
  const ReleaseHostLease({required super.vmId, required super.operationId});
}

final class ScheduleRetry extends VmEffect {
  const ScheduleRetry({
    required super.vmId,
    required super.operationId,
    required super.driverGeneration,
    required this.delay,
  });

  final Duration delay;
}

final class CancelRetry extends VmEffect {
  const CancelRetry({required super.vmId, required super.operationId});
}

final class CreateRecoveryOperation extends VmEffect {
  const CreateRecoveryOperation({
    required super.vmId,
    required super.operationId,
    required super.driverGeneration,
    required this.error,
  });

  final OperationError error;
}

final class ScheduleStableReset extends VmEffect {
  const ScheduleStableReset({
    required super.vmId,
    required super.operationId,
    required super.driverGeneration,
    this.delay = const Duration(seconds: 30),
  });

  final Duration delay;
}

final class RemoveManagedFiles extends VmEffect {
  const RemoveManagedFiles({required super.vmId, required super.operationId});
}

final class FailOperation extends VmEffect {
  const FailOperation({
    required super.vmId,
    required OperationId super.operationId,
    required this.error,
  });

  final OperationError error;
}

final class CompleteOperation extends VmEffect {
  const CompleteOperation({
    required super.vmId,
    required OperationId super.operationId,
    this.cancelled = false,
  });

  final bool cancelled;
}

final class EmitEvent extends VmEffect {
  const EmitEvent({
    required super.vmId,
    required super.operationId,
    super.driverGeneration,
    required this.type,
    this.payload,
  });

  final String type;
  final JsonObjectValue? payload;
}

final class VmTransition {
  VmTransition({required this.state, Iterable<VmEffect> effects = const []})
    : effects = List<VmEffect>.unmodifiable(effects);

  final VmControllerState state;
  final List<VmEffect> effects;
}

VmTransition reduce(VmControllerState state, VmCommand command) {
  return switch (command) {
    StartRequested(:final operationId) => _start(state, operationId),
    StopRequested(:final operationId) => _stop(state, operationId),
    RestartRequested(:final operationId) => _restart(state, operationId),
    DeleteRequested(:final operationId) => _delete(state, operationId),
    SpecUpdated(
      :final specGeneration,
      :final restartPolicy,
      :final restartRequired,
    ) =>
      _specUpdated(state, specGeneration, restartPolicy, restartRequired),
    ReconcileRequested() => _reconcile(state),
    HostLeaseAcquired(:final operationId) => _leaseAcquired(state, operationId),
    HostLeaseReleased(:final operationId) => _leaseReleased(state, operationId),
    HostLeaseReleaseFailed(:final operationId, :final error) =>
      _leaseReleaseFailed(state, operationId, error),
    HostLeaseFailed(:final operationId, :final error) => _leaseFailed(
      state,
      operationId,
      error,
    ),
    DriverSpawned(:final operationId, :final driverGeneration) =>
      _driverSpawned(state, operationId, driverGeneration),
    DriverSpawnFailed(
      :final operationId,
      :final driverGeneration,
      :final error,
      :final occurredAt,
    ) =>
      _runtimeSetupFailed(
        state,
        operationId,
        driverGeneration,
        error,
        occurredAt,
      ),
    DriverHandshakeCompleted(:final operationId, :final driverGeneration) =>
      _handshakeCompleted(state, operationId, driverGeneration),
    DriverHandshakeFailed(
      :final operationId,
      :final driverGeneration,
      :final error,
      :final occurredAt,
    ) =>
      _runtimeSetupFailed(
        state,
        operationId,
        driverGeneration,
        error,
        occurredAt,
      ),
    RecoveryOperationCreated(
      :final operationId,
      :final failedDriverGeneration,
    ) =>
      _recoveryOperationCreated(state, operationId, failedDriverGeneration),
    StableWindowElapsed(:final operationId, :final driverGeneration) =>
      _stableWindowElapsed(state, operationId, driverGeneration),
    ManagedFilesRemoved(:final operationId) => _managedFilesRemoved(
      state,
      operationId,
    ),
    ManagedFilesRemovalFailed(:final operationId, :final error) =>
      _managedFilesRemovalFailed(state, operationId, error),
    DriverCommandSucceeded(
      :final operationId,
      :final driverGeneration,
      :final command,
    ) =>
      _driverCommandSucceeded(state, operationId, driverGeneration, command),
    DriverCommandFailed(
      :final operationId,
      :final driverGeneration,
      :final command,
      :final error,
    ) =>
      _driverCommandFailed(
        state,
        operationId,
        driverGeneration,
        command,
        error,
      ),
    VmStateChanged(:final operationId, :final driverGeneration, :final phase) =>
      _vmStateChanged(state, operationId, driverGeneration, phase),
    DriverExited(
      :final operationId,
      :final driverGeneration,
      :final cleanShutdown,
      :final error,
      :final occurredAt,
    ) =>
      _driverExited(
        state,
        operationId,
        driverGeneration,
        cleanShutdown: cleanShutdown,
        error: error,
        occurredAt: occurredAt,
      ),
    DriverChannelClosed(
      :final operationId,
      :final driverGeneration,
      :final error,
      :final occurredAt,
    ) =>
      _driverExited(
        state,
        operationId,
        driverGeneration,
        cleanShutdown: false,
        error: error,
        occurredAt: occurredAt,
      ),
    HeartbeatMissed(:final operationId, :final driverGeneration) =>
      _heartbeatMissed(state, operationId, driverGeneration),
    RetryTimerFired(:final operationId, :final driverGeneration) =>
      _retryTimerFired(state, operationId, driverGeneration),
    OperationCancelled(:final operationId) => _operationCancelled(
      state,
      operationId,
    ),
  };
}

VmTransition _start(VmControllerState state, OperationId operationId) {
  if (state.deletionState != VmDeletionState.active) {
    return VmTransition(
      state: state,
      effects: [
        FailOperation(
          vmId: state.vmId,
          operationId: operationId,
          error: _deletedVmError,
        ),
      ],
    );
  }
  if (state.desiredState == DesiredState.running &&
      state.phase == VmPhase.running &&
      state.activeDriverGeneration != null) {
    return VmTransition(
      state: state,
      effects: [CompleteOperation(vmId: state.vmId, operationId: operationId)],
    );
  }
  if (state.currentOperation case final current? when !current.isTerminal) {
    return VmTransition(
      state: state,
      effects: [
        FailOperation(
          vmId: state.vmId,
          operationId: operationId,
          error: _operationConflictError,
        ),
      ],
    );
  }
  if (state.activeDriverGeneration == null &&
      state.leaseState == VmLeaseState.releasing) {
    final next = state.copyWith(
      desiredState: DesiredState.running,
      phase: VmPhase.stopped,
      currentOperation: VmControllerOperation(
        id: operationId,
        kind: VmOperationKind.start,
        state: OperationState.running,
      ),
      driverOperationId: operationId,
      retryState: VmRetryState(maxAttempts: state.retryState.maxAttempts),
      clearPendingRecoveryGeneration: true,
      clearPendingRecoveryError: true,
      clearLastError: true,
    );
    return VmTransition(
      state: next,
      effects: [PersistVm(vmId: state.vmId, operationId: operationId)],
    );
  }
  if (state.activeDriverGeneration == null &&
      state.leaseState != VmLeaseState.none) {
    return VmTransition(
      state: state,
      effects: [
        FailOperation(
          vmId: state.vmId,
          operationId: operationId,
          error: _operationConflictError,
        ),
      ],
    );
  }
  final next = state.copyWith(
    desiredState: DesiredState.running,
    currentOperation: VmControllerOperation(
      id: operationId,
      kind: VmOperationKind.start,
      state: OperationState.running,
    ),
    retryState: VmRetryState(maxAttempts: state.retryState.maxAttempts),
    leaseState: VmLeaseState.acquiring,
    clearLastError: true,
    clearPendingRecoveryGeneration: true,
    clearPendingRecoveryError: true,
  );
  return VmTransition(
    state: next,
    effects: [
      PersistVm(vmId: state.vmId, operationId: operationId),
      AcquireHostLease(vmId: state.vmId, operationId: operationId),
    ],
  );
}

VmTransition _delete(VmControllerState state, OperationId operationId) {
  if (state.deletionState == VmDeletionState.deleted) {
    return VmTransition(
      state: state,
      effects: [CompleteOperation(vmId: state.vmId, operationId: operationId)],
    );
  }
  final previous = state.currentOperation;
  final operation = VmControllerOperation(
    id: operationId,
    kind: VmOperationKind.delete,
    state: OperationState.running,
  );
  final activeGeneration = state.activeDriverGeneration;
  if (activeGeneration != null) {
    final next = state.copyWith(
      desiredState: DesiredState.stopped,
      phase: VmPhase.deleting,
      deletionState: VmDeletionState.deleting,
      currentOperation: operation,
      driverOperationId: operationId,
      retryState: VmRetryState(maxAttempts: state.retryState.maxAttempts),
      clearPendingRecoveryGeneration: true,
      clearPendingRecoveryError: true,
    );
    return VmTransition(
      state: next,
      effects: [
        if (state.retryState.retryScheduled)
          CancelRetry(vmId: state.vmId, operationId: operationId),
        if (previous != null && !previous.isTerminal)
          FailOperation(
            vmId: state.vmId,
            operationId: previous.id,
            error: _operationSupersededError,
          ),
        PersistVm(vmId: state.vmId, operationId: operationId),
        PersistRuntime(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: activeGeneration,
        ),
        if (state.phase == VmPhase.running)
          StopRuntime(
            vmId: state.vmId,
            operationId: operationId,
            driverGeneration: activeGeneration,
          )
        else
          KillDriver(
            vmId: state.vmId,
            operationId: operationId,
            driverGeneration: activeGeneration,
          ),
      ],
    );
  }
  if (state.leaseState != VmLeaseState.none) {
    return VmTransition(
      state: state.copyWith(
        desiredState: DesiredState.stopped,
        phase: VmPhase.deleting,
        deletionState: VmDeletionState.deleting,
        currentOperation: operation,
        leaseState: VmLeaseState.releasing,
        retryState: VmRetryState(maxAttempts: state.retryState.maxAttempts),
        clearPendingRecoveryGeneration: true,
        clearPendingRecoveryError: true,
      ),
      effects: [
        if (state.retryState.retryScheduled)
          CancelRetry(vmId: state.vmId, operationId: operationId),
        if (previous != null && !previous.isTerminal)
          FailOperation(
            vmId: state.vmId,
            operationId: previous.id,
            error: _operationSupersededError,
          ),
        PersistVm(vmId: state.vmId, operationId: operationId),
        ReleaseHostLease(vmId: state.vmId, operationId: operationId),
      ],
    );
  }
  return VmTransition(
    state: state.copyWith(
      desiredState: DesiredState.stopped,
      phase: VmPhase.deleting,
      deletionState: VmDeletionState.removingFiles,
      currentOperation: operation,
      clearActiveDriverGeneration: true,
      clearActiveSpecGeneration: true,
      clearDriverOperationId: true,
      leaseState: VmLeaseState.none,
      retryState: VmRetryState(maxAttempts: state.retryState.maxAttempts),
      clearPendingRecoveryGeneration: true,
      clearPendingRecoveryError: true,
    ),
    effects: [
      if (state.retryState.retryScheduled)
        CancelRetry(vmId: state.vmId, operationId: operationId),
      if (previous != null && !previous.isTerminal)
        FailOperation(
          vmId: state.vmId,
          operationId: previous.id,
          error: _operationSupersededError,
        ),
      PersistVm(vmId: state.vmId, operationId: operationId),
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: state.driverGeneration,
      ),
      RemoveManagedFiles(vmId: state.vmId, operationId: operationId),
    ],
  );
}

VmTransition _specUpdated(
  VmControllerState state,
  int specGeneration,
  RestartPolicy restartPolicy,
  bool restartRequired,
) {
  if (specGeneration <= state.specGeneration ||
      state.deletionState == VmDeletionState.deleted) {
    return VmTransition(state: state);
  }
  final operationId = state.driverOperationId ?? state.currentOperation?.id;
  final next = state.copyWith(
    specGeneration: specGeneration,
    restartPolicy: restartPolicy,
    restartRequired:
        state.restartRequired ||
        state.activeDriverGeneration != null && restartRequired,
  );
  return VmTransition(
    state: next,
    effects: [
      PersistVm(vmId: state.vmId, operationId: operationId),
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: state.activeDriverGeneration,
      ),
      EmitEvent(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: state.activeDriverGeneration,
        type: 'vm.spec_updated',
      ),
    ],
  );
}

VmTransition _managedFilesRemoved(
  VmControllerState state,
  OperationId operationId,
) {
  final operation = state.currentOperation;
  if (state.deletionState != VmDeletionState.removingFiles ||
      operation?.id != operationId ||
      operation!.kind != VmOperationKind.delete ||
      operation.isTerminal) {
    return VmTransition(state: state);
  }
  final completed = operation.copyWith(state: OperationState.succeeded);
  return VmTransition(
    state: state.copyWith(
      phase: VmPhase.deleted,
      deletionState: VmDeletionState.deleted,
      currentOperation: completed,
    ),
    effects: [
      PersistVm(vmId: state.vmId, operationId: operationId),
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: state.driverGeneration,
      ),
      CompleteOperation(vmId: state.vmId, operationId: operationId),
      EmitEvent(vmId: state.vmId, operationId: operationId, type: 'vm.deleted'),
    ],
  );
}

VmTransition _managedFilesRemovalFailed(
  VmControllerState state,
  OperationId operationId,
  OperationError error,
) {
  final operation = state.currentOperation;
  if (state.deletionState != VmDeletionState.removingFiles ||
      operation?.id != operationId ||
      operation!.isTerminal) {
    return VmTransition(state: state);
  }
  return VmTransition(
    state: state.copyWith(
      phase: VmPhase.failed,
      deletionState: VmDeletionState.deleting,
      currentOperation: operation.copyWith(state: OperationState.failed),
      lastError: error,
    ),
    effects: [
      PersistVm(vmId: state.vmId, operationId: operationId),
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: state.driverGeneration,
      ),
      FailOperation(vmId: state.vmId, operationId: operationId, error: error),
      EmitEvent(
        vmId: state.vmId,
        operationId: operationId,
        type: 'vm.delete_failed',
      ),
    ],
  );
}

VmTransition _reconcile(VmControllerState state) {
  if (state.deletionState == VmDeletionState.deleted) {
    return VmTransition(state: state);
  }
  if (state.deletionState == VmDeletionState.removingFiles ||
      state.deletionState == VmDeletionState.deleting &&
          state.activeDriverGeneration == null &&
          state.leaseState == VmLeaseState.none) {
    final operationId = state.currentOperation?.id;
    if (operationId == null || state.currentOperation!.isTerminal) {
      return VmTransition(state: state);
    }
    return VmTransition(
      state: state.copyWith(
        phase: VmPhase.deleting,
        deletionState: VmDeletionState.removingFiles,
      ),
      effects: [RemoveManagedFiles(vmId: state.vmId, operationId: operationId)],
    );
  }
  final currentOperation = state.currentOperation;
  final operationId = currentOperation != null && !currentOperation.isTerminal
      ? currentOperation.id
      : null;
  if (state.desiredState == DesiredState.running) {
    if (state.activeDriverGeneration != null ||
        state.leaseState != VmLeaseState.none ||
        state.retryState.retryScheduled) {
      return VmTransition(state: state);
    }
    if (operationId == null) {
      return VmTransition(
        state: state.copyWith(
          phase: VmPhase.stopped,
          pendingRecoveryGeneration: state.driverGeneration,
          pendingRecoveryError: _reconcileError,
          retryState: VmRetryState(
            attempts: state.retryState.attempts,
            maxAttempts: state.retryState.maxAttempts,
            scheduledDelay: Duration.zero,
            failureTimes: state.retryState.failureTimes,
          ),
        ),
        effects: [
          CreateRecoveryOperation(
            vmId: state.vmId,
            operationId: null,
            driverGeneration: state.driverGeneration,
            error: _reconcileError,
          ),
        ],
      );
    }
    return VmTransition(
      state: state.copyWith(
        phase: VmPhase.stopped,
        leaseState: VmLeaseState.acquiring,
      ),
      effects: [
        PersistRuntime(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: state.driverGeneration,
        ),
        AcquireHostLease(vmId: state.vmId, operationId: operationId),
      ],
    );
  }
  if (state.activeDriverGeneration case final generation?) {
    return VmTransition(
      state: state.copyWith(
        phase: state.deletionState == VmDeletionState.deleting
            ? VmPhase.deleting
            : VmPhase.stopping,
        driverOperationId: operationId,
        retryState: VmRetryState(
          attempts: state.retryState.attempts,
          maxAttempts: state.retryState.maxAttempts,
        ),
      ),
      effects: [
        PersistRuntime(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: generation,
        ),
        if (state.phase == VmPhase.running)
          StopRuntime(
            vmId: state.vmId,
            operationId: operationId,
            driverGeneration: generation,
          )
        else
          KillDriver(
            vmId: state.vmId,
            operationId: operationId,
            driverGeneration: generation,
          ),
      ],
    );
  }
  if (state.leaseState == VmLeaseState.acquiring ||
      state.leaseState == VmLeaseState.held) {
    return VmTransition(
      state: state.copyWith(leaseState: VmLeaseState.releasing),
      effects: [ReleaseHostLease(vmId: state.vmId, operationId: operationId)],
    );
  }
  return VmTransition(state: state);
}

VmTransition _stop(VmControllerState state, OperationId operationId) {
  if (state.currentOperation case final current?
      when !current.isTerminal && current.kind == VmOperationKind.stop) {
    return VmTransition(
      state: state,
      effects: [
        FailOperation(
          vmId: state.vmId,
          operationId: operationId,
          error: _operationConflictError,
        ),
      ],
    );
  }
  if (state.retryState.retryScheduled &&
      state.activeDriverGeneration == null &&
      (state.leaseState == VmLeaseState.none ||
          state.leaseState == VmLeaseState.releasing)) {
    final previous = state.currentOperation;
    final completed = VmControllerOperation(
      id: operationId,
      kind: VmOperationKind.stop,
      state: OperationState.succeeded,
    );
    return VmTransition(
      state: state.copyWith(
        desiredState: DesiredState.stopped,
        phase: VmPhase.stopped,
        currentOperation: completed,
        retryState: VmRetryState(maxAttempts: state.retryState.maxAttempts),
        clearDriverOperationId: true,
        clearPendingRecoveryGeneration: true,
        clearPendingRecoveryError: true,
      ),
      effects: [
        CancelRetry(vmId: state.vmId, operationId: operationId),
        if (previous != null && !previous.isTerminal)
          FailOperation(
            vmId: state.vmId,
            operationId: previous.id,
            error: _operationSupersededError,
          ),
        PersistVm(vmId: state.vmId, operationId: operationId),
        PersistRuntime(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: state.driverGeneration,
        ),
        CompleteOperation(vmId: state.vmId, operationId: operationId),
        EmitEvent(
          vmId: state.vmId,
          operationId: operationId,
          type: 'vm.stopped',
        ),
      ],
    );
  }
  if (state.desiredState == DesiredState.stopped &&
      state.activeDriverGeneration == null &&
      state.leaseState == VmLeaseState.none) {
    return VmTransition(
      state: state,
      effects: [CompleteOperation(vmId: state.vmId, operationId: operationId)],
    );
  }
  final previous = state.currentOperation;
  final releasesLease =
      state.activeDriverGeneration == null &&
      state.leaseState != VmLeaseState.none;
  final next = state.copyWith(
    desiredState: DesiredState.stopped,
    phase: VmPhase.stopping,
    driverOperationId: operationId,
    leaseState: releasesLease ? VmLeaseState.releasing : state.leaseState,
    currentOperation: VmControllerOperation(
      id: operationId,
      kind: VmOperationKind.stop,
      state: OperationState.running,
    ),
    clearPendingRecoveryGeneration: true,
    clearPendingRecoveryError: true,
  );
  return VmTransition(
    state: next,
    effects: [
      if (previous != null && !previous.isTerminal)
        FailOperation(
          vmId: state.vmId,
          operationId: previous.id,
          error: _operationSupersededError,
        ),
      PersistVm(vmId: state.vmId, operationId: operationId),
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: state.activeDriverGeneration,
      ),
      if (state.activeDriverGeneration case final generation?)
        if (state.phase == VmPhase.running)
          StopRuntime(
            vmId: state.vmId,
            operationId: operationId,
            driverGeneration: generation,
          )
        else
          KillDriver(
            vmId: state.vmId,
            operationId: operationId,
            driverGeneration: generation,
          )
      else if (releasesLease)
        ReleaseHostLease(vmId: state.vmId, operationId: operationId),
    ],
  );
}

VmTransition _restart(VmControllerState state, OperationId operationId) {
  if (state.currentOperation case final current?
      when !current.isTerminal && current.kind == VmOperationKind.restart) {
    return VmTransition(
      state: state,
      effects: [
        FailOperation(
          vmId: state.vmId,
          operationId: operationId,
          error: _operationConflictError,
        ),
      ],
    );
  }
  if (state.deletionState != VmDeletionState.active) {
    return VmTransition(
      state: state,
      effects: [
        FailOperation(
          vmId: state.vmId,
          operationId: operationId,
          error: _deletedVmError,
        ),
      ],
    );
  }
  if (state.activeDriverGeneration == null &&
      state.leaseState == VmLeaseState.none) {
    final started = _start(state, operationId);
    final current = started.state.currentOperation;
    return VmTransition(
      state: started.state.copyWith(
        currentOperation:
            current != null && current.kind == VmOperationKind.start
            ? VmControllerOperation(
                id: operationId,
                kind: VmOperationKind.restart,
                state: OperationState.running,
              )
            : current,
      ),
      effects: started.effects,
    );
  }
  if (state.activeDriverGeneration == null &&
      state.leaseState == VmLeaseState.releasing) {
    final previous = state.currentOperation;
    return VmTransition(
      state: state.copyWith(
        desiredState: DesiredState.running,
        phase: VmPhase.stopped,
        driverOperationId: operationId,
        currentOperation: VmControllerOperation(
          id: operationId,
          kind: VmOperationKind.restart,
          state: OperationState.running,
        ),
        retryState: VmRetryState(maxAttempts: state.retryState.maxAttempts),
        clearLastError: true,
        clearPendingRecoveryGeneration: true,
        clearPendingRecoveryError: true,
      ),
      effects: [
        if (previous != null && !previous.isTerminal)
          FailOperation(
            vmId: state.vmId,
            operationId: previous.id,
            error: _operationSupersededError,
          ),
        PersistVm(vmId: state.vmId, operationId: operationId),
      ],
    );
  }
  if (state.activeDriverGeneration == null &&
      state.leaseState != VmLeaseState.none) {
    return VmTransition(
      state: state,
      effects: [
        FailOperation(
          vmId: state.vmId,
          operationId: operationId,
          error: _operationConflictError,
        ),
      ],
    );
  }
  final previous = state.currentOperation;
  final next = state.copyWith(
    desiredState: DesiredState.running,
    phase: VmPhase.stopping,
    driverOperationId: operationId,
    currentOperation: VmControllerOperation(
      id: operationId,
      kind: VmOperationKind.restart,
      state: OperationState.running,
    ),
    retryState: VmRetryState(maxAttempts: state.retryState.maxAttempts),
    clearLastError: true,
    clearPendingRecoveryGeneration: true,
    clearPendingRecoveryError: true,
  );
  return VmTransition(
    state: next,
    effects: [
      if (previous != null && !previous.isTerminal)
        FailOperation(
          vmId: state.vmId,
          operationId: previous.id,
          error: _operationSupersededError,
        ),
      PersistVm(vmId: state.vmId, operationId: operationId),
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: state.activeDriverGeneration,
      ),
      if (state.activeDriverGeneration case final generation?)
        StopRuntime(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: generation,
        )
      else
        AcquireHostLease(vmId: state.vmId, operationId: operationId),
    ],
  );
}

VmTransition _leaseFailed(
  VmControllerState state,
  OperationId operationId,
  OperationError error,
) {
  final operation = state.currentOperation;
  if (state.leaseState != VmLeaseState.acquiring ||
      operation?.id != operationId ||
      operation!.isTerminal) {
    return VmTransition(state: state);
  }
  final failed = operation.copyWith(state: OperationState.failed);
  return VmTransition(
    state: state.copyWith(
      desiredState: DesiredState.stopped,
      phase: VmPhase.failed,
      leaseState: VmLeaseState.none,
      currentOperation: failed,
      lastError: error,
    ),
    effects: [
      PersistVm(vmId: state.vmId, operationId: operationId),
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: state.driverGeneration,
      ),
      FailOperation(vmId: state.vmId, operationId: operationId, error: error),
      EmitEvent(
        vmId: state.vmId,
        operationId: operationId,
        type: 'vm.start_failed',
      ),
    ],
  );
}

VmTransition _leaseReleased(VmControllerState state, OperationId operationId) {
  final operation = state.currentOperation;
  if (state.leaseState == VmLeaseState.releasing &&
      operation == null &&
      state.pendingRecoveryGeneration != null) {
    return VmTransition(
      state: state.copyWith(leaseState: VmLeaseState.none),
      effects: [
        PersistRuntime(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: state.driverGeneration,
        ),
      ],
    );
  }
  final acceptsSupersedingOperation =
      operation != null &&
      (state.desiredState == DesiredState.running &&
              const {
                VmOperationKind.start,
                VmOperationKind.restart,
                VmOperationKind.recovery,
              }.contains(operation.kind) ||
          state.desiredState == DesiredState.stopped &&
              const {
                VmOperationKind.stop,
                VmOperationKind.delete,
              }.contains(operation.kind));
  if (state.leaseState != VmLeaseState.releasing ||
      operation == null ||
      operation.id != operationId && !acceptsSupersedingOperation) {
    return VmTransition(state: state);
  }
  final activeOperation = operation;
  final activeOperationId = activeOperation.id;
  if (activeOperation.kind == VmOperationKind.delete &&
      !activeOperation.isTerminal) {
    return VmTransition(
      state: state.copyWith(
        phase: VmPhase.deleting,
        deletionState: VmDeletionState.removingFiles,
        leaseState: VmLeaseState.none,
        clearDriverOperationId: true,
      ),
      effects: [
        PersistVm(vmId: state.vmId, operationId: activeOperationId),
        PersistRuntime(
          vmId: state.vmId,
          operationId: activeOperationId,
          driverGeneration: state.driverGeneration,
        ),
        RemoveManagedFiles(vmId: state.vmId, operationId: activeOperationId),
      ],
    );
  }
  if (state.retryState.scheduledDelay case final delay?) {
    final retryOperationId = activeOperation.id;
    return VmTransition(
      state: state.copyWith(leaseState: VmLeaseState.none),
      effects: [
        PersistRuntime(
          vmId: state.vmId,
          operationId: retryOperationId,
          driverGeneration: state.driverGeneration,
        ),
        ScheduleRetry(
          vmId: state.vmId,
          operationId: retryOperationId,
          driverGeneration: state.driverGeneration,
          delay: delay,
        ),
      ],
    );
  }
  if (const {
        VmOperationKind.start,
        VmOperationKind.restart,
        VmOperationKind.recovery,
      }.contains(activeOperation.kind) &&
      !activeOperation.isTerminal &&
      state.desiredState == DesiredState.running) {
    final nextOperationId = activeOperation.id;
    return VmTransition(
      state: state.copyWith(
        phase: VmPhase.stopped,
        leaseState: VmLeaseState.acquiring,
      ),
      effects: [
        PersistRuntime(
          vmId: state.vmId,
          operationId: nextOperationId,
          driverGeneration: state.driverGeneration,
        ),
        AcquireHostLease(vmId: state.vmId, operationId: nextOperationId),
      ],
    );
  }
  if (activeOperation.isTerminal) {
    return VmTransition(
      state: state.copyWith(leaseState: VmLeaseState.none),
      effects: [
        PersistRuntime(
          vmId: state.vmId,
          operationId: activeOperationId,
          driverGeneration: state.driverGeneration,
        ),
        EmitEvent(
          vmId: state.vmId,
          operationId: activeOperationId,
          type: state.phase == VmPhase.failed ? 'vm.failed' : 'vm.stopped',
        ),
      ],
    );
  }
  final completed = activeOperation.copyWith(state: OperationState.succeeded);
  final next = state.copyWith(
    phase: VmPhase.stopped,
    leaseState: VmLeaseState.none,
    currentOperation: completed,
  );
  return VmTransition(
    state: next,
    effects: [
      PersistRuntime(
        vmId: state.vmId,
        operationId: activeOperationId,
        driverGeneration: state.driverGeneration,
      ),
      CompleteOperation(vmId: state.vmId, operationId: activeOperationId),
      EmitEvent(
        vmId: state.vmId,
        operationId: activeOperationId,
        type: 'vm.stopped',
      ),
    ],
  );
}

VmTransition _leaseAcquired(VmControllerState state, OperationId operationId) {
  if (state.leaseState != VmLeaseState.acquiring ||
      state.currentOperation?.id != operationId) {
    return VmTransition(state: state);
  }
  final generation = state.driverGeneration + 1;
  final next = state.copyWith(
    phase: VmPhase.spawningDriver,
    driverGeneration: generation,
    activeDriverGeneration: generation,
    activeSpecGeneration: state.specGeneration,
    driverOperationId: operationId,
    leaseState: VmLeaseState.held,
  );
  return VmTransition(
    state: next,
    effects: [
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: generation,
      ),
      SpawnDriver(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: generation,
      ),
    ],
  );
}

VmTransition _driverSpawned(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
) {
  if (!_matchesRuntimeCallback(state, operationId, driverGeneration) ||
      state.phase != VmPhase.spawningDriver) {
    return VmTransition(state: state);
  }
  return VmTransition(
    state: state.copyWith(phase: VmPhase.handshaking),
    effects: [
      ConnectDriver(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
      ),
    ],
  );
}

VmTransition _handshakeCompleted(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
) {
  if (!_matchesRuntimeCallback(state, operationId, driverGeneration) ||
      state.phase != VmPhase.handshaking) {
    return VmTransition(state: state);
  }
  return VmTransition(
    state: state.copyWith(phase: VmPhase.configuring),
    effects: [
      ConfigureRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
      ),
    ],
  );
}

VmTransition _driverCommandSucceeded(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
  RuntimeCommandKind command,
) {
  if (!_matchesRuntimeCallback(state, operationId, driverGeneration)) {
    return VmTransition(state: state);
  }
  if (command != RuntimeCommandKind.configure ||
      state.phase != VmPhase.configuring) {
    return VmTransition(state: state);
  }
  return VmTransition(
    state: state.copyWith(phase: VmPhase.starting),
    effects: [
      StartRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
      ),
    ],
  );
}

VmTransition _driverCommandFailed(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
  RuntimeCommandKind command,
  OperationError error,
) {
  if (!_matchesRuntimeCallback(state, operationId, driverGeneration)) {
    return VmTransition(state: state);
  }
  return _markDriverUnhealthy(
    state,
    operationId,
    driverGeneration,
    error,
    eventType: 'vm.driver_command_failed.${command.name}',
  );
}

VmTransition _heartbeatMissed(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
) {
  if (!_matchesRuntimeCallback(state, operationId, driverGeneration)) {
    return VmTransition(state: state);
  }
  return _markDriverUnhealthy(
    state,
    operationId,
    driverGeneration,
    _heartbeatError,
    eventType: 'vm.driver_unhealthy',
  );
}

VmTransition _markDriverUnhealthy(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
  OperationError error, {
  required String eventType,
}) {
  if (const {
    VmPhase.crashed,
    VmPhase.failed,
    VmPhase.stopping,
    VmPhase.deleting,
    VmPhase.deleted,
  }.contains(state.phase)) {
    return VmTransition(state: state);
  }
  return VmTransition(
    state: state.copyWith(phase: VmPhase.crashed, lastError: error),
    effects: [
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
      ),
      KillDriver(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
      ),
      EmitEvent(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
        type: eventType,
      ),
    ],
  );
}

VmTransition _vmStateChanged(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
  VmPhase phase,
) {
  if (!_matchesRuntimeCallback(state, operationId, driverGeneration)) {
    return VmTransition(state: state);
  }
  if (state.phase == phase || !_allowsPhaseTransition(state.phase, phase)) {
    return VmTransition(state: state);
  }
  if (phase != VmPhase.running) {
    return VmTransition(
      state: state.copyWith(phase: phase),
      effects: [
        PersistRuntime(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: driverGeneration,
        ),
        EmitEvent(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: driverGeneration,
          type: 'vm.state_changed',
        ),
      ],
    );
  }
  final operationKind = state.currentOperation?.kind;
  if (state.desiredState != DesiredState.running ||
      operationKind == VmOperationKind.stop ||
      operationKind == VmOperationKind.delete ||
      state.currentOperation?.state == OperationState.cancelled) {
    return VmTransition(state: state);
  }
  final currentOperation = state.currentOperation;
  final completesOperation =
      currentOperation != null &&
      currentOperation.id == operationId &&
      !currentOperation.isTerminal &&
      currentOperation.kind != VmOperationKind.recovery;
  final operation = completesOperation
      ? currentOperation.copyWith(state: OperationState.succeeded)
      : currentOperation;
  final appliedGeneration =
      state.activeSpecGeneration ?? state.observedGeneration;
  final recoveryRunning =
      currentOperation?.kind == VmOperationKind.recovery &&
      currentOperation?.state == OperationState.running;
  final next = state.copyWith(
    phase: VmPhase.running,
    observedGeneration: appliedGeneration,
    restartRequired: appliedGeneration < state.specGeneration,
    currentOperation: operation,
    retryState: VmRetryState(
      attempts: state.retryState.attempts,
      maxAttempts: state.retryState.maxAttempts,
      stableResetGeneration: recoveryRunning ? driverGeneration : null,
      failureTimes: state.retryState.failureTimes,
    ),
  );
  return VmTransition(
    state: next,
    effects: [
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
      ),
      if (completesOperation)
        CompleteOperation(vmId: state.vmId, operationId: operationId),
      if (recoveryRunning)
        ScheduleStableReset(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: driverGeneration,
        ),
      EmitEvent(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
        type: 'vm.running',
      ),
    ],
  );
}

VmTransition _driverExited(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration, {
  required bool cleanShutdown,
  OperationError? error,
  DateTime? occurredAt,
}) {
  if (!_matchesRuntimeCallback(state, operationId, driverGeneration)) {
    return VmTransition(state: state);
  }
  final operation = state.currentOperation;
  final explicitLifecycle =
      operation?.id == operationId &&
      !operation!.isTerminal &&
      (operation.kind == VmOperationKind.stop ||
          operation.kind == VmOperationKind.delete ||
          operation.kind == VmOperationKind.restart &&
              state.phase == VmPhase.stopping);
  if (explicitLifecycle) {
    final next = state.copyWith(
      clearActiveDriverGeneration: true,
      clearActiveSpecGeneration: true,
      leaseState: VmLeaseState.releasing,
      lastError: error,
    );
    return VmTransition(
      state: next,
      effects: [
        PersistRuntime(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: driverGeneration,
        ),
        ReleaseHostLease(vmId: state.vmId, operationId: operationId),
      ],
    );
  }

  if (state.desiredState == DesiredState.stopped &&
      operation?.state == OperationState.cancelled) {
    return VmTransition(
      state: state.copyWith(
        clearActiveDriverGeneration: true,
        clearActiveSpecGeneration: true,
        phase: VmPhase.stopped,
        leaseState: VmLeaseState.releasing,
      ),
      effects: [
        PersistRuntime(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: driverGeneration,
        ),
        ReleaseHostLease(vmId: state.vmId, operationId: operationId),
      ],
    );
  }

  final shouldRestart =
      state.desiredState == DesiredState.running &&
      state.deletionState == VmDeletionState.active &&
      (state.restartPolicy == RestartPolicy.always ||
          !cleanShutdown && state.restartPolicy == RestartPolicy.onFailure);
  final exitError = error ?? _driverExitedError;
  final recentFailures = occurredAt == null
      ? state.retryState.failureTimes
      : state.retryState.failureTimes
            .where(
              (failure) =>
                  !failure.isAfter(occurredAt) &&
                  occurredAt.difference(failure) <= const Duration(minutes: 5),
            )
            .toList(growable: false);
  final attemptsBeforeFailure = occurredAt == null
      ? state.retryState.attempts
      : recentFailures.length;
  if (shouldRestart &&
      attemptsBeforeFailure >= state.retryState.maxAttempts &&
      operation != null &&
      !operation.isTerminal) {
    return _permanentFailure(state, operationId, driverGeneration, exitError);
  }

  final needsRecoveryOperation =
      shouldRestart && (operation == null || operation.isTerminal);
  final retryBudgetExhausted =
      shouldRestart && attemptsBeforeFailure >= state.retryState.maxAttempts;
  final retryState = shouldRestart
      ? VmRetryState(
          attempts: retryBudgetExhausted
              ? attemptsBeforeFailure
              : attemptsBeforeFailure + 1,
          maxAttempts: state.retryState.maxAttempts,
          scheduledDelay: retryBudgetExhausted
              ? null
              : _retryDelay(attemptsBeforeFailure + 1),
          failureTimes: occurredAt == null
              ? recentFailures
              : [...recentFailures, if (!retryBudgetExhausted) occurredAt],
        )
      : VmRetryState(
          attempts: state.retryState.attempts,
          maxAttempts: state.retryState.maxAttempts,
          failureTimes: state.retryState.failureTimes,
        );
  final failedOperation =
      !shouldRestart && operation != null && !operation.isTerminal
      ? operation.copyWith(state: OperationState.failed)
      : operation;
  final next = state.copyWith(
    clearActiveDriverGeneration: true,
    clearActiveSpecGeneration: true,
    desiredState: shouldRestart ? DesiredState.running : DesiredState.stopped,
    phase: shouldRestart
        ? cleanShutdown
              ? VmPhase.stopped
              : VmPhase.crashed
        : cleanShutdown
        ? VmPhase.stopped
        : VmPhase.failed,
    leaseState: VmLeaseState.releasing,
    retryState: retryState,
    currentOperation: needsRecoveryOperation ? null : failedOperation,
    clearCurrentOperation: needsRecoveryOperation,
    pendingRecoveryGeneration: needsRecoveryOperation ? driverGeneration : null,
    clearPendingRecoveryGeneration: !needsRecoveryOperation,
    pendingRecoveryError: needsRecoveryOperation ? exitError : null,
    clearPendingRecoveryError: !needsRecoveryOperation,
    lastError: exitError,
  );
  return VmTransition(
    state: next,
    effects: [
      if (!shouldRestart) ...[
        PersistVm(vmId: state.vmId, operationId: operationId),
        if (failedOperation != null && !operation!.isTerminal)
          FailOperation(
            vmId: state.vmId,
            operationId: operationId,
            error: exitError,
          ),
      ],
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
      ),
      if (needsRecoveryOperation)
        CreateRecoveryOperation(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: driverGeneration,
          error: exitError,
        ),
      ReleaseHostLease(vmId: state.vmId, operationId: operationId),
    ],
  );
}

VmTransition _retryTimerFired(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
) {
  if (!state.retryState.retryScheduled ||
      state.driverGeneration != driverGeneration ||
      state.activeDriverGeneration != null ||
      state.leaseState != VmLeaseState.none ||
      state.desiredState != DesiredState.running ||
      state.deletionState != VmDeletionState.active ||
      state.currentOperation?.id != operationId) {
    return VmTransition(state: state);
  }
  final next = state.copyWith(
    leaseState: VmLeaseState.acquiring,
    retryState: VmRetryState(
      attempts: state.retryState.attempts,
      maxAttempts: state.retryState.maxAttempts,
      failureTimes: state.retryState.failureTimes,
    ),
  );
  return VmTransition(
    state: next,
    effects: [
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
      ),
      AcquireHostLease(vmId: state.vmId, operationId: operationId),
    ],
  );
}

VmTransition _recoveryOperationCreated(
  VmControllerState state,
  OperationId operationId,
  int failedDriverGeneration,
) {
  if (state.pendingRecoveryGeneration != failedDriverGeneration ||
      state.deletionState != VmDeletionState.active ||
      state.desiredState != DesiredState.running) {
    return VmTransition(
      state: state,
      effects: [
        FailOperation(
          vmId: state.vmId,
          operationId: operationId,
          error: _operationSupersededError,
        ),
      ],
    );
  }
  final operation = VmControllerOperation(
    id: operationId,
    kind: VmOperationKind.recovery,
    state: OperationState.running,
  );
  final next = state.copyWith(
    currentOperation: operation,
    driverOperationId: operationId,
    clearPendingRecoveryGeneration: true,
    clearPendingRecoveryError: true,
  );
  final error = state.pendingRecoveryError ?? _driverExitedError;
  if (state.leaseState == VmLeaseState.held ||
      !state.retryState.retryScheduled &&
          state.retryState.attempts >= state.retryState.maxAttempts) {
    return _permanentFailure(next, operationId, failedDriverGeneration, error);
  }
  return VmTransition(
    state: next,
    effects: [
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: failedDriverGeneration,
      ),
      if (state.leaseState == VmLeaseState.none)
        ScheduleRetry(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: failedDriverGeneration,
          delay: state.retryState.scheduledDelay!,
        ),
    ],
  );
}

VmTransition _stableWindowElapsed(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
) {
  final operation = state.currentOperation;
  if (state.phase != VmPhase.running ||
      state.activeDriverGeneration != driverGeneration ||
      state.retryState.stableResetGeneration != driverGeneration ||
      operation?.id != operationId ||
      operation!.kind != VmOperationKind.recovery ||
      operation.isTerminal) {
    return VmTransition(state: state);
  }
  return VmTransition(
    state: state.copyWith(
      retryState: VmRetryState(maxAttempts: state.retryState.maxAttempts),
      currentOperation: operation.copyWith(state: OperationState.succeeded),
    ),
    effects: [
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
      ),
      CompleteOperation(vmId: state.vmId, operationId: operationId),
      EmitEvent(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
        type: 'vm.restart_stable',
      ),
    ],
  );
}

VmTransition _runtimeSetupFailed(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
  OperationError error,
  DateTime? occurredAt,
) => _driverExited(
  state,
  operationId,
  driverGeneration,
  cleanShutdown: false,
  error: error,
  occurredAt: occurredAt,
);

VmTransition _leaseReleaseFailed(
  VmControllerState state,
  OperationId operationId,
  OperationError error,
) {
  if (state.leaseState == VmLeaseState.releasing &&
      state.currentOperation == null &&
      state.pendingRecoveryGeneration != null) {
    return VmTransition(
      state: state.copyWith(
        leaseState: VmLeaseState.held,
        pendingRecoveryError: error,
        lastError: error,
      ),
      effects: [
        PersistRuntime(
          vmId: state.vmId,
          operationId: operationId,
          driverGeneration: state.driverGeneration,
        ),
        EmitEvent(
          vmId: state.vmId,
          operationId: operationId,
          type: 'vm.lease_release_failed',
        ),
      ],
    );
  }
  final currentOperation = state.currentOperation;
  final acceptsSupersedingOperation =
      currentOperation != null &&
      (state.desiredState == DesiredState.running &&
              const {
                VmOperationKind.start,
                VmOperationKind.restart,
                VmOperationKind.recovery,
              }.contains(currentOperation.kind) ||
          state.desiredState == DesiredState.stopped &&
              const {
                VmOperationKind.stop,
                VmOperationKind.delete,
              }.contains(currentOperation.kind));
  if (state.leaseState != VmLeaseState.releasing ||
      currentOperation == null ||
      currentOperation.id != operationId && !acceptsSupersedingOperation) {
    return VmTransition(state: state);
  }
  final operation = currentOperation;
  final correlatedOperationId = operation.id;
  final shouldFail = !operation.isTerminal;
  return VmTransition(
    state: state.copyWith(
      desiredState: DesiredState.stopped,
      phase: VmPhase.failed,
      leaseState: VmLeaseState.held,
      currentOperation: shouldFail
          ? operation.copyWith(state: OperationState.failed)
          : operation,
      lastError: error,
    ),
    effects: [
      PersistRuntime(
        vmId: state.vmId,
        operationId: correlatedOperationId,
        driverGeneration: state.driverGeneration,
      ),
      if (shouldFail)
        FailOperation(
          vmId: state.vmId,
          operationId: correlatedOperationId,
          error: error,
        ),
      EmitEvent(
        vmId: state.vmId,
        operationId: correlatedOperationId,
        type: 'vm.lease_release_failed',
      ),
    ],
  );
}

VmTransition _operationCancelled(
  VmControllerState state,
  OperationId operationId,
) {
  final operation = state.currentOperation;
  if (operation?.id != operationId || operation!.isTerminal) {
    return VmTransition(state: state);
  }
  final cancelled = operation.copyWith(state: OperationState.cancelled);
  final activeGeneration = state.activeDriverGeneration;
  final hasLease = state.leaseState != VmLeaseState.none;
  final next = state.copyWith(
    desiredState: DesiredState.stopped,
    phase: activeGeneration == null ? VmPhase.stopped : VmPhase.stopping,
    currentOperation: cancelled,
    retryState: VmRetryState(
      attempts: state.retryState.attempts,
      maxAttempts: state.retryState.maxAttempts,
      failureTimes: state.retryState.failureTimes,
    ),
    leaseState: activeGeneration == null && hasLease
        ? VmLeaseState.releasing
        : state.leaseState,
  );
  return VmTransition(
    state: next,
    effects: [
      if (state.retryState.retryScheduled)
        CancelRetry(vmId: state.vmId, operationId: operationId),
      PersistVm(vmId: state.vmId, operationId: operationId),
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: activeGeneration,
      ),
      CompleteOperation(
        vmId: state.vmId,
        operationId: operationId,
        cancelled: true,
      ),
      if (activeGeneration != null)
        if (state.phase == VmPhase.running)
          StopRuntime(
            vmId: state.vmId,
            operationId: operationId,
            driverGeneration: activeGeneration,
          )
        else
          KillDriver(
            vmId: state.vmId,
            operationId: operationId,
            driverGeneration: activeGeneration,
          )
      else if (hasLease)
        ReleaseHostLease(vmId: state.vmId, operationId: operationId),
    ],
  );
}

VmTransition _permanentFailure(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
  OperationError error,
) {
  final current = state.currentOperation;
  final failOperation = current?.id == operationId && !current!.isTerminal;
  final needsLeaseRelease =
      state.leaseState == VmLeaseState.held ||
      state.leaseState == VmLeaseState.acquiring;
  final next = state.copyWith(
    clearActiveDriverGeneration: true,
    clearActiveSpecGeneration: true,
    desiredState: DesiredState.stopped,
    phase: VmPhase.failed,
    leaseState: needsLeaseRelease
        ? VmLeaseState.releasing
        : state.leaseState == VmLeaseState.releasing
        ? VmLeaseState.releasing
        : VmLeaseState.none,
    retryState: VmRetryState(
      attempts: state.retryState.attempts,
      maxAttempts: state.retryState.maxAttempts,
      failureTimes: state.retryState.failureTimes,
    ),
    currentOperation: failOperation
        ? current.copyWith(state: OperationState.failed)
        : current,
    lastError: error,
    clearPendingRecoveryGeneration: true,
    clearPendingRecoveryError: true,
  );
  return VmTransition(
    state: next,
    effects: [
      PersistVm(vmId: state.vmId, operationId: operationId),
      PersistRuntime(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
      ),
      if (failOperation)
        FailOperation(vmId: state.vmId, operationId: operationId, error: error),
      EmitEvent(
        vmId: state.vmId,
        operationId: operationId,
        driverGeneration: driverGeneration,
        type: 'vm.permanent_failure',
      ),
      if (needsLeaseRelease)
        ReleaseHostLease(vmId: state.vmId, operationId: operationId),
    ],
  );
}

bool _matchesRuntimeCallback(
  VmControllerState state,
  OperationId operationId,
  int driverGeneration,
) =>
    state.activeDriverGeneration == driverGeneration &&
    state.driverOperationId == operationId;

bool _allowsPhaseTransition(VmPhase current, VmPhase next) {
  if (current == next || current == VmPhase.deleted) return false;
  return switch (current) {
    VmPhase.configuring => const {
      VmPhase.starting,
      VmPhase.running,
      VmPhase.stopping,
      VmPhase.stopped,
      VmPhase.crashed,
      VmPhase.failed,
    }.contains(next),
    VmPhase.starting => const {
      VmPhase.running,
      VmPhase.stopping,
      VmPhase.stopped,
      VmPhase.crashed,
      VmPhase.failed,
    }.contains(next),
    VmPhase.running => const {
      VmPhase.stopping,
      VmPhase.stopped,
      VmPhase.crashed,
      VmPhase.failed,
      VmPhase.deleting,
    }.contains(next),
    VmPhase.stopping => const {
      VmPhase.stopped,
      VmPhase.crashed,
      VmPhase.failed,
      VmPhase.deleting,
    }.contains(next),
    VmPhase.crashed || VmPhase.failed => next == VmPhase.stopped,
    VmPhase.deleting => const {VmPhase.deleted, VmPhase.failed}.contains(next),
    VmPhase.defined ||
    VmPhase.provisioning ||
    VmPhase.stopped ||
    VmPhase.spawningDriver ||
    VmPhase.handshaking ||
    VmPhase.deleted => false,
  };
}

Duration _retryDelay(int attempt) {
  final seconds = 1 << (attempt - 1).clamp(0, 5);
  return Duration(seconds: seconds > 30 ? 30 : seconds);
}

final _operationSupersededError = OperationError(
  code: ErrorCode.vmOperationConflict,
  message: 'operation was superseded by a newer lifecycle command',
  retryable: true,
  details: JsonObjectValue.empty,
);

final _operationConflictError = OperationError(
  code: ErrorCode.vmOperationConflict,
  message: 'another lifecycle operation is already active',
  retryable: true,
  details: JsonObjectValue.empty,
);

final _driverExitedError = OperationError(
  code: ErrorCode.driverStartFailed,
  message: 'driver exited unexpectedly',
  retryable: true,
  details: JsonObjectValue.empty,
);

final _heartbeatError = OperationError(
  code: ErrorCode.driverUnhealthy,
  message: 'driver heartbeat deadline was missed',
  retryable: true,
  details: JsonObjectValue.empty,
);

final _reconcileError = OperationError(
  code: ErrorCode.driverStartFailed,
  message: 'reconciliation requires a recovery operation',
  retryable: true,
  details: JsonObjectValue.empty,
);

final _deletedVmError = OperationError(
  code: ErrorCode.vmOperationConflict,
  message: 'deleted VM cannot be started',
  retryable: false,
  details: JsonObjectValue.empty,
);
