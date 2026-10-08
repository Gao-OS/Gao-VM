import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_models/gaovm_models.dart';

/// Exit codes: 0 success, 1 API/action failure, 2 usage, 3 transport,
/// 4 invalid server response, 124 deadline. All diagnostic output is JSON.
Future<int> runCli(
  List<String> args, {
  void Function(String)? output,
  void Function(String)? error,
}) async {
  final write = output ?? stdout.writeln;
  final writeError = error ?? stderr.writeln;
  final compact = args.contains('--json');
  String encode(Object? value) => compact
      ? jsonEncode(value)
      : const JsonEncoder.withIndent('  ').convert(value);
  int fail(int code, String kind, Object detail) {
    writeError(encode({'code': kind, 'detail': '$detail', 'retryable': false}));
    return code;
  }

  try {
    final options = _Options.parse(args);
    if (options.help) {
      write(
        encode({
          'usage':
              'gaovm [--socket-path PATH] [--timeout-seconds N] [--json] <command>',
          'commands': [
            'vm list',
            'vm create',
            'vm get VM_ID',
            'vm patch VM_ID',
            'vm start VM_ID',
            'vm stop VM_ID',
            'vm restart VM_ID',
            'vm kill VM_ID',
            'vm wait VM_ID',
            'operation get OP_ID',
            'operation cancel OP_ID',
            'operation wait OP_ID',
          ],
          'options': {
            '--body-json JSON': 'required by vm create and vm patch',
            '--if-match REVISION': 'required by vm patch',
            '--condition CONDITION': 'required by vm wait',
            '--service-name NAME': 'service_ready VM wait target',
            '--timeout-seconds N': '1-86400; required by waits, otherwise 30',
            '--idempotency-key KEY':
                'reuse the same key when retrying a mutation',
          },
        }),
      );
      return 0;
    }
    final route = _route(options);
    final response = await GaoVmApiClient(socketPath: options.socket).request(
      route.method,
      route.path,
      timeout:
          options.timeout +
          (route.path.endsWith('/wait')
              ? const Duration(seconds: 5)
              : Duration.zero),
      body: route.body,
      ifMatch: route.ifMatch,
      idempotencyKey: route.method == 'GET' || route.path.endsWith('/wait')
          ? null
          : options.idempotencyKey ?? _newKey(),
    );
    Operation? terminal;
    if (route.terminalOperation) {
      try {
        terminal = Operation.fromJson(response.body.toJson());
      } on FormatException {
        throw const ApiProtocolException('invalid Operation wait response');
      } on ArgumentError {
        throw const ApiProtocolException('invalid Operation wait response');
      }
      if (terminal.state == OperationState.pending ||
          terminal.state == OperationState.running) {
        throw const ApiProtocolException(
          'Operation wait returned nonterminal state',
        );
      }
    }
    write(encode(response.body.toJson()));
    return terminal == null || terminal.state == OperationState.succeeded
        ? 0
        : 1;
  } on FormatException catch (exception) {
    return fail(2, 'CLI_USAGE', exception.message);
  } on ApiProblemException catch (exception) {
    writeError(encode(exception.problem.toJson()));
    return exception.problem.code == ErrorCode.waitTimeout ? 124 : 1;
  } on ApiTimeoutException catch (exception) {
    return fail(124, 'CLI_TIMEOUT', exception);
  } on ApiTransportException catch (exception) {
    return fail(3, 'CLI_TRANSPORT', exception);
  } on ApiProtocolException catch (exception) {
    return fail(4, 'CLI_PROTOCOL', exception);
  }
}

_Request _route(_Options options) {
  final command = options.command;
  if (command.length == 2 && command[0] == 'vm' && command[1] == 'list') {
    return _Request('GET', '/v1/vms');
  }
  if (command.length == 2 && command[0] == 'vm' && command[1] == 'create') {
    if (options.bodyJson == null)
      throw const FormatException('create requires --body-json');
    return _Request('POST', '/v1/vms', body: _body(options.bodyJson!));
  }
  if (command.length == 3 && command[1] == 'get') {
    final prefix = switch (command[0]) {
      'vm' => 'vm_',
      'operation' => 'op_',
      _ => null,
    };
    if (prefix != null) {
      final id = _id(command[2], prefix);
      final collection = command[0] == 'vm' ? 'vms' : 'operations';
      return _Request('GET', '/v1/$collection/$id');
    }
  }
  if (command.length == 3 &&
      command[0] == 'vm' &&
      const {'start', 'stop', 'restart', 'kill'}.contains(command[1])) {
    late VmId id;
    try {
      id = VmId(command[2]);
    } on ArgumentError {
      throw const FormatException('VM target must be a real vm_ ULID');
    }
    return _Request(
      'POST',
      '/v1/vms/${id.value}/actions/${command[1]}',
      body: JsonObjectValue.empty,
    );
  }
  if (command.length == 3 && command[0] == 'vm' && command[1] == 'patch') {
    if (options.bodyJson == null || options.ifMatch == null) {
      throw const FormatException('patch requires --body-json and --if-match');
    }
    return _Request(
      'PATCH',
      '/v1/vms/${_id(command[2], 'vm_')}',
      body: _body(options.bodyJson!),
      ifMatch: _etag(options.ifMatch!),
    );
  }
  if (command.length == 3 &&
      command[0] == 'operation' &&
      command[1] == 'cancel') {
    return _Request(
      'POST',
      '/v1/operations/${_id(command[2], 'op_')}/cancel',
      body: JsonObjectValue.empty,
    );
  }
  if (command.length == 3 &&
      command[0] == 'operation' &&
      command[1] == 'wait') {
    if (!options.timeoutExplicit)
      throw const FormatException('wait requires --timeout-seconds');
    return _Request(
      'POST',
      '/v1/operations/${_id(command[2], 'op_')}/wait',
      body: JsonObjectValue.fromJson({
        'timeout_seconds': options.timeout.inSeconds,
      }),
      terminalOperation: true,
    );
  }
  if (command.length == 3 && command[0] == 'vm' && command[1] == 'wait') {
    if (!options.timeoutExplicit || options.condition == null)
      throw const FormatException(
        'VM wait requires --condition and --timeout-seconds',
      );
    return _Request(
      'POST',
      '/v1/vms/${_id(command[2], 'vm_')}/wait',
      body: JsonObjectValue.fromJson({
        'condition': options.condition,
        'timeout_seconds': options.timeout.inSeconds,
        if (options.serviceName != null) 'service_name': options.serviceName,
      }),
    );
  }
  throw const FormatException('unsupported command; use --help');
}

final class _Request {
  const _Request(
    this.method,
    this.path, {
    this.body,
    this.ifMatch,
    this.terminalOperation = false,
  });
  final String method;
  final String path;
  final JsonObjectValue? body;
  final String? ifMatch;
  final bool terminalOperation;
}

String _etag(String value) {
  if (!RegExp(r'^(?:[1-9][0-9]*|"[1-9][0-9]*")$').hasMatch(value) ||
      int.tryParse(value.replaceAll('"', '')) == null) {
    throw const FormatException(
      '--if-match must be a positive revision or quoted ETag',
    );
  }
  return '"${value.replaceAll('"', '')}"';
}

String _id(String value, String prefix) {
  try {
    ResourceId.parse(value);
    if (!value.startsWith(prefix)) throw ArgumentError();
    return value;
  } on ArgumentError {
    throw FormatException('target must be a real $prefix ULID');
  }
}

JsonObjectValue _body(String value) {
  try {
    return JsonObjectValue.fromJson(jsonDecode(value));
  } on FormatException {
    throw const FormatException('--body-json must be a JSON object');
  } on ArgumentError {
    throw const FormatException('--body-json must be a JSON object');
  }
}

String _newKey() {
  final random = Random.secure();
  return 'cli-${List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

final class _Options {
  const _Options({
    required this.socket,
    required this.timeout,
    required this.command,
    required this.help,
    this.idempotencyKey,
    this.bodyJson,
    this.ifMatch,
    this.timeoutExplicit = false,
    this.condition,
    this.serviceName,
  });
  final String socket;
  final Duration timeout;
  final List<String> command;
  final bool help;
  final String? idempotencyKey;
  final String? bodyJson;
  final String? ifMatch;
  final bool timeoutExplicit;
  final String? condition;
  final String? serviceName;

  static _Options parse(List<String> args) {
    var socket = File('state/run/api.sock').absolute.path;
    var seconds = 30;
    var timeoutExplicit = false;
    var help = false;
    String? idempotencyKey;
    String? bodyJson;
    String? ifMatch;
    String? condition;
    String? serviceName;
    final command = <String>[];
    final seenOptions = <String>{};
    for (var i = 0; i < args.length; i++) {
      String value() {
        if (!seenOptions.add(args[i])) {
          throw FormatException('duplicate option ${args[i]}');
        }
        if (i + 1 >= args.length ||
            args[i + 1].startsWith('--') ||
            args[i + 1] == '-h') {
          throw FormatException('missing value for ${args[i]}');
        }
        return args[++i];
      }

      switch (args[i]) {
        case '--socket-path':
          socket = value();
        case '--body-json':
          bodyJson = value();
        case '--if-match':
          ifMatch = value();
        case '--condition':
          condition = value();
        case '--service-name':
          serviceName = value();
        case '--idempotency-key':
          idempotencyKey = value();
          if (!RegExp(r'^[\x21-\x7e]{1,255}$').hasMatch(idempotencyKey)) {
            throw const FormatException(
              'idempotency key must be 1-255 visible ASCII characters',
            );
          }
        case '--timeout-seconds':
          timeoutExplicit = true;
          seconds = int.tryParse(value()) ?? 0;
          if (seconds <= 0 || seconds > 86400) {
            throw const FormatException('timeout must be 1-86400 seconds');
          }
        case '--json':
          break;
        case '--help' || '-h':
          help = true;
        default:
          if (args[i].startsWith('-'))
            throw FormatException('unknown option ${args[i]}');
          command.add(args[i]);
      }
    }
    final verb = command.take(2).join(' ');
    final unsupported = [
      if (bodyJson != null && !const {'vm create', 'vm patch'}.contains(verb))
        '--body-json',
      if (ifMatch != null && verb != 'vm patch') '--if-match',
      if (condition != null && verb != 'vm wait') '--condition',
      if (serviceName != null && verb != 'vm wait') '--service-name',
      if (idempotencyKey != null &&
          !const {
            'vm create',
            'vm patch',
            'vm start',
            'vm stop',
            'vm restart',
            'vm kill',
            'operation cancel',
          }.contains(verb))
        '--idempotency-key',
    ];
    if (unsupported.isNotEmpty) {
      throw FormatException('${unsupported.join(', ')} not supported by $verb');
    }
    return _Options(
      socket: socket,
      timeout: Duration(seconds: seconds),
      command: command,
      help: help,
      idempotencyKey: idempotencyKey,
      bodyJson: bodyJson,
      ifMatch: ifMatch,
      timeoutExplicit: timeoutExplicit,
      condition: condition,
      serviceName: serviceName,
    );
  }
}
