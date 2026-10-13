import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  test(
    'capabilities reads public advertisements without a body or mutation headers',
    () async {
      await _withReply(
        _capabilities,
        (socket) async {
          for (final compact in [true, false]) {
            final result = await _invoke(socket, [
              'capabilities',
              if (compact) '--json',
            ]);
            expect(result.code, 0, reason: result.error);
            expect(result.error, isEmpty);
            expect(jsonDecode(result.output), _capabilities);
            if (compact) expect(result.output.trim().split('\n'), hasLength(1));
          }
        },
        beforeReply: (request) async {
          expect(request.method, 'GET');
          expect(request.uri.path, '/v1/system/capabilities');
          expect(request.uri.query, isEmpty);
          expect(request.headers.value('idempotency-key'), isNull);
          expect(request.headers.value('if-match'), isNull);
          expect(
            await request.fold<int>(0, (sum, chunk) => sum + chunk.length),
            0,
          );
        },
      );
    },
  );
  test(
    'capabilities preserves guest advertisements and configured limits',
    () async {
      final report = {
        ..._capabilities,
        'guest': [
          'health',
          'system.info',
          'exec',
          'artifact.collect',
          'service.status',
          'shutdown',
          'reboot',
        ],
        'limits': {
          'max_defined_vms': 512,
          'max_running_vms': 3,
          'max_concurrent_boots': 1,
        },
      };
      await _withReply(report, (socket) async {
        final result = await _invoke(socket, ['capabilities', '--json']);
        expect(result.code, 0, reason: result.error);
        expect(result.error, isEmpty);
        expect(jsonDecode(result.output), report);
      });
    },
  );
  test('capabilities follows the frozen backend-array constraints', () async {
    for (final backends in [
      <String>[],
      ['vz', 'vz'],
    ]) {
      final report = {..._capabilities, 'backends': backends};
      await _withReply(report, (socket) async {
        final result = await _invoke(socket, ['capabilities', '--json']);
        expect(result.code, 0, reason: result.error);
        expect(jsonDecode(result.output), report);
      });
    }
  });
  test(
    'capabilities rejects malformed or private advertisements as protocol failures',
    () async {
      final limits = _capabilities['limits'] as Map<String, Object?>;
      for (final invalid in [
        const {},
        const [],
        {..._capabilities, 'api_version': 'v2'},
        {..._capabilities, 'private_driver': true},
        {..._capabilities}..remove('guest'),
        {..._capabilities, 'backends': 'vz'},
        {
          ..._capabilities,
          'backends': [null],
        },
        {
          ..._capabilities,
          'backends': ['unknown'],
        },
        {..._capabilities, 'guest': {}},
        {
          ..._capabilities,
          'guest': [1],
        },
        {
          ..._capabilities,
          'guest': ['guest.status'],
        },
        {
          ..._capabilities,
          'guest': ['health', 'health'],
        },
        {..._capabilities, 'limits': []},
        {
          ..._capabilities,
          'limits': {...limits, 'max_driver_processes': 8},
        },
        for (final name in limits.keys) ...[
          {
            ..._capabilities,
            'limits': {...limits}..remove(name),
          },
          for (final value in [0, -1, 1.5, '8', null])
            {
              ..._capabilities,
              'limits': {...limits, name: value},
            },
        ],
      ]) {
        await _withReply(invalid, (socket) async {
          final result = await _invoke(socket, ['capabilities', '--json']);
          expect(result.code, 4, reason: '$invalid');
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
        });
      }
    },
  );
  test('capabilities requires the documented successful HTTP status', () async {
    for (final status in [HttpStatus.created, HttpStatus.accepted]) {
      await _withReply(_capabilities, (socket) async {
        final result = await _invoke(socket, ['capabilities', '--json']);
        expect(result.code, 4);
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
      }, status: status);
    }
  });
  test(
    'capabilities preserves a structured API failure and request ID',
    () async {
      final problem = Problem(
        type: Uri.parse('https://gaovm.dev/problems/internal-error'),
        title: 'Capabilities unavailable',
        status: HttpStatus.serviceUnavailable,
        code: ErrorCode.internalError,
        detail: 'Capabilities unavailable.',
        requestId: RequestId.generate(),
        retryable: true,
        details: JsonObjectValue.empty,
      );
      await _withReply(problem.toJson(), (socket) async {
        final result = await _invoke(socket, ['capabilities', '--json']);
        expect(result.code, 1);
        expect(result.output, isEmpty);
        expect(Problem.fromJson(jsonDecode(result.error)), problem);
      }, status: problem.status);
    },
  );
  test(
    'capabilities bounds a stalled response by the explicit local deadline',
    () async {
      final release = Completer<void>();
      await _withReply(_capabilities, (socket) async {
        try {
          final result = await _invoke(socket, [
            'capabilities',
            '--json',
            '--timeout-seconds',
            '1',
          ]);
          expect(result.code, 124);
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_TIMEOUT');
        } finally {
          release.complete();
        }
      }, beforeReply: (_) => release.future);
    },
  );
  test(
    'capabilities reports an unavailable socket as a transport failure',
    () async {
      await _withReply(_capabilities, (socket) async {
        final result = await _invoke('$socket.missing', [
          'capabilities',
          '--json',
        ]);
        expect(result.code, 3);
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_TRANSPORT');
      });
    },
  );
  test(
    'capabilities rejects mutation, target, wait and query options before I/O',
    () async {
      var requests = 0;
      await _withReply(
        _capabilities,
        (socket) async {
          for (final arguments in [
            [VmId.generate().value],
            ['--body-json', '{}'],
            ['--idempotency-key', 'not-a-mutation'],
            ['--if-match', '1'],
            ['--condition', 'runtime_running'],
            ['--service-name', 'sshd'],
            ['--output-dir', '/private/tmp'],
            ['--vm-id', VmId.generate().value],
            ['--operation-id', OperationId.generate().value],
            ['--test-run-id', TestRunId.generate().value],
            ['--after-sequence', '0'],
            ['--label-selector', 'team=qa'],
            ['--limit', '1'],
            ['--cursor', 'not-a-list'],
            ['--sort', 'name'],
            ['--resource-type', 'virtual_machine'],
            ['--resource-id', VmId.generate().value],
            ['--state', 'running'],
            for (final timeout in ['0', '-1', '86401', 'not-a-number'])
              ['--timeout-seconds', timeout],
            ['--timeout-seconds', '1', '--timeout-seconds', '2'],
          ]) {
            final result = await _invoke(socket, [
              'capabilities',
              ...arguments,
              '--json',
            ]);
            expect(result.code, 2, reason: arguments.join(' '));
            expect(result.output, isEmpty);
            expect(jsonDecode(result.error)['code'], 'CLI_USAGE');
          }
          expect(requests, 0);
        },
        beforeReply: (_) async {
          requests++;
        },
      );
    },
  );
  test('help lists capabilities without connecting to a daemon', () async {
    final result = await _invoke('/unavailable/gao-vm/api.sock', [
      '--help',
      '--json',
    ]);
    expect(result.code, 0, reason: result.error);
    expect(jsonDecode(result.output)['commands'], contains('capabilities'));
  });
  test(
    'CLI process reads capabilities from a non-repository directory',
    () async {
      await _withReply(_capabilities, (socket) async {
        final process = await Process.start(Platform.resolvedExecutable, [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          File('bin/gaovm_cli.dart').absolute.path,
          '--socket-path',
          socket,
          'capabilities',
          '--json',
          '--timeout-seconds',
          '5',
        ], workingDirectory: File(socket).parent.path);
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
          expect(jsonDecode(await output), _capabilities);
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

const _capabilities = {
  'api_version': 'v1',
  'backends': ['vz'],
  'guest': <String>[],
  'limits': {
    'max_defined_vms': 128,
    'max_running_vms': 8,
    'max_concurrent_boots': 2,
  },
};

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

Future<void> _withReply(
  Object? body,
  Future<void> Function(String socket) action, {
  Future<void> Function(HttpRequest)? beforeReply,
  int status = HttpStatus.ok,
}) async {
  final temporary =
      await (Platform.isMacOS
              ? Directory('/private/tmp')
              : Directory.systemTemp)
          .createTemp('gvm-caps-cli-');
  imageFileMode(temporary.path, 0x1c0);
  final path = '${temporary.path}/api.sock';
  final listener = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  imageFileMode(path, 0x180);
  final server = HttpServer.listenOn(listener);
  final handlers = <Future<void>>[];
  Future<void> reply(HttpRequest request) async {
    try {
      await beforeReply?.call(request);
      request.response
        ..statusCode = status
        ..headers.contentType = status >= 400
            ? ContentType('application', 'problem+json')
            : ContentType.json
        ..headers.set('x-request-id', RequestId.generate().value)
        ..write(jsonEncode(body));
      await request.response.close();
    } on HttpException {
      // A deadline closes the client connection before this fixture replies.
    } on SocketException {
      // The client owns cancellation of its transport connection.
    }
  }

  final subscription = server.listen((request) => handlers.add(reply(request)));
  try {
    await action(path);
  } finally {
    await server.close(force: true);
    await listener.close();
    await subscription.cancel();
    await Future.wait(handlers);
    await temporary.delete(recursive: true);
  }
}
