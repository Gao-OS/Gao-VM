import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'src/generated_contract.dart';
import 'src/tool_bindings.dart';

part 'src/stdio_framing.dart';

final _toolContracts = jsonDecode(toolContractsJson) as Map<String, dynamic>;
const _maximumTools = 64;
const _maximumPending = 128;
const _outputDeadline = Duration(seconds: 5);

enum _LegacyPhase { disconnected, negotiated, ready }

/// A separate public API client, never a daemon or driver session.
final class GaoVmMcpServer {
  GaoVmMcpServer({required this.api});

  final GaoVmApiClient api;

  Future<void> serve(
    Stream<List<int>> input,
    FutureOr<void> Function(String) output,
  ) async {
    final session = _McpSession(api);
    final pending = <Future<void>>{};
    final cancellations = <Object, ApiRequestCancellation>{};
    final awaitingOutput = <ApiRequestCancellation>{};
    final tools = <ApiRequestCancellation>{};
    Completer<void>? capacity;
    Completer<void>? activeWrite;
    final failure = Completer<void>();
    void fail(Object error, StackTrace stack) {
      if (!failure.isCompleted) {
        failure.completeError(error, stack);
        if (activeWrite != null && !activeWrite!.isCompleted) {
          activeWrite!.completeError(error, stack);
        }
      }
    }

    void finished(Future<void> task) {
      pending.remove(task);
      if (pending.length < _maximumPending && capacity != null) {
        final available = capacity!;
        capacity = null;
        available.complete();
      }
    }

    var writing = Future<void>.value();
    Future<void> emit(String message, {ApiRequestCancellation? cancellation}) {
      if (cancellation != null) awaitingOutput.add(cancellation);
      final emitted = writing.then<void>((_) async {
        if (!failure.isCompleted && cancellation?.isCancelled != true) {
          final completed = Completer<void>();
          activeWrite = completed;
          unawaited(
            Future<void>.sync(() => output(message)).then<void>(
              (_) {
                if (!completed.isCompleted) completed.complete();
              },
              onError: (Object error, StackTrace stack) {
                if (!completed.isCompleted)
                  completed.completeError(error, stack);
              },
            ),
          );
          final deadline = Timer(_outputDeadline, () {
            if (!completed.isCompleted) {
              completed.completeError(
                TimeoutException(
                  'Protocol output did not drain',
                  _outputDeadline,
                ),
                StackTrace.current,
              );
            }
          });
          try {
            await completed.future;
          } finally {
            deadline.cancel();
            activeWrite = null;
          }
        }
      });
      writing = emitted.catchError(fail);
      return emitted.whenComplete(() => awaitingOutput.remove(cancellation));
    }

    void dispatch(Object? decoded) {
      final rawId = decoded is Map ? decoded['id'] : null;
      final id = rawId is String || rawId is int ? rawId : null;
      if (id != null && cancellations.containsKey(id)) {
        late Future<void> task;
        task = Future<void>.sync(
          () => emit(
            _rpcError(const {}, -32600, 'Duplicate in-flight request ID'),
          ),
        ).catchError(fail).whenComplete(() => finished(task));
        pending.add(task);
        return;
      }
      final cancellation = ApiRequestCancellation();
      if (id != null) cancellations[id] = cancellation;
      final tool =
          id != null && decoded is Map && decoded['method'] == 'tools/call';
      final busy = tool && tools.length >= _maximumTools;
      if (tool && !busy) tools.add(cancellation);
      late Future<void> task;
      task = session
          .respond(decoded, cancellation: cancellation, busy: busy)
          .then<void>(
            (response) async {
              if (!cancellation.isCancelled && response != null)
                await emit(response, cancellation: cancellation);
            },
            onError: (Object error, StackTrace stack) async {
              if (cancellation.isCancelled ||
                  error is ApiRequestCancelledException)
                return;
              await emit(
                _rpcError(
                  decoded is Map ? decoded : const {},
                  -32603,
                  'Internal error',
                ),
                cancellation: cancellation,
              );
            },
          )
          .catchError(fail)
          .whenComplete(() {
            finished(task);
            tools.remove(cancellation);
            if (id != null && identical(cancellations[id], cancellation)) {
              cancellations.remove(id);
            }
          });
      pending.add(task);
    }

    final frames = StreamIterator<_McpFrame>(_mcpFrames(input));
    var ended = false;
    Future<void> read() async {
      while (true) {
        while (pending.length >= _maximumPending) {
          // One waiter, rather than attaching new listeners to every long-lived
          // request each time a short request releases a slot.
          capacity ??= Completer<void>();
          await capacity!.future;
        }
        if (!await frames.moveNext()) break;
        final frame = frames.current;
        if (frame.code != null) {
          await emit(_rpcError(const {}, frame.code!, frame.detail!));
          continue;
        }
        Object? decoded;
        try {
          decoded = jsonDecode(frame.line!);
        } on FormatException {
          await emit(_rpcError(const {}, -32700, 'Parse error'));
          continue;
        }
        if (decoded is Map &&
            decoded['jsonrpc'] == '2.0' &&
            !decoded.containsKey('id') &&
            decoded['method'] == 'notifications/cancelled') {
          final params = decoded['params'];
          final id = params is Map ? params['requestId'] : null;
          if (id is int || id is String) {
            final cancellation = cancellations.remove(id);
            if (cancellation != null) {
              tools.remove(cancellation);
              cancellation.cancel();
            }
          }
          continue;
        }
        dispatch(decoded);
      }
      ended = true;
    }

    try {
      await Future.any([read(), failure.future]);
    } finally {
      for (final cancellation in cancellations.values.toList(growable: false)) {
        if (!ended ||
            failure.isCompleted ||
            !awaitingOutput.contains(cancellation)) {
          cancellation.cancel();
        }
      }
      cancellations.clear();
      await frames.cancel();
      final deadline = ended
          ? Timer(_outputDeadline, () {
              fail(
                TimeoutException(
                  'Protocol output did not drain before shutdown deadline',
                  _outputDeadline,
                ),
                StackTrace.current,
              );
            })
          : null;
      try {
        await Future.wait(pending);
      } finally {
        deadline?.cancel();
      }
    }
    if (failure.isCompleted) await failure.future;
  }
}

final class _McpSession {
  _McpSession(this.api);
  final GaoVmApiClient api;
  var legacy = _LegacyPhase.disconnected;

  Future<String?> respond(
    Object? decoded, {
    ApiRequestCancellation? cancellation,
    bool busy = false,
  }) async {
    if (decoded is! Map<String, dynamic>) {
      return _rpcError(const {}, -32600, 'Invalid request');
    }
    final request = decoded;
    if (request['jsonrpc'] != '2.0' ||
        request['method'] is! String ||
        request.containsKey('id') &&
            request['id'] is! String &&
            request['id'] is! int) {
      return _rpcError(const {}, -32600, 'Invalid request');
    }
    // JSON-RPC notifications never receive a response, even when unknown.
    if (!request.containsKey('id')) {
      if (request['method'] == 'notifications/initialized' &&
          legacy == _LegacyPhase.negotiated) {
        legacy = _LegacyPhase.ready;
      }
      return null;
    }
    if (request.containsKey('params') && request['params'] is! Map) {
      return _rpcError(request, -32602, 'Parameters must be an object');
    }
    final params = request['params'] as Map? ?? const {};
    final metadata = params['_meta'];
    final modern =
        params.containsKey('_meta') &&
        (metadata is! Map ||
            metadata.keys.any(
              (key) =>
                  key is String && key.startsWith('io.modelcontextprotocol/'),
            ));
    if (!modern && request['method'] == 'initialize') {
      final client = params['clientInfo'];
      if (params['protocolVersion'] is! String ||
          params['capabilities'] is! Map ||
          client is! Map ||
          client['name'] is! String ||
          client['version'] is! String) {
        return _rpcError(request, -32602, 'Invalid initialize parameters');
      }
      if (legacy != _LegacyPhase.disconnected) {
        return _rpcError(request, -32600, 'Session is already initialized');
      }
      legacy = _LegacyPhase.negotiated;
      return jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {
          'protocolVersion': '2025-11-25',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'gaovm-mcp', 'version': '0.1.0'},
        },
      });
    }
    if (!modern && request['method'] == 'ping') {
      return jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': {}});
    }
    if (!modern && legacy != _LegacyPhase.ready) {
      return _rpcError(
        request,
        -32602,
        'Initialize or provide modern protocol metadata',
      );
    }
    if (modern &&
        (metadata is! Map ||
            metadata['io.modelcontextprotocol/protocolVersion'] is! String ||
            metadata['io.modelcontextprotocol/clientCapabilities'] is! Map)) {
      return _rpcError(
        request,
        -32602,
        'Required protocol metadata is missing or invalid',
      );
    }
    final version = modern
        ? metadata['io.modelcontextprotocol/protocolVersion']
        : null;
    if (modern && version != '2026-07-28') {
      return _rpcError(request, -32022, 'Unsupported protocol version', {
        'supported': ['2026-07-28'],
        'requested': version,
      });
    }
    if (modern && request['method'] == 'server/discover') {
      return jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {
          'resultType': 'complete',
          'supportedVersions': ['2026-07-28'],
          'capabilities': {'tools': {}},
          '_meta': {
            'io.modelcontextprotocol/serverInfo': {
              'name': 'gaovm-mcp',
              'version': '0.1.0',
            },
          },
        },
      });
    }
    if (request['method'] == 'tools/list') {
      return jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {
          if (modern) 'resultType': 'complete',
          'tools': _toolContracts.values.toList(),
        },
      });
    }
    if (request['method'] != 'tools/call') {
      return _rpcError(request, -32601, 'Method not found');
    }
    final binding = toolBindings
        .where((binding) => binding.name == params['name'])
        .firstOrNull;
    if (binding == null) {
      return jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'error': {'code': -32602, 'message': 'Unknown tool: ${params['name']}'},
      });
    }
    if (params.containsKey('arguments') && params['arguments'] is! Map) {
      return _rpcError(request, -32602, 'Tool arguments must be an object');
    }
    final arguments = params['arguments'] as Map? ?? const {};
    final invalid = _validateArguments(
      arguments,
      _toolContracts[binding.name]['inputSchema'] as Map,
    );
    if (invalid != null || busy) {
      final problem = invalid != null
          ? {
              'code': 'MCP_INVALID_ARGUMENT',
              'detail': invalid,
              'retryable': false,
            }
          : {
              'code': 'MCP_SERVER_BUSY',
              'detail':
                  'At most $_maximumTools tool requests can be in flight. Reuse the '
                  'idempotency_key when retrying a mutation.',
              'retryable': true,
            };
      return jsonEncode({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {
          if (modern) 'resultType': 'complete',
          'content': [
            {'type': 'text', 'text': jsonEncode(problem)},
          ],
          'structuredContent': problem,
          'isError': true,
        },
      });
    }
    var path = binding.path;
    for (final parameter in RegExp(r'\{([^}]+)\}').allMatches(path)) {
      final name = parameter[1]!;
      final id = ResourceId.parse(arguments[name] as String);
      final expected = switch (name) {
        'vm_id' => 'vm_',
        'operation_id' => 'op_',
        'test_run_id' => 'tr_',
        _ => throw StateError('unsupported public resource parameter'),
      };
      if (!id.value.startsWith(expected)) {
        throw FormatException('$name has the wrong resource type');
      }
      path = path.replaceAll('{$name}', id.value);
    }
    late Map<String, Object?> body;
    late Map<String, Object?> meta;
    var isError = false;
    try {
      final response = await api.request(
        binding.method.toUpperCase(),
        path,
        body: arguments.containsKey('body')
            ? JsonObjectValue.fromJson(arguments['body'])
            : binding.method == 'post'
            ? JsonObjectValue.empty
            : null,
        idempotencyKey: arguments['idempotency_key'] as String?,
        timeout: _requestTimeout(binding.name, arguments),
        cancellation: cancellation,
        query: {
          for (final name in [
            'cursor',
            'limit',
            'label_selector',
            'sort',
            'kind',
          ])
            if (arguments.containsKey(name)) name: '${arguments[name]}',
        },
      );
      body = response.body.toJson();
      meta = {
        'dev.gaovm/requestId': response.requestId,
        'dev.gaovm/httpStatus': response.status,
        if (response.etag != null) 'dev.gaovm/etag': response.etag,
      };
    } on ApiProblemException catch (error) {
      body = error.problem.toJson();
      isError = true;
      meta = {
        'dev.gaovm/requestId': error.problem.requestId.value,
        'dev.gaovm/httpStatus': error.problem.status,
      };
    } on ApiTransportException catch (error) {
      body = {
        'code': 'MCP_API_UNAVAILABLE',
        'detail': error.message,
        'retryable': true,
      };
      isError = true;
      meta = {};
    } on ApiTimeoutException catch (error) {
      body = {
        'code': 'MCP_API_TIMEOUT',
        'detail':
            '$error. A mutation may have been accepted; reuse its '
            'idempotency_key when retrying.',
        'retryable': true,
      };
      isError = true;
      meta = {};
    } on ApiProtocolException catch (error) {
      body = {
        'code': 'MCP_API_PROTOCOL',
        'detail': error.message,
        'retryable': false,
      };
      isError = true;
      meta = {};
    }
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': request['id'],
      'result': {
        if (modern) 'resultType': 'complete',
        'content': [
          {'type': 'text', 'text': jsonEncode(body)},
        ],
        'structuredContent': body,
        'isError': isError,
        '_meta': meta,
      },
    });
  }
}

Duration _requestTimeout(String tool, Map arguments) {
  final explicit = arguments['request_timeout_seconds'] as num?;
  final wait = (arguments['body'] as Map?)?['timeout_seconds'];
  final seconds =
      explicit ??
      (tool == 'vm_wait' && wait is num && wait > 0 && wait <= 86400
          ? wait + 5
          : 30);
  return Duration(
    microseconds: (seconds * Duration.microsecondsPerSecond).ceil(),
  );
}

String _rpcError(Map request, int code, String message, [Map? data]) =>
    jsonEncode({
      'jsonrpc': '2.0',
      'id': request['id'],
      'error': {
        'code': code,
        'message': message,
        if (data != null) 'data': data,
      },
    });

/// Validate adapter controls locally. Public bodies receive authoritative
/// domain/schema validation at their public API endpoint, before any effects.
String? _validateArguments(Map arguments, Map schema) {
  final properties = schema['properties'] as Map;
  for (final name in arguments.keys) {
    if (!properties.containsKey(name)) return 'Unknown argument: $name';
  }
  for (final name in schema['required'] as List? ?? const []) {
    if (!arguments.containsKey(name)) return 'Missing argument: $name';
  }
  for (final entry in arguments.entries) {
    final rule = properties[entry.key] as Map;
    final value = entry.value;
    final type = rule['type'];
    if (type == 'string' && value is! String ||
        type == 'integer' && value is! int ||
        type == 'number' && (value is! num || !value.isFinite) ||
        type == 'object' && value is! Map) {
      return '${entry.key} must be a $type';
    }
    if (rule['enum'] is List && !(rule['enum'] as List).contains(value)) {
      return '${entry.key} is not an accepted value';
    }
    if (value is String) {
      if (rule['minLength'] is int && value.length < rule['minLength'] ||
          rule['maxLength'] is int && value.length > rule['maxLength'] ||
          rule['pattern'] is String &&
              !RegExp(rule['pattern'] as String).hasMatch(value) ||
          entry.key == 'idempotency_key' &&
              RegExp(r'[\x00\r\n]').hasMatch(value)) {
        return '${entry.key} has an invalid string value';
      }
    }
    if (value is num) {
      if (rule['minimum'] is num && value < rule['minimum'] ||
          rule['maximum'] is num && value > rule['maximum'] ||
          rule['exclusiveMinimum'] is num &&
              value <= rule['exclusiveMinimum']) {
        return '${entry.key} is out of range';
      }
    }
  }
  return null;
}
