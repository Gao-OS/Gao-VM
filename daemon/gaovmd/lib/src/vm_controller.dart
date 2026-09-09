import 'dart:async';
import 'dart:collection';

import 'package:gaovm_models/gaovm_models.dart';

import 'vm_controller_reducer.dart';

abstract interface class VmEffectRunner {
  Future<VmCommand?> run(VmEffect effect, VmControllerState state);
}

abstract interface class TransactionalVmEffectRunner implements VmEffectRunner {
  bool isDurable(VmEffect effect);

  Future<List<VmCommand?>> runDurableBatch(
    List<VmEffect> effects,
    VmControllerState state,
  );
}

abstract interface class CancellableVmEffectRunner implements VmEffectRunner {
  Future<void> cancel(VmEffect effect, VmControllerState state);
}

/// A short database-only acceptance transaction. It must commit the operation,
/// catalog intent, command and event/outbox together before returning.
abstract interface class VmAcceptanceAction<T> {
  Future<VmAcceptedIntent<T>> commit(VmControllerState executionState);
}

/// Prepares and commits the durable adoption prefix without external effects.
/// A failed commit must leave persistence unchanged. Duplicate and deferred
/// results must return the unchanged execution snapshot and no effects.
abstract interface class VmIntentAdoptionAction {
  Future<VmIntentAdoption> commit(VmControllerState executionState);
}

enum VmIntentAdoptionDisposition { adopted, duplicate, deferred }

final class VmIntentAdoption {
  VmIntentAdoption({
    required this.disposition,
    required this.state,
    required List<VmEffect> remainingEffects,
    this.sourceCommand,
  }) : remainingEffects = List<VmEffect>.unmodifiable(remainingEffects);

  final VmIntentAdoptionDisposition disposition;
  final VmControllerState state;
  final List<VmEffect> remainingEffects;
  final VmCommand? sourceCommand;
}

final class VmAcceptedIntent<T> {
  VmAcceptedIntent({required this.intentRevision, required this.result}) {
    if (intentRevision < 0)
      throw ArgumentError.value(intentRevision, 'intentRevision');
  }

  final int intentRevision;
  final T result;
}

class VmEffectException implements Exception {
  const VmEffectException(this.operationError, {this.cause});

  final OperationError operationError;
  final Object? cause;

  @override
  String toString() => operationError.message;
}

final class VmEffectTimeoutException extends VmEffectException {
  const VmEffectTimeoutException(super.operationError);
}

final class VmEffectBatchException implements Exception {
  const VmEffectBatchException(this.effect, this.error, this.stackTrace);

  final VmEffect effect;
  final Object error;
  final StackTrace stackTrace;
}

abstract interface class VmTimerHandle {
  bool get isActive;

  void cancel();
}

abstract interface class VmTimerScheduler {
  VmTimerHandle schedule(Duration delay, void Function() callback);
}

final class DartVmTimerScheduler implements VmTimerScheduler {
  const DartVmTimerScheduler();

  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) =>
      _DartVmTimerHandle(Timer(delay, callback));
}

final class VmControllerClosedException implements Exception {
  const VmControllerClosedException();

  @override
  String toString() => 'VM controller is shutting down';
}

final class VmControllerShutdownException implements Exception {
  VmControllerShutdownException(Iterable<OperationError> errors)
    : errors = List<OperationError>.unmodifiable(errors);

  final List<OperationError> errors;

  @override
  String toString() =>
      'VM controller shutdown failed: '
      '${errors.map((error) => error.message).join('; ')}';
}

final class VmController {
  VmController({
    required VmControllerState initialState,
    required VmEffectRunner effectRunner,
    int? initialAcceptedIntentRevision,
    VmTimerScheduler timerScheduler = const DartVmTimerScheduler(),
    void Function(VmControllerState state)? onStateChanged,
    Duration effectTimeout = const Duration(seconds: 30),
    Duration shutdownTimeout = const Duration(seconds: 35),
    OperationId Function()? newTeardownOperationId,
  }) : _state = initialState,
       _acceptedIntentRevision =
           initialAcceptedIntentRevision ?? initialState.appliedIntentRevision,
       _effectRunner = effectRunner,
       _timerScheduler = timerScheduler,
       _onStateChanged = onStateChanged,
       _effectTimeout = effectTimeout,
       _shutdownTimeout = shutdownTimeout,
       _newTeardownOperationId =
           newTeardownOperationId ?? OperationId.generate {
    if (effectTimeout <= Duration.zero || shutdownTimeout <= Duration.zero) {
      throw ArgumentError('controller deadlines must be positive');
    }
    if (_acceptedIntentRevision < initialState.appliedIntentRevision) {
      throw ArgumentError('accepted intent revision precedes executing intent');
    }
  }

  final VmEffectRunner _effectRunner;
  final VmTimerScheduler _timerScheduler;
  final void Function(VmControllerState state)? _onStateChanged;
  final Duration _effectTimeout;
  final Duration _shutdownTimeout;
  final OperationId Function() _newTeardownOperationId;
  final Queue<_QueuedWork> _externalCommands = Queue<_QueuedWork>();
  final Queue<_QueuedCommand> _internalCommands = Queue<_QueuedCommand>();
  final List<Completer<void>> _idleWaiters = [];

  VmControllerState _state;
  bool _processing = false;
  bool _acceptingExternal = true;
  Completer<VmControllerState>? _causalCompleter;
  Future<void>? _shutdownFuture;
  VmEffect? _activeEffect;
  VmControllerState? _activeEffectState;
  final List<OperationError> _shutdownErrors = [];
  final Set<VmEffect> _cancellationsInFlight = HashSet.identity();
  Future<void> _mutationTail = Future<void>.value();
  int _acceptedIntentRevision;
  VmTimerHandle? _retryTimer;
  VmTimerHandle? _stableResetTimer;

  VmControllerState get state => _state;
  int get acceptedIntentRevision => _acceptedIntentRevision;

  /// Acceptance shares the durable-write gate, never the external-effect wait.
  /// The execution snapshot stays intact until the queued intent is adopted.
  Future<T> accept<T>(VmAcceptanceAction<T> action) => _mutate(() async {
    if (!_acceptingExternal) throw const VmControllerClosedException();
    final accepted = await action.commit(_state);
    if (accepted.intentRevision > _acceptedIntentRevision) {
      _acceptedIntentRevision = accepted.intentRevision;
    }
    return accepted.result;
  });

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _mutationTail.then((_) => action());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  bool get isAccepting => _acceptingExternal;
  bool get isIdle =>
      !_processing &&
      _externalCommands.isEmpty &&
      _internalCommands.isEmpty &&
      _causalCompleter == null;
  bool get hasPendingTimers =>
      (_retryTimer?.isActive ?? false) ||
      (_stableResetTimer?.isActive ?? false);
  int get pendingCancellationCount => _cancellationsInFlight.length;

  Future<VmControllerState> submit(VmCommand command) {
    if (!_acceptingExternal) {
      return Future<VmControllerState>.error(
        const VmControllerClosedException(),
      );
    }
    final completer = Completer<VmControllerState>();
    _externalCommands.add(_QueuedCommand(command, completer));
    _startDrain();
    return completer.future;
  }

  /// Queues adoption in the external FIFO. Completion acknowledges the durable
  /// prefix and installed state, not completion of the remaining effect lane.
  Future<VmIntentAdoptionDisposition> adopt(VmIntentAdoptionAction action) {
    if (!_acceptingExternal) {
      return Future<VmIntentAdoptionDisposition>.error(
        const VmControllerClosedException(),
      );
    }
    final completer = Completer<VmIntentAdoptionDisposition>();
    _externalCommands.add(_QueuedAdoption(action, completer, Zone.current));
    _startDrain();
    return completer.future;
  }

  Future<void> waitUntilIdle() {
    if (isIdle) return Future<void>.value();
    final completer = Completer<void>();
    _idleWaiters.add(completer);
    return completer.future;
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
    _shutdownErrors.clear();
    _acceptingExternal = false;
    _cancelTimers();
    _cancelActiveEffect();
    while (_externalCommands.isNotEmpty) {
      _externalCommands.removeFirst().reject(
        const VmControllerClosedException(),
      );
    }
    try {
      await _mutationTail.timeout(_shutdownTimeout);
    } on TimeoutException {
      throw VmControllerShutdownException([
        _timeoutError('controller acceptance shutdown'),
      ]);
    }
    _internalCommands.addFirst(
      _QueuedCommand(
        ControllerShutdownRequested(_newTeardownOperationId()),
        null,
      ),
    );
    _startDrain();
    try {
      await waitUntilIdle().timeout(_shutdownTimeout);
    } on TimeoutException {
      final timeoutError = _timeoutError('controller shutdown');
      _shutdownErrors.add(timeoutError);
      _cancelActiveEffect();
    }
    _cancelTimers();
    if (_shutdownErrors.isNotEmpty) {
      throw VmControllerShutdownException(_shutdownErrors);
    }
  }

  void _startDrain() {
    if (_processing) return;
    _processing = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    while (_internalCommands.isNotEmpty || _externalCommands.isNotEmpty) {
      final queued = _internalCommands.isNotEmpty
          ? _internalCommands.removeFirst()
          : _externalCommands.removeFirst();
      if (queued is _QueuedAdoption) {
        await _adoptQueued(queued);
        continue;
      }
      final commandWork = queued as _QueuedCommand;
      try {
        final transition = reduce(_state, commandWork.command);
        _state = transition.state;
        _onStateChanged?.call(_state);
        _synchronizeTimers();
        await _executeEffects(
          transition.effects,
          transition.state,
          commandWork.command,
        );
        if (commandWork.completer != null) {
          _causalCompleter = commandWork.completer;
        }
        if (_internalCommands.isEmpty && _causalCompleter != null) {
          _causalCompleter!.complete(_state);
          _causalCompleter = null;
        }
      } catch (error, stackTrace) {
        commandWork.reject(error, stackTrace);
        if (identical(_causalCompleter, commandWork.completer)) {
          _causalCompleter = null;
        }
      }
      if (_internalCommands.isEmpty && _causalCompleter != null) {
        _causalCompleter!.complete(_state);
        _causalCompleter = null;
      }
    }
    _processing = false;
    final waiters = List<Completer<void>>.of(_idleWaiters);
    _idleWaiters.clear();
    for (final waiter in waiters) {
      waiter.complete();
    }
    if (_internalCommands.isNotEmpty || _externalCommands.isNotEmpty) {
      _startDrain();
    }
  }

  Future<void> _adoptQueued(_QueuedAdoption queued) async {
    late VmIntentAdoption adoption;
    try {
      adoption = await _mutate(() async {
        final result = await queued.callerZone.run(
          () => queued.action.commit(_state),
        );
        if (result.disposition != VmIntentAdoptionDisposition.adopted) {
          if (!identical(result.state, _state) ||
              result.remainingEffects.isNotEmpty) {
            throw StateError('unadopted intent must preserve execution');
          }
        } else {
          _state = result.state;
          _onStateChanged?.call(_state);
          _synchronizeTimers();
        }
        queued.completer.complete(result.disposition);
        return result;
      });
    } catch (error, stackTrace) {
      queued.reject(error, stackTrace);
      return;
    }
    await _executeEffects(
      adoption.remainingEffects,
      adoption.state,
      adoption.sourceCommand,
    );
  }

  Future<void> _executeEffects(
    List<VmEffect> effects,
    VmControllerState state,
    VmCommand? sourceCommand,
  ) async {
    for (var index = 0; index < effects.length;) {
      final effect = effects[index];
      final transactional = _effectRunner is TransactionalVmEffectRunner
          ? _effectRunner
          : null;
      if (transactional != null && transactional.isDurable(effect)) {
        final batch = <VmEffect>[effect];
        var next = index + 1;
        while (next < effects.length &&
            transactional.isDurable(effects[next])) {
          batch.add(effects[next]);
          next++;
        }
        try {
          final results = await _mutate(
            () => _runBatchWithDeadline(transactional, batch, state),
          );
          for (var offset = 0; offset < batch.length; offset++) {
            _enqueueEffectResult(batch[offset], results[offset]);
          }
        } catch (error) {
          final failedEffect = error is VmEffectBatchException
              ? error.effect
              : batch.first;
          if (sourceCommand is EffectExecutionFailed) {
            if (!_acceptingExternal) {
              _shutdownErrors.add(_operationError(failedEffect, error));
            }
            index = next;
            continue;
          }
          OperationId? rolledBackCompletionOperationId;
          for (final durableEffect in batch) {
            if (durableEffect is CompleteOperation) {
              rolledBackCompletionOperationId = durableEffect.operationId;
            }
            if (sourceCommand is HostLeaseLost &&
                durableEffect is FailOperation) {
              // The proposed terminal state did not commit with this batch.
              rolledBackCompletionOperationId = durableEffect.operationId;
            }
          }
          _handleEffectFailure(
            failedEffect,
            error,
            rolledBackCompletionOperationId: rolledBackCompletionOperationId,
          );
          if (sourceCommand is! EffectExecutionFailed &&
              sourceCommand is! ControllerShutdownRequested &&
              sourceCommand is! ControllerDriverShutdownFailed &&
              sourceCommand is! ControllerLeaseShutdownFailed &&
              sourceCommand is! HostLeaseLost &&
              sourceCommand is! HostLeaseRunningMarkFailed) {
            break;
          }
        }
        index = next;
        continue;
      }

      try {
        final result = await _runWithDeadline(
          effect,
          state,
          () => _runEffect(effect, state),
        );
        _enqueueEffectResult(effect, result);
      } catch (error) {
        if (sourceCommand is EffectExecutionFailed) {
          if (!_acceptingExternal) {
            _shutdownErrors.add(_operationError(effect, error));
          }
          index++;
          continue;
        }
        OperationId? skippedCompletionOperationId;
        if (effect is MarkHostLeaseRunning) {
          for (final remaining in effects.skip(index + 1)) {
            if (remaining is CompleteOperation &&
                remaining.operationId == effect.operationId) {
              skippedCompletionOperationId = remaining.operationId;
            }
          }
        }
        _handleEffectFailure(
          effect,
          error,
          rolledBackCompletionOperationId: skippedCompletionOperationId,
        );
        if (sourceCommand is! EffectExecutionFailed &&
            sourceCommand is! ControllerShutdownRequested &&
            sourceCommand is! ControllerDriverShutdownFailed &&
            sourceCommand is! ControllerLeaseShutdownFailed &&
            sourceCommand is! HostLeaseLost &&
            sourceCommand is! HostLeaseRunningMarkFailed) {
          break;
        }
      }
      index++;
    }
  }

  Future<List<VmCommand?>> _runBatchWithDeadline(
    TransactionalVmEffectRunner runner,
    List<VmEffect> effects,
    VmControllerState state,
  ) async {
    _activeEffect = effects.first;
    _activeEffectState = state;
    final timer = Timer(_effectTimeout, () {
      for (final effect in effects) {
        _requestCancellation(effect, state);
      }
    });
    try {
      final result = await runner.runDurableBatch(effects, state);
      return result;
    } finally {
      timer.cancel();
      for (final effect in effects) {
        _cancellationsInFlight.remove(effect);
      }
      _activeEffect = null;
      _activeEffectState = null;
    }
  }

  Future<T> _runWithDeadline<T>(
    VmEffect effect,
    VmControllerState state,
    Future<T> Function() action,
  ) async {
    _activeEffect = effect;
    _activeEffectState = state;
    var timedOut = false;
    final timer = Timer(_effectTimeout, () {
      timedOut = true;
      _requestCancellation(effect, state);
    });
    try {
      final result = await action();
      if (timedOut) {
        throw VmEffectTimeoutException(
          _timeoutError('${effect.runtimeType} execution'),
        );
      }
      return result;
    } finally {
      timer.cancel();
      _cancellationsInFlight.remove(effect);
      _activeEffect = null;
      _activeEffectState = null;
    }
  }

  void _enqueueEffectResult(VmEffect effect, VmCommand? result) {
    result ??= switch (effect) {
      ShutdownDriver(:final driverGeneration, :final operationId) =>
        ControllerDriverShutdownSucceeded(driverGeneration!, operationId!),
      ShutdownLease() => const ControllerLeaseShutdownSucceeded(),
      _ => null,
    };
    _internalCommands.add(
      _QueuedCommand(
        result ??
            EffectExecutionSucceeded(
              effectType: effect.runtimeType.toString(),
              operationId: effect.operationId,
              driverGeneration: effect.driverGeneration,
            ),
        null,
      ),
    );
  }

  void _handleEffectFailure(
    VmEffect effect,
    Object error, {
    OperationId? rolledBackCompletionOperationId,
  }) {
    final command = _failureCommand(
      effect,
      error,
      rolledBackCompletionOperationId: rolledBackCompletionOperationId,
    );
    if (!_acceptingExternal) {
      _shutdownErrors.add(_operationError(effect, error));
    }
    _internalCommands.add(_QueuedCommand(command, null));
  }

  VmCommand _failureCommand(
    VmEffect effect,
    Object error, {
    OperationId? rolledBackCompletionOperationId,
  }) {
    final operationError = _operationError(effect, error);
    final operationId = effect.operationId;
    final driverGeneration = effect.driverGeneration;
    final effectiveRollbackOperationId = rolledBackCompletionOperationId;
    if (effect is MarkHostLeaseRunning &&
        operationId != null &&
        driverGeneration != null) {
      return HostLeaseRunningMarkFailed(
        operationId: operationId,
        driverGeneration: driverGeneration,
        error: operationError,
        rolledBackCompletionOperationId: effectiveRollbackOperationId,
      );
    }
    final underlying = error is VmEffectBatchException ? error.error : error;
    if (underlying is VmEffectTimeoutException) {
      return EffectExecutionFailed(
        effectType: effect.runtimeType.toString(),
        operationId: operationId,
        driverGeneration: driverGeneration,
        error: operationError,
        duringShutdown: !_acceptingExternal,
        rolledBackCompletionOperationId: effectiveRollbackOperationId,
      );
    }
    return switch (effect) {
      AcquireHostLease() when operationId != null => HostLeaseFailed(
        operationId: operationId,
        error: operationError,
      ),
      SpawnDriver() when operationId != null && driverGeneration != null =>
        DriverSpawnFailed(
          operationId: operationId,
          driverGeneration: driverGeneration,
          error: operationError,
        ),
      ConnectDriver() when operationId != null && driverGeneration != null =>
        DriverHandshakeFailed(
          operationId: operationId,
          driverGeneration: driverGeneration,
          error: operationError,
        ),
      ConfigureRuntime() when operationId != null && driverGeneration != null =>
        DriverCommandFailed(
          operationId: operationId,
          driverGeneration: driverGeneration,
          command: RuntimeCommandKind.configure,
          error: operationError,
        ),
      StartRuntime() when operationId != null && driverGeneration != null =>
        DriverCommandFailed(
          operationId: operationId,
          driverGeneration: driverGeneration,
          command: RuntimeCommandKind.start,
          error: operationError,
        ),
      StopRuntime() when operationId != null && driverGeneration != null =>
        DriverCommandFailed(
          operationId: operationId,
          driverGeneration: driverGeneration,
          command: RuntimeCommandKind.stop,
          error: operationError,
        ),
      KillDriver() when operationId != null && driverGeneration != null =>
        DriverCommandFailed(
          operationId: operationId,
          driverGeneration: driverGeneration,
          command: RuntimeCommandKind.kill,
          error: operationError,
        ),
      ShutdownDriver() when driverGeneration != null =>
        ControllerDriverShutdownFailed(driverGeneration, operationError),
      ShutdownLease() => ControllerLeaseShutdownFailed(operationError),
      ReleaseHostLease() => HostLeaseReleaseFailed(operationId, operationError),
      RemoveManagedFiles() when operationId != null =>
        ManagedFilesRemovalFailed(operationId, operationError),
      CreateRecoveryOperation() when driverGeneration != null =>
        RecoveryOperationCreationFailed(
          failedDriverGeneration: driverGeneration,
          error: operationError,
        ),
      _ => EffectExecutionFailed(
        effectType: effect.runtimeType.toString(),
        operationId: operationId,
        driverGeneration: driverGeneration,
        error: operationError,
        duringShutdown: !_acceptingExternal,
        rolledBackCompletionOperationId: effectiveRollbackOperationId,
      ),
    };
  }

  OperationError _operationError(VmEffect effect, Object error) {
    final underlying = error is VmEffectBatchException ? error.error : error;
    if (underlying is VmEffectException) return underlying.operationError;
    return OperationError(
      code: ErrorCode.internalError,
      message: '${effect.runtimeType} failed: $underlying',
      retryable: true,
      details: JsonObjectValue.empty,
    );
  }

  OperationError _timeoutError(String subject) => OperationError(
    code: ErrorCode.waitTimeout,
    message: '$subject timed out',
    retryable: true,
    details: JsonObjectValue.empty,
  );

  void _requestCancellation(VmEffect effect, VmControllerState state) {
    if (!_cancellationsInFlight.add(effect)) return;
    final runner = _effectRunner;
    if (runner is! CancellableVmEffectRunner) return;
    try {
      runner.cancel(effect, state).ignore();
    } catch (_) {
      // Cancellation is advisory; the original effect remains authoritative.
    }
  }

  void _cancelActiveEffect() {
    final effect = _activeEffect;
    final state = _activeEffectState;
    if (effect == null || state == null) return;
    _requestCancellation(effect, state);
  }

  Future<VmCommand?> _runEffect(
    VmEffect effect,
    VmControllerState state,
  ) async {
    if (effect is ScheduleRetry) {
      if (!_acceptingExternal) return null;
      _retryTimer?.cancel();
      late VmTimerHandle handle;
      handle = _timerScheduler.schedule(effect.delay, () {
        if (!identical(_retryTimer, handle)) return;
        _retryTimer = null;
        _enqueueInternal(
          RetryTimerFired(
            operationId: effect.operationId!,
            driverGeneration: effect.driverGeneration!,
          ),
        );
      });
      _retryTimer = handle;
      return null;
    }
    if (effect is CancelRetry) {
      _retryTimer?.cancel();
      _retryTimer = null;
      return null;
    }
    if (effect is ScheduleStableReset) {
      if (!_acceptingExternal) return null;
      _stableResetTimer?.cancel();
      late VmTimerHandle handle;
      handle = _timerScheduler.schedule(effect.delay, () {
        if (!identical(_stableResetTimer, handle)) return;
        _stableResetTimer = null;
        _enqueueInternal(
          StableWindowElapsed(
            operationId: effect.operationId!,
            driverGeneration: effect.driverGeneration!,
          ),
        );
      });
      _stableResetTimer = handle;
      return null;
    }
    if (!_acceptingExternal &&
        (effect is AcquireHostLease ||
            effect is SpawnDriver ||
            effect is ConnectDriver ||
            effect is ConfigureRuntime ||
            effect is StartRuntime)) {
      return null;
    }
    return _effectRunner.run(effect, state);
  }

  void _enqueueInternal(VmCommand command) {
    if (!_acceptingExternal) return;
    _internalCommands.add(_QueuedCommand(command, null));
    _startDrain();
  }

  void _synchronizeTimers() {
    if (!_state.retryState.retryScheduled) {
      _retryTimer?.cancel();
      _retryTimer = null;
    }
    final stableGeneration = _state.retryState.stableResetGeneration;
    final operation = _state.currentOperation;
    if (stableGeneration == null ||
        _state.activeDriverGeneration != stableGeneration ||
        operation == null ||
        operation.kind != VmOperationKind.recovery ||
        operation.isTerminal) {
      _stableResetTimer?.cancel();
      _stableResetTimer = null;
    }
  }

  void _cancelTimers() {
    _retryTimer?.cancel();
    _stableResetTimer?.cancel();
    _retryTimer = null;
    _stableResetTimer = null;
  }
}

sealed class _QueuedWork {
  const _QueuedWork();

  void reject(Object error, [StackTrace? stackTrace]);
}

final class _QueuedAdoption extends _QueuedWork {
  const _QueuedAdoption(this.action, this.completer, this.callerZone);

  final VmIntentAdoptionAction action;
  final Completer<VmIntentAdoptionDisposition> completer;
  // Commit-time guards must see the enqueue caller's transaction context,
  // even when another caller started the active drain.
  final Zone callerZone;

  @override
  void reject(Object error, [StackTrace? stackTrace]) =>
      completer.completeError(error, stackTrace);
}

final class _QueuedCommand extends _QueuedWork {
  const _QueuedCommand(this.command, this.completer);

  final VmCommand command;
  final Completer<VmControllerState>? completer;

  @override
  void reject(Object error, [StackTrace? stackTrace]) =>
      completer?.completeError(error, stackTrace);
}

final class _DartVmTimerHandle implements VmTimerHandle {
  const _DartVmTimerHandle(this._timer);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}
