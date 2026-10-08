import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  test(
    'doctor reads the public report without mutation headers or a body',
    () async {
      final report = {
        'healthy': true,
        'checks': [
          {
            'name': 'database',
            'status': 'ok',
            'message': 'Catalog is readable.',
          },
          {
            'name': 'guest_profile',
            'status': 'warning',
            'message': 'Guest execution is not verified.',
          },
        ],
      };
      await _withReport(report, (socket) async {
        final result = await _invoke(socket, [
          'doctor',
          '--timeout-seconds',
          '5',
        ]);
        expect(result.code, 0, reason: result.error);
        expect(result.error, isEmpty);
        expect(jsonDecode(result.output), report);
      });
    },
  );
  test(
    'an unhealthy doctor report remains JSON output with a failure exit',
    () async {
      final report = {
        'healthy': false,
        'checks': [
          {
            'name': 'entitlement',
            'status': 'error',
            'message': 'The virtualization entitlement is absent.',
          },
        ],
      };
      await _withReport(report, (socket) async {
        final result = await _invoke(socket, ['doctor']);
        expect(result.code, 1);
        expect(result.error, isEmpty);
        expect(jsonDecode(result.output), report);
      });
    },
  );
  test(
    'doctor rejects malformed or contradictory reports as protocol failures',
    () async {
      final valid = {
        'healthy': true,
        'checks': [
          {'name': 'database', 'status': 'ok', 'message': 'Readable.'},
        ],
      };
      for (final report in <Map<String, Object?>>[
        {},
        {...valid, 'healthy': 'true'},
        {...valid, 'unknown': true},
        {...valid, 'checks': {}},
        {
          ...valid,
          'checks': [null],
        },
        {
          ...valid,
          'checks': [
            {'name': 'database', 'status': 'ok'},
          ],
        },
        {
          ...valid,
          'checks': [
            {'name': 'database', 'status': 'unknown', 'message': ''},
          ],
        },
        {
          ...valid,
          'checks': [
            {'name': 'database', 'status': 'error', 'message': ''},
          ],
        },
        {
          ...valid,
          'checks': [
            {'name': 'database', 'status': 'ok', 'message': '', 'extra': 1},
          ],
        },
      ]) {
        await _withReport(report, (socket) async {
          final result = await _invoke(socket, ['doctor']);
          expect(result.code, 4, reason: '$report');
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
        });
      }
    },
  );
  test('doctor obeys the explicit local request deadline', () async {
    final release = Completer<void>();
    await _withReport({'healthy': true, 'checks': []}, (socket) async {
      try {
        final result = await _invoke(socket, [
          'doctor',
          '--timeout-seconds',
          '1',
        ]);
        expect(result.code, 124);
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_TIMEOUT');
      } finally {
        release.complete();
      }
    }, beforeReply: () => release.future);
  });
  test(
    'doctor rejects mutation, target, and pagination options before connecting',
    () async {
      for (final args in <List<String>>[
        ['doctor', 'default'],
        ['doctor', '--body-json', '{}'],
        ['doctor', '--idempotency-key', 'repair'],
        ['doctor', '--limit', '1'],
        ['doctor', '--condition', 'runtime_running'],
        ['doctor', '--timeout-seconds', '0'],
        ['doctor', '--timeout-seconds', '86401'],
      ]) {
        final result = await _invoke(
          '/private/tmp/absent-gaovm-doctor.sock',
          args,
        );
        expect(result.code, 2, reason: '$args');
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_USAGE');
      }
    },
  );
}

Future<({int code, String output, String error})> _invoke(
  String socket,
  List<String> args,
) async {
  final output = StringBuffer(), error = StringBuffer();
  final code = await runCli(
    ['--socket-path', socket, ...args, '--json'],
    output: output.writeln,
    error: error.writeln,
  );
  return (code: code, output: output.toString(), error: error.toString());
}

Future<void> _withReport(
  Map<String, Object?> report,
  Future<void> Function(String socket) action, {
  Future<void> Function()? beforeReply,
}) async {
  final temporary = await Directory.systemTemp.createTemp('gvm-doctor-cli-');
  final router = PublicApiRouter()
    ..add('GET', '/v1/system/doctor', (request) async {
      expect(request.bodyBytes, isEmpty);
      expect(request.uri.query, isEmpty);
      expect(request.headers['idempotency-key'], isNull);
      await beforeReply?.call();
      return PublicApiResponse.json(status: HttpStatus.ok, body: report);
    });
  final server = PublicApiServer(
    socketPath: '${temporary.path}/api.sock',
    openApiDocument: const {},
    systemHealth: _Health(),
    router: router,
  );
  try {
    await server.start();
    await action(server.socketPath);
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
