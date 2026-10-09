import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_mcp/gaovm_mcp.dart';
import 'package:test/test.dart';

void main() {
  test('protocol output never overlaps a stalled earlier write', () async {
    final input = StreamController<List<int>>();
    final first = Completer<void>();
    final second = Completer<void>();
    final release = Completer<void>();
    var active = 0;
    var maximum = 0;
    final serving =
        GaoVmMcpServer(
          api: GaoVmApiClient(socketPath: '/unused-mcp-output.sock'),
        ).serve(input.stream, (message) async {
          active++;
          if (active > maximum) maximum = active;
          final id = (jsonDecode(message) as Map)['id'];
          if (id == 'first') {
            first.complete();
            await release.future;
          } else {
            second.complete();
          }
          active--;
        });
    try {
      input.add(_request('first', 'server/discover'));
      await first.future.timeout(const Duration(seconds: 2));
      input.add(_request('second', 'server/discover'));
      await expectLater(
        second.future.timeout(const Duration(milliseconds: 30)),
        throwsA(isA<TimeoutException>()),
      );
      release.complete();
      await second.future.timeout(const Duration(seconds: 2));
      expect(maximum, 1);
    } finally {
      if (!release.isCompleted) release.complete();
      await input.close();
      await serving;
    }
  });

  test(
    'cancellation suppresses a response queued behind a stalled write',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-queued-cancel-');
      final path = '${root.path}/api.sock';
      final http = await HttpServer.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      final before = Completer<void>();
      final after = Completer<void>();
      var calls = 0;
      final subscription = http.listen((request) {
        (++calls == 1 ? before : after).complete();
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"items":[],"next_cursor":null}');
        request.response.close();
      });
      final input = StreamController<List<int>>();
      final first = Completer<void>();
      final release = Completer<void>();
      final beforeWritten = Completer<void>();
      final afterWritten = Completer<void>();
      final ids = <String>[];
      final serving = GaoVmMcpServer(api: GaoVmApiClient(socketPath: path))
          .serve(input.stream, (message) async {
            final id = (jsonDecode(message) as Map)['id'] as String;
            if (id == 'first') {
              first.complete();
              await release.future;
            }
            ids.add(id);
            if (id == 'before') beforeWritten.complete();
            if (id == 'after') afterWritten.complete();
          });
      try {
        input.add(_request('first', 'server/discover'));
        await first.future.timeout(const Duration(seconds: 2));
        input.add(_request('cancel-me', 'server/discover'));
        input.add(_request('before', 'tools/call', {'name': 'vm_list'}));
        await before.future.timeout(const Duration(seconds: 2));
        input.add(
          utf8.encode(
            '${jsonEncode({
              'jsonrpc': '2.0',
              'method': 'notifications/cancelled',
              'params': {'requestId': 'cancel-me'},
            })}\n',
          ),
        );
        input.add(_request('after', 'tools/call', {'name': 'vm_list'}));
        await after.future.timeout(const Duration(seconds: 2));
        release.complete();
        await Future.wait([
          beforeWritten.future,
          afterWritten.future,
        ]).timeout(const Duration(seconds: 2));
        await input.close();
        await serving;
        expect(ids, unorderedEquals(['first', 'before', 'after']));
      } finally {
        if (!release.isCompleted) release.complete();
        await input.close();
        await serving;
        await http.close(force: true);
        await subscription.cancel();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'EOF drains already completed responses queued behind an active write',
    () async {
      final input = StreamController<List<int>>();
      final first = Completer<void>();
      final release = Completer<void>();
      final ids = <String>[];
      final serving =
          GaoVmMcpServer(
            api: GaoVmApiClient(socketPath: '/unused-mcp-output.sock'),
          ).serve(input.stream, (message) async {
            final id = (jsonDecode(message) as Map)['id'] as String;
            if (id == 'first') {
              first.complete();
              await release.future;
            }
            ids.add(id);
          });
      try {
        input.add(_request('first', 'server/discover'));
        await first.future.timeout(const Duration(seconds: 2));
        input.add(_request('second', 'server/discover'));
        await input.close();
        release.complete();
        await serving.timeout(const Duration(seconds: 2));
        expect(ids, ['first', 'second']);
      } finally {
        if (!release.isCompleted) release.complete();
        await input.close();
        await serving;
      }
    },
  );

  test(
    'stalled output backpressures input after 128 pending requests',
    () async {
      final input = StreamController<List<int>>();
      final full = Completer<void>();
      final excess = Completer<void>();
      final started = Completer<void>();
      final release = Completer<void>();
      var consumed = 0;
      final serving =
          GaoVmMcpServer(
            api: GaoVmApiClient(socketPath: '/unused-mcp-output.sock'),
          ).serve(
            input.stream.map((chunk) {
              consumed++;
              if (consumed == 128) full.complete();
              if (consumed == 129) excess.complete();
              return chunk;
            }),
            (_) async {
              if (!started.isCompleted) {
                started.complete();
                await release.future;
              }
            },
          );
      try {
        input.add(_request('0', 'server/discover'));
        await started.future.timeout(const Duration(seconds: 2));
        for (var i = 1; i < 160; i++) {
          input.add(_request('$i', 'server/discover'));
        }
        await full.future.timeout(const Duration(seconds: 2));
        await expectLater(
          excess.future.timeout(const Duration(milliseconds: 30)),
          throwsA(isA<TimeoutException>()),
        );
        expect(consumed, 128);
      } finally {
        if (!release.isCompleted) release.complete();
        await input.close();
        await serving;
      }
    },
  );

  test(
    'a stalled output fails once instead of timing out every queued reply',
    () async {
      final input = StreamController<List<int>>();
      final release = Completer<void>();
      var writes = 0;
      final serving =
          GaoVmMcpServer(
            api: GaoVmApiClient(socketPath: '/unused-mcp-output.sock'),
          ).serve(input.stream, (_) {
            writes++;
            return release.future;
          });
      final failed = expectLater(
        serving.timeout(const Duration(seconds: 7)),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            contains('Protocol output did not drain'),
          ),
        ),
      );
      try {
        input.add(_request('first', 'server/discover'));
        input.add(_request('second', 'server/discover'));
        await failed;
        expect(writes, 1);
      } finally {
        release.complete();
        await input.close();
        await serving.catchError((Object _) {});
      }
    },
  );

  test(
    'output timeout closes an outstanding API connection without process exit',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mcp-output-deadline-',
      );
      final path = '${root.path}/api.sock';
      final listener = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      final sockets = <Socket>[];
      final received = Completer<void>();
      final closed = Completer<void>();
      final subscription = listener.listen((socket) {
        sockets.add(socket);
        var headers = '';
        socket.listen(
          (bytes) {
            headers += utf8.decode(bytes);
            if (headers.contains('\r\n\r\n') && !received.isCompleted)
              received.complete();
          },
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
        );
      });
      final input = StreamController<List<int>>();
      final release = Completer<void>();
      final serving = GaoVmMcpServer(
        api: GaoVmApiClient(socketPath: path),
      ).serve(input.stream, (_) => release.future);
      final failed = expectLater(
        serving.timeout(const Duration(seconds: 7)),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            contains('Protocol output did not drain'),
          ),
        ),
      );
      try {
        input.add(_request('held', 'tools/call', {'name': 'vm_list'}));
        await received.future.timeout(const Duration(seconds: 2));
        input.add(_request('blocked-output', 'server/discover'));
        await failed;
        await closed.future.timeout(const Duration(seconds: 2));
        expect(sockets, hasLength(1));
      } finally {
        release.complete();
        await input.close();
        await serving.catchError((Object _) {});
        for (final socket in sockets) {
          socket.destroy();
        }
        await listener.close();
        await subscription.cancel();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'EOF has one drain deadline even when earlier output makes progress',
    () async {
      final input = StreamController<List<int>>();
      final started = Completer<void>();
      final first = Completer<void>();
      final second = Completer<void>();
      Timer? progress;
      final serving =
          GaoVmMcpServer(
            api: GaoVmApiClient(socketPath: '/unused-mcp-output.sock'),
          ).serve(input.stream, (message) {
            if ((jsonDecode(message) as Map)['id'] == 'first') {
              started.complete();
              return first.future;
            }
            return second.future;
          });
      final failed = expectLater(
        serving.timeout(const Duration(seconds: 7)),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            contains('shutdown deadline'),
          ),
        ),
      );
      try {
        input.add(_request('first', 'server/discover'));
        await started.future.timeout(const Duration(seconds: 2));
        input.add(_request('second', 'server/discover'));
        await input.close();
        // Simulate a cooperative first write: progress must not restart EOF's
        // overall drain budget for every remaining queued response.
        progress = Timer(const Duration(seconds: 3), () => first.complete());
        await failed;
      } finally {
        progress?.cancel();
        if (!first.isCompleted) first.complete();
        if (!second.isCompleted) second.complete();
        await input.close();
        await serving.catchError((Object _) {});
      }
    },
  );
}

List<int> _request(
  String id,
  String method, [
  Map<String, Object?> params = const {},
]) => utf8.encode(
  '${jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': {
      '_meta': {'io.modelcontextprotocol/protocolVersion': '2026-07-28', 'io.modelcontextprotocol/clientCapabilities': {}},
      ...params,
    },
  })}\n',
);
