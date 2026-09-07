import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/durable_event_feed.dart';
import 'package:gaovmd/src/event_api_handlers.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:gaovmd/src/public_api_server.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/sqlite_durable_event_feed.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:test/test.dart';

void main() {
  test(
    'real UDS resumes SQLite events gaplessly with header precedence and filters',
    () async {
      final directory = await Directory.systemTemp.createTemp('event-api-');
      final database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      final socketPath = '${directory.path}/api.sock';
      final events = SqliteEventRepository(database);
      final vms = SqliteVmRepository(database);
      final vm = (await vms.create(name: 'a', spec: _spec)).metadata.id;
      final otherVm = (await vms.create(name: 'b', spec: _spec)).metadata.id;
      Future<Event> append(VmId target) => events.append(
        type: 'vm.changed',
        resourceType: ResourceType.virtualMachine,
        resourceId: target,
        vmId: target,
        payload: JsonObjectValue.empty,
      );
      final first = await append(vm);
      await append(otherVm);
      final second = await append(vm);
      final router = PublicApiRouter();
      EventApiHandlers(
        feed: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 5),
        ),
      ).register(router);
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {},
        systemHealth: _Health(),
        router: router,
      );
      final clients = <HttpClient>[];
      HttpClient client() {
        final result = HttpClient()
          ..connectionFactory = (uri, proxyHost, proxyPort) =>
              Socket.startConnect(
                InternetAddress(socketPath, type: InternetAddressType.unix),
                0,
              );
        clients.add(result);
        return result;
      }

      try {
        await server.start();
        final uri = Uri.parse('http://localhost/v1/events?vm_id=$vm');
        final firstClient = client();
        final response = await (await firstClient.getUrl(
          uri,
        )).close().timeout(const Duration(seconds: 2));
        expect(response.statusCode, 200);
        expect(response.headers.contentType!.mimeType, 'text/event-stream');
        expect(await _sequences(response, 2), [
          first.sequence,
          second.sequence,
        ]);
        firstClient.close(force: true);
        final third = await append(vm);
        final reconnectClient = client();
        final reconnect = await reconnectClient.getUrl(
          uri.replace(query: '${uri.query}&after_sequence=0'),
        );
        reconnect.headers.set('Last-Event-ID', second.sequence.toString());
        final resumed = await reconnect.close().timeout(
          const Duration(seconds: 2),
        );
        expect(await _sequences(resumed, 1), [third.sequence]);
        reconnectClient.close(force: true);

        final invalidClient = client();
        final invalid = await (await invalidClient.getUrl(
          Uri.parse('http://localhost/v1/events?after=-1'),
        )).close();
        expect(invalid.statusCode, 400);
        final problem =
            jsonDecode(await utf8.decoder.bind(invalid).join()) as Map;
        expect(problem['code'], 'INVALID_REQUEST');
      } finally {
        for (final current in clients) {
          current.close(force: true);
        }
        await server.close();
        database.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'rejects invalid cursors, aliases, repeated and unknown parameters before subscribing',
    () async {
      for (final suffix in [
        '?after=-1',
        '?after=+1',
        '?after=1.5',
        '?after=',
        '?after=abc',
        '?after=9223372036854775808',
        '?after=1&after=1',
        '?after_sequence=1&after=2',
        '?unknown=1',
        '?vm_id=bad',
        '?operation_id=bad',
        '?test_run_id=bad',
        '?vm_id=x&vm_id=y',
      ]) {
        final feed = _Feed(const Stream.empty());
        final response = await _request(feed, '/v1/events$suffix');
        expect(response.status, 400, reason: suffix);
        expect(response.problem!.code, ErrorCode.invalidRequest);
        expect(response.streamBody, isNull);
        expect(feed.after, isNull);
      }
      for (final header in [
        <String>[],
        ['1', '2'],
        [''],
        ['-1'],
        ['1.1'],
        ['1\n2'],
      ]) {
        final feed = _Feed(const Stream.empty());
        final response = await _request(
          feed,
          '/v1/events',
          headers: {'last-event-id': header},
        );
        expect(response.status, 400);
        expect(feed.after, isNull);
      }
    },
  );

  test(
    'passes all typed filters to the feed and accepts the documented alias',
    () async {
      final vm = VmId.generate();
      final operation = OperationId.generate();
      final run = TestRunId.generate();
      final feed = _Feed(const Stream.empty());
      final response = await _request(
        feed,
        '/v1/events?after=3&vm_id=$vm&operation_id=$operation&test_run_id=$run',
      );
      expect(feed.after, 3);
      expect(feed.vmId, vm);
      expect(feed.operationId, operation);
      expect(feed.testRunId, run);
      await response.streamBody!.drain<void>();
    },
  );

  test(
    'pause reaches the feed and suspends heartbeat; cancellation releases it',
    () async {
      var sourcePaused = false;
      var sourceCancelled = false;
      final source = StreamController<Event>(
        sync: true,
        onPause: () => sourcePaused = true,
        onResume: () => sourcePaused = false,
        onCancel: () => sourceCancelled = true,
      );
      final response = await _request(
        _Feed(source.stream),
        '/v1/events',
        heartbeat: const Duration(milliseconds: 15),
      );
      final connected = Completer<void>();
      final heartbeat = Completer<void>();
      final chunks = <String>[];
      final subscription = response.streamBody!.listen((bytes) {
        final text = utf8.decode(bytes);
        chunks.add(text);
        if (text.startsWith(': connected')) connected.complete();
        if (text.startsWith(': heartbeat') && !heartbeat.isCompleted)
          heartbeat.complete();
      });
      await connected.future;
      subscription.pause();
      expect(sourcePaused, isTrue);
      final count = chunks.length;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chunks, hasLength(count));
      subscription.resume();
      expect(sourcePaused, isFalse);
      await heartbeat.future.timeout(const Duration(seconds: 1));
      await subscription.cancel();
      expect(sourceCancelled, isTrue);
      await source.close();
    },
  );

  test(
    'feed errors close the stream and preserve the original error',
    () async {
      var cancelled = false;
      final source = StreamController<Event>(onCancel: () => cancelled = true);
      final response = await _request(_Feed(source.stream), '/v1/events');
      final error = StateError('feed failed');
      final done = Completer<void>();
      final errors = <Object>[];
      response.streamBody!.listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );
      source.addError(error);
      await done.future.timeout(const Duration(seconds: 1));
      expect(errors, [same(error)]);
      expect(cancelled, isTrue);
      await source.close();
    },
  );

  test('heartbeat configuration must be positive', () {
    expect(
      () => EventApiHandlers(
        feed: _Feed(const Stream.empty()),
        heartbeatInterval: Duration.zero,
      ),
      throwsArgumentError,
    );
  });

  test('validates and frames replay using Last-Event-ID precedence', () async {
    final event = _event(5);
    final feed = _Feed(Stream.value(event));
    final response = await _request(
      feed,
      '/v1/events?after_sequence=2&after=2',
      headers: {
        'last-event-id': ['4'],
      },
    );
    expect(response.status, HttpStatus.ok);
    expect(feed.after, 4);
    expect(response.contentType.mimeType, 'text/event-stream');
    final text = await utf8.decoder.bind(response.streamBody!).join();
    expect(
      text,
      ': connected\n\nid: 5\ndata: ${jsonEncode(event.toJson())}\n\n',
    );
    expect(text, isNot(contains('\nevent: injected')));
  });
}

Future<PublicApiResponse> _request(
  DurableEventFeed feed,
  String uri, {
  Map<String, List<String>> headers = const {},
  Duration heartbeat = const Duration(seconds: 15),
}) {
  final router = PublicApiRouter();
  EventApiHandlers(feed: feed, heartbeatInterval: heartbeat).register(router);
  return router.handler('GET', '/v1/events')!(
    PublicApiRequest(
      requestId: RequestId.generate(),
      method: 'GET',
      uri: Uri.parse(uri),
      headers: headers,
      jsonBody: null,
    ),
  );
}

final class _Feed implements DurableEventFeed {
  _Feed(this.events);
  final Stream<Event> events;
  int? after;
  VmId? vmId;
  OperationId? operationId;
  TestRunId? testRunId;
  @override
  Future<int> latestSequence() async => 0;
  @override
  Stream<Event> watch({
    int after = 0,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
  }) {
    this.after = after;
    this.vmId = vmId;
    this.operationId = operationId;
    this.testRunId = testRunId;
    return events;
  }
}

Event _event(int sequence, {String type = 'vm.changed'}) => Event.fromJson({
  'sequence': sequence,
  'event_id': EventId.generate().value,
  'type': type,
  'resource_type': 'system',
  'resource_id': null,
  'vm_id': null,
  'operation_id': null,
  'test_run_id': null,
  'payload': {'message': 'unsafe\nevent: injected'},
  'occurred_at': '2026-09-07T00:00:00Z',
});

Future<List<int>> _sequences(HttpClientResponse response, int count) => utf8
    .decoder
    .bind(response)
    .transform(const LineSplitter())
    .where((line) => line.startsWith('data: '))
    .map((line) => (jsonDecode(line.substring(6)) as Map)['sequence'] as int)
    .take(count)
    .toList()
    .timeout(const Duration(seconds: 2));

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
