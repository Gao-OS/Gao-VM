import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gaovm_rpc/gaovm_rpc.dart';

import 'atomic_json_file.dart';
import 'rotating_logger.dart';
import 'vm_config_store.dart';

typedef EventEmitter = void Function(String type, Map<String, Object?> payload);

class RpcChannel {
  RpcChannel(this.socket)
      : _remote = '${socket.remoteAddress.address}:${socket.remotePort}' {
    _subscription = _codec.decodeObjectStream(socket).listen(
      _onMessage,
      onError: (Object error, StackTrace stackTrace) {
        _closeWithError(error);
      },
      onDone: () {
        _closeWithError(StateError('Socket EOF ($_remote)'));
      },
      cancelOnError: true,
    );
  }

  final Socket socket;
  final String _remote;
  final LengthPrefixedJsonRpcCodec _codec = const LengthPrefixedJsonRpcCodec();
  final Map<Object?, Completer<Map<String, Object?>>> _pendingResponses = {};
  final Map<String, List<Completer<Map<String, Object?>>>> _requestWaiters = {};
  final Completer<void> _closed = Completer<void>();
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<Map<String, Object?>?> Function(Map<String, Object?> request)? onRequest;
  int _nextId = -1;
  bool _isClosed = false;
  Future<void> _writeQueue = Future<void>.value();

  Future<void> get done => _closed.future;

  Future<Map<String, Object?>> sendRequest(String method, {Object? params}) {
    final id = _nextId--;
    final completer = Completer<Map<String, Object?>>();
    _pendingResponses[id] = completer;
    unawaited(_send(JsonRpcProtocol.request(id: id, method: method, params: params)));
    return completer.future;
  }

  Future<void> sendNotification(String method, {Object? params}) {
    return _send(JsonRpcProtocol.notification(method: method, params: params));
  }

  Future<void> sendResult({required Object? id, required Object? result}) {
    return _send(JsonRpcProtocol.result(id: id, result: result));
  }

  Future<void> sendError({
    required Object? id,
    required int code,
    required String message,
    Object? data,
  }) {
    return _send(JsonRpcProtocol.error(
      id: id,
      code: code,
      message: message,
      data: data,
    ));
  }

  Future<Map<String, Object?>> waitForRequest(String method, {Duration? timeout}) {
    final completer = Completer<Map<String, Object?>>();
    _requestWaiters.putIfAbsent(method, () => []).add(completer);
    final future = completer.future;
    if (timeout == null) {
      return future;
    }
    return future.timeout(timeout, onTimeout: () {
      final waiters = _requestWaiters[method];
      waiters?.remove(completer);
      throw TimeoutException('Timed out waiting for request: $method');
    });
  }

  Future<void> close() async {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    socket.destroy();
    await _subscription?.cancel();
    _closePending(StateError('Channel closed ($_remote)'));
  }

  Future<void> _send(Map<String, Object?> object) async {
    if (_isClosed) {
      throw StateError('Channel is closed ($_remote)');
    }
    _writeQueue = _writeQueue.then((_) async {
      if (_isClosed) {
        throw StateError('Channel is closed ($_remote)');
      }
      socket.add(_codec.encodeObject(object));
      await socket.flush();
    });
    await _writeQueue;
  }

  void _onMessage(Map<String, Object?> message) {
    if (JsonRpcProtocol.isRequest(message)) {
      final method = message['method'] as String;
      final waiters = _requestWaiters[method];
      if (waiters != null && waiters.isNotEmpty) {
        final completer = waiters.removeAt(0);
        if (!completer.isCompleted) {
          completer.complete(message);
        }
        if (waiters.isEmpty) {
          _requestWaiters.remove(method);
        }
        return;
      }
      _dispatchRequest(message);
      return;
    }
    if (JsonRpcProtocol.isResponse(message)) {
      final id = message['id'];
      final completer = _pendingResponses.remove(id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(message);
      }
      return;
    }
    unawaited(sendError(
      id: message['id'],
      code: JsonRpcErrorCode.invalidRequest,
      message: 'Invalid JSON-RPC object',
    ));
  }

  void _dispatchRequest(Map<String, Object?> request) {
    final handler = onRequest;
    if (handler == null) {
      if (request.containsKey('id')) {
        unawaited(sendError(
          id: request['id'],
          code: JsonRpcErrorCode.methodNotFound,
          message: 'No request handler configured',
        ));
      }
      return;
    }
    () async {
      try {
        final response = await handler(request);
        if (response != null) {
          await _send(response);
        }
      } catch (error) {
        if (request.containsKey('id')) {
          try {
            await sendError(
              id: request['id'],
              code: JsonRpcErrorCode.internalError,
              message: error.toString(),
            );
          } catch (_) {
            // Peer disconnected while we were preparing the error response.
          }
        }
      }
    }();
  }

  void _closeWithError(Object error) {
    if (_isClosed) {
      _closePending(error);
      return;
    }
    _isClosed = true;
    _closePending(error);
    unawaited(socket.close());
  }

  void _closePending(Object error) {
    for (final completer in _pendingResponses.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pendingResponses.clear();

    for (final waiters in _requestWaiters.values) {
      for (final completer in waiters) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      }
    }
    _requestWaiters.clear();

    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }
}

class DriverSupervisor {
  DriverSupervisor({
    required this.driverBinary,
    required this.stateDir,
    this.logger,
    EventEmitter? emitEvent,
  })  : _emitEvent = emitEvent,
        _runtimeStateFile = AtomicJsonFile('$stateDir/daemon_state.json'),
        _desiredStateFile = AtomicJsonFile('$stateDir/desired_state.json') {
    _reconcileTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_reconcileTick());
    });
  }

  static const List<String> daemonCapabilities = ['hello', 'ping'];
  static const List<String> requiredCapabilities = ['hello', 'ping'];
  static const String protocolVersion = 'gaovm.v1.2';

  final String driverBinary;
  final String stateDir;
  final RotatingLogger? logger;
  EventEmitter? _emitEvent;
  final AtomicJsonFile _runtimeStateFile;
  final AtomicJsonFile _desiredStateFile;

  Process? _process;
  RpcChannel? _driverChannel;
  Timer? _heartbeatTimer;
  Timer? _reconcileTimer;
  Timer? _restartTimer;
  bool _desiredRunning = false;
  bool _startInProgress = false;
  bool _stopInProgress = false;
  int _restartAttempts = 0;
  String? _lastFailure;
  String? _driverSocketPath;
  String? _authToken;

  Future<void> restoreDesiredState() async {
    final file = File('$stateDir/desired_state.json');
    if (!await file.exists()) {
      await _persistDesiredState();
      await _persistRuntimeState();
      return;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map && decoded['desired'] == 'running') {
      _desiredRunning = true;
    } else {
      _desiredRunning = false;
    }
    await _persistRuntimeState();
  }

  void attachEventEmitter(EventEmitter emitEvent) {
    _emitEvent = emitEvent;
  }

  Future<void> dispose() async {
    _reconcileTimer?.cancel();
    _heartbeatTimer?.cancel();
    _restartTimer?.cancel();
    await stop();
  }

  Map<String, Object?> status() => {
        'desired': _desiredRunning ? 'running' : 'stopped',
        'actual': _driverChannel != null ? 'running' : 'stopped',
        'restartAttempts': _restartAttempts,
        'maxRestartAttempts': 5,
        'driverPid': _process?.pid,
        'driverSocketPath': _driverSocketPath,
        'lastFailure': _lastFailure,
      };

  Future<void> start() async {
    _desiredRunning = true;
    await _persistDesiredState();
    await _persistRuntimeState();
    await _startDriverIfNeeded();
  }

  Future<void> stop() async {
    _desiredRunning = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    await _persistDesiredState();
    await _persistRuntimeState();
    await _stopDriverProcess();
  }

  Future<void> _reconcileTick() async {
    if (_desiredRunning && _driverChannel == null && !_startInProgress && _restartTimer == null) {
      await _startDriverIfNeeded();
    }
  }

  Future<void> _startDriverIfNeeded() async {
    if (_startInProgress || _driverChannel != null || !_desiredRunning) {
      return;
    }
    _startInProgress = true;
    try {
      final runDir = Directory('$stateDir/run');
      await runDir.create(recursive: true);
      final socketPath = '${runDir.path}/driver.sock';
      final existing = File(socketPath);
      if (await existing.exists()) {
        await existing.delete();
      }
      _driverSocketPath = socketPath;
      _authToken = _generateToken();
      final driverLogPath = '$stateDir/logs/gaovm-driver-vz.log';

      final process = await Process.start(driverBinary, [
        '--socket-path',
        socketPath,
      ], runInShell: false, environment: {
        ...Platform.environment,
        'GAOVM_AUTH_TOKEN': _authToken!,
        'GAOVM_DRIVER_LOG_PATH': driverLogPath,
      });
      _process = process;
      process.stderr.transform(utf8.decoder).listen((data) {
        unawaited(logger?.warn('driver stderr: ${data.trimRight()}') ?? Future<void>.value());
        stderr.write('[vz_macos stderr] $data');
      });
      process.stdout.transform(utf8.decoder).listen((data) {
        unawaited(logger?.info('driver stdout: ${data.trimRight()}') ?? Future<void>.value());
        stdout.write('[vz_macos stdout] $data');
      });
      unawaited(process.exitCode.then(_onDriverExit));

      final socket = await _connectToDriverWithRetry(socketPath);
      final channel = RpcChannel(socket);
      await _performHandshake(channel, expectedToken: _authToken!);
      _driverChannel = channel;
      _restartAttempts = 0;
      _lastFailure = null;
      _installDriverRequestHandler(channel);
      _startHeartbeat(channel);
      unawaited(channel.done.then((_) => _onDriverChannelClosed()));
      _emit('driver.started', {
        'pid': process.pid,
        'socketPath': socketPath,
      });
      unawaited(logger?.info('driver started pid=${process.pid} socket=$socketPath') ?? Future<void>.value());
      await _persistRuntimeState();
    } catch (error) {
      _lastFailure = 'Driver start failed: $error';
      _emit('driver.start_failed', {'error': error.toString()});
      unawaited(logger?.error('driver start failed: $error') ?? Future<void>.value());
      final process = _process;
      if (process != null) {
        process.kill(ProcessSignal.sigkill);
      }
      await _teardownDriverArtifacts();
      await _scheduleRestartOrPermanentFailure();
      await _persistRuntimeState();
    } finally {
      _startInProgress = false;
    }
  }

  Future<Socket> _connectToDriverWithRetry(String socketPath) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        return await Socket.connect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        );
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw StateError('Timed out connecting to driver socket $socketPath: ${lastError ?? 'unknown error'}');
  }

  Future<void> _performHandshake(RpcChannel channel, {required String expectedToken}) async {
    final helloRequest = await channel.waitForRequest('hello', timeout: const Duration(seconds: 5));
    final params = _asMap(helloRequest['params']);
    final protocol = params['protocol'];
    final token = params['authToken'];
    final driverCaps = _asStringList(params['capabilities']);

    if (protocol != protocolVersion) {
      await channel.sendError(
        id: helloRequest['id'],
        code: JsonRpcErrorCode.handshakeFailed,
        message: 'Protocol mismatch',
        data: {'expected': protocolVersion, 'actual': protocol},
      );
      throw StateError('Protocol mismatch');
    }
    if (token != expectedToken) {
      await channel.sendError(
        id: helloRequest['id'],
        code: JsonRpcErrorCode.authFailed,
        message: 'Auth token mismatch',
      );
      throw StateError('Auth token mismatch');
    }

    final accepted = _negotiateCapabilities(driverCaps, daemonCapabilities);
    if (!_containsAll(accepted, requiredCapabilities)) {
      await channel.sendError(
        id: helloRequest['id'],
        code: JsonRpcErrorCode.capabilityMismatch,
        message: 'Capability mismatch',
        data: {
          'required': requiredCapabilities,
          'driverCapabilities': driverCaps,
          'daemonCapabilities': daemonCapabilities,
        },
      );
      throw StateError('Capability mismatch (driver -> daemon hello)');
    }

    await channel.sendResult(
      id: helloRequest['id'],
      result: {
        'protocol': protocolVersion,
        'capabilities': daemonCapabilities,
        'acceptedCapabilities': accepted,
      },
    );

    final daemonHelloResponse = await channel.sendRequest('hello', params: {
      'protocol': protocolVersion,
      'authToken': expectedToken,
      'capabilities': daemonCapabilities,
      'requiredCapabilities': requiredCapabilities,
    }).timeout(const Duration(seconds: 5));

    if (daemonHelloResponse['error'] != null) {
      throw StateError('Driver rejected daemon hello: ${daemonHelloResponse['error']}');
    }
    final result = _asMap(daemonHelloResponse['result']);
    final daemonAccepted = _asStringList(result['acceptedCapabilities']);
    if (!_containsAll(daemonAccepted, requiredCapabilities)) {
      throw StateError('Capability mismatch (daemon -> driver hello)');
    }
  }

  void _installDriverRequestHandler(RpcChannel channel) {
    channel.onRequest = (request) async {
      final method = request['method'];
      final id = request['id'];
      if (method == 'ping') {
        return JsonRpcProtocol.result(id: id, result: {
          'ok': true,
          'ts': DateTime.now().toUtc().toIso8601String(),
        });
      }
      if (method == 'hello') {
        final params = _asMap(request['params']);
        final token = params['authToken'];
        if (token != _authToken) {
          return JsonRpcProtocol.error(
            id: id,
            code: JsonRpcErrorCode.authFailed,
            message: 'Auth token mismatch',
          );
        }
        final caps = _asStringList(params['capabilities']);
        final accepted = _negotiateCapabilities(caps, daemonCapabilities);
        if (!_containsAll(accepted, requiredCapabilities)) {
          return JsonRpcProtocol.error(
            id: id,
            code: JsonRpcErrorCode.capabilityMismatch,
            message: 'Capability mismatch',
          );
        }
        return JsonRpcProtocol.result(id: id, result: {
          'protocol': protocolVersion,
          'capabilities': daemonCapabilities,
          'acceptedCapabilities': accepted,
        });
      }
      if (id != null) {
        return JsonRpcProtocol.error(
          id: id,
          code: JsonRpcErrorCode.methodNotFound,
          message: 'Unsupported driver method: $method',
        );
      }
      return null;
    };
  }

  void _startHeartbeat(RpcChannel channel) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(() async {
        try {
          final response = await channel.sendRequest('ping', params: {
            'ts': DateTime.now().toUtc().toIso8601String(),
          }).timeout(const Duration(seconds: 5));
          if (response['error'] != null) {
            _lastFailure = 'Driver ping error: ${response['error']}';
          }
        } catch (error) {
          _lastFailure = 'Driver ping failed: $error';
        }
      }());
    });
  }

  Future<void> _stopDriverProcess() async {
    if (_stopInProgress) {
      return;
    }
    _stopInProgress = true;
    try {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      final process = _process;
      final channel = _driverChannel;
      _driverChannel = null;
      if (channel != null) {
        await channel.close();
      }
      if (process != null) {
        try {
          await process.exitCode.timeout(const Duration(milliseconds: 500));
        } on TimeoutException {
          process.kill(ProcessSignal.sigterm);
          try {
            await process.exitCode.timeout(const Duration(seconds: 2));
          } on TimeoutException {
            process.kill(ProcessSignal.sigkill);
            try {
              await process.exitCode.timeout(const Duration(seconds: 2));
            } on TimeoutException {
              _lastFailure = 'Driver did not exit after SIGKILL during stop()';
            }
          }
        }
      }
      await _teardownDriverArtifacts(clearProcess: true);
      await _persistRuntimeState();
      _emit('driver.stopped', {});
      unawaited(logger?.info('driver stopped') ?? Future<void>.value());
    } finally {
      _stopInProgress = false;
    }
  }

  Future<void> _onDriverExit(int exitCode) async {
    if (_process == null) {
      return;
    }
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final exitedPid = _process?.pid;
    _process = null;
    if (_driverChannel != null) {
      await _driverChannel!.close();
      _driverChannel = null;
    }
    await _teardownDriverArtifacts();
    _emit('driver.exited', {
      'pid': exitedPid,
      'exitCode': exitCode,
    });
    unawaited(logger?.warn('driver exited pid=$exitedPid code=$exitCode') ?? Future<void>.value());
    if (_desiredRunning && !_stopInProgress) {
      _lastFailure = 'Driver exited unexpectedly with code $exitCode';
      await _scheduleRestartOrPermanentFailure();
    }
    await _persistRuntimeState();
  }

  Future<void> _onDriverChannelClosed() async {
    if (_driverChannel == null) {
      return;
    }
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _driverChannel = null;
    await _persistRuntimeState();
  }

  Future<void> _scheduleRestartOrPermanentFailure() async {
    if (!_desiredRunning) {
      return;
    }
    if (_restartTimer != null) {
      return;
    }
    if (_restartAttempts >= 5) {
      _desiredRunning = false;
      await _persistDesiredState();
      _emit('driver.permanent_failure', {
        'reason': _lastFailure ?? 'restart attempts exhausted',
        'attempts': _restartAttempts,
      });
      unawaited(logger?.error('driver permanent failure after $_restartAttempts attempts: ${_lastFailure ?? 'unknown'}') ?? Future<void>.value());
      await _persistRuntimeState();
      return;
    }

    _restartAttempts += 1;
    final backoffSeconds = min(1 << (_restartAttempts - 1), 30);
    _emit('driver.restart_scheduled', {
      'attempt': _restartAttempts,
      'delaySeconds': backoffSeconds,
    });
    _restartTimer = Timer(Duration(seconds: backoffSeconds), () {
      _restartTimer = null;
      unawaited(_startDriverIfNeeded());
    });
  }

  Future<void> _teardownDriverArtifacts({bool clearProcess = false}) async {
    if (clearProcess) {
      _process = null;
    }
    final socketPath = _driverSocketPath;
    if (socketPath != null) {
      final file = File(socketPath);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> _persistDesiredState() {
    return _desiredStateFile.write({
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'desired': _desiredRunning ? 'running' : 'stopped',
      'maxRestartAttempts': 5,
      'lastFailure': _lastFailure,
    });
  }

  Future<void> _persistRuntimeState() {
    return _runtimeStateFile.write({
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'desired': _desiredRunning ? 'running' : 'stopped',
      'actual': _driverChannel != null ? 'running' : 'stopped',
      'restartAttempts': _restartAttempts,
      'maxRestartAttempts': 5,
      'restartPending': _restartTimer != null,
      'driverPid': _process?.pid,
      'driverSocketPath': _driverSocketPath,
      'driverBinary': driverBinary,
      'lastFailure': _lastFailure,
    });
  }

  Future<Map<String, Object?>> driverExec(String method, {Object? params}) async {
    final channel = _driverChannel;
    if (channel == null) {
      throw StateError('Driver is not running');
    }
    final response = await channel.sendRequest(method, params: params).timeout(const Duration(seconds: 5));
    if (response['error'] != null) {
      throw StateError('Driver error: ${response['error']}');
    }
    return response;
  }

  Future<Map<String, Object?>> doctor() async {
    final driverFile = File(driverBinary);
    final socketFile = _driverSocketPath == null ? null : File(_driverSocketPath!);
    return {
      'ok': true,
      'daemon': status(),
      'checks': {
        'driverBinaryPath': driverBinary,
        'driverBinaryExists': await driverFile.exists(),
        'driverSocketPath': _driverSocketPath,
        'driverSocketExists': socketFile == null ? false : await socketFile.exists(),
        'stateDir': stateDir,
        'stateDirExists': await Directory(stateDir).exists(),
      },
    };
  }

  String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  void _emit(String type, Map<String, Object?> payload) {
    _emitEvent?.call(type, payload);
  }
}

class DaemonRpcServer {
  DaemonRpcServer({
    required this.socketPath,
    required this.supervisor,
    required this.configStore,
    this.logger,
  });

  final String socketPath;
  final DriverSupervisor supervisor;
  final VmConfigStore configStore;
  final RotatingLogger? logger;
  final List<_ClientSession> _clients = [];
  ServerSocket? _server;

  Future<void> start() async {
    final socketFile = File(socketPath);
    await socketFile.parent.create(recursive: true);
    if (await socketFile.exists()) {
      await socketFile.delete();
    }
    _server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    supervisor.attachEventEmitter(_emitEvent);
    await logger?.info('daemon rpc socket bound at $socketPath');
    _server!.listen((socket) {
      final session = _ClientSession(server: this, socket: socket);
      _clients.add(session);
      unawaited(session.run().whenComplete(() {
        _clients.remove(session);
      }));
    });
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    final socketFile = File(socketPath);
    if (await socketFile.exists()) {
      await socketFile.delete();
    }
    for (final client in List<_ClientSession>.from(_clients)) {
      await client.close();
    }
    _clients.clear();
    await supervisor.dispose();
  }

  void emitEvent(String type, Map<String, Object?> payload) => _emitEvent(type, payload);

  void _emitEvent(String type, Map<String, Object?> payload) {
    final event = <String, Object?>{
      'type': type,
      'payload': payload,
      'ts': DateTime.now().toUtc().toIso8601String(),
    };
    stdout.writeln('[event] ${jsonEncode(event)}');
    unawaited(logger?.debug('event ${event['type']}: ${jsonEncode(event['payload'])}') ?? Future<void>.value());
    for (final client in _clients) {
      if (client.subscribed) {
        unawaited(client.channel.sendNotification('event', params: event));
      }
    }
  }
}

class _ClientSession {
  _ClientSession({required this.server, required Socket socket}) : channel = RpcChannel(socket);

  static const List<String> daemonCapabilities = [
    'hello',
    'ping',
    'subscribe_events',
    'doctor',
    'driver.exec',
    'list_vms',
    'vm.start',
    'vm.stop',
    'vm.status',
    'vm.config.get',
    'vm.config.set',
    'vm.config.patch',
  ];
  static const List<String> requiredCapabilities = ['hello', 'ping'];
  static const String protocolVersion = 'gaovm.v1.2';

  final DaemonRpcServer server;
  final RpcChannel channel;
  bool subscribed = false;
  bool _handshakeComplete = false;

  Future<void> run() async {
    channel.onRequest = _handleRequest;
    await channel.done;
  }

  Future<void> close() => channel.close();

  Future<Map<String, Object?>?> _handleRequest(Map<String, Object?> request) async {
    final method = request['method'] as String;
    final id = request['id'];
    final params = _asMap(request['params']);

    if (method == 'hello') {
      final protocol = params['protocol'];
      if (protocol != protocolVersion) {
        return JsonRpcProtocol.error(
          id: id,
          code: JsonRpcErrorCode.handshakeFailed,
          message: 'Protocol mismatch',
          data: {'expected': protocolVersion, 'actual': protocol},
        );
      }
      final clientCaps = _asStringList(params['capabilities']);
      final accepted = _negotiateCapabilities(clientCaps, daemonCapabilities);
      if (!_containsAll(accepted, requiredCapabilities)) {
        return JsonRpcProtocol.error(
          id: id,
          code: JsonRpcErrorCode.capabilityMismatch,
          message: 'Capability mismatch',
          data: {'required': requiredCapabilities},
        );
      }
      _handshakeComplete = true;
      // Bidirectional hello: daemon also initiates a hello request to the client.
      unawaited(() async {
        try {
          await channel.sendRequest('hello', params: {
            'protocol': protocolVersion,
            'capabilities': daemonCapabilities,
            'requiredCapabilities': requiredCapabilities,
          });
        } catch (_) {
          // Best-effort for bootstrap clients; client hello response is not yet required for CLI stub.
        }
      }());
      return JsonRpcProtocol.result(id: id, result: {
        'protocol': protocolVersion,
        'capabilities': daemonCapabilities,
        'acceptedCapabilities': accepted,
      });
    }

    if (!_handshakeComplete) {
      return JsonRpcProtocol.error(
        id: id,
        code: JsonRpcErrorCode.handshakeFailed,
        message: 'hello handshake required before method $method',
      );
    }

    switch (method) {
      case 'ping':
        return JsonRpcProtocol.result(id: id, result: {
          'ok': true,
          'ts': DateTime.now().toUtc().toIso8601String(),
        });
      case 'subscribe_events':
        subscribed = true;
        return JsonRpcProtocol.result(id: id, result: {
          'ok': true,
        });
      case 'list_vms':
        final status = server.supervisor.status();
        return JsonRpcProtocol.result(id: id, result: [
          {
            'id': 'default',
            'desired': status['desired'],
            'actual': status['actual'],
            'driverPid': status['driverPid'],
          }
        ]);
      case 'vm.start':
        if (server.supervisor.status()['actual'] != 'running') {
          await server.configStore.activatePendingIfPresent(emitEvent: server.emitEvent);
        }
        await server.supervisor.start();
        return JsonRpcProtocol.result(id: id, result: server.supervisor.status());
      case 'vm.stop':
        await server.supervisor.stop();
        return JsonRpcProtocol.result(id: id, result: server.supervisor.status());
      case 'vm.status':
        return JsonRpcProtocol.result(id: id, result: server.supervisor.status());
      case 'vm.config.get':
        return JsonRpcProtocol.result(id: id, result: await server.configStore.getConfigSnapshot());
      case 'vm.config.set':
        final config = _asMap(params['config']);
        final result = await server.configStore.setConfig(
          config,
          isRunning: server.supervisor.status()['actual'] == 'running',
          emitEvent: server.emitEvent,
        );
        return JsonRpcProtocol.result(id: id, result: result);
      case 'vm.config.patch':
        final patch = _asMap(params['patch']);
        final result = await server.configStore.patchConfig(
          patch,
          isRunning: server.supervisor.status()['actual'] == 'running',
          emitEvent: server.emitEvent,
        );
        return JsonRpcProtocol.result(id: id, result: result);
      case 'doctor':
        return JsonRpcProtocol.result(id: id, result: await server.supervisor.doctor());
      case 'driver.exec':
        final driverMethod = params['method']?.toString();
        if (driverMethod == null || driverMethod.isEmpty) {
          return JsonRpcProtocol.error(
            id: id,
            code: JsonRpcErrorCode.invalidParams,
            message: 'driver.exec requires params.method',
          );
        }
        final response = await server.supervisor.driverExec(
          driverMethod,
          params: params['params'],
        );
        return JsonRpcProtocol.result(id: id, result: {
          'method': driverMethod,
          'driverResult': response['result'],
        });
      default:
        return JsonRpcProtocol.error(
          id: id,
          code: JsonRpcErrorCode.methodNotFound,
          message: 'Unknown method: $method',
        );
    }
  }
}

Map<String, Object?> _asMap(Object? value) {
  if (value == null) {
    return <String, Object?>{};
  }
  if (value is! Map) {
    throw StateError('Expected JSON object, got ${value.runtimeType}');
  }
  return Map<String, Object?>.from(value);
}

List<String> _asStringList(Object? value) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw StateError('Expected JSON array, got ${value.runtimeType}');
  }
  return value.map((e) => e.toString()).toList(growable: false);
}

List<String> _negotiateCapabilities(List<String> offered, List<String> supported) {
  final supportedSet = supported.toSet();
  return offered.where(supportedSet.contains).toList(growable: false);
}

bool _containsAll(List<String> actual, List<String> required) {
  final set = actual.toSet();
  for (final capability in required) {
    if (!set.contains(capability)) {
      return false;
    }
  }
  return true;
}
