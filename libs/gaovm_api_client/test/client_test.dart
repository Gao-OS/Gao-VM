import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  test('HTTP/1.1 UDS JSON preserves request ID and ETag', () async {
    final requestId = RequestId.generate();
    await _serve(
      (request) async {
        expect(request.protocolVersion, '1.1');
        expect(request.uri.path, '/v1/vms');
        expect(request.uri.queryParameters['label_selector'], 'channel=stable');
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('X-Request-ID', requestId.value);
        request.response.headers.set('ETag', '"7"');
        request.response.write('{"items":[],"next_cursor":null}');
        await request.response.close();
      },
      (client) async {
        final result = await client.request(
          'GET',
          '/v1/vms',
          query: {'label_selector': 'channel=stable'},
        );
        expect(result.status, 200);
        expect(result.requestId, requestId.value);
        expect(result.etag, '"7"');
        expect(result.body.toJson()['items'], isEmpty);
      },
    );
  });

  test(
    'structured API Problem is retained rather than replaced with text',
    () async {
      final problem = Problem(
        type: Uri.parse('https://gaovm.dev/problems/vm-not-found'),
        title: 'VM not found',
        status: 404,
        code: ErrorCode.vmNotFound,
        detail: 'No VM exists.',
        requestId: RequestId.generate(),
        retryable: false,
        details: JsonObjectValue.empty,
      );
      await _serve(
        (request) async {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType(
            'application',
            'problem+json',
          );
          request.response.write(jsonEncode(problem.toJson()));
          await request.response.close();
        },
        (client) async {
          await expectLater(
            client.request('GET', '/v1/vms/missing'),
            throwsA(
              isA<ApiProblemException>().having(
                (error) => error.problem,
                'problem',
                problem,
              ),
            ),
          );
        },
      );
    },
  );

  test('non-object JSON is a protocol failure', () async {
    await _serve(
      (request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write('[]');
        await request.response.close();
      },
      (client) async {
        await expectLater(
          client.request('GET', '/v1/vms'),
          throwsA(isA<ApiProtocolException>()),
        );
      },
    );
  });

  test(
    'oversized JSON is rejected without retaining an unbounded response',
    () async {
      await _serve(
        (request) async {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'data': 'x' * (1024 * 1024)}));
          await request.response.close();
        },
        (client) async {
          await expectLater(
            client.request('GET', '/v1/vms'),
            throwsA(
              isA<ApiProtocolException>().having(
                (error) => error.message,
                'message',
                contains('1 MiB'),
              ),
            ),
          );
        },
      );
    },
  );

  test('the explicit deadline covers a server that never replies', () async {
    final release = Completer<void>();
    await _serve(
      (request) async {
        await release.future;
        await request.response.close();
      },
      (client) async {
        try {
          await expectLater(
            client.request(
              'GET',
              '/v1/vms',
              timeout: const Duration(milliseconds: 50),
            ),
            throwsA(isA<ApiTimeoutException>()),
          );
        } finally {
          release.complete();
        }
      },
    );
  });

  test('only public versioned requests are allowed', () async {
    await expectLater(
      GaoVmApiClient(
        socketPath: '/missing.sock',
      ).request('POST', '/driver.exec'),
      throwsArgumentError,
    );
  });
}

Future<void> _serve(
  Future<void> Function(HttpRequest) handler,
  Future<void> Function(GaoVmApiClient) check,
) async {
  final directory = await Directory.systemTemp.createTemp('api-client-');
  final socket = '${directory.path}/api.sock';
  final server = await HttpServer.bind(
    InternetAddress(socket, type: InternetAddressType.unix),
    0,
  );
  final subscription = server.listen((request) {
    unawaited(handler(request));
  });
  try {
    await check(GaoVmApiClient(socketPath: socket));
  } finally {
    await server.close(force: true);
    await subscription.cancel();
    await directory.delete(recursive: true);
  }
}
