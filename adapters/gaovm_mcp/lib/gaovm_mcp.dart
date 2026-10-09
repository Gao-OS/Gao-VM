import 'dart:convert';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'src/generated_contract.dart';
import 'src/tool_bindings.dart';

final _toolContracts = jsonDecode(toolContractsJson) as Map<String, dynamic>;

/// A separate public API client, never a daemon or driver session.
final class GaoVmMcpServer {
  GaoVmMcpServer({required this.api});

  final GaoVmApiClient api;

  Future<void> serve(
    Stream<List<int>> input,
    void Function(String) output,
  ) async {
    await for (final line
        in input.transform(utf8.decoder).transform(const LineSplitter())) {
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        output(_rpcError(const {}, -32700, 'Parse error'));
        continue;
      }
      if (decoded is! Map<String, dynamic>) {
        output(_rpcError(const {}, -32600, 'Invalid request'));
        continue;
      }
      final request = decoded;
      if (request['jsonrpc'] != '2.0' ||
          request['method'] is! String ||
          request.containsKey('id') &&
              request['id'] is! String &&
              request['id'] is! int) {
        output(_rpcError(const {}, -32600, 'Invalid request'));
        continue;
      }
      // JSON-RPC notifications never receive a response, even when unknown.
      if (!request.containsKey('id')) continue;
      if (request.containsKey('params') && request['params'] is! Map) {
        output(_rpcError(request, -32602, 'Parameters must be an object'));
        continue;
      }
      final metadata = (request['params'] as Map?)?['_meta'];
      if (metadata is! Map ||
          metadata['io.modelcontextprotocol/protocolVersion'] is! String ||
          metadata['io.modelcontextprotocol/clientCapabilities'] is! Map) {
        output(
          _rpcError(
            request,
            -32602,
            'Required protocol metadata is missing or invalid',
          ),
        );
        continue;
      }
      final version = metadata['io.modelcontextprotocol/protocolVersion'];
      if (version != '2026-07-28') {
        output(
          _rpcError(request, -32022, 'Unsupported protocol version', {
            'supported': ['2026-07-28'],
            'requested': version,
          }),
        );
        continue;
      }
      if (request['method'] == 'server/discover') {
        output(
          jsonEncode({
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
          }),
        );
        continue;
      }
      if (request['method'] == 'tools/list') {
        output(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': {
              'resultType': 'complete',
              'tools': _toolContracts.values.toList(),
            },
          }),
        );
        continue;
      }
      if (request['method'] != 'tools/call') {
        output(_rpcError(request, -32601, 'Method not found'));
        continue;
      }
      final params = request['params'] as Map;
      final binding = toolBindings
          .where((binding) => binding.name == params['name'])
          .firstOrNull;
      if (binding == null) {
        output(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'error': {
              'code': -32602,
              'message': 'Unknown tool: ${params['name']}',
            },
          }),
        );
        continue;
      }
      if (params.containsKey('arguments') && params['arguments'] is! Map) {
        output(_rpcError(request, -32602, 'Tool arguments must be an object'));
        continue;
      }
      final arguments = params['arguments'] as Map? ?? const {};
      final invalid = _validateArguments(
        arguments,
        _toolContracts[binding.name]['inputSchema'] as Map,
      );
      if (invalid != null) {
        final problem = {
          'code': 'MCP_INVALID_ARGUMENT',
          'detail': invalid,
          'retryable': false,
        };
        output(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': {
              'resultType': 'complete',
              'content': [
                {'type': 'text', 'text': jsonEncode(problem)},
              ],
              'structuredContent': problem,
              'isError': true,
            },
          }),
        );
        continue;
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
      output(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': {
            'resultType': 'complete',
            'content': [
              {'type': 'text', 'text': jsonEncode(body)},
            ],
            'structuredContent': body,
            'isError': isError,
            '_meta': meta,
          },
        }),
      );
    }
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
