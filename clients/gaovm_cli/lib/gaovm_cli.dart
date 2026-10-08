import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_models/gaovm_models.dart';

/// Exit codes: 0 success, 1 API/action failure, 2 usage, 3 transport,
/// 4 invalid server response, 124 deadline, 130 SIGINT, 143 SIGTERM.
/// All diagnostic output is JSON.
Future<int> runCli(
  List<String> args, {
  void Function(String)? output,
  void Function(String)? error,
}) async {
  final void Function(String) write = output ?? stdout.writeln;
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
            'vm delete VM_ID',
            'vm start VM_ID',
            'vm stop VM_ID',
            'vm restart VM_ID',
            'vm kill VM_ID',
            'vm wait VM_ID',
            'image import',
            'image list',
            'image get IMG_ID',
            'image delete IMG_ID',
            'operation get OP_ID',
            'operation list',
            'operation cancel OP_ID',
            'operation wait OP_ID',
            'test run',
            'test get TR_ID',
            'test cancel TR_ID',
            'test artifacts TR_ID',
            'events',
          ],
          'options': {
            '--after-sequence N':
                'events: exclusive sequence cursor; default 0',
            '--vm-id VM_ID': 'events: VM filter',
            '--operation-id OP_ID': 'events: Operation filter',
            '--test-run-id TR_ID': 'events: TestRun filter',
            '--label-selector SELECTOR':
                'vm/image list: comma-separated label filters',
            '--sort FIELD':
                'vm list: created_at, name, id; prefix - to descend',
            '--limit N':
                'vm/image/operation list and test artifacts: 1-200 items per page',
            '--cursor CURSOR':
                'vm/image/operation list and test artifacts: unchanged next_cursor value',
            '--resource-type TYPE': 'operation list: resource type filter',
            '--resource-id ID': 'operation list: resource ID filter',
            '--state STATE': 'operation list: operation state filter',
            '--body-json JSON':
                'required by vm create, vm patch, image import, and test run',
            '--if-match REVISION': 'required by vm patch',
            '--condition CONDITION': 'required by vm wait',
            '--service-name NAME': 'guest_service_ready VM wait target',
            '--timeout-seconds N': '1-86400; required by waits, otherwise 30',
            '--idempotency-key KEY':
                'reuse the same key when retrying a mutation',
          },
        }),
      );
      return 0;
    }
    final client = GaoVmApiClient(socketPath: options.socket);
    if (options.command.length == 1 && options.command.single == 'events') {
      final vmId = options.query['vm_id'];
      final operationId = options.query['operation_id'];
      final testRunId = options.query['test_run_id'];
      final signal = await _consumeEvents(
        client.watchEvents(
          afterSequence: int.parse(options.query['after_sequence'] ?? '0'),
          vmId: vmId == null ? null : VmId(_id(vmId, 'vm_')),
          operationId: operationId == null
              ? null
              : OperationId(_id(operationId, 'op_')),
          testRunId: testRunId == null
              ? null
              : TestRunId(_id(testRunId, 'tr_')),
          timeout: options.timeout,
        ),
        write,
      );
      return fail(
        signal == ProcessSignal.sigint ? 130 : 143,
        'CLI_INTERRUPTED',
        'event stream interrupted by $signal',
      );
    }
    if (options.command.length == 3 &&
        options.command[0] == 'image' &&
        options.command[1] == 'get') {
      final id = ImageId(_id(options.command[2], 'img_'));
      final image = await _findImage(client, id, options.timeout);
      if (image == null)
        return fail(
          1,
          'IMAGE_NOT_FOUND',
          'No image exists with ID ${id.value}.',
        );
      write(encode(image.toJson()));
      return 0;
    }
    final route = _route(options);
    final response = await client.request(
      route.method,
      route.path,
      query: route.query,
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

Future<Image?> _findImage(
  GaoVmApiClient client,
  ImageId id,
  Duration timeout,
) async {
  final elapsed = Stopwatch()..start();
  final seenCursors = <String>{};
  String? cursor;
  do {
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) throw ApiTimeoutException(timeout);
    final response = await client.request(
      'GET',
      '/v1/images',
      query: {'limit': '200', if (cursor != null) 'cursor': cursor},
      timeout: remaining,
    );
    final page = response.body.toJson();
    final items = page['items'];
    final next = page['next_cursor'];
    if (page.length != 2 ||
        !page.containsKey('next_cursor') ||
        items is! List ||
        next != null && (next is! String || next.isEmpty || next.length > 512))
      throw const ApiProtocolException('invalid Image list response');
    if (next is String && !seenCursors.add(next))
      throw const ApiProtocolException('Image list repeated its cursor');
    try {
      final images = items.map(Image.fromJson).toList();
      for (final image in images) {
        if (image.id == id) return image;
      }
    } on FormatException {
      throw const ApiProtocolException('invalid Image list response');
    } on ArgumentError {
      throw const ApiProtocolException('invalid Image list response');
    }
    cursor = next as String?;
  } while (cursor != null);
  return null;
}

Future<ProcessSignal> _consumeEvents(
  Stream<Event> source,
  void Function(String) write,
) async {
  final done = Completer<ProcessSignal>();
  final signals = <StreamSubscription<ProcessSignal>>[];
  StreamSubscription<Event>? events;
  void fail(Object error, [StackTrace? stack]) {
    if (!done.isCompleted) done.completeError(error, stack);
  }

  try {
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      signals.add(
        signal.watch().listen((received) {
          if (!done.isCompleted) done.complete(received);
        }, onError: fail),
      );
    }
    events = source.listen(
      (event) {
        if (done.isCompleted) return;
        try {
          write(jsonEncode(event.toJson()));
        } catch (error, stack) {
          fail(error, stack);
        }
      },
      onError: fail,
      onDone: () => fail(
        const ApiTransportException(
          'event stream closed; resume from the last consumed sequence',
        ),
      ),
      cancelOnError: true,
    );
    return await done.future;
  } finally {
    await events?.cancel();
    for (final signal in signals) {
      await signal.cancel();
    }
  }
}

_Request _route(_Options options) {
  final command = options.command;
  if (command.length == 2 && command[0] == 'vm' && command[1] == 'list') {
    return _Request('GET', '/v1/vms', query: options.query);
  }
  if (command.length == 2 && command[0] == 'image' && command[1] == 'list') {
    return _Request('GET', '/v1/images', query: options.query);
  }
  if (command.length == 3 && command[0] == 'image' && command[1] == 'delete') {
    return _Request('DELETE', '/v1/images/${_id(command[2], 'img_')}');
  }
  if (command.length == 2 &&
      command[0] == 'operation' &&
      command[1] == 'list') {
    return _Request('GET', '/v1/operations', query: options.query);
  }
  if (command.length == 2 && command[0] == 'vm' && command[1] == 'create') {
    if (options.bodyJson == null)
      throw const FormatException('create requires --body-json');
    return _Request('POST', '/v1/vms', body: _body(options.bodyJson!));
  }
  if (command.length == 2 && command[0] == 'test' && command[1] == 'run') {
    if (options.bodyJson == null)
      throw const FormatException('test run requires --body-json');
    return _Request('POST', '/v1/test-runs', body: _body(options.bodyJson!));
  }
  if (command.length == 3 && command[0] == 'test' && command[1] == 'get') {
    return _Request('GET', '/v1/test-runs/${_id(command[2], 'tr_')}');
  }
  if (command.length == 3 && command[0] == 'test' && command[1] == 'cancel') {
    return _Request('POST', '/v1/test-runs/${_id(command[2], 'tr_')}/cancel');
  }
  if (command.length == 3 &&
      command[0] == 'test' &&
      command[1] == 'artifacts') {
    return _Request(
      'GET',
      '/v1/test-runs/${_id(command[2], 'tr_')}/artifacts',
      query: options.query,
    );
  }
  if (command.length == 2 && command[0] == 'image' && command[1] == 'import') {
    if (options.bodyJson == null)
      throw const FormatException('image import requires --body-json');
    return _Request(
      'POST',
      '/v1/images/import',
      body: _body(options.bodyJson!),
    );
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
      const {
        'start',
        'stop',
        'restart',
        'kill',
        'delete',
      }.contains(command[1])) {
    late VmId id;
    try {
      id = VmId(command[2]);
    } on ArgumentError {
      throw const FormatException('VM target must be a real vm_ ULID');
    }
    return _Request(
      command[1] == 'delete' ? 'DELETE' : 'POST',
      command[1] == 'delete'
          ? '/v1/vms/${id.value}'
          : '/v1/vms/${id.value}/actions/${command[1]}',
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
    this.query = const {},
  });
  final String method;
  final String path;
  final JsonObjectValue? body;
  final String? ifMatch;
  final bool terminalOperation;
  final Map<String, String> query;
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
    this.query = const {},
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
  final Map<String, String> query;

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
    final query = <String, String>{};
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
        case '--after-sequence' ||
            '--vm-id' ||
            '--operation-id' ||
            '--test-run-id' ||
            '--label-selector' ||
            '--limit' ||
            '--cursor' ||
            '--sort' ||
            '--resource-type' ||
            '--resource-id' ||
            '--state':
          final key = args[i].substring(2).replaceAll('-', '_');
          query[key] = value();
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
    final allowedQuery = switch (verb) {
      'events' => const {
        'after_sequence',
        'vm_id',
        'operation_id',
        'test_run_id',
      },
      'vm list' => const {'label_selector', 'limit', 'cursor', 'sort'},
      'image list' => const {'label_selector', 'limit', 'cursor'},
      'test artifacts' => const {'limit', 'cursor'},
      'operation list' => const {
        'limit',
        'cursor',
        'resource_type',
        'resource_id',
        'state',
      },
      _ => const <String>{},
    };
    for (final key in query.keys) {
      if (!allowedQuery.contains(key))
        throw FormatException(
          '--${key.replaceAll('_', '-')} not supported by $verb',
        );
    }
    if (query['after_sequence'] case final value?) {
      if (!RegExp(r'^[0-9]+$').hasMatch(value) || int.tryParse(value) == null) {
        throw const FormatException(
          '--after-sequence must be a nonnegative decimal integer',
        );
      }
    }
    if (query['limit'] case final value?) {
      final limit = int.tryParse(value);
      if (limit == null || limit < 1 || limit > 200)
        throw const FormatException('--limit must be 1-200');
    }
    if (query['cursor'] case final value?) {
      if (value.isEmpty || value.length > 512)
        throw const FormatException('--cursor must contain 1-512 characters');
    }
    if (query['sort'] case final value?) {
      if (!const {
        'created_at',
        '-created_at',
        'name',
        '-name',
        'id',
        '-id',
      }.contains(value))
        throw const FormatException('unsupported --sort');
    }
    final unsupported = [
      if (bodyJson != null &&
          !const {
            'vm create',
            'vm patch',
            'image import',
            'test run',
          }.contains(verb))
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
            'vm delete',
            'image import',
            'image delete',
            'operation cancel',
            'test run',
            'test cancel',
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
      query: Map.unmodifiable(query),
    );
  }
}
