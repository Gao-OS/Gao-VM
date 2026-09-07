import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';

import 'runtime_driver.dart';
import 'vm_controller.dart';
import 'vm_controller_reducer.dart';
import 'vm_effect_runner.dart';

typedef RuntimeDriverConfigurationResolver =
    Future<RuntimeDriverConfiguration> Function(VmControllerState state);
typedef RuntimeDriverCommandDispatcher =
    Future<void> Function(VmId vmId, VmCommand command);
typedef RuntimeDriverEventObserver = void Function(RuntimeEvent event);
typedef RuntimeDriverLogObserver = void Function(RuntimeDriverLogChunk chunk);

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
    implements VmDriverEffectAdapter, VmEffectCancellationAdapter {
  RuntimeDriverEffectAdapter({
    required RuntimeDriverFactory factory,
    required RuntimeDriverConfigurationResolver resolveConfiguration,
    required RuntimeDriverCommandDispatcher dispatch,
    DriverCapabilities? requiredCapabilities,
    RuntimeDriverEventObserver? observeEvent,
    RuntimeDriverLogObserver? observeLog,
    DateTime Function()? now,
  }) : _factory = factory,
       _resolveConfiguration = resolveConfiguration,
       _dispatch = dispatch,
       _requiredCapabilities =
           requiredCapabilities ?? DriverCapabilities.runtimeCore,
       _observeEvent = observeEvent,
       _observeLog = observeLog,
       _now = now ?? DateTime.now;

  final RuntimeDriverFactory _factory;
  final RuntimeDriverConfigurationResolver _resolveConfiguration;
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
    final configuration = await _resolveConfiguration(state);
    record.latestOperationId = operationId;
    await record.session.execute(
      RuntimeConfigureCommand(
        correlation: _correlation(state.vmId, driverGeneration, operationId),
        configuration: configuration,
      ),
    );
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
          final failure = record.dispatchFailure;
          if (failure != null) throw failure;
        }
        return;
      }
    }
  }

  Future<void> close() => _closeFuture ??= _close();

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
    _records.clear();
    _activeByVm.clear();
    for (final record in records) {
      record.terminalReported = true;
      await record.eventSubscription?.cancel();
      await record.logSubscription?.cancel();
      await _factory.release(record.session.correlation);
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
    await record.session.execute(command);
  });

  Future<void> _translateErrors(Future<void> Function() action) async {
    try {
      _requireOpen();
      await action();
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
    if (!_matchesCorrelation(record, event.correlation)) {
      _routeChannelError(record, _foreignCorrelationError());
      return;
    }
    _observeEvent?.call(event);
    switch (event) {
      case RuntimeStateChanged(:final state):
        final operationId = _eventOperationId(record, event.correlation);
        _enqueue(
          record,
          VmStateChanged(
            operationId: operationId,
            driverGeneration: event.correlation.driverGeneration,
            phase: _phase(state),
          ),
        );
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
      case DisplayStateChanged() ||
          RuntimeConsoleReady() ||
          RuntimeGuestChannelReady() ||
          RuntimeDriverWarning():
        break;
    }
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
    _enqueue(
      record,
      DriverChannelClosed(
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
    _scheduleCleanup(record);
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
    _enqueue(
      record,
      DriverExited(
        operationId: _eventOperationId(record, correlation),
        driverGeneration: correlation.driverGeneration,
        cleanShutdown: clean,
        error: error,
        occurredAt: occurredAt,
      ),
    );
    _scheduleCleanup(record);
  }

  void _scheduleCleanup(_RuntimeDriverRecord record) {
    if (record.cleanupScheduled) return;
    record.cleanupScheduled = true;
    record.dispatchTail = record.dispatchTail.then((_) async {
      await _cleanupRecord(record);
    });
  }

  Future<void> _cleanupRecord(_RuntimeDriverRecord record) async {
    final key = _RuntimeDriverKey(
      record.session.correlation.vmId,
      record.session.correlation.driverGeneration,
    );
    await record.eventSubscription?.cancel();
    await record.logSubscription?.cancel();
    await _factory.release(record.session.correlation);
    if (identical(_records[key], record)) _records.remove(key);
    if (_activeByVm[record.session.correlation.vmId] == key) {
      _activeByVm.remove(record.session.correlation.vmId);
    }
  }

  void _enqueue(_RuntimeDriverRecord record, VmCommand command) {
    if (record.dispatchFailure != null) return;
    record.dispatchTail = record.dispatchTail.then((_) async {
      if (record.dispatchFailure != null) return;
      try {
        await _dispatch(record.session.correlation.vmId, command);
      } catch (error, stackTrace) {
        final failure = RuntimeDriverDispatchException(
          vmId: record.session.correlation.vmId,
          driverGeneration: record.session.correlation.driverGeneration,
          command: command,
          error: error,
          stackTrace: stackTrace,
        );
        record.dispatchFailure = failure;
        _dispatchFailure ??= failure;
        record.terminalReported = true;
        _scheduleCleanup(record);
      }
    });
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
  StreamSubscription<RuntimeEvent>? eventSubscription;
  StreamSubscription<RuntimeDriverLogChunk>? logSubscription;
  Future<void> dispatchTail = Future<void>.value();
  bool terminalReported = false;
  bool cleanupScheduled = false;
  bool cleanShutdownObserved = false;
  RuntimeDriverError? runtimeError;
  RuntimeDriverDispatchException? dispatchFailure;
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
