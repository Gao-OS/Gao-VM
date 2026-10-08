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
    'schema reads the public document without a body or mutation headers',
    () async {
      await _withReply(
        _document,
        (socket) async {
          for (final compact in [true, false]) {
            final result = await _invoke(socket, [
              'schema',
              if (compact) '--json',
            ]);
            expect(result.code, 0, reason: result.error);
            expect(result.error, isEmpty);
            expect(jsonDecode(result.output), _document);
            if (compact) expect(result.output.trim().split('\n'), hasLength(1));
          }
        },
        beforeReply: (request) async {
          expect(request.method, 'GET');
          expect(request.uri.path, '/v1/openapi.json');
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
    'schema rejects an invalid OpenAPI envelope as a protocol failure',
    () async {
      for (final invalid in [
        const {},
        const [],
        {..._document, 'openapi': 3},
        {..._document, 'openapi': '3.0.3'},
        {..._document, 'info': <String, Object?>{}},
        {
          ..._document,
          'info': {'title': 3, 'version': 'v1'},
        },
        {..._document, 'paths': []},
        {..._document, 'components': null},
        {
          ..._document,
          'components': {'schemas': []},
        },
      ]) {
        await _withReply(invalid, (socket) async {
          final result = await _invoke(socket, ['schema', '--json']);
          expect(result.code, 4);
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
        });
      }
    },
  );
  test('schema accepts compatible OpenAPI 3.1 patch versions', () async {
    final document = {..._document, 'openapi': '3.1.1'};
    await _withReply(document, (socket) async {
      final result = await _invoke(socket, ['schema', '--json']);
      expect(result.code, 0, reason: result.error);
      expect(jsonDecode(result.output), document);
    });
  });
  test('schema preserves a structured API failure and request ID', () async {
    final problem = Problem(
      type: Uri.parse('https://gaovm.dev/problems/internal-error'),
      title: 'Schema unavailable',
      status: HttpStatus.serviceUnavailable,
      code: ErrorCode.internalError,
      detail: 'Schema unavailable.',
      requestId: RequestId.generate(),
      retryable: true,
      details: JsonObjectValue.empty,
    );
    await _withReply(problem.toJson(), (socket) async {
      final result = await _invoke(socket, ['schema', '--json']);
      expect(result.code, 1);
      expect(result.output, isEmpty);
      expect(Problem.fromJson(jsonDecode(result.error)), problem);
    }, status: problem.status);
  });
  test(
    'schema bounds a stalled response by the explicit local deadline',
    () async {
      final release = Completer<void>();
      await _withReply(_document, (socket) async {
        try {
          final result = await _invoke(socket, [
            'schema',
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
  test('schema reports an unavailable socket as a transport failure', () async {
    await _withReply(_document, (socket) async {
      final result = await _invoke('$socket.missing', ['schema', '--json']);
      expect(result.code, 3);
      expect(result.output, isEmpty);
      expect(jsonDecode(result.error)['code'], 'CLI_TRANSPORT');
    });
  });
  test(
    'schema rejects mutation, target, wait and query options locally',
    () async {
      await _withReply(_document, (socket) async {
        for (final arguments in [
          ['schema', VmId.generate().value],
          ['schema', '--body-json', '{}'],
          ['schema', '--idempotency-key', 'not-a-mutation'],
          ['schema', '--if-match', '1'],
          ['schema', '--condition', 'runtime_running'],
          ['schema', '--service-name', 'sshd'],
          ['schema', '--vm-id', VmId.generate().value],
          ['schema', '--limit', '1'],
          ['schema', '--cursor', 'not-a-list'],
          ['schema', '--timeout-seconds', '0'],
        ]) {
          final result = await _invoke('$socket.missing', [
            ...arguments,
            '--json',
          ]);
          expect(result.code, 2, reason: arguments.join(' '));
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_USAGE');
        }
      });
    },
  );
  test(
    'CLI process reads the linked public schema from a non-repository directory',
    () async {
      final document = await loadPublicOpenApiDocument(
        File('../../schemas/openapi/gaovm-v1.yaml'),
      );
      final temporary =
          await (Platform.isMacOS
                  ? Directory('/private/tmp')
                  : Directory.systemTemp)
              .createTemp('gvm-schema-process-');
      imageFileMode(temporary.path, 0x1c0);
      final server = PublicApiServer(
        socketPath: '${temporary.path}/api.sock',
        openApiDocument: document,
        systemHealth: _Health(),
      );
      try {
        await server.start();
        final process = await Process.start(Platform.resolvedExecutable, [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          File('bin/gaovm_cli.dart').absolute.path,
          '--socket-path',
          server.socketPath,
          'schema',
          '--json',
          '--timeout-seconds',
          '5',
        ], workingDirectory: temporary.path);
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
          expect(jsonDecode(await output), document);
        } finally {
          if (!exited) {
            process.kill(ProcessSignal.sigkill);
            await process.exitCode.timeout(const Duration(seconds: 5));
          }
          await output;
          await error;
        }
      } finally {
        await server.close();
        await temporary.delete(recursive: true);
      }
    },
  );
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}

const _document = {
  'openapi': '3.1.0',
  'info': {'title': 'GaoVM', 'version': 'v1'},
  'paths': <String, Object?>{},
  'components': {
    'schemas': {
      'Sample': {'type': 'object'},
    },
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
          .createTemp('gvm-schema-cli-');
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
