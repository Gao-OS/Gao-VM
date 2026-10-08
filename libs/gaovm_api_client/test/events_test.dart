import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  test('invalid cursors and deadlines are rejected before connecting', () {
    final client = GaoVmApiClient(socketPath: '/unused/api.sock');
    expect(() => client.watchEvents(afterSequence: -1), throwsArgumentError);
    expect(
      () => client.watchEvents(timeout: Duration.zero),
      throwsArgumentError,
    );
    for (final cursor in ['', '-1', '+1', '1.0', 'invalid', '9' * 100]) {
      expect(
        () => client.watchEvents(lastEventId: cursor),
        throwsArgumentError,
      );
    }
  });

  test(
    'heartbeats cannot extend the total event subscription deadline',
    () async {
      final connected = Completer<void>();
      final release = Completer<void>();
      var heartbeats = 0;
      await _serve(
        (request) async {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.bufferOutput = false;
          connected.complete();
          final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
            heartbeats++;
            request.response.write(': heartbeat\n\n');
            unawaited(request.response.flush().catchError((Object _) {}));
          });
          try {
            await release.future;
          } finally {
            timer.cancel();
            try {
              await request.response.close();
            } catch (_) {}
          }
        },
        (client) async {
          try {
            await expectLater(
              client
                  .watchEvents(timeout: const Duration(seconds: 2))
                  .drain<void>(),
              throwsA(isA<ApiTimeoutException>()),
            ).timeout(const Duration(seconds: 4));
            expect(
              connected.isCompleted,
              isTrue,
              reason:
                  'the fixture must establish a stream before testing heartbeats',
            );
            expect(heartbeats, greaterThan(1));
          } finally {
            release.complete();
          }
        },
      );
    },
  );

  test(
    'cancelling an idle subscription closes it without waiting for its deadline',
    () async {
      final connected = Completer<void>(), release = Completer<void>();
      await _serve(
        (request) async {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(': connected\n\n');
          await request.response.flush();
          connected.complete();
          await release.future;
          try {
            await request.response.close();
          } catch (_) {}
        },
        (client) async {
          final subscription = client
              .watchEvents(timeout: const Duration(seconds: 30))
              .listen((_) {});
          try {
            await connected.future.timeout(const Duration(seconds: 2));
            await subscription.cancel().timeout(
              const Duration(milliseconds: 500),
            );
          } finally {
            release.complete();
            await subscription.cancel();
          }
        },
      );
    },
  );

  test(
    'malformed, stale and oversized event frames are protocol failures',
    () async {
      String json(int sequence) => jsonEncode(
        Event(
          sequence: sequence,
          eventId: EventId.generate(),
          type: 'system.changed',
          resourceType: ResourceType.system,
          payload: JsonObjectValue.empty,
          occurredAt: DateTime.now(),
        ).toJson(),
      );
      for (final bytes in [
        utf8.encode('data: ${json(11)}\n\n'),
        utf8.encode('id: -1\ndata: ${json(11)}\n\n'),
        utf8.encode('id: 11\ndata: ${json(12)}\n\n'),
        utf8.encode('id: 10\ndata: ${json(10)}\n\n'),
        utf8.encode(
          'id: 11\ndata: ${json(11)}\n\nid: 11\ndata: ${json(11)}\n\n',
        ),
        utf8.encode('id: 11\ndata: ${json(11)}\n'),
        [0xff, 10, 10],
        utf8.encode(':${'x' * (1024 * 1024)}'),
      ]) {
        await _serve(
          (request) async {
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.add(bytes);
            try {
              await request.response.close();
            } catch (_) {}
          },
          (client) async {
            await expectLater(
              client.watchEvents(afterSequence: 10).drain<void>(),
              throwsA(isA<ApiProtocolException>()),
            );
          },
        );
      }
    },
  );

  test(
    'clean stream EOF is a transport interruption, not successful completion',
    () async {
      await _serve(
        (request) async {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(': connected\n\n');
          await request.response.close();
        },
        (client) async {
          await expectLater(
            client.watchEvents().drain<void>(),
            throwsA(isA<ApiTransportException>()),
          );
        },
      );
    },
  );

  test(
    'event connection failures preserve the structured API Problem',
    () async {
      final problem = Problem(
        type: Uri.parse('https://gaovm.dev/problems/invalid-request'),
        title: 'Invalid request',
        status: 400,
        code: ErrorCode.invalidRequest,
        detail: 'Invalid cursor.',
        requestId: RequestId.generate(),
        retryable: false,
        details: JsonObjectValue.empty,
      );
      await _serve(
        (request) async {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType(
            'application',
            'problem+json',
          );
          request.response.write(jsonEncode(problem.toJson()));
          await request.response.close();
        },
        (client) async {
          await expectLater(
            client.watchEvents().drain<void>(),
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

  test(
    'event stream resumes with typed filters and parses split UTF-8 frames',
    () async {
      final vm = VmId.generate(),
          operation = OperationId.generate(),
          testRun = TestRunId.generate();
      final event = Event(
        sequence: 13,
        eventId: EventId.generate(),
        type: 'vm.running',
        resourceType: ResourceType.virtualMachine,
        resourceId: vm,
        vmId: vm,
        operationId: operation,
        testRunId: testRun,
        payload: JsonObjectValue.fromJson({'message': '日本語'}),
        occurredAt: DateTime.now(),
      );
      Uri? uri;
      String? accept, lastId;
      await _serve(
        (request) async {
          uri = request.uri;
          accept = request.headers.value(HttpHeaders.acceptHeader);
          lastId = request.headers.value('Last-Event-ID');
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.bufferOutput = false;
          final bytes = utf8.encode(
            ': connected\r\n\r\nid: 13\r\ndata: ${jsonEncode(event.toJson())}\r\n\r\n',
          );
          for (final byte in bytes) {
            request.response.add([byte]);
            await request.response.flush();
          }
          try {
            await request.response.close();
          } catch (_) {}
        },
        (client) async {
          final received = await client
              .watchEvents(
                afterSequence: 4,
                lastEventId: '12',
                vmId: vm,
                operationId: operation,
                testRunId: testRun,
              )
              .take(1)
              .toList();
          expect(received, [event]);
          expect(uri!.path, '/v1/events');
          expect(uri!.queryParameters, {
            'after_sequence': '4',
            'vm_id': vm.value,
            'operation_id': operation.value,
            'test_run_id': testRun.value,
          });
          expect(accept, 'text/event-stream');
          expect(lastId, '12');
        },
      );
    },
  );
}

Future<void> _serve(
  Future<void> Function(HttpRequest) handler,
  Future<void> Function(GaoVmApiClient) check,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'gaovm-events-client-',
  );
  final server = await HttpServer.bind(
    InternetAddress(
      '${directory.path}/api.sock',
      type: InternetAddressType.unix,
    ),
    0,
  );
  final subscription = server.listen((request) {
    unawaited(handler(request));
  });
  try {
    await check(GaoVmApiClient(socketPath: '${directory.path}/api.sock'));
  } finally {
    await server.close(force: true);
    await subscription.cancel();
    await directory.delete(recursive: true);
  }
}
