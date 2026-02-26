import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_rpc/gaovm_rpc.dart';

Future<void> main(List<String> args) async {
  final config = _parseArgs(args);
  if (config.showHelp) {
    _printUsage();
    return;
  }

  final client = _GaovmCliClient(
    socketPath: config.socketPath,
    verbose: config.verbose,
  );

  try {
    await client.connectAndHandshake();
    switch (config.command) {
      case 'ping':
        final result = await client.request('ping');
        _printJson(result['result']);
        break;
      case 'status':
        final result = await client.request('vm.status');
        _printJson(result['result']);
        break;
      case 'list':
        final result = await client.request('list_vms');
        _printJson(result['result']);
        break;
      case 'start':
        final result = await client.request('vm.start');
        _printJson(result['result']);
        break;
      case 'stop':
        final result = await client.request('vm.stop');
        _printJson(result['result']);
        break;
      case 'open-display':
        final result = await client.request('vm.open_display');
        _printJson(result['result']);
        break;
      case 'close-display':
        final result = await client.request('vm.close_display');
        _printJson(result['result']);
        break;
      case 'events':
        final result = await client.request('subscribe_events');
        _printJson(result['result']);
        stdout.writeln('listening for events on unix:${config.socketPath}');
        await client.waitForExitSignal();
        break;
      case 'config-get':
        final result = await client.request('vm.config.get');
        _printJson(result['result']);
        break;
      case 'config-set':
        if (config.configJson == null) {
          throw StateError('config-set requires --json with a JSON object');
        }
        final decoded = jsonDecode(config.configJson!);
        if (decoded is! Map) {
          throw StateError('--json must be a JSON object');
        }
        final result = await client.request('vm.config.set', params: {
          'config': Map<String, Object?>.from(decoded),
        });
        _printJson(result['result']);
        break;
      case 'config-patch':
        if (config.configJson == null) {
          throw StateError('config-patch requires --json with a JSON object');
        }
        final decoded = jsonDecode(config.configJson!);
        if (decoded is! Map) {
          throw StateError('--json must be a JSON object');
        }
        final result = await client.request('vm.config.patch', params: {
          'patch': Map<String, Object?>.from(decoded),
        });
        _printJson(result['result']);
        break;
      case 'doctor':
        final result = await client.request('doctor');
        _printJson(result['result']);
        break;
      case 'driver-exec':
        if (config.method == null || config.method!.isEmpty) {
          throw StateError('driver-exec requires --method');
        }
        Object? params;
        if (config.paramsJson != null) {
          params = jsonDecode(config.paramsJson!);
        }
        final result = await client.request('driver.exec', params: {
          'method': config.method,
          if (params != null) 'params': params,
        });
        _printJson(result['result']);
        break;
      default:
        stderr.writeln('Unknown command: ${config.command}');
        _printUsage();
        exitCode = 2;
    }
  } on SocketException catch (error) {
    stderr.writeln('Connection failed: $error');
    exitCode = 1;
  } on _RpcException catch (error) {
    stderr.writeln('RPC error (${error.code}): ${error.message}');
    if (error.data != null) {
      stderr.writeln(jsonEncode(error.data));
    }
    exitCode = 1;
  } catch (error) {
    stderr.writeln('gaovm_cli fatal: $error');
    exitCode = 1;
  } finally {
    await client.close();
  }
}

class _CliConfig {
  _CliConfig({
    required this.socketPath,
    required this.command,
    required this.configJson,
    required this.method,
    required this.paramsJson,
    required this.showHelp,
    required this.verbose,
  });

  final String socketPath;
  final String command;
  final String? configJson;
  final String? method;
  final String? paramsJson;
  final bool showHelp;
  final bool verbose;
}

_CliConfig _parseArgs(List<String> args) {
  var socketPath = Directory.current.uri.resolve('state/run/daemon.sock').toFilePath();
  var verbose = false;
  var command = 'status';
  String? configJson;
  String? method;
  String? paramsJson;
  var showHelp = false;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--socket-path':
        socketPath = args[++i];
      case '--verbose':
      case '-v':
        verbose = true;
        break;
      case '--json':
        configJson = args[++i];
        break;
      case '--method':
        method = args[++i];
        break;
      case '--params-json':
        paramsJson = args[++i];
        break;
      case '--help':
      case '-h':
        showHelp = true;
        break;
      default:
        if (args[i].startsWith('-')) {
          stderr.writeln('Unknown option: ${args[i]}');
          showHelp = true;
        } else {
          command = args[i];
        }
    }
  }

  return _CliConfig(
    socketPath: socketPath,
    command: command,
    configJson: configJson,
    method: method,
    paramsJson: paramsJson,
    showHelp: showHelp,
    verbose: verbose,
  );
}

void _printUsage() {
  stdout.writeln('Usage: gaovm_cli [--socket-path PATH] [--verbose] <command>');
  stdout.writeln('Commands: ping, list, status, start, stop, events, doctor, driver-exec, config-get, config-set, config-patch');
  stdout.writeln('config-set: gaovm_cli config-set --json \'{\"cpu\":2,...}\'');
  stdout.writeln('config-patch: gaovm_cli config-patch --json \'{\"graphics\":{\"enabled\":false}}\'');
  stdout.writeln('driver-exec: gaovm_cli driver-exec --method ping [--params-json \'{...}\']');
}

void _printJson(Object? value) {
  const encoder = JsonEncoder.withIndent('  ');
  stdout.writeln(encoder.convert(value));
}

class _RpcException implements Exception {
  _RpcException({required this.code, required this.message, this.data});

  final int code;
  final String message;
  final Object? data;
}

class _GaovmCliClient {
  _GaovmCliClient({
    required this.socketPath,
    required this.verbose,
  });

  static const String _protocol = 'gaovm.v1.2';
  static const List<String> _capabilities = [
    'hello',
    'ping',
    'subscribe_events',
    'doctor',
    'driver.exec',
    'list_vms',
    'vm.start',
    'vm.stop',
    'vm.status',
    'vm.open_display',
    'vm.close_display',
    'vm.config.get',
    'vm.config.set',
    'vm.config.patch',
  ];
  static const List<String> _requiredCapabilities = ['hello', 'ping'];

  final String socketPath;
  final bool verbose;
  final LengthPrefixedJsonRpcCodec _codec = const LengthPrefixedJsonRpcCodec();
  final Map<Object?, Completer<Map<String, Object?>>> _pending = {};
  final Completer<void> _closed = Completer<void>();

  Socket? _socket;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void> _writeQueue = Future<void>.value();
  int _nextId = 1;
  bool _helloDone = false;
  bool _daemonHelloSeen = false;
  bool _isClosed = false;

  Future<void> connectAndHandshake() async {
    _socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    _subscription = _codec.decodeObjectStream(_socket!).listen(
      _onMessage,
      onError: (Object error, StackTrace stackTrace) {
        _closeWithError(error);
      },
      onDone: () {
        _closeWithError(StateError('daemon socket closed'));
      },
      cancelOnError: true,
    );

    final response = await request('hello', params: {
      'protocol': _protocol,
      'capabilities': _capabilities,
      'requiredCapabilities': _requiredCapabilities,
    }).timeout(const Duration(seconds: 5));
    final result = _asMap(response['result']);
    _validateHelloResult(result);
    _helloDone = true;
    if (!_daemonHelloSeen) {
      throw StateError('Bidirectional hello failed: daemon did not send hello request');
    }
  }

  Future<Map<String, Object?>> request(String method, {Object? params}) {
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    unawaited(_send(JsonRpcProtocol.request(id: id, method: method, params: params)));
    return completer.future.then((message) {
      final err = message['error'];
      if (err != null) {
        final errMap = _asMap(err);
        throw _RpcException(
          code: (errMap['code'] as num?)?.toInt() ?? -32000,
          message: errMap['message']?.toString() ?? 'Unknown RPC error',
          data: errMap['data'],
        );
      }
      return message;
    });
  }

  Future<void> waitForExitSignal() async {
    final sigint = ProcessSignal.sigint.watch().first;
    final sigterm = ProcessSignal.sigterm.watch().first;
    await Future.any([sigint, sigterm, _closed.future]);
  }

  Future<void> close() async {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    _socket?.destroy();
    await _subscription?.cancel();
    _failPending(StateError('CLI client closed'));
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }

  void _onMessage(Map<String, Object?> message) {
    if (verbose) {
      stdout.writeln('<< ${jsonEncode(message)}');
    }
    final method = message['method'];
    if (method == 'event' && !message.containsKey('id')) {
      _printJson(message['params']);
      return;
    }
    if (JsonRpcProtocol.isResponse(message)) {
      final pending = _pending.remove(message['id']);
      if (pending != null && !pending.isCompleted) {
        pending.complete(message);
      }
      return;
    }
    if (JsonRpcProtocol.isRequest(message)) {
      unawaited(_handleServerRequest(message));
      return;
    }
    unawaited(_send(JsonRpcProtocol.error(
      id: message['id'],
      code: JsonRpcErrorCode.invalidRequest,
      message: 'Invalid JSON-RPC object',
    )));
  }

  Future<void> _handleServerRequest(Map<String, Object?> request) async {
    final method = request['method'] as String;
    final id = request['id'];
    if (method == 'hello') {
      final params = _asMap(request['params']);
      final protocol = params['protocol'];
      if (protocol != _protocol) {
        await _send(JsonRpcProtocol.error(
          id: id,
          code: JsonRpcErrorCode.handshakeFailed,
          message: 'Protocol mismatch',
          data: {'expected': _protocol, 'actual': protocol},
        ));
        return;
      }
      final offered = _asStringList(params['capabilities']);
      final accepted = offered.where(_capabilities.contains).toList(growable: false);
      if (!_containsAll(accepted, _requiredCapabilities)) {
        await _send(JsonRpcProtocol.error(
          id: id,
          code: JsonRpcErrorCode.capabilityMismatch,
          message: 'Capability mismatch',
          data: {'required': _requiredCapabilities},
        ));
        return;
      }
      _daemonHelloSeen = true;
      await _send(JsonRpcProtocol.result(id: id, result: {
        'protocol': _protocol,
        'capabilities': _capabilities,
        'acceptedCapabilities': accepted,
      }));
      return;
    }

    if (!_helloDone) {
      await _send(JsonRpcProtocol.error(
        id: id,
        code: JsonRpcErrorCode.handshakeFailed,
        message: 'hello handshake required',
      ));
      return;
    }

    if (method == 'ping') {
      await _send(JsonRpcProtocol.result(id: id, result: {
        'ok': true,
        'ts': DateTime.now().toUtc().toIso8601String(),
      }));
      return;
    }

    await _send(JsonRpcProtocol.error(
      id: id,
      code: JsonRpcErrorCode.methodNotFound,
      message: 'Unsupported daemon->client method: $method',
    ));
  }

  Future<void> _send(Map<String, Object?> object) async {
    if (_isClosed || _socket == null) {
      throw StateError('not connected');
    }
    if (verbose) {
      stdout.writeln('>> ${jsonEncode(object)}');
    }
    _writeQueue = _writeQueue.then((_) async {
      if (_isClosed || _socket == null) {
        throw StateError('not connected');
      }
      _socket!.add(_codec.encodeObject(object));
      await _socket!.flush();
    });
    await _writeQueue;
  }

  void _validateHelloResult(Map<String, Object?> result) {
    final protocol = result['protocol'];
    if (protocol != _protocol) {
      throw StateError('Protocol mismatch: $protocol');
    }
    final accepted = _asStringList(result['acceptedCapabilities']);
    if (!_containsAll(accepted, _requiredCapabilities)) {
      throw StateError('Capability mismatch: accepted=$accepted required=$_requiredCapabilities');
    }
  }

  void _closeWithError(Object error) {
    _failPending(error);
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pending.clear();
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

bool _containsAll(List<String> actual, List<String> required) {
  final set = actual.toSet();
  for (final item in required) {
    if (!set.contains(item)) {
      return false;
    }
  }
  return true;
}
