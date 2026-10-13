import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';

import 'runtime_driver.dart';
import 'guest_bridge_client.dart';
import 'host_guest_session.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'vm_effect_runner.dart';

typedef RuntimeDriverConfigurationResolver =
    Future<RuntimeDriverConfiguration> Function(VmControllerState state);

/// Owns configuration asset lifetimes through the driver's configure response.
/// The provider must await [use] before releasing its locks or file handles.
typedef RuntimeDriverConfigurationScope =
    Future<void> Function(
      VmControllerState state,
      Future<void> Function(RuntimeDriverConfiguration configuration) use,
    );
typedef RuntimeDriverCommandDispatcher =
    Future<void> Function(VmId vmId, VmCommand command);
typedef RuntimeDriverEventObserver = void Function(RuntimeEvent event);
typedef RuntimeDriverLogObserver = void Function(RuntimeDriverLogChunk chunk);
typedef RuntimeGuestSessionErrorObserver =
    void Function(
      DriverCorrelation correlation,
      Object error,
      StackTrace stackTrace,
    );

final class RuntimeDriverDispatchException implements Exception {
  RuntimeDriverDispatchException({
    required this.vmId,
    required this.driverGeneration,
    required this.command,
    required this.error,
    required this.stackTrace,
  });

  final VmId vmId;
  final int driverGeneration;
  final VmCommand command;
  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() =>
      'failed to dispatch ${command.runtimeType} for '
      '${vmId.value} generation $driverGeneration: $error';
}

final class RuntimeDriverEffectAdapter
    implements
        VmDriverEffectAdapter,
        VmDisplayEffectAdapter,
        VmEffectCancellationAdapter {
  RuntimeDriverEffectAdapter({
    required RuntimeDriverFactory factory,
    required RuntimeDriverConfigurationResolver resolveConfiguration,
    required RuntimeDriverCommandDispatcher dispatch,
    DriverCapabilities? requiredCapabilities,
    RuntimeDriverEventObserver? observeEvent,
    RuntimeDriverLogObserver? observeLog,
    DateTime Function()? now,
  }) : this.scopedConfiguration(
         factory: factory,
         withConfiguration: (state, use) async =>
             use(await resolveConfiguration(state)),
         dispatch: dispatch,
         requiredCapabilities: requiredCapabilities,
         observeEvent: observeEvent,
         observeLog: observeLog,
         now: now,
       );

  RuntimeDriverEffectAdapter.scopedConfiguration({
    required RuntimeDriverFactory factory,
    required RuntimeDriverConfigurationScope withConfiguration,
    required RuntimeDriverCommandDispatcher dispatch,
    DriverCapabilities? requiredCapabilities,
    RuntimeDriverEventObserver? observeEvent,
    RuntimeDriverLogObserver? observeLog,
    DateTime Function()? now,
  }) : _factory = factory,
       _withConfiguration = withConfiguration,
       _dispatch = dispatch,
       _requiredCapabilities =
           requiredCapabilities ?? DriverCapabilities.runtimeCore,
       _observeEvent = observeEvent,
       _observeLog = observeLog,
       _now = now ?? DateTime.now;

  final RuntimeDriverFactory _factory;
  final RuntimeDriverConfigurationScope _withConfiguration;
  final RuntimeDriverCommandDispatcher _dispatch;
  final DriverCapabilities _requiredCapabilities;
  final RuntimeDriverEventObserver? _observeEvent;
  final RuntimeDriverLogObserver? _observeLog;
  final DateTime Function() _now;
  final Map<_RuntimeDriverKey, _RuntimeDriverRecord> _records = {};
  final Map<_RuntimeDriverKey, _InFlightSpawn> _inFlightSpawns = {};
  final Map<VmId, _RuntimeDriverKey> _activeByVm = {};
  RuntimeDriverDispatchException? _dispatchFailure;
  bool _closed = false;
  Future<void>? _closeFuture;

  int get activeSessionCount => _records.length;

  /// Exact current generation only. Guest connection establishment remains in
  /// the readiness owner; accepting execution never creates a driver channel.
  GuestControlConnection? readyGuestConnection(VmId vmId, int generation) {
    if (_closed) return null;
    final key = _activeByVm[vmId];
    if (key == null || key != _RuntimeDriverKey(vmId, generation)) return null;
    final record = _records[key];
    if (record == null ||
        record.terminalReported ||
        !record.runtimeRunning ||
        !record.guestEnabled ||
        record.dispatchFailure != null)
      return null;
    return record.guestSession?.readyConnection;
  }

  @override
  Future<void> spawn(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {
    if (_closed) {
      final error = _closedError();
      throw VmEffectException(_operationError(error), cause: error);
    }
    final correlation = DriverCorrelation(
      vmId: state.vmId,
      driverGeneration: driverGeneration,
      operationId: operationId,
    );
    final key = _RuntimeDriverKey(state.vmId, driverGeneration);
    if (_activeByVm.containsKey(state.vmId) ||
        _records.containsKey(key) ||
        _inFlightSpawns.containsKey(key)) {
      throw VmEffectException(
        _operationError(
          RuntimeDriverError(
            code: RuntimeDriverErrorCode.invalidRuntimeState,
            message: 'driver generation is already active',
            retryable: false,
          ),
        ),
      );
    }
    final spawnFuture = _factory.spawn(
      RuntimeDriverLaunch(correlation: correlation),
    );
    _inFlightSpawns[key] = _InFlightSpawn(correlation, spawnFuture);
    _activeByVm[state.vmId] = key;
    try {
      final session = await spawnFuture;
      if (_closed) {
        await _factory.release(correlation);
        throw _closedError();
      }
      final record = _RuntimeDriverRecord(session, operationId);
      _records[key] = record;
      if (session is GuestSessionProvider) {
        final guest = (session as GuestSessionProvider).guestSession;
        record.guestSession = guest;
        record.guestSubscription = guest.readiness.listen((observation) {
          if (record.terminalReported ||
              !record.guestEnabled ||
              !_matchesCorrelation(record, observation.correlation))
            return;
          record.latestGuestObservation = observation;
          _enqueueGuestReadiness(record);
        });
      }
      record.eventSubscription = session.events.listen(
        (event) => _routeEvent(record, event),
        onError: (Object error, StackTrace stackTrace) {
          _routeChannelError(record, error);
        },
        onDone: () {
          _routeChannelError(record, StateError('driver event stream closed'));
        },
      );
      record.logSubscription = session.logs.listen(
        (chunk) => _routeLog(record, chunk),
        onError: (Object error, StackTrace stackTrace) {
          _routeChannelError(record, error);
        },
      );
      unawaited(
        session.exited.then(
          (exit) => _routeExit(record, exit),
          onError: (Object error, StackTrace stackTrace) {
            _routeChannelError(record, error);
          },
        ),
      );
    } on RuntimeDriverError catch (error) {
      throw VmEffectException(_operationError(error), cause: error);
    } finally {
      final pending = _inFlightSpawns[key];
      if (pending != null && identical(pending.future, spawnFuture)) {
        _inFlightSpawns.remove(key);
      }
      if (!_records.containsKey(key) && _activeByVm[state.vmId] == key) {
        _activeByVm.remove(state.vmId);
      }
    }
  }

  @override
  Future<void> connect(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) => _translateErrors(() async {
    final record = _requireRecord(state.vmId, driverGeneration);
    await record.session.connect(_requiredCapabilities);
  });

  @override
  Future<void> configure(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) => _translateErrors(() async {
    final record = _requireRecord(state.vmId, driverGeneration);
    await _withConfiguration(state, (configuration) async {
      record.latestOperationId = operationId;
      await record.session.execute(
        RuntimeConfigureCommand(
          correlation: _correlation(state.vmId, driverGeneration, operationId),
          configuration: configuration,
        ),
      );
      record.guestEnabled = configuration.guestAgent.enabled;
    });
  });

  @override
  Future<void> start(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) => _execute(
    state.vmId,
    driverGeneration,
    RuntimeStartCommand(
      correlation: _correlation(state.vmId, driverGeneration, operationId),
    ),
  );

  @override
  Future<void> stop(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) => _execute(
    state.vmId,
    driverGeneration,
    RuntimeStopCommand(
      correlation: _correlation(state.vmId, driverGeneration, operationId),
    ),
  );

  @override
  Future<void> kill(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) => _execute(
    state.vmId,
    driverGeneration,
    RuntimeKillCommand(
      correlation: _correlation(state.vmId, driverGeneration, operationId),
    ),
  );

  @override
  Future<void> cancel(VmEffect effect, VmControllerState state) async {
    final driverGeneration = effect.driverGeneration;
    if (effect is SpawnDriver && driverGeneration != null) {
      await _factory.cancelSpawn(
        DriverCorrelation(
          vmId: state.vmId,
          driverGeneration: driverGeneration,
          operationId: effect.operationId,
        ),
      );
      return;
    }
    final operationId = effect.operationId;
    if (driverGeneration == null || operationId == null) return;
    final record = _records[_RuntimeDriverKey(state.vmId, driverGeneration)];
    await record?.session.cancel(operationId);
  }

  Future<void> waitUntilEventsDispatched() async {
    await Future<void>.value();
    while (true) {
      final observed = <_RuntimeDriverRecord, Future<void>>{
        for (final record in _records.values) record: record.dispatchTail,
      };
      await Future.wait(observed.values);
      await Future<void>.value();
      final stable = observed.entries.every(
        (entry) =>
            !_records.values.contains(entry.key) ||
            identical(entry.key.dispatchTail, entry.value),
      );
      if (stable) {
        final adapterFailure = _dispatchFailure;
        if (adapterFailure != null) throw adapterFailure;
        for (final record in _records.values) {
          final cleanupFailure = record.cleanupFailure;
          if (cleanupFailure != null) throw cleanupFailure;
          final failure = record.dispatchFailure;
          if (failure != null) throw failure;
          final guestFailure = record.guestDispatchFailure;
          if (guestFailure != null) throw guestFailure;
        }
        return;
      }
    }
  }

  /// Start one owned health/reconnect probe per running generation and retry
  /// current readiness evidence. Guest exec or artifact commands are not replayed.
  void reconcileGuestSessions({RuntimeGuestSessionErrorObserver? onError}) {
    if (_closed) return;
    for (final record in _records.values) {
      _connectGuest(record, onError: onError);
      final failure = record.guestDispatchFailure;
      if (failure != null) {
        onError?.call(
          record.session.correlation,
          failure.error,
          failure.stackTrace,
        );
        _enqueueGuestReadiness(record);
      }
    }
  }

  Future<void> close() {
    final pending = _closeFuture;
    if (pending != null) return pending;
    late Future<void> attempt;
    attempt = _close().whenComplete(() {
      if (identical(_closeFuture, attempt)) _closeFuture = null;
    });
    _closeFuture = attempt;
    return attempt;
  }

  Future<void> _close() async {
    _closed = true;
    final spawns = List<_InFlightSpawn>.of(_inFlightSpawns.values);
    for (final spawn in spawns) {
      await _factory.cancelSpawn(spawn.correlation);
    }
    for (final spawn in spawns) {
      try {
        await spawn.future;
      } catch (_) {
        // Cancellation is the expected terminal result for pending spawns.
      }
    }
    final records = List<_RuntimeDriverRecord>.of(_records.values);
    for (final record in records) {
      record.terminalReported = true;
      await _cleanupRecord(record);
      // Cleanup can itself run on dispatchTail, so join delivery only from this
      // outer close path. Keep the catalog alive until admitted work has drained.
      await record.dispatchTail;
    }
  }

  Future<void> _execute(
    VmId vmId,
    int driverGeneration,
    RuntimeCommand command,
  ) => _translateErrors(() async {
    final record = _requireRecord(vmId, driverGeneration);
    final operationId = command.correlation.operationId;
    if (operationId != null) record.latestOperationId = operationId;
    if (command is RuntimeKillCommand) {
      // A stop may exit before its superseding kill reaches the socket. Process
      // termination still satisfies the kill for this exact owned generation.
      record.terminalOperationId = operationId;
      if (record.terminalReported) {
        _scheduleCleanup(record);
        return;
      }
    }
    await record.session.execute(command);
  });

  Future<T> _translateErrors<T>(Future<T> Function() action) async {
    try {
      _requireOpen();
      return await action();
    } on RuntimeDriverError catch (error) {
      throw VmEffectException(_operationError(error), cause: error);
    } on DriverCapabilityMismatch catch (error) {
      throw VmEffectException(
        OperationError(
          code: ErrorCode.driverUnhealthy,
          message: error.toString(),
          retryable: false,
          details: JsonObjectValue.empty,
        ),
        cause: error,
      );
    }
  }

  _RuntimeDriverRecord _requireRecord(VmId vmId, int driverGeneration) {
    final record = _records[_RuntimeDriverKey(vmId, driverGeneration)];
    if (record != null) return record;
    throw RuntimeDriverError(
      code: RuntimeDriverErrorCode.generationMismatch,
      message: 'driver session does not match the active generation',
      retryable: false,
    );
  }

  void _requireOpen() {
    if (_closed) throw _closedError();
  }

  RuntimeDriverError _closedError() => RuntimeDriverError(
    code: RuntimeDriverErrorCode.cancelled,
    message: 'runtime driver adapter is closed',
    retryable: false,
  );

  void _routeEvent(_RuntimeDriverRecord record, RuntimeEvent event) {
    if (record.terminalReported) return;
    if (!_matchesCorrelation(record, event.correlation)) {
      _routeChannelError(record, _foreignCorrelationError());
      return;
    }
    _observeEvent?.call(event);
    switch (event) {
      case RuntimeStateChanged(:final state):
        record.runtimeRunning = state == RuntimeDriverState.running;
        final operationId = _eventOperationId(record, event.correlation);
        _enqueue(
          record,
          VmStateChanged(
            operationId: operationId,
            driverGeneration: event.correlation.driverGeneration,
            phase: _phase(state),
          ),
        );
        if (state == RuntimeDriverState.running) _connectGuest(record);
      case RuntimeCleanShutdown():
        record.cleanShutdownObserved = true;
      case RuntimeErrorEvent(:final error):
        record.runtimeError = error;
      case RuntimeHeartbeatMissed():
        _enqueue(
          record,
          HeartbeatMissed(
            operationId: _eventOperationId(record, event.correlation),
            driverGeneration: event.correlation.driverGeneration,
          ),
        );
      case DisplayStateChanged(:final state):
        record.displayRevision++;
        record.latestDisplayState = VmDisplayState.values.byName(state.name);
        _enqueue(
          record,
          DisplayObserved(
            driverGeneration: event.correlation.driverGeneration,
            operationId: event.correlation.operationId,
            state: record.latestDisplayState!,
            occurredAt: event.occurredAt,
          ),
        );
      case RuntimeConsoleReady() ||
          RuntimeGuestChannelReady() ||
          RuntimeDriverWarning():
        break;
    }
  }

  @override
  Future<VmDisplayState> setDisplay(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration, {
    required bool open,
  }) => _translateErrors(() async {
    final record = _requireRecord(state.vmId, driverGeneration);
    final revision = record.displayRevision;
    final correlation = _correlation(state.vmId, driverGeneration, operationId);
    // Display operation correlation must not replace the runtime lifecycle
    // owner used for null-correlated state, heartbeat and exit events.
    final result = await record.session.execute(
      open
          ? DisplayOpenCommand(correlation: correlation)
          : DisplayCloseCommand(correlation: correlation),
    );
    final value = result.data?.toJson()['display_state'];
    final snapshot = VmDisplayState.values
        .where(
          (state) => state != VmDisplayState.unknown && state.name == value,
        )
        .firstOrNull;
    if (result.status == RuntimeCommandStatus.accepted || snapshot == null) {
      throw RuntimeDriverError(
        code: RuntimeDriverErrorCode.protocolViolation,
        message: 'display response did not confirm a snapshot',
        retryable: false,
      );
    }
    return record.displayRevision != revision &&
            record.latestDisplayState != null
        ? record.latestDisplayState!
        : snapshot;
  });

  void _connectGuest(
    _RuntimeDriverRecord record, {
    RuntimeGuestSessionErrorObserver? onError,
  }) {
    final guest = record.guestSession;
    if (!record.guestEnabled ||
        !record.runtimeRunning ||
        guest == null ||
        record.guestProbe != null ||
        record.terminalReported ||
        _closed)
      return;
    // A guest hello/health failure is independent of driver/VM lifecycle. Keep
    // ownership until real IO completion, not just a caller timeout wrapper.
    late final Future<void> probe;
    probe = guest
        .refresh(deadline: GuestBridgeDeadline.after(guest.frameTimeout))
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            if (!_closed && !record.terminalReported) {
              onError?.call(record.session.correlation, error, stackTrace);
            }
          },
        )
        .whenComplete(() {
          if (identical(record.guestProbe, probe)) record.guestProbe = null;
        });
    record.guestProbe = probe;
  }

  void _routeExit(_RuntimeDriverRecord record, RuntimeDriverExit exit) {
    if (!_matchesCorrelation(record, exit.correlation)) {
      _routeChannelError(record, _foreignCorrelationError());
      return;
    }
    final runtimeError = record.runtimeError;
    _reportTermination(
      record,
      exit.correlation,
      clean: record.cleanShutdownObserved || exit.clean,
      error: runtimeError != null
          ? _operationError(runtimeError)
          : exit.error == null
          ? null
          : _operationError(exit.error!),
      occurredAt: exit.occurredAt,
    );
  }

  void _routeChannelError(_RuntimeDriverRecord record, Object error) {
    if (record.terminalReported) return;
    record.terminalReported = true;
    _scheduleCleanup(
      record,
      terminalCommand: DriverChannelClosed(
        operationId: record.latestOperationId,
        driverGeneration: record.session.correlation.driverGeneration,
        error: OperationError(
          code: ErrorCode.driverUnhealthy,
          message: 'driver channel closed: $error',
          retryable: true,
          details: JsonObjectValue.empty,
        ),
        occurredAt: _now().toUtc(),
      ),
    );
  }

  void _routeLog(_RuntimeDriverRecord record, RuntimeDriverLogChunk chunk) {
    if (!_matchesCorrelation(record, chunk.correlation)) {
      _routeChannelError(record, _foreignCorrelationError());
      return;
    }
    _observeLog?.call(chunk);
  }

  bool _matchesCorrelation(
    _RuntimeDriverRecord record,
    DriverCorrelation correlation,
  ) =>
      correlation.vmId == record.session.correlation.vmId &&
      correlation.driverGeneration ==
          record.session.correlation.driverGeneration;

  RuntimeDriverError _foreignCorrelationError() => RuntimeDriverError(
    code: RuntimeDriverErrorCode.generationMismatch,
    message: 'driver observation correlation does not match its session',
    retryable: false,
  );

  void _reportTermination(
    _RuntimeDriverRecord record,
    DriverCorrelation correlation, {
    required bool clean,
    OperationError? error,
    DateTime? occurredAt,
  }) {
    if (record.terminalReported) return;
    record.terminalReported = true;
    _scheduleCleanup(
      record,
      terminalCommand: DriverExited(
        operationId:
            record.terminalOperationId ??
            _eventOperationId(record, correlation),
        driverGeneration: correlation.driverGeneration,
        cleanShutdown: clean,
        error: error,
        occurredAt: occurredAt,
      ),
    );
  }

  void _scheduleCleanup(
    _RuntimeDriverRecord record, {
    VmCommand? terminalCommand,
  }) {
    if (terminalCommand != null) record.terminalCommand = terminalCommand;
    if (record.cleanupScheduled) return;
    record.cleanupScheduled = true;
    record.dispatchTail = record.dispatchTail.then((_) async {
      try {
        await _cleanupRecord(record, terminalCommand: record.terminalCommand);
        record.cleanupFailure = null;
      } catch (error) {
        final failure = error is RuntimeDriverError
            ? error
            : RuntimeDriverError(
                code: RuntimeDriverErrorCode.driverUnhealthy,
                message: 'driver process release failed: $error',
                retryable: true,
              );
        record.cleanupFailure = failure;
        await _dispatchCommand(
          record,
          EffectExecutionFailed(
            effectType: 'DriverProcessRelease',
            operationId: record.terminalOperationId ?? record.latestOperationId,
            driverGeneration: record.session.correlation.driverGeneration,
            error: _operationError(failure),
          ),
        );
      } finally {
        record.cleanupScheduled = false;
      }
    });
  }

  Future<void> _cleanupRecord(
    _RuntimeDriverRecord record, {
    VmCommand? terminalCommand,
  }) async {
    final key = _RuntimeDriverKey(
      record.session.correlation.vmId,
      record.session.correlation.driverGeneration,
    );
    await record.eventSubscription?.cancel();
    await record.logSubscription?.cancel();
    await record.guestSubscription?.cancel();
    final guestClosing = record.guestSession?.close();
    await _factory.release(record.session.correlation);
    await guestClosing;
    await record.guestProbe;
    if (_activeByVm[record.session.correlation.vmId] == key) {
      _activeByVm.remove(record.session.correlation.vmId);
    }
    if (terminalCommand != null && !_closed) {
      // A newer stop/kill can own this generation while process release waits.
      // Report completion to that accepted operation, never to a replacement
      // generation or the superseded operation captured before cleanup.
      final completion = switch (terminalCommand) {
        DriverExited(
          :final driverGeneration,
          :final cleanShutdown,
          :final error,
          :final occurredAt,
        ) =>
          DriverExited(
            operationId: record.latestOperationId,
            driverGeneration: driverGeneration,
            cleanShutdown: cleanShutdown,
            error: error,
            occurredAt: occurredAt,
          ),
        DriverChannelClosed(
          :final driverGeneration,
          :final error,
          :final occurredAt,
        ) =>
          DriverChannelClosed(
            operationId: record.latestOperationId,
            driverGeneration: driverGeneration,
            error: error,
            occurredAt: occurredAt,
          ),
        _ => terminalCommand,
      };
      await _dispatchCommand(record, completion);
    }
    if (identical(_records[key], record)) _records.remove(key);
  }

  void _enqueue(_RuntimeDriverRecord record, VmCommand command) {
    if (record.dispatchFailure != null) return;
    record.dispatchTail = record.dispatchTail.then((_) async {
      await _dispatchCommand(record, command);
    });
  }

  void _enqueueGuestReadiness(_RuntimeDriverRecord record) {
    if (_closed ||
        record.terminalReported ||
        !record.runtimeRunning ||
        !record.guestEnabled ||
        record.dispatchFailure != null ||
        record.guestPublicationPending)
      return;
    record.guestPublicationPending = true;
    record.dispatchTail = record.dispatchTail.then((_) async {
      final observation = record.latestGuestObservation;
      try {
        if (_closed ||
            record.terminalReported ||
            !record.runtimeRunning ||
            observation == null ||
            !observation.isCurrent)
          return;
        await _dispatchCommand(
          record,
          GuestReadinessObserved(
            vmId: observation.correlation.vmId,
            driverGeneration: observation.correlation.driverGeneration,
            revision: observation.revision,
            ready: observation.ready,
            stillCurrent: () => observation.isCurrent,
          ),
        );
      } finally {
        record.guestPublicationPending = false;
        // Coalesce changes arriving during delivery. A failed unchanged
        // observation waits for the next tick instead of retrying in a loop.
        if (!identical(observation, record.latestGuestObservation)) {
          _enqueueGuestReadiness(record);
        }
      }
    });
  }

  Future<void> _dispatchCommand(
    _RuntimeDriverRecord record,
    VmCommand command,
  ) async {
    if (record.dispatchFailure != null) return;
    try {
      await _dispatch(record.session.correlation.vmId, command);
      if (command is GuestReadinessObserved) record.guestDispatchFailure = null;
    } catch (error, stackTrace) {
      final failure = RuntimeDriverDispatchException(
        vmId: record.session.correlation.vmId,
        driverGeneration: record.session.correlation.driverGeneration,
        command: command,
        error: error,
        stackTrace: stackTrace,
      );
      if (command is GuestReadinessObserved) {
        // Surface the rolled-back observation without converting a guest
        // publication failure into driver death or a VM restart decision.
        record.guestDispatchFailure = failure;
        return;
      }
      record.dispatchFailure = failure;
      _dispatchFailure ??= failure;
      record.terminalReported = true;
      _scheduleCleanup(record);
    }
  }

  OperationId _eventOperationId(
    _RuntimeDriverRecord record,
    DriverCorrelation correlation,
  ) => correlation.operationId ?? record.latestOperationId;

  DriverCorrelation _correlation(
    VmId vmId,
    int driverGeneration,
    OperationId operationId,
  ) => DriverCorrelation(
    vmId: vmId,
    driverGeneration: driverGeneration,
    operationId: operationId,
  );
}

final class _RuntimeDriverKey {
  const _RuntimeDriverKey(this.vmId, this.driverGeneration);

  final VmId vmId;
  final int driverGeneration;

  @override
  bool operator ==(Object other) =>
      other is _RuntimeDriverKey &&
      other.vmId == vmId &&
      other.driverGeneration == driverGeneration;

  @override
  int get hashCode => Object.hash(vmId, driverGeneration);
}

final class _RuntimeDriverRecord {
  _RuntimeDriverRecord(this.session, this.launchOperationId)
    : latestOperationId = launchOperationId;

  final RuntimeDriverSession session;
  final OperationId launchOperationId;
  OperationId latestOperationId;
  OperationId? terminalOperationId;
  StreamSubscription<RuntimeEvent>? eventSubscription;
  StreamSubscription<RuntimeDriverLogChunk>? logSubscription;
  HostGuestSession? guestSession;
  StreamSubscription<GuestReadinessObservation>? guestSubscription;
  Future<void>? guestProbe;
  bool guestEnabled = false;
  bool runtimeRunning = false;
  int displayRevision = 0;
  VmDisplayState? latestDisplayState;
  GuestReadinessObservation? latestGuestObservation;
  bool guestPublicationPending = false;
  Future<void> dispatchTail = Future<void>.value();
  bool terminalReported = false;
  bool cleanupScheduled = false;
  VmCommand? terminalCommand;
  RuntimeDriverError? cleanupFailure;
  bool cleanShutdownObserved = false;
  RuntimeDriverError? runtimeError;
  RuntimeDriverDispatchException? dispatchFailure;
  RuntimeDriverDispatchException? guestDispatchFailure;
}

final class _InFlightSpawn {
  const _InFlightSpawn(this.correlation, this.future);

  final DriverCorrelation correlation;
  final Future<RuntimeDriverSession> future;
}

VmPhase _phase(RuntimeDriverState state) => switch (state) {
  RuntimeDriverState.configured => VmPhase.configuring,
  RuntimeDriverState.starting => VmPhase.starting,
  RuntimeDriverState.running => VmPhase.running,
  RuntimeDriverState.stopping => VmPhase.stopping,
  RuntimeDriverState.stopped => VmPhase.stopped,
  RuntimeDriverState.error => VmPhase.crashed,
};

OperationError _operationError(RuntimeDriverError error) => OperationError(
  code: switch (error.code) {
    RuntimeDriverErrorCode.invalidRuntimeConfig => ErrorCode.vmSpecInvalid,
    RuntimeDriverErrorCode.runtimeStartFailed => ErrorCode.driverStartFailed,
    RuntimeDriverErrorCode.invalidRuntimeState ||
    RuntimeDriverErrorCode.runtimeStopFailed ||
    RuntimeDriverErrorCode.runtimeKillFailed ||
    RuntimeDriverErrorCode.driverUnhealthy ||
    RuntimeDriverErrorCode.capabilityMismatch ||
    RuntimeDriverErrorCode.generationMismatch ||
    RuntimeDriverErrorCode.protocolViolation ||
    RuntimeDriverErrorCode.authenticationFailed ||
    RuntimeDriverErrorCode.displayUnavailable ||
    RuntimeDriverErrorCode.cancelled => ErrorCode.driverUnhealthy,
    RuntimeDriverErrorCode.driverInternalError => ErrorCode.internalError,
  },
  message: error.message,
  retryable: error.retryable,
  details: error.details ?? JsonObjectValue.empty,
);
