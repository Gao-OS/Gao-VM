import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';

import 'driver_protocol_v2.dart';
import 'driver_rpc_channel.dart';
import 'driver_runtime_layout.dart';
import 'runtime_driver.dart';

final class DriverExecutable {
  DriverExecutable({
    required this.path,
    this.prefixArguments = const [],
    this.environment = const {},
  }) {
    if (!path.startsWith('/')) {
      throw ArgumentError.value(
        path,
        'path',
        'driver executable must be absolute',
      );
    }
  }

  final String path;
  final List<String> prefixArguments;
  final Map<String, String> environment;
}

typedef DriverExecutableResolver =
    FutureOr<DriverExecutable> Function(VmId vmId);
typedef DriverBundlePathResolver = FutureOr<String> Function(VmId vmId);

final class DriverProcessManager implements RuntimeDriverFactory {
  DriverProcessManager({
    required DriverRuntimeLayout layout,
    required DriverExecutableResolver resolveExecutable,
    required DriverBundlePathResolver resolveBundlePath,
    Duration connectTimeout = const Duration(seconds: 10),
    Duration handshakeTimeout = const Duration(seconds: 5),
    Duration heartbeatInterval = const Duration(seconds: 5),
    Duration heartbeatTimeout = const Duration(seconds: 5),
    Duration shutdownTimeout = const Duration(seconds: 10),
    DateTime Function()? now,
    Random? secureRandom,
  }) : _layout = layout,
       _resolveExecutable = resolveExecutable,
       _resolveBundlePath = resolveBundlePath,
       _connectTimeout = connectTimeout,
       _handshakeTimeout = handshakeTimeout,
       _heartbeatInterval = heartbeatInterval,
       _heartbeatTimeout = heartbeatTimeout,
       _shutdownTimeout = shutdownTimeout,
       _now = now ?? DateTime.now,
       _random = secureRandom ?? Random.secure() {
    if (connectTimeout <= Duration.zero ||
        handshakeTimeout <= Duration.zero ||
        heartbeatInterval <= Duration.zero ||
        heartbeatTimeout <= Duration.zero ||
        shutdownTimeout <= Duration.zero) {
      throw ArgumentError('driver process deadlines must be positive');
    }
  }

  final DriverRuntimeLayout _layout;
  final DriverExecutableResolver _resolveExecutable;
  final DriverBundlePathResolver _resolveBundlePath;
  final Duration _connectTimeout;
  final Duration _handshakeTimeout;
  final Duration _heartbeatInterval;
  final Duration _heartbeatTimeout;
  final Duration _shutdownTimeout;
  final DateTime Function() _now;
  final Random _random;
  final Map<_DriverKey, ProcessRuntimeDriverSession> _sessions = {};
  final Map<_DriverKey, _SpawnAttempt> _spawns = {};
  final Map<_DriverKey, Future<void>> _releases = {};
  final Map<VmId, _DriverKey> _activeByVm = {};
  bool _closed = false;
  Future<void>? _closeFuture;

  int get activeProcessCount => _sessions.length;
  int get pendingSpawnCount => _spawns.length;
  int get activeGenerationCount => _activeByVm.length;

  @override
  Future<RuntimeDriverSession> spawn(RuntimeDriverLaunch launch) async {
    if (_closed) throw _cancelled('driver process manager is closed');
    final correlation = launch.correlation;
    final key = _DriverKey(correlation.vmId, correlation.driverGeneration);
    if (_activeByVm.containsKey(correlation.vmId)) {
      throw RuntimeDriverError(
        code: RuntimeDriverErrorCode.invalidRuntimeState,
        message: 'VM already owns an active driver generation',
        retryable: false,
      );
    }
    final attempt = _SpawnAttempt(correlation);
    _spawns[key] = attempt;
    _activeByVm[correlation.vmId] = key;
    final operation = _spawn(key, attempt);
    attempt.settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<RuntimeDriverSession> _spawn(
    _DriverKey key,
    _SpawnAttempt attempt,
  ) async {
    final correlation = attempt.correlation;
    DriverRuntimePaths? paths;
    Process? process;
    try {
      paths = await _layout.create(correlation);
      _requireAttemptActive(key, attempt);
      final executable = await _resolveExecutable(correlation.vmId);
      final bundlePath = await _resolveBundlePath(correlation.vmId);
      if (!bundlePath.startsWith('/')) {
        throw ArgumentError('driver bundle path must be absolute');
      }
      final token = _generateToken();
      final arguments = [
        ...executable.prefixArguments,
        '--vm-id',
        correlation.vmId.value,
        '--generation',
        '${correlation.driverGeneration}',
        '--socket-path',
        paths.socketPath,
        '--bundle-path',
        bundlePath,
        '--backend',
        'vz',
      ];
      process = await Process.start(
        executable.path,
        arguments,
        workingDirectory: paths.directory,
        runInShell: false,
        environment: {
          ...Platform.environment,
          ...executable.environment,
          'GAOVM_AUTH_TOKEN': token,
          'GAOVM_DRIVER_LOG_PATH': '$bundlePath/logs/driver.log',
        },
      );
      attempt.process = process;
      _requireAttemptActive(key, attempt);
      final session = ProcessRuntimeDriverSession._(
        correlation: correlation,
        process: process,
        paths: paths,
        authToken: token,
        connectTimeout: _connectTimeout,
        handshakeTimeout: _handshakeTimeout,
        heartbeatInterval: _heartbeatInterval,
        heartbeatTimeout: _heartbeatTimeout,
        now: _now,
      );
      attempt.session = session;
      _sessions[key] = session;
      await _layout.writeMetadata(
        paths,
        correlation: correlation,
        pid: process.pid,
        executable: executable.path,
        bundlePath: bundlePath,
        createdAt: _now(),
      );
      _requireAttemptActive(key, attempt);
      return session;
    } catch (error) {
      final session = attempt.session;
      if (session != null) {
        try {
          await _releaseSession(key, session);
        } catch (_) {
          // Keep ownership if process exit could not be confirmed. A later
          // release/close retries cleanup without masking the launch error.
        }
      } else {
        process?.kill(ProcessSignal.sigkill);
        if (process != null) {
          try {
            await process.exitCode.timeout(const Duration(seconds: 2));
          } catch (_) {}
        }
        if (paths != null) await _layout.remove(paths);
      }
      if (!_sessions.containsKey(key) && _activeByVm[correlation.vmId] == key) {
        _activeByVm.remove(correlation.vmId);
      }
      if (error is RuntimeDriverError) rethrow;
      throw RuntimeDriverError(
        code: RuntimeDriverErrorCode.runtimeStartFailed,
        message: 'failed to launch driver process: $error',
        retryable: true,
      );
    } finally {
      if (identical(_spawns[key], attempt)) _spawns.remove(key);
    }
  }

  @override
  Future<void> cancelSpawn(DriverCorrelation correlation) async {
    final key = _DriverKey(correlation.vmId, correlation.driverGeneration);
    final attempt = _spawns[key];
    if (attempt != null) {
      attempt.cancelled = true;
      attempt.process?.kill(ProcessSignal.sigkill);
    }
    final session = _sessions[key];
    if (session != null) await release(correlation);
  }

  @override
  Future<void> release(DriverCorrelation correlation) async {
    final key = _DriverKey(correlation.vmId, correlation.driverGeneration);
    final session = _sessions[key];
    if (session == null) return;
    await _releaseSession(key, session);
  }

  Future<void> close() {
    _closed = true;
    final existing = _closeFuture;
    if (existing != null) return existing;
    final operation = _close();
    _closeFuture = operation;
    return operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_closeFuture, operation)) _closeFuture = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  Future<void> _close() async {
    final elapsed = Stopwatch()..start();
    final attempts = List<_SpawnAttempt>.of(_spawns.values);
    for (final attempt in attempts) {
      attempt.cancelled = true;
      attempt.process?.kill(ProcessSignal.sigkill);
    }
    await _withinShutdownDeadline(
      Future.wait([for (final attempt in attempts) attempt.settled]),
      elapsed,
      'driver spawn compensation did not finish before shutdown deadline',
    );
    final sessions = Map<_DriverKey, ProcessRuntimeDriverSession>.of(_sessions);
    await _withinShutdownDeadline(
      Future.wait([
        for (final entry in sessions.entries)
          _releaseSession(entry.key, entry.value),
      ]),
      elapsed,
      'driver process exit did not finish before shutdown deadline',
    );
  }

  Future<void> _withinShutdownDeadline(
    Future<void> operation,
    Stopwatch elapsed,
    String message,
  ) {
    final remaining = _shutdownTimeout - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      throw RuntimeDriverError(
        code: RuntimeDriverErrorCode.driverUnhealthy,
        message: message,
        retryable: true,
      );
    }
    return operation.timeout(
      remaining,
      onTimeout: () => throw RuntimeDriverError(
        code: RuntimeDriverErrorCode.driverUnhealthy,
        message: message,
        retryable: true,
      ),
    );
  }

  Future<void> _releaseSession(
    _DriverKey key,
    ProcessRuntimeDriverSession session,
  ) {
    final existing = _releases[key];
    if (existing != null) return existing;
    final future = () async {
      await session._release();
      if (!session._processExited) {
        throw RuntimeDriverError(
          code: RuntimeDriverErrorCode.driverUnhealthy,
          message: 'driver process exit could not be confirmed',
          retryable: true,
        );
      }
      await _layout.remove(session.paths);
      if (identical(_sessions[key], session)) _sessions.remove(key);
      if (_activeByVm[session.correlation.vmId] == key) {
        _activeByVm.remove(session.correlation.vmId);
      }
    }();
    _releases[key] = future;
    return future.whenComplete(() {
      if (identical(_releases[key], future)) _releases.remove(key);
    });
  }

  void _requireAttemptActive(_DriverKey key, _SpawnAttempt attempt) {
    if (_closed || attempt.cancelled || !identical(_spawns[key], attempt)) {
      throw _cancelled('driver spawn was cancelled');
    }
  }

  String _generateToken() {
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

final class ProcessRuntimeDriverSession implements RuntimeDriverSession {
  ProcessRuntimeDriverSession._({
    required this.correlation,
    required Process process,
    required this.paths,
    required String authToken,
    required Duration connectTimeout,
    required Duration handshakeTimeout,
    required Duration heartbeatInterval,
    required Duration heartbeatTimeout,
    required DateTime Function() now,
  }) : _process = process,
       _authToken = authToken,
       _connectTimeout = connectTimeout,
       _handshakeTimeout = handshakeTimeout,
       _heartbeatInterval = heartbeatInterval,
       _heartbeatTimeout = heartbeatTimeout,
       _now = now {
    _logs = StreamController<RuntimeDriverLogChunk>(
      sync: true,
      onListen: _attachLogConsumer,
      onPause: _pauseLogInputs,
      onResume: _resumeLogInputs,
      onCancel: _detachLogConsumer,
    );
    _startLogInputs();
    process.exitCode.then(_onProcessExit, onError: _onExitError);
  }

  final Process _process;
  final DriverRuntimePaths paths;
  final String _authToken;
  final Duration _connectTimeout;
  final Duration _handshakeTimeout;
  final Duration _heartbeatInterval;
  final Duration _heartbeatTimeout;
  final DateTime Function() _now;
  final StreamController<RuntimeEvent> _events =
      StreamController<RuntimeEvent>.broadcast(sync: true);
  late final StreamController<RuntimeDriverLogChunk> _logs;
  final Completer<RuntimeDriverExit> _exit = Completer<RuntimeDriverExit>();
  final Set<OperationId> _cancelledOperations = {};
  DriverRpcChannel? _channel;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<List<int>>? _stderrSubscription;
  Future<void> _lifecycleTail = Future<void>.value();
  DriverCapabilities _capabilities = DriverCapabilities(const []);
  Future<DriverCapabilities>? _connectFuture;
  OperationId? _latestOperationId;
  OperationId? _activeLifecycleOperation;
  Timer? _heartbeatTimer;
  Timer? _stopEscalationTimer;
  Timer? _killEscalationTimer;
  bool _pingInFlight = false;
  bool _heartbeatFailed = false;
  bool _cleanShutdown = false;
  bool _terminalRequested = false;
  bool _processExited = false;
  bool _connected = false;
  bool _released = false;
  bool _logListenerAttached = false;
  bool _logConsumerActive = false;
  bool _logInputsPaused = false;
  Future<void>? _releaseFuture;

  @override
  final DriverCorrelation correlation;

  int get pid => _process.pid;
  bool get logInputsPaused => _logInputsPaused;

  @override
  DriverCapabilities get capabilities => _capabilities;
  @override
  Stream<RuntimeEvent> get events => _events.stream;
  @override
  Stream<RuntimeDriverLogChunk> get logs => _logs.stream;
  @override
  Future<RuntimeDriverExit> get exited => _exit.future;

  @override
  Future<DriverCapabilities> connect(DriverCapabilities required) async {
    if (_connected) {
      if (!_capabilities.containsAll(required)) {
        throw DriverCapabilityMismatch(
          required: required,
          offered: _capabilities,
        );
      }
      return _capabilities;
    }
    final capabilities = await (_connectFuture ??= _connect(required));
    if (!capabilities.containsAll(required)) {
      throw DriverCapabilityMismatch(required: required, offered: capabilities);
    }
    return capabilities;
  }

  Future<DriverCapabilities> _connect(DriverCapabilities required) async {
    final socket = await _connectSocket();
    final driverHello = Completer<DriverHello>();
    var handshakeComplete = false;
    late DriverRpcChannel channel;
    channel = DriverRpcChannel(
      socket,
      onRequest: (request) async {
        if (request['method'] != 'session.hello') {
          return DriverProtocolV2.encodeError(
            id: request['id'],
            correlation: correlation.withOperation(null),
            rpcCode: -32601,
            code: 'CAPABILITY_NOT_NEGOTIATED',
            message: 'session.hello must complete before driver requests',
            retryable: false,
          );
        }
        final hello = DriverProtocolV2.decodeHelloRequest(
          request,
          expectedSession: correlation,
        );
        if (hello.role != DriverPeerRole.driver ||
            !_constantTimeEquals(hello.authToken, _authToken)) {
          throw RuntimeDriverError(
            code: RuntimeDriverErrorCode.authenticationFailed,
            message: 'driver hello authentication failed',
            retryable: false,
          );
        }
        final offered = DriverCapabilities.all;
        if (!offered.containsAll(hello.required) ||
            !hello.offered.containsAll(required)) {
          throw DriverCapabilityMismatch(
            required: required,
            offered: hello.offered,
          );
        }
        final accepted = offered.negotiate(hello.offered);
        if (!driverHello.isCompleted) driverHello.complete(hello);
        return DriverProtocolV2.encodeHelloResult(
          id: request['id'],
          correlation: correlation.withOperation(null),
          accepted: accepted,
        );
      },
      onNotification: (notification) {
        if (!handshakeComplete) {
          throw RuntimeDriverError(
            code: RuntimeDriverErrorCode.protocolViolation,
            message: 'driver notification arrived before hello completed',
            retryable: false,
          );
        }
        final event = DriverProtocolV2.decodeEvent(
          notification,
          expectedSession: correlation,
        );
        if (event is RuntimeCleanShutdown) _cleanShutdown = true;
        if (!_events.isClosed) _events.add(event);
      },
    );
    _channel = channel;
    channel.done.then((cause) {
      _connected = false;
      if (cause != null &&
          !_processExited &&
          !_cleanShutdown &&
          !_terminalRequested &&
          !_events.isClosed) {
        _events.addError(cause);
      }
    });
    try {
      final daemonHello = channel.sendRequest(
        (id) => DriverProtocolV2.encodeHelloRequest(
          id: id,
          correlation: correlation.withOperation(null),
          role: DriverPeerRole.daemon,
          authToken: _authToken,
          offered: DriverCapabilities.all,
          required: required,
        ),
      );
      final handshake = Future.wait<Object>([driverHello.future, daemonHello]);
      final results = await Future.any<List<Object>>([
        handshake,
        channel.done.then<List<Object>>((cause) {
          if (cause is RuntimeDriverError) throw cause;
          throw RuntimeDriverError(
            code: RuntimeDriverErrorCode.protocolViolation,
            message: 'driver channel closed during handshake: $cause',
            retryable: false,
          );
        }),
      ]).timeout(_handshakeTimeout);
      final accepted = DriverProtocolV2.decodeHelloResult(
        results[1] as Map<String, Object?>,
        expectedSession: correlation,
      );
      if (!accepted.containsAll(required)) {
        throw DriverCapabilityMismatch(required: required, offered: accepted);
      }
      handshakeComplete = true;
      _capabilities = accepted;
      _connected = true;
      _scheduleHeartbeat();
      return accepted;
    } catch (_) {
      await channel.close();
      rethrow;
    }
  }

  @override
  Future<RuntimeCommandResult> execute(RuntimeCommand command) {
    _requireConnected();
    _requireCorrelation(command.correlation);
    final capability = command.capability;
    if (capability != null && !_capabilities.contains(capability)) {
      throw DriverCapabilityMismatch(
        required: DriverCapabilities({capability}),
        offered: _capabilities,
      );
    }
    if (command is RuntimePingCommand ||
        command is RuntimeStatusCommand ||
        command is DisplayStatusCommand ||
        command is ConsoleStatusCommand ||
        command is GuestStatusCommand) {
      return _executeNow(command);
    }
    final completer = Completer<RuntimeCommandResult>();
    _lifecycleTail = _lifecycleTail
        .catchError((Object _) {})
        .then((_) async {
          _requireConnected();
          // A kill is an explicit escalation of an accepted graceful stop.
          // Other queued lifecycle work must still fail once termination begins.
          if (_terminalRequested && command is! RuntimeKillCommand) {
            throw _cancelled('driver session is terminating');
          }
          final operationId = command.correlation.operationId;
          if (operationId != null && _cancelledOperations.remove(operationId)) {
            throw _cancelled('driver operation was cancelled before dispatch');
          }
          if (operationId != null) _latestOperationId = operationId;
          _activeLifecycleOperation = operationId;
          if (command is RuntimeKillCommand) {
            // Even a failed or hung kill RPC must terminate the owned process.
            _terminalRequested = true;
            _armStopEscalation(Duration.zero);
          }
          try {
            return await _executeNow(command);
          } finally {
            if (_activeLifecycleOperation == operationId) {
              _activeLifecycleOperation = null;
            }
          }
        })
        .then(completer.complete, onError: completer.completeError);
    return completer.future;
  }

  Future<RuntimeCommandResult> _executeNow(RuntimeCommand command) async {
    final channel = _channel!;
    final response = await channel.sendRequest(
      (id) => DriverProtocolV2.encodeCommandRequest(id: id, command: command),
    );
    final result = DriverProtocolV2.decodeCommandResult(
      response,
      expected: command.correlation,
    );
    if (command is RuntimeStopCommand) {
      _terminalRequested = true;
      _armStopEscalation(command.gracePeriod);
    } else if (command is RuntimeKillCommand) {
      _terminalRequested = true;
      _armStopEscalation(Duration.zero);
    }
    return result;
  }

  @override
  Future<RuntimeCommandResult> ping() {
    _requireConnected();
    return _executeNow(
      RuntimePingCommand(
        correlation: correlation.withOperation(_latestOperationId),
      ),
    );
  }

  @override
  Future<void> cancel(OperationId operationId) async {
    if (_activeLifecycleOperation == operationId && !_processExited) {
      _terminalRequested = true;
      _process.kill(ProcessSignal.sigterm);
      _killEscalationTimer?.cancel();
      _killEscalationTimer = Timer(const Duration(seconds: 2), () {
        if (!_processExited) _process.kill(ProcessSignal.sigkill);
      });
      return;
    }
    _cancelledOperations.add(operationId);
  }

  @override
  Future<void> close() async {
    _cancelTimers();
    await _channel?.close();
    _channel = null;
  }

  Future<void> _release() async {
    final existing = _releaseFuture;
    if (existing != null) return existing;
    final future = _releaseOnce();
    _releaseFuture = future;
    try {
      await future;
    } finally {
      if (!_processExited && identical(_releaseFuture, future)) {
        _releaseFuture = null;
      }
    }
  }

  Future<void> _releaseOnce() async {
    if (_released && _processExited) return;
    _released = true;
    if (!_processExited) {
      if (_connected && correlation.operationId != null) {
        try {
          await _executeNow(
            RuntimeStopCommand(
              correlation: correlation,
              gracePeriod: const Duration(seconds: 2),
            ),
          ).timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
      try {
        await exited.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        _process.kill(ProcessSignal.sigterm);
        try {
          await exited.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          _process.kill(ProcessSignal.sigkill);
          await exited.timeout(const Duration(seconds: 2));
        }
      }
    }
    await close();
    await _cancelLogInputs();
    _events.close().ignore();
    if (!_logListenerAttached) {
      final drain = _logs.stream.listen((_) {});
      await _logs.close();
      await drain.cancel();
    } else {
      _logs.close().ignore();
    }
  }

  Future<Socket> _connectSocket() async {
    final elapsed = Stopwatch()..start();
    Object? lastError;
    while (elapsed.elapsed < _connectTimeout) {
      if (_processExited) {
        throw RuntimeDriverError(
          code: RuntimeDriverErrorCode.runtimeStartFailed,
          message: 'driver exited before opening its control socket',
          retryable: true,
        );
      }
      try {
        return await Socket.connect(
          InternetAddress(paths.socketPath, type: InternetAddressType.unix),
          0,
        ).timeout(const Duration(milliseconds: 250));
      } on SocketException catch (error) {
        lastError = error;
        final code = error.osError?.errorCode;
        if (code != 2 && code != 61 && code != 111) rethrow;
      } on TimeoutException catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw RuntimeDriverError(
      code: RuntimeDriverErrorCode.runtimeStartFailed,
      message: 'timed out waiting for driver socket: $lastError',
      retryable: true,
    );
  }

  void _scheduleHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer(_heartbeatInterval, _heartbeat);
  }

  void _heartbeat() {
    if (!_connected || _processExited || _pingInFlight || _heartbeatFailed)
      return;
    _pingInFlight = true;
    ping()
        .timeout(_heartbeatTimeout)
        .then(
          (_) {
            _pingInFlight = false;
            _scheduleHeartbeat();
          },
          onError: (Object error, StackTrace stackTrace) {
            _pingInFlight = false;
            _heartbeatFailed = true;
            final operationId = _latestOperationId ?? correlation.operationId;
            if (operationId != null && !_events.isClosed) {
              _events.add(
                RuntimeHeartbeatMissed(
                  correlation: correlation.withOperation(operationId),
                  occurredAt: _now().toUtc(),
                ),
              );
            }
          },
        );
  }

  void _armStopEscalation(Duration gracePeriod) {
    _stopEscalationTimer?.cancel();
    _killEscalationTimer?.cancel();
    _stopEscalationTimer = Timer(gracePeriod + const Duration(seconds: 2), () {
      if (_processExited) return;
      _process.kill(ProcessSignal.sigterm);
      _killEscalationTimer = Timer(const Duration(seconds: 2), () {
        if (!_processExited) _process.kill(ProcessSignal.sigkill);
      });
    });
  }

  void _onProcessExit(int exitCode) {
    _processExited = true;
    _cancelTimers();
    if (!_exit.isCompleted) {
      _exit.complete(
        RuntimeDriverExit(
          correlation: correlation.withOperation(
            _activeLifecycleOperation ?? _latestOperationId,
          ),
          occurredAt: _now().toUtc(),
          clean: _cleanShutdown,
          exitCode: exitCode,
          error: _cleanShutdown
              ? null
              : RuntimeDriverError(
                  code: RuntimeDriverErrorCode.driverUnhealthy,
                  message: 'driver process exited with code $exitCode',
                  retryable: true,
                ),
        ),
      );
    }
  }

  void _onExitError(Object error, StackTrace stackTrace) {
    if (!_exit.isCompleted) _exit.completeError(error, stackTrace);
  }

  void _emitLog(RuntimeDriverLogStream stream, List<int> bytes) {
    if (_logs.isClosed || !_logConsumerActive || bytes.isEmpty) return;
    const maximumChunkBytes = 65536;
    for (var offset = 0; offset < bytes.length; offset += maximumChunkBytes) {
      final end = min(offset + maximumChunkBytes, bytes.length);
      _logs.add(
        RuntimeDriverLogChunk(
          correlation: correlation.withOperation(
            _activeLifecycleOperation ?? _latestOperationId,
          ),
          stream: stream,
          bytes: Uint8List.fromList(bytes.sublist(offset, end)),
        ),
      );
    }
  }

  void _startLogInputs() {
    _stdoutSubscription ??= _process.stdout.listen(
      (bytes) => _emitLog(RuntimeDriverLogStream.stdout, bytes),
      onError: _emitLogError,
    );
    _stderrSubscription ??= _process.stderr.listen(
      (bytes) => _emitLog(RuntimeDriverLogStream.stderr, bytes),
      onError: _emitLogError,
    );
  }

  void _attachLogConsumer() {
    _logListenerAttached = true;
    _logConsumerActive = true;
  }

  void _pauseLogInputs() {
    _logInputsPaused = true;
    _stdoutSubscription?.pause();
    _stderrSubscription?.pause();
  }

  void _resumeLogInputs() {
    _logInputsPaused = false;
    _stdoutSubscription?.resume();
    _stderrSubscription?.resume();
  }

  Future<void> _cancelLogInputs() async {
    _logInputsPaused = false;
    final stdout = _stdoutSubscription;
    final stderr = _stderrSubscription;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    await Future.wait([
      if (stdout != null) stdout.cancel(),
      if (stderr != null) stderr.cancel(),
    ]);
  }

  void _detachLogConsumer() {
    _logConsumerActive = false;
    _resumeLogInputs();
  }

  void _emitLogError(Object error, StackTrace stackTrace) {
    if (!_logs.isClosed && _logConsumerActive) {
      _logs.addError(error, stackTrace);
    }
  }

  void _cancelTimers() {
    _heartbeatTimer?.cancel();
    _stopEscalationTimer?.cancel();
    _killEscalationTimer?.cancel();
    _heartbeatTimer = null;
    _stopEscalationTimer = null;
    _killEscalationTimer = null;
  }

  void _requireConnected() {
    if (!_connected || _channel == null || _processExited) {
      throw RuntimeDriverError(
        code: RuntimeDriverErrorCode.invalidRuntimeState,
        message: 'driver session is not connected',
        retryable: false,
      );
    }
  }

  void _requireCorrelation(DriverCorrelation candidate) {
    if (candidate.vmId != correlation.vmId ||
        candidate.driverGeneration != correlation.driverGeneration) {
      throw RuntimeDriverError(
        code: RuntimeDriverErrorCode.generationMismatch,
        message: 'driver command correlation does not match its session',
        retryable: false,
      );
    }
  }
}

final class _DriverKey {
  const _DriverKey(this.vmId, this.generation);
  final VmId vmId;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is _DriverKey &&
      other.vmId == vmId &&
      other.generation == generation;
  @override
  int get hashCode => Object.hash(vmId, generation);
}

final class _SpawnAttempt {
  _SpawnAttempt(this.correlation);
  final DriverCorrelation correlation;
  late final Future<void> settled;
  bool cancelled = false;
  Process? process;
  ProcessRuntimeDriverSession? session;
}

bool _constantTimeEquals(String left, String right) {
  final a = utf8.encode(left);
  final b = utf8.encode(right);
  var difference = a.length ^ b.length;
  final length = max(a.length, b.length);
  for (var index = 0; index < length; index++) {
    difference |= a[index % a.length] ^ b[index % b.length];
  }
  return difference == 0;
}

RuntimeDriverError _cancelled(String message) => RuntimeDriverError(
  code: RuntimeDriverErrorCode.cancelled,
  message: message,
  retryable: true,
);
