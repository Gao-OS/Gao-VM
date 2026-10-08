import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  test(
    'guest exec sends the public request without interpreting argv',
    () async {
      final vm = VmId.generate();
      final accepted = _acceptance(vm);
      PublicApiRequest? received;
      final router = PublicApiRouter()
        ..add('POST', '/v1/vms/{vm_id}/guest/exec', (request) async {
          received = request;
          return PublicApiResponse.json(status: 202, body: accepted);
        });
      await _withApi(router, (server) async {
        final result = await _invoke(server.socketPath, [
          'guest',
          'exec',
          vm.value,
          '--body-json',
          jsonEncode(_request),
          '--idempotency-key',
          'guest-explicit-retry-key',
          '--json',
        ]);
        expect(result.code, 0, reason: result.error);
        expect(result.error, isEmpty);
        expect(jsonDecode(result.output), accepted);
        expect(received?.pathParameters['vm_id'], vm.value);
        expect(received?.uri.query, isEmpty);
        expect(received?.jsonBody?.toJson(), _request);
        expect(
          ContentType.parse(received!.headers['content-type']!.single).mimeType,
          ContentType.json.mimeType,
        );
        expect(received?.headers['idempotency-key'], [
          'guest-explicit-retry-key',
        ]);
        expect(received?.headers['if-match'], isNull);
      });
    },
  );
  test(
    'guest exec supports both JSON formats and generates request keys',
    () async {
      final vm = VmId.generate();
      final accepted = _acceptance(vm);
      final keys = <String>[];
      final router = PublicApiRouter()
        ..add('POST', '/v1/vms/{vm_id}/guest/exec', (request) async {
          keys.add(request.headers['idempotency-key']!.single);
          return PublicApiResponse.json(status: 202, body: accepted);
        });
      await _withApi(router, (server) async {
        for (final compact in [true, false]) {
          final result = await _invoke(server.socketPath, [
            'guest',
            'exec',
            vm.value,
            '--body-json',
            jsonEncode(_request),
            if (compact) '--json',
          ]);
          expect(result.code, 0, reason: result.error);
          expect(result.error, isEmpty);
          expect(jsonDecode(result.output), accepted);
          expect(
            result.output.trim().split('\n').length,
            compact ? equals(1) : greaterThan(1),
          );
        }
        expect(keys.toSet(), hasLength(2));
        for (final key in keys) {
          expect(RegExp(r'^[\x21-\x7e]{1,255}$').hasMatch(key), isTrue);
        }
      });
    },
  );
  test(
    'guest exec rejects malformed or misbound operation acceptances',
    () async {
      final vm = VmId.generate();
      final accepted = _acceptance(vm);
      for (final body in [
        const [],
        const {},
        {...accepted, 'operation_id': 'not-an-operation'},
        {...accepted, 'operation_id': VmId.generate().value},
        {...accepted, 'operation_id': 3},
        {...accepted, 'resource_type': 'image'},
        {...accepted, 'resource_id': VmId.generate().value},
        {...accepted, 'state': 'failed'},
        {...accepted, 'state': 'cancelled'},
      ]) {
        final router = PublicApiRouter()
          ..add(
            'POST',
            '/v1/vms/{vm_id}/guest/exec',
            (_) async => PublicApiResponse.json(status: 202, body: body),
          );
        await _withApi(router, (server) async {
          final result = await _invoke(server.socketPath, [
            'guest',
            'exec',
            vm.value,
            '--body-json',
            jsonEncode(_request),
            '--json',
          ]);
          expect(result.code, 4, reason: jsonEncode(body));
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
        });
      }
    },
  );
  test('guest exec requires the contract HTTP acceptance status', () async {
    final vm = VmId.generate();
    for (final status in [200, 201]) {
      final router = PublicApiRouter()
        ..add(
          'POST',
          '/v1/vms/{vm_id}/guest/exec',
          (_) async =>
              PublicApiResponse.json(status: status, body: _acceptance(vm)),
        );
      await _withApi(router, (server) async {
        final result = await _invoke(server.socketPath, [
          'guest',
          'exec',
          vm.value,
          '--body-json',
          jsonEncode(_request),
          '--json',
        ]);
        expect(result.code, 4, reason: 'HTTP $status is not acceptance');
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
      });
    }
  });
  test(
    'guest exec preserves API Problems and never retries a rejected write',
    () async {
      final vm = VmId.generate();
      for (final (status, code, retryable) in [
        (503, ErrorCode.guestAgentUnavailable, true),
        (404, ErrorCode.vmNotFound, false),
        (409, ErrorCode.vmOperationConflict, true),
        (409, ErrorCode.idempotencyConflict, false),
        (504, ErrorCode.waitTimeout, true),
      ]) {
        var requests = 0;
        final router = PublicApiRouter()
          ..add('POST', '/v1/vms/{vm_id}/guest/exec', (_) async {
            requests++;
            return PublicApiResponse.problem(
              status: status,
              code: code,
              type: 'guest-request-rejected',
              title: 'Guest request rejected',
              detail: 'No command was accepted.',
              retryable: retryable,
              details: JsonObjectValue.fromJson({
                'reason': 'fixture rejection',
              }),
            );
          });
        await _withApi(router, (server) async {
          final result = await _invoke(server.socketPath, [
            'guest',
            'exec',
            vm.value,
            '--body-json',
            jsonEncode(_request),
            '--json',
          ]);
          expect(result.code, code == ErrorCode.waitTimeout ? 124 : 1);
          expect(result.output, isEmpty);
          final problem = Problem.fromJson(jsonDecode(result.error));
          expect(problem.code, code);
          expect(problem.status, status);
          expect(problem.retryable, retryable);
          expect(problem.requestId.value, startsWith('req_'));
          expect(problem.details.toJson(), {'reason': 'fixture rejection'});
          expect(requests, 1);
        });
      }
    },
  );
  test(
    'a local guest exec deadline does not rewrite the guest budget or retry',
    () async {
      final vm = VmId.generate();
      final release = Completer<void>();
      var requests = 0;
      Object? guestTimeout;
      final router = PublicApiRouter()
        ..add('POST', '/v1/vms/{vm_id}/guest/exec', (request) async {
          requests++;
          guestTimeout = request.jsonBody?.toJson()['timeout_seconds'];
          await release.future;
          return PublicApiResponse.json(status: 202, body: _acceptance(vm));
        });
      await _withApi(router, (server) async {
        try {
          final result = await _invoke(server.socketPath, [
            'guest',
            'exec',
            vm.value,
            '--body-json',
            jsonEncode(_request),
            '--idempotency-key',
            'retry-after-local-timeout',
            '--timeout-seconds',
            '1',
            '--json',
          ]);
          expect(result.code, 124);
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_TIMEOUT');
          expect(guestTimeout, 600);
          expect(requests, 1);
        } finally {
          release.complete();
        }
      });
    },
  );
  test('guest request semantics remain owned by the public API', () async {
    final vm = VmId.generate();
    final invalid = {..._request, 'argv': 'not-an-argv-vector'};
    JsonObjectValue? received;
    final router = PublicApiRouter()
      ..add('POST', '/v1/vms/{vm_id}/guest/exec', (request) async {
        received = request.jsonBody;
        return PublicApiResponse.problem(
          status: 400,
          code: ErrorCode.invalidRequest,
          type: 'invalid-request',
          title: 'Invalid Guest request',
          detail: 'argv must be an array.',
          retryable: false,
        );
      });
    await _withApi(router, (server) async {
      final result = await _invoke(server.socketPath, [
        'guest',
        'exec',
        vm.value,
        '--body-json',
        jsonEncode(invalid),
        '--json',
      ]);
      expect(received?.toJson(), invalid);
      expect(result.code, 1);
      expect(result.output, isEmpty);
      expect(
        Problem.fromJson(jsonDecode(result.error)).code,
        ErrorCode.invalidRequest,
      );
    });
  });
  test(
    'guest exec distinguishes usage errors from an unavailable transport',
    () async {
      final vm = VmId.generate().value;
      final body = jsonEncode(_request);
      final command = ['guest', 'exec', vm];
      final request = [...command, '--body-json', body];
      await _withApi(PublicApiRouter(), (server) async {
        final missingSocket = '${server.socketPath}.missing';
        final unavailable = await _invoke(missingSocket, [
          ...request,
          '--json',
        ]);
        expect(unavailable.code, 3);
        expect(unavailable.output, isEmpty);
        expect(jsonDecode(unavailable.error)['code'], 'CLI_TRANSPORT');
        for (final arguments in [
          ['guest', 'exec'],
          command,
          ['guest', 'exec', 'default', '--body-json', body],
          ['guest', 'exec', OperationId.generate().value, '--body-json', body],
          [...request, 'extra'],
          [...command, '--body-json', '[]'],
          [...command, '--body-json', 'null'],
          [...command, '--body-json', '{'],
          [...request, '--body-json', body],
          [...request, '--if-match', '1'],
          [...request, '--condition', 'runtime_running'],
          [...request, '--service-name', 'sshd'],
          [...request, '--vm-id', vm],
          [...request, '--limit', '1'],
          [...request, '--idempotency-key', 'has space'],
          [...request, '--timeout-seconds', '0'],
          [...request, '--timeout-seconds', '1', '--timeout-seconds', '2'],
        ]) {
          final result = await _invoke(missingSocket, [...arguments, '--json']);
          expect(result.code, 2, reason: arguments.join(' '));
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_USAGE');
        }
      });
    },
  );
  test(
    'the CLI process submits guest exec from outside the repository',
    () async {
      final vm = VmId.generate();
      final accepted = _acceptance(vm);
      JsonObjectValue? received;
      final router = PublicApiRouter()
        ..add('POST', '/v1/vms/{vm_id}/guest/exec', (request) async {
          received = request.jsonBody;
          expect(request.pathParameters['vm_id'], vm.value);
          return PublicApiResponse.json(status: 202, body: accepted);
        });
      await _withApi(router, (server) async {
        final process = await Process.start(
          Platform.resolvedExecutable,
          [
            '--packages=${File('.dart_tool/package_config.json').absolute.path}',
            File('bin/gaovm_cli.dart').absolute.path,
            '--socket-path',
            server.socketPath,
            'guest',
            'exec',
            vm.value,
            '--body-json',
            jsonEncode(_request),
            '--json',
            '--timeout-seconds',
            '5',
          ],
          workingDirectory: File(server.socketPath).parent.path,
        );
        final output = utf8.decoder.bind(process.stdout).join();
        final error = utf8.decoder.bind(process.stderr).join();
        var exited = false;
        try {
          final code = await process.exitCode.timeout(
            const Duration(seconds: 15),
          );
          exited = true;
          expect(code, 0, reason: await error);
          expect(await error, isEmpty);
          expect(jsonDecode(await output), accepted);
          expect(received?.toJson(), _request);
        } finally {
          if (!exited) {
            process.kill(ProcessSignal.sigkill);
            await process.exitCode.timeout(const Duration(seconds: 5));
          }
          await output;
          await error;
        }
      });
    },
  );
}

const _request = {
  'argv': [
    '/usr/bin/printf',
    'argument with spaces',
    'quoted"argument',
    r'$(do-not-run)',
    '; data only',
    '测试',
  ],
  'cwd': '/does-not-exist-on-host',
  'env': {'TEST_VALUE': r'$literal value'},
  'timeout_seconds': 600,
  'capture': {'stdout': true, 'stderr': false, 'max_inline_bytes': 65536},
};

Map<String, Object?> _acceptance(VmId vm) => OperationAcceptance(
  operationId: OperationId.generate(),
  state: OperationState.pending,
  resourceType: ResourceType.virtualMachine,
  resourceId: vm,
).toJson();

Future<({int code, String output, String error})> _invoke(
  String socket,
  List<String> arguments,
) async {
  final output = StringBuffer(), error = StringBuffer();
  final code = await runCli(
    ['--socket-path', socket, ...arguments],
    output: output.writeln,
    error: error.writeln,
  );
  return (code: code, output: output.toString(), error: error.toString());
}

Future<void> _withApi(
  PublicApiRouter router,
  Future<void> Function(PublicApiServer) action,
) async {
  final temporary =
      await (Platform.isMacOS
              ? Directory('/private/tmp')
              : Directory.systemTemp)
          .createTemp('gvm-guest-cli-');
  imageFileMode(temporary.path, 0x1c0);
  final server = PublicApiServer(
    socketPath: '${temporary.path}/api.sock',
    openApiDocument: const {},
    systemHealth: _Health(),
    router: router,
  );
  try {
    await server.start();
    await action(server);
  } finally {
    await server.close();
    await temporary.delete(recursive: true);
  }
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
