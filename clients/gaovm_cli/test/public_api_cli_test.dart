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
    'VM delete uses DELETE with an explicit target and idempotency key',
    () async {
      final vm = VmId.generate();
      final operation = OperationId.generate();
      String? target;
      List<String>? key;
      final router = PublicApiRouter()
        ..add('DELETE', '/v1/vms/{vm_id}', (request) async {
          target = request.pathParameters['vm_id'];
          key = request.headers['idempotency-key'];
          return PublicApiResponse.json(
            status: 202,
            body: {
              'operation_id': operation.value,
              'resource_id': vm.value,
              'resource_type': 'virtual_machine',
              'state': 'pending',
            },
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, [
          'vm',
          'delete',
          vm.value,
          '--idempotency-key',
          'delete-once',
        ]);
        expect(result.code, 0, reason: result.error);
        expect(target, vm.value);
        expect(key, ['delete-once']);
        expect(jsonDecode(result.output)['operation_id'], operation.value);
      });
    },
  );

  test('legacy passthrough and non-VM targets are JSON usage errors', () async {
    for (final args in [
      ['driver-exec'],
      ['vm', 'start', 'default'],
      ['vm', 'delete', 'default'],
      ['vm', 'start', OperationId.generate().value],
      ['operation', 'get', VmId.generate().value],
    ]) {
      final output = StringBuffer(), error = StringBuffer();
      final code = await runCli(
        args,
        output: output.writeln,
        error: error.writeln,
      );
      expect(code, 2, reason: args.join(' '));
      expect(output.toString(), isEmpty);
      expect(jsonDecode(error.toString())['code'], 'CLI_USAGE');
    }
  });

  test(
    'an unavailable public socket has a stable JSON transport exit',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gaovm-cli-missing-',
      );
      try {
        final output = StringBuffer(), error = StringBuffer();
        final code = await runCli(
          [
            '--socket-path',
            '${directory.path}/missing.sock',
            'vm',
            'list',
            '--json',
          ],
          output: output.writeln,
          error: error.writeln,
        );
        expect(code, 3);
        expect(output.toString(), isEmpty);
        expect(jsonDecode(error.toString())['code'], 'CLI_TRANSPORT');
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('an invalid response has a stable JSON protocol exit', () async {
    final router = PublicApiRouter()
      ..add(
        'GET',
        '/v1/vms',
        (_) async => PublicApiResponse.json(status: 200, body: []),
      );
    await _withServer(router, (server) async {
      final result = await _invoke(server, ['vm', 'list']);
      expect(result.code, 4);
      expect(result.output, isEmpty);
      expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
    });
  });

  test(
    'API failure preserves the structured Problem and its request ID',
    () async {
      final vm = VmId.generate();
      final router = PublicApiRouter()
        ..add(
          'GET',
          '/v1/vms/{vm_id}',
          (_) async => PublicApiResponse.problem(
            status: 404,
            code: ErrorCode.vmNotFound,
            type: 'vm-not-found',
            title: 'VM not found',
            detail: 'No VM exists.',
            retryable: false,
          ),
        );
      await _withServer(router, (server) async {
        final result = await _invoke(server, ['vm', 'get', vm.value]);
        expect(result.code, 1);
        expect(result.output, isEmpty);
        final problem = Problem.fromJson(jsonDecode(result.error));
        expect(problem.code, ErrorCode.vmNotFound);
        expect(problem.status, 404);
        expect(problem.requestId.value, startsWith('req_'));
        expect(problem.detail, 'No VM exists.');
      });
    },
  );

  test('local request deadline has a stable JSON timeout exit', () async {
    final release = Completer<void>();
    final router = PublicApiRouter()
      ..add('GET', '/v1/vms', (_) async {
        await release.future;
        return PublicApiResponse.json(status: 200, body: {'items': []});
      });
    await _withServer(router, (server) async {
      try {
        final result = await _invoke(server, [
          'vm',
          'list',
          '--timeout-seconds',
          '1',
        ]);
        expect(result.code, 124);
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_TIMEOUT');
      } finally {
        release.complete();
      }
    });
  });

  test(
    'inapplicable and malformed options fail locally with JSON usage',
    () async {
      var calls = 0;
      final router = PublicApiRouter()
        ..add('GET', '/v1/vms', (_) async {
          calls++;
          return PublicApiResponse.json(
            status: 200,
            body: {'items': [], 'next_cursor': null},
          );
        });
      await _withServer(router, (server) async {
        for (final args in [
          ['vm', 'list', '--body-json', '{}'],
          ['vm', 'list', '--if-match', '7'],
          ['vm', 'list', '--condition', 'runtime_running'],
          ['vm', 'list', '--service-name', 'sshd'],
          ['vm', 'list', '--idempotency-key', 'ignored-key'],
          ['vm', 'list', '--socket-path', '--json'],
          ['vm', 'list', '--timeout-seconds', '1', '--timeout-seconds', '2'],
          ['vm', 'list', '--limit', '0'],
          ['vm', 'list', '--limit', '201'],
          ['vm', 'list', '--limit', 'invalid'],
          ['vm', 'list', '--limit', '1', '--limit', '2'],
          ['vm', 'list', '--cursor', ''],
          ['vm', 'list', '--cursor', 'x' * 513],
          ['vm', 'list', '--sort', 'invalid'],
          ['vm', 'list', '--state', 'pending'],
          ['operation', 'list', '--label-selector', 'channel=nightly'],
          ['operation', 'list', '--sort', 'name'],
          ['vm', 'get', VmId.generate().value, '--limit', '1'],
        ]) {
          final result = await _invoke(server, args);
          expect(result.code, 2, reason: args.join(' '));
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_USAGE');
        }
        expect(calls, 0);
      });
    },
  );

  test('JSON help describes the supported public command groups', () async {
    final output = StringBuffer(), error = StringBuffer();
    final code = await runCli(
      ['--help', '--json'],
      output: output.writeln,
      error: error.writeln,
    );
    expect(code, 0);
    expect(error.toString(), isEmpty);
    final help = jsonDecode(output.toString()) as Map;
    expect(
      help['commands'],
      containsAll([
        'vm list',
        'vm create',
        'vm patch VM_ID',
        'vm delete VM_ID',
        'vm wait VM_ID',
        'image import',
        'image list',
        'image get IMG_ID',
        'image delete IMG_ID',
        'operation list',
        'operation cancel OP_ID',
        'operation wait OP_ID',
        'test run',
        'test get TR_ID',
        'test cancel TR_ID',
        'test artifacts TR_ID',
        'events',
        'doctor',
      ]),
    );
    expect(help['options'], contains('--label-selector SELECTOR'));
    expect(help['options'], contains('--cursor CURSOR'));
    expect(help['options'], contains('--after-sequence N'));
    expect(help['options'], contains('--vm-id VM_ID'));
    expect(help['options'], contains('--operation-id OP_ID'));
    expect(help['options'], contains('--test-run-id TR_ID'));
    expect(
      help['options']['--service-name NAME'],
      'guest_service_ready VM wait target',
    );
  });

  test(
    'VM wait preserves structured WAIT_TIMEOUT and a stable timeout exit',
    () async {
      final vm = VmId.generate();
      JsonObjectValue? body;
      List<String>? idempotencyKey;
      final router = PublicApiRouter()
        ..add('POST', '/v1/vms/{vm_id}/wait', (request) async {
          body = request.jsonBody;
          idempotencyKey = request.headers['idempotency-key'];
          return PublicApiResponse.problem(
            status: 504,
            code: ErrorCode.waitTimeout,
            type: 'wait-timeout',
            title: 'Wait timed out',
            detail: 'Condition not reached.',
            retryable: true,
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, [
          'vm',
          'wait',
          vm.value,
          '--condition',
          'runtime_running',
          '--timeout-seconds',
          '1',
        ]);
        expect(body?.toJson(), {
          'condition': 'runtime_running',
          'timeout_seconds': 1,
        });
        expect(idempotencyKey, isNull);
        expect(result.code, 124, reason: result.error);
        expect(result.output, isEmpty);
        final problem = Problem.fromJson(jsonDecode(result.error));
        expect(problem.code, ErrorCode.waitTimeout);
        expect(problem.retryable, isTrue);
      });
    },
  );

  test(
    'bounded Operation wait returns a failed terminal result with nonzero exit',
    () async {
      final vm = VmId.generate(), operationId = OperationId.generate();
      final operation = Operation(
        id: operationId,
        type: 'vm.start',
        resourceType: ResourceType.virtualMachine,
        resourceId: vm,
        state: OperationState.failed,
        requestId: RequestId.generate(),
        cancellable: false,
        request: JsonObjectValue.empty,
        error: OperationError(
          code: ErrorCode.driverStartFailed,
          message: 'driver failed',
          retryable: false,
          details: JsonObjectValue.empty,
        ),
        createdAt: DateTime.now(),
        completedAt: DateTime.now(),
      );
      var calls = 0;
      final router = PublicApiRouter()
        ..add('POST', '/v1/operations/{operation_id}/wait', (request) async {
          calls++;
          expect(request.jsonBody?.toJson(), {'timeout_seconds': 1});
          expect(request.headers['idempotency-key'], isNull);
          return PublicApiResponse.json(status: 200, body: operation.toJson());
        });
      await _withServer(router, (server) async {
        final missing = await _invoke(server, [
          'operation',
          'wait',
          operationId.value,
        ]);
        expect(missing.code, 2);
        expect(calls, 0);
        final result = await _invoke(server, [
          'operation',
          'wait',
          operationId.value,
          '--timeout-seconds',
          '1',
        ]);
        expect(result.code, 1, reason: result.error);
        expect(Operation.fromJson(jsonDecode(result.output)), operation);
        expect(result.error, isEmpty);
        expect(calls, 1);
      });
    },
  );

  test(
    'patch requires an explicit revision and sends the public If-Match contract',
    () async {
      final vm = VmId.generate();
      var calls = 0;
      final router = PublicApiRouter()
        ..add('PATCH', '/v1/vms/{vm_id}', (request) async {
          calls++;
          expect(request.headers['if-match'], ['"7"']);
          expect(request.headers['idempotency-key'], ['patch-once']);
          expect(request.jsonBody?.toJson(), {
            'spec': {'cpu': 4},
          });
          return PublicApiResponse.json(
            status: 202,
            body: {
              'operation_id': OperationId.generate().value,
              'resource_id': vm.value,
              'resource_type': 'vm',
              'state': 'pending',
            },
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, [
          'vm',
          'patch',
          vm.value,
          '--body-json',
          '{"spec":{"cpu":4}}',
          '--if-match',
          '7',
          '--idempotency-key',
          'patch-once',
        ]);
        expect(result.code, 0, reason: result.error);
        final missing = await _invoke(server, [
          'vm',
          'patch',
          vm.value,
          '--body-json',
          '{"spec":{"cpu":4}}',
        ]);
        expect(missing.code, 2);
        expect(calls, 1);
      });
    },
  );

  test(
    'start submits an explicit VM and idempotency key and returns its Operation',
    () async {
      final vm = VmId.generate();
      final operation = OperationId.generate();
      final router = PublicApiRouter()
        ..add('POST', '/v1/vms/{vm_id}/actions/start', (request) async {
          expect(request.pathParameters['vm_id'], vm.value);
          expect(request.headers['idempotency-key'], ['retry-start']);
          expect(request.jsonBody?.toJson(), isEmpty);
          return PublicApiResponse.json(
            status: 202,
            body: {
              'operation_id': operation.value,
              'resource_id': vm.value,
              'resource_type': 'vm',
              'state': 'pending',
            },
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, [
          'vm',
          'start',
          vm.value,
          '--idempotency-key',
          'retry-start',
        ]);
        expect(result.code, 0, reason: result.error);
        expect(jsonDecode(result.output)['operation_id'], operation.value);
        expect(jsonDecode(result.output)['state'], 'pending');
        expect(result.error, isEmpty);
      });
    },
  );

  test(
    'CLI entrypoint lists VMs using HTTP over the public Unix socket',
    () async {
      final directory = await Directory.systemTemp.createTemp('gaovm-cli-');
      imageFileMode(directory.path, 0x1c0);
      var calls = 0;
      final router = PublicApiRouter()
        ..add('GET', '/v1/vms', (request) async {
          calls++;
          return PublicApiResponse.json(
            status: 200,
            body: {
              'items': [
                {'id': 'vm_00000000000000000000000001'},
              ],
              'next_cursor': null,
            },
          );
        });
      final server = PublicApiServer(
        socketPath: '${directory.path}/api.sock',
        openApiDocument: const {},
        systemHealth: _Health(),
        router: router,
      );
      try {
        await server.start();
        final result = await Process.run(Platform.resolvedExecutable, [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          '${Directory.current.path}/bin/gaovm_cli.dart',
          '--socket-path',
          server.socketPath,
          'vm',
          'list',
          '--json',
        ]).timeout(const Duration(seconds: 15));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(jsonDecode(result.stdout as String), {
          'items': [
            {'id': 'vm_00000000000000000000000001'},
          ],
          'next_cursor': null,
        });
        expect(calls, 1);
      } finally {
        await server.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test('TestRun query honors the explicit local deadline', () async {
    final release = Completer<void>();
    final router = PublicApiRouter()
      ..add('GET', '/v1/test-runs/{test_run_id}', (request) async {
        expect(request.headers['idempotency-key'], isNull);
        await release.future;
        return PublicApiResponse.json(status: 200, body: const {});
      });
    await _withServer(router, (server) async {
      try {
        final result = await _invoke(server, [
          'test',
          'get',
          TestRunId.generate().value,
          '--timeout-seconds',
          '1',
        ]);
        expect(result.code, 124);
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_TIMEOUT');
      } finally {
        release.complete();
      }
    });
  });
}

Future<void> _withServer(
  PublicApiRouter router,
  Future<void> Function(PublicApiServer) action,
) async {
  final directory = await Directory.systemTemp.createTemp('gaovm-cli-wire-');
  imageFileMode(directory.path, 0x1c0);
  final server = PublicApiServer(
    socketPath: '${directory.path}/api.sock',
    openApiDocument: const {},
    systemHealth: _Health(),
    router: router,
  );
  try {
    await server.start();
    await action(server);
  } finally {
    await server.close();
    await directory.delete(recursive: true);
  }
}

Future<({int code, String output, String error})> _invoke(
  PublicApiServer server,
  List<String> args,
) async {
  final output = StringBuffer(), error = StringBuffer();
  final code = await runCli(
    ['--socket-path', server.socketPath, ...args, '--json'],
    output: output.writeln,
    error: error.writeln,
  );
  return (code: code, output: output.toString(), error: error.toString());
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
