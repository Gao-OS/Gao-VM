import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';

import 'runtime_driver.dart';

final class ManualRuntimeTask {
  ManualRuntimeTask._(this.deadline, this.sequence, this._callback);

  final Duration deadline;
  final int sequence;
  final void Function() _callback;
  bool _cancelled = false;

  bool get isActive => !_cancelled;

  void cancel() => _cancelled = true;

  void _run() {
    if (_cancelled) return;
    _cancelled = true;
    _callback();
  }
}

final class ManualRuntimeScheduler {
  Duration _elapsed = Duration.zero;
  var _sequence = 0;
  final List<ManualRuntimeTask> _tasks = [];

  Duration get elapsed => _elapsed;
  DateTime get now =>
      DateTime.fromMillisecondsSinceEpoch(_elapsed.inMilliseconds, isUtc: true);
  int get pendingTaskCount => _tasks.where((task) => task.isActive).length;

  ManualRuntimeTask schedule(Duration delay, void Function() callback) {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay', 'must not be negative');
    }
    final task = ManualRuntimeTask._(_elapsed + delay, _sequence++, callback);
    _tasks.add(task);
    return task;
  }

  void advanceBy(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    final target = _elapsed + duration;
    while (true) {
      final active = _orderedActiveTasks();
      if (active.isEmpty || active.first.deadline > target) break;
      _elapsed = active.first.deadline;
      _runDue();
    }
    _elapsed = target;
  }

  bool runNext() {
    final active = _orderedActiveTasks();
    if (active.isEmpty) return false;
    _elapsed = active.first.deadline;
    _runDue();
    return true;
  }

  void runUntilIdle() {
    while (runNext()) {}
  }

  void _runDue() {
    while (true) {
      final due = _orderedActiveTasks()
          .where((task) => task.deadline <= _elapsed)
          .toList(growable: false);
      if (due.isEmpty) return;
      due.first._run();
    }
  }

  List<ManualRuntimeTask> _orderedActiveTasks() =>
      _tasks.where((task) => task.isActive).toList()..sort((left, right) {
        final byDeadline = left.deadline.compareTo(right.deadline);
        return byDeadline != 0
            ? byDeadline
            : left.sequence.compareTo(right.sequence);
      });
}

final class FakeRuntimeDriverScenario {
  const FakeRuntimeDriverScenario({
    this.spawnDelay = Duration.zero,
    this.startDelay = Duration.zero,
    this.heartbeatInitiallyHung = false,
    this.capabilities,
    this.configureFailures = const [],
    this.startFailures = const [],
  });

  final Duration spawnDelay;
  final Duration startDelay;
  final bool heartbeatInitiallyHung;
  final DriverCapabilities? capabilities;
  final List<RuntimeDriverError> configureFailures;
  final List<RuntimeDriverError> startFailures;
}

typedef FakeRuntimeScenarioResolver =
    FakeRuntimeDriverScenario Function(RuntimeDriverLaunch launch);

final class FakeRuntimeDriverFactory implements RuntimeDriverFactory {
  FakeRuntimeDriverFactory({
    required this.scheduler,
    this.scenario = const FakeRuntimeDriverScenario(),
    this.scenarioForLaunch,
  });

  final ManualRuntimeScheduler scheduler;
  final FakeRuntimeDriverScenario scenario;
  final FakeRuntimeScenarioResolver? scenarioForLaunch;
  final Map<String, FakeRuntimeDriverSession> _sessions = {};
  final Map<String, _PendingFakeSpawn> _pendingSpawns = {};
  final Set<String> _cancelledSpawns = {};

  int get activeSessionCount => _sessions.length;
  int get pendingSpawnCount => _pendingSpawns.length;
  Iterable<FakeRuntimeDriverSession> get sessions =>
      List<FakeRuntimeDriverSession>.unmodifiable(_sessions.values);

  FakeRuntimeDriverControl controlFor(DriverCorrelation correlation) {
    final session = _sessions[_key(correlation)];
    if (session == null) {
      throw StateError('fake runtime session does not exist');
    }
    return session.control;
  }

  @override
  Future<FakeRuntimeDriverSession> spawn(RuntimeDriverLaunch launch) async {
    final key = _key(launch.correlation);
    if (_cancelledSpawns.remove(key)) {
      throw _cancelledError('fake driver spawn was cancelled');
    }
    if (_sessions.containsKey(key)) {
      throw StateError('fake runtime session already exists for $key');
    }
    final selectedScenario = scenarioForLaunch?.call(launch) ?? scenario;
    if (selectedScenario.spawnDelay > Duration.zero) {
      if (_pendingSpawns.containsKey(key)) {
        throw StateError('fake runtime spawn is already pending for $key');
      }
      final completer = Completer<FakeRuntimeDriverSession>();
      late ManualRuntimeTask task;
      task = scheduler.schedule(selectedScenario.spawnDelay, () {
        final pending = _pendingSpawns[key];
        if (pending == null || !identical(pending.task, task)) return;
        _pendingSpawns.remove(key);
        final session = _createSession(launch, selectedScenario);
        completer.complete(session);
      });
      _pendingSpawns[key] = _PendingFakeSpawn(task, completer);
      return completer.future;
    }
    return _createSession(launch, selectedScenario);
  }

  FakeRuntimeDriverSession _createSession(
    RuntimeDriverLaunch launch,
    FakeRuntimeDriverScenario selectedScenario,
  ) {
    final key = _key(launch.correlation);
    final session = FakeRuntimeDriverSession._(
      correlation: launch.correlation,
      scheduler: scheduler,
      scenario: selectedScenario,
    );
    _sessions[key] = session;
    return session;
  }

  @override
  Future<void> cancelSpawn(DriverCorrelation correlation) async {
    _cancelledSpawns.add(_key(correlation));
    final pending = _pendingSpawns.remove(_key(correlation));
    if (pending != null) {
      pending.task.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          _cancelledError('fake driver spawn was cancelled'),
        );
      }
    }
    await release(correlation);
  }

  @override
  Future<void> release(DriverCorrelation correlation) async {
    final pending = _pendingSpawns.remove(_key(correlation));
    if (pending != null) {
      pending.task.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          _cancelledError('fake driver spawn was released'),
        );
      }
    }
    final session = _sessions.remove(_key(correlation));
    await session?.close();
  }

  String _key(DriverCorrelation correlation) =>
      '${correlation.vmId.value}:${correlation.driverGeneration}';
}

final class _PendingFakeSpawn {
  const _PendingFakeSpawn(this.task, this.completer);

  final ManualRuntimeTask task;
  final Completer<FakeRuntimeDriverSession> completer;
}

final class FakeRuntimeDriverSession implements RuntimeDriverSession {
  FakeRuntimeDriverSession._({
    required this.correlation,
    required ManualRuntimeScheduler scheduler,
    required FakeRuntimeDriverScenario scenario,
  }) : _scheduler = scheduler,
       _scenario = scenario,
       capabilities = scenario.capabilities ?? DriverCapabilities.all {
    _heartbeatHung = scenario.heartbeatInitiallyHung;
    _configureFailures.addAll(scenario.configureFailures);
    _startFailures.addAll(scenario.startFailures);
    control = FakeRuntimeDriverControl._(this);
  }

  final ManualRuntimeScheduler _scheduler;
  final FakeRuntimeDriverScenario _scenario;
  final StreamController<RuntimeEvent> _events =
      StreamController<RuntimeEvent>.broadcast(sync: true);
  final StreamController<RuntimeDriverLogChunk> _logs =
      StreamController<RuntimeDriverLogChunk>.broadcast(sync: true);
  final Completer<RuntimeDriverExit> _exit = Completer<RuntimeDriverExit>();
  final List<RuntimeCommand> _commands = [];
  final Map<OperationId, ManualRuntimeTask> _pendingTasks = {};
  final List<Completer<RuntimeCommandResult>> _pendingPings = [];
  final Queue<RuntimeDriverError> _configureFailures = Queue();
  final Queue<RuntimeDriverError> _startFailures = Queue();

  @override
  final DriverCorrelation correlation;
  @override
  final DriverCapabilities capabilities;
  late final FakeRuntimeDriverControl control;
  RuntimeDriverState _state = RuntimeDriverState.stopped;
  DriverCapabilities? _acceptedCapabilities;
  bool _configured = false;
  bool _heartbeatHung = false;
  bool _closed = false;
  RuntimeDriverState? _nullStateOnNextLifecycle;

  List<RuntimeCommand> get commandHistory =>
      List<RuntimeCommand>.unmodifiable(_commands);
  RuntimeDriverState get state => _state;

  @override
  Stream<RuntimeEvent> get events => _events.stream;
  @override
  Stream<RuntimeDriverLogChunk> get logs => _logs.stream;
  @override
  Future<RuntimeDriverExit> get exited => _exit.future;

  @override
  Future<DriverCapabilities> connect(DriverCapabilities required) async {
    _requireOperational();
    final accepted = capabilities.negotiate(required);
    if (!accepted.containsAll(required)) {
      throw DriverCapabilityMismatch(required: required, offered: capabilities);
    }
    _acceptedCapabilities = accepted;
    return accepted;
  }

  @override
  Future<RuntimeCommandResult> execute(RuntimeCommand command) async {
    _requireOperational();
    _requireCorrelation(command.correlation);
    final accepted = _acceptedCapabilities;
    if (accepted == null) throw _invalidState('fake runtime is not connected');
    final capability = command.capability;
    if (capability != null && !accepted.contains(capability)) {
      throw RuntimeDriverError(
        code: RuntimeDriverErrorCode.capabilityMismatch,
        message: 'capability ${capability.name} was not negotiated',
        retryable: false,
      );
    }
    _commands.add(command);
    if (command is RuntimeConfigureCommand ||
        command is RuntimeStartCommand ||
        command is RuntimeStopCommand ||
        command is RuntimeKillCommand) {
      final injectedState = _nullStateOnNextLifecycle;
      _nullStateOnNextLifecycle = null;
      if (injectedState != null) {
        _emit(
          RuntimeStateChanged(
            correlation: DriverCorrelation(
              vmId: correlation.vmId,
              driverGeneration: correlation.driverGeneration,
              operationId: null,
            ),
            occurredAt: _scheduler.now,
            state: injectedState,
          ),
        );
      }
    }
    return switch (command) {
      RuntimeConfigureCommand() => _configure(command),
      RuntimeStartCommand() => _start(command),
      RuntimeStopCommand() => _stop(command),
      RuntimeKillCommand() => _kill(command),
      RuntimeStatusCommand() ||
      RuntimePingCommand() ||
      DisplayStatusCommand() ||
      ConsoleStatusCommand() ||
      GuestStatusCommand() => const RuntimeCommandResult(
        status: RuntimeCommandStatus.succeeded,
      ),
      DisplayOpenCommand() || DisplayCloseCommand() =>
        const RuntimeCommandResult(status: RuntimeCommandStatus.succeeded),
    };
  }

  RuntimeCommandResult _configure(RuntimeConfigureCommand command) {
    if (_configureFailures.isNotEmpty) throw _configureFailures.removeFirst();
    if (_configured && _state == RuntimeDriverState.configured) {
      return const RuntimeCommandResult(status: RuntimeCommandStatus.noop);
    }
    if (const {
      RuntimeDriverState.starting,
      RuntimeDriverState.running,
      RuntimeDriverState.stopping,
      RuntimeDriverState.error,
    }.contains(_state)) {
      throw _invalidState('runtime configure is invalid while ${_state.name}');
    }
    _configured = true;
    _emitState(RuntimeDriverState.configured, command.correlation);
    return const RuntimeCommandResult(status: RuntimeCommandStatus.succeeded);
  }

  RuntimeCommandResult _start(RuntimeStartCommand command) {
    if (_startFailures.isNotEmpty) throw _startFailures.removeFirst();
    if (!_configured)
      throw _invalidState('runtime must be configured before start');
    if (_state == RuntimeDriverState.starting ||
        _state == RuntimeDriverState.running) {
      return const RuntimeCommandResult(status: RuntimeCommandStatus.noop);
    }
    if (_state == RuntimeDriverState.stopping ||
        _state == RuntimeDriverState.error) {
      throw _invalidState('runtime start is invalid while ${_state.name}');
    }
    _emitState(RuntimeDriverState.starting, command.correlation);
    final operationId = command.correlation.operationId;
    final task = _scheduler.schedule(_scenario.startDelay, () {
      if (_closed) return;
      if (operationId != null) _pendingTasks.remove(operationId);
      _emitState(RuntimeDriverState.running, command.correlation);
    });
    if (operationId != null) _pendingTasks[operationId] = task;
    return const RuntimeCommandResult(status: RuntimeCommandStatus.accepted);
  }

  RuntimeCommandResult _stop(RuntimeStopCommand command) {
    if (_state == RuntimeDriverState.stopped) {
      return const RuntimeCommandResult(status: RuntimeCommandStatus.noop);
    }
    if (_state == RuntimeDriverState.stopping) {
      return const RuntimeCommandResult(status: RuntimeCommandStatus.noop);
    }
    if (_state == RuntimeDriverState.error) {
      throw _invalidState('runtime stop is invalid while error');
    }
    _cancelAllPending();
    _emitState(RuntimeDriverState.stopping, command.correlation);
    _emitState(RuntimeDriverState.stopped, command.correlation);
    _finishExit(
      RuntimeDriverExit(
        correlation: command.correlation,
        occurredAt: _scheduler.now,
        clean: true,
        exitCode: 0,
      ),
    );
    return const RuntimeCommandResult(status: RuntimeCommandStatus.accepted);
  }

  RuntimeCommandResult _kill(RuntimeKillCommand command) {
    _cancelAllPending();
    _finishExit(
      RuntimeDriverExit(
        correlation: command.correlation,
        occurredAt: _scheduler.now,
        clean: false,
        exitCode: 137,
      ),
    );
    return const RuntimeCommandResult(status: RuntimeCommandStatus.accepted);
  }

  @override
  Future<RuntimeCommandResult> ping() async {
    _requireOperational();
    if (_acceptedCapabilities == null) {
      throw _invalidState('fake runtime is not connected');
    }
    if (!_heartbeatHung) {
      return const RuntimeCommandResult(status: RuntimeCommandStatus.succeeded);
    }
    final completer = Completer<RuntimeCommandResult>();
    _pendingPings.add(completer);
    return completer.future;
  }

  @override
  Future<void> cancel(OperationId operationId) async {
    _cancelPending(operationId);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancelAllPending();
    _failPendingPings(_cancelledError('fake runtime session closed'));
    if (!_exit.isCompleted) {
      _finishExit(
        RuntimeDriverExit(
          correlation: correlation,
          occurredAt: _scheduler.now,
          clean: true,
          exitCode: 0,
        ),
      );
    }
    await _events.close();
    await _logs.close();
  }

  void _requireOperational() {
    if (_closed || _exit.isCompleted) {
      throw _invalidState('fake runtime session is terminal');
    }
  }

  void _requireCorrelation(DriverCorrelation candidate) {
    if (candidate.vmId != correlation.vmId ||
        candidate.driverGeneration != correlation.driverGeneration) {
      throw RuntimeDriverError(
        code: RuntimeDriverErrorCode.generationMismatch,
        message: 'command correlation does not match fake session',
        retryable: false,
      );
    }
  }

  void _emitState(RuntimeDriverState state, DriverCorrelation correlation) {
    _state = state;
    _emit(
      RuntimeStateChanged(
        correlation: correlation,
        occurredAt: _scheduler.now,
        state: state,
      ),
    );
  }

  void _emit(RuntimeEvent event, {bool allowAfterExit = false}) {
    if (_closed || _exit.isCompleted && !allowAfterExit) return;
    _events.add(event);
  }

  void _cancelPending(OperationId? operationId) {
    if (operationId == null) return;
    _pendingTasks.remove(operationId)?.cancel();
  }

  void _cancelAllPending() {
    for (final task in _pendingTasks.values) {
      task.cancel();
    }
    _pendingTasks.clear();
  }

  void _finishExit(RuntimeDriverExit exit) {
    if (_exit.isCompleted) return;
    _cancelAllPending();
    _exit.complete(exit);
    _failPendingPings(
      RuntimeDriverError(
        code: RuntimeDriverErrorCode.driverUnhealthy,
        message: 'fake runtime session exited',
        retryable: true,
      ),
    );
  }

  void _resumeHeartbeat() {
    _heartbeatHung = false;
    final pending = List<Completer<RuntimeCommandResult>>.of(_pendingPings);
    _pendingPings.clear();
    for (final ping in pending) {
      if (!ping.isCompleted) {
        ping.complete(
          const RuntimeCommandResult(status: RuntimeCommandStatus.succeeded),
        );
      }
    }
  }

  void _failPendingPings(RuntimeDriverError error) {
    final pending = List<Completer<RuntimeCommandResult>>.of(_pendingPings);
    _pendingPings.clear();
    for (final ping in pending) {
      if (!ping.isCompleted) ping.completeError(error);
    }
  }
}

RuntimeDriverError _invalidState(String message) => RuntimeDriverError(
  code: RuntimeDriverErrorCode.invalidRuntimeState,
  message: message,
  retryable: false,
);

final class FakeRuntimeDriverControl {
  FakeRuntimeDriverControl._(this._session);

  final FakeRuntimeDriverSession _session;

  RuntimeDriverState get state => _session.state;
  List<RuntimeCommand> get commandHistory => _session.commandHistory;

  void emitEventForTest(RuntimeEvent event) {
    _session._emit(event, allowAfterExit: true);
  }

  void emitLogForTest(RuntimeDriverLogChunk chunk) {
    if (_session._closed) return;
    _session._logs.add(chunk);
  }

  void exitForTest(RuntimeDriverExit exit) {
    _session._finishExit(exit);
  }

  Future<void> closeEventStreamForTest() => _session._events.close();

  void errorEventStreamForTest(Object error) {
    _session._events.addError(error);
  }

  void errorLogStreamForTest(Object error) {
    _session._logs.addError(error);
  }

  void failNextConfigure(RuntimeDriverError error) {
    _requireInjectionActive();
    _session._configureFailures.add(error);
  }

  void emitNullStateOnNextLifecycle(RuntimeDriverState state) {
    _requireInjectionActive();
    _session._nullStateOnNextLifecycle = state;
  }

  void failNextStart(RuntimeDriverError error) {
    _requireInjectionActive();
    _session._startFailures.add(error);
  }

  void hangHeartbeat() {
    _requireInjectionActive();
    _session._heartbeatHung = true;
  }

  void resumeHeartbeat() {
    _requireInjectionActive();
    _session._resumeHeartbeat();
  }

  void emitState(
    RuntimeDriverState state, {
    OperationId? operationId,
    bool late = false,
  }) {
    if (!late) _requireInjectionActive();
    final correlation = _session.correlation.withOperation(
      operationId ?? _session.correlation.operationId,
    );
    _session._state = state;
    _session._emit(
      RuntimeStateChanged(
        correlation: correlation,
        occurredAt: _session._scheduler.now,
        state: state,
      ),
      allowAfterExit: late,
    );
  }

  void guestShutdown({OperationId? operationId}) {
    _requireInjectionActive();
    final correlation = _session.correlation.withOperation(
      operationId ?? _session.correlation.operationId,
    );
    emitState(RuntimeDriverState.stopped, operationId: operationId);
    _session._emit(
      RuntimeCleanShutdown(
        correlation: correlation,
        occurredAt: _session._scheduler.now,
      ),
    );
  }

  void runtimeError(RuntimeDriverError error, {OperationId? operationId}) {
    _requireInjectionActive();
    _session._emit(
      RuntimeErrorEvent(
        correlation: _session.correlation.withOperation(
          operationId ?? _session.correlation.operationId,
        ),
        occurredAt: _session._scheduler.now,
        error: error,
      ),
    );
  }

  void crash({int exitCode = 42, RuntimeDriverError? error}) {
    _requireInjectionActive();
    _session._cancelAllPending();
    _session._finishExit(
      RuntimeDriverExit(
        correlation: _session.correlation,
        occurredAt: _session._scheduler.now,
        clean: false,
        exitCode: exitCode,
        error:
            error ??
            RuntimeDriverError(
              code: RuntimeDriverErrorCode.driverUnhealthy,
              message: 'injected fake driver crash',
              retryable: true,
            ),
      ),
    );
  }

  void emitLargeWarning(int characterCount) {
    _requireInjectionActive();
    if (characterCount < 0) {
      throw ArgumentError.value(characterCount, 'characterCount');
    }
    _session._emit(
      RuntimeDriverWarning(
        correlation: _session.correlation,
        occurredAt: _session._scheduler.now,
        code: 'FAKE_LARGE_EVENT',
        message: List.filled(characterCount, 'x').join(),
      ),
    );
  }

  void emitLog(
    int byteCount, {
    RuntimeDriverLogStream stream = RuntimeDriverLogStream.stdout,
  }) {
    _requireInjectionActive();
    if (byteCount < 0) throw ArgumentError.value(byteCount, 'byteCount');
    if (_session._closed) return;
    _session._logs.add(
      RuntimeDriverLogChunk(
        correlation: _session.correlation,
        stream: stream,
        bytes: Uint8List(byteCount),
      ),
    );
  }

  void _requireInjectionActive() {
    if (_session._closed || _session._exit.isCompleted) {
      throw _invalidState('fake runtime session is terminal');
    }
  }
}

RuntimeDriverError _cancelledError(String message) => RuntimeDriverError(
  code: RuntimeDriverErrorCode.cancelled,
  message: message,
  retryable: true,
);
