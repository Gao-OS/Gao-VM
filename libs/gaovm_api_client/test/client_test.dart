import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

part 'artifact_cases.dart';

void main() {
  _artifactTests();
  test('VM PATCH preserves merge-patch media type, revision and key', () async {
    String? mediaType;
    String? revision;
    String? key;
    Object? body;
    await _serve(
      (request) async {
        mediaType = request.headers.contentType?.mimeType;
        revision = request.headers.value('If-Match');
        key = request.headers.value('Idempotency-Key');
        body = jsonDecode(await utf8.decoder.bind(request).join());
        request.response.headers.contentType = ContentType.json;
        request.response.write('{}');
        await request.response.close();
      },
      (client) async {
        final patch = {
          'spec': {'guest_profile': null, 'cpu': 8},
        };
        await client.request(
          'PATCH',
          '/v1/vms/vm_01J00000000000000000000000',
          body: JsonObjectValue.fromJson(patch),
          ifMatch: '"7"',
          idempotencyKey: 'edit-1',
        );
        expect(mediaType, 'application/merge-patch+json');
        expect(revision, '"7"');
        expect(key, 'edit-1');
        expect(body, patch);
      },
    );
  });

  test('an unavailable readiness snapshot remains a health response', () async {
    final requestId = RequestId.generate();
    await _serve(
      (request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/v1/system/ready');
        request.response.statusCode = HttpStatus.serviceUnavailable;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('X-Request-ID', requestId.value);
        request.response.write(
          jsonEncode({
            'ready': false,
            'checks': {'database': false, 'runtime': 'not ready'},
          }),
        );
        await request.response.close();
      },
      (client) async {
        final result = await client.request('GET', '/v1/system/ready');
        expect(result.status, HttpStatus.serviceUnavailable);
        expect(result.requestId, requestId.value);
        expect(result.body.toJson(), {
          'ready': false,
          'checks': {'database': false, 'runtime': 'not ready'},
        });
      },
    );
  });

  test('unavailable liveness permits omitted checks', () async {
    await _serve(
      (request) async {
        request.response.statusCode = 503;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"live":false}');
        await request.response.close();
      },
      (client) async {
        final result = await client.request('GET', '/v1/system/live');
        expect(result.status, 503);
        expect(result.body.toJson(), {'live': false});
      },
    );
  });

  for (final probe in ['live', 'ready']) {
    for (final invalid in ['true', 'missing', 'flag type', 'checks', 'extra']) {
      test('unavailable $probe rejects $invalid health data', () async {
        final body = <String, Object?>{probe: false, 'checks': {}};
        switch (invalid) {
          case 'true':
            body[probe] = true;
          case 'missing':
            body.remove(probe);
          case 'flag type':
            body[probe] = 'false';
          case 'checks':
            body['checks'] = [];
          case 'extra':
            body['state'] = 'running';
        }
        await _serve(
          (request) async {
            request.response.statusCode = 503;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode(body));
            await request.response.close();
          },
          (client) async {
            await expectLater(
              client.request('GET', '/v1/system/$probe'),
              throwsA(isA<ApiProtocolException>()),
            );
          },
        );
      });
    }
  }

  for (final request in [
    ('POST', '/v1/system/ready'),
    ('GET', '/v1/system/ready/'),
    ('GET', '/v1/vms'),
  ]) {
    test('health 503 handling is not applied to $request', () async {
      await _serve(
        (request) async {
          request.response.statusCode = 503;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"ready":false,"checks":{}}');
          await request.response.close();
        },
        (client) async {
          await expectLater(
            client.request(request.$1, request.$2),
            throwsA(isA<ApiProtocolException>()),
          );
        },
      );
    });
  }

  test('a health endpoint still preserves a structured 503 Problem', () async {
    final problem = Problem(
      type: Uri.parse('https://gaovm.dev/problems/internal-error'),
      title: 'Dependencies unavailable',
      status: 503,
      code: ErrorCode.internalError,
      detail: 'Cannot perform the health check.',
      requestId: RequestId.generate(),
      retryable: true,
      details: JsonObjectValue.empty,
    );
    await _serve(
      (request) async {
        request.response.statusCode = 503;
        request.response.headers.contentType = ContentType(
          'application',
          'problem+json',
        );
        request.response.write(jsonEncode(problem.toJson()));
        await request.response.close();
      },
      (client) async {
        await expectLater(
          client.request('GET', '/v1/system/ready'),
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
  });

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
