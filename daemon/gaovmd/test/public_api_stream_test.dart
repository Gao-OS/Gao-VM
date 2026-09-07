import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/public_api_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late String socketPath;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'gaovmd-public-api-stream-',
    );
    socketPath = '${temporaryDirectory.path}/api.sock';
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'streams response chunks beyond the ordinary request deadline',
    () async {
      final chunks = StreamController<List<int>>();
      final router = PublicApiRouter()
        ..add(
          'GET',
          '/v1/events',
          (_) async => PublicApiResponse.stream(
            body: chunks.stream,
            contentType: ContentType('text', 'event-stream', charset: 'utf-8'),
            headers: const {'Cache-Control': 'no-cache'},
          ),
        );
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: const _HealthService(),
        router: router,
        requestDeadline: const Duration(milliseconds: 20),
        newRequestId: () => _requestId,
      );
      addTearDown(server.close);
      addTearDown(chunks.close);
      await server.start();

      final response = _request(socketPath, 'GET', '/v1/events');
      chunks.add(utf8.encode('event: first\n\n'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      chunks.add(utf8.encode('event: second\n\n'));
      await chunks.close();

      final result = await response;
      expect(result.status, HttpStatus.ok);
      expect(
        result.headers['content-type'],
        'text/event-stream; charset=utf-8',
      );
      expect(result.headers['cache-control'], 'no-cache');
      expect(result.headers['x-request-id'], _requestId.value);
      expect(utf8.decode(result.body), 'event: first\n\nevent: second\n\n');
    },
  );

  test('client disconnect cancels a source awaiting its next chunk', () async {
    final listened = Completer<void>();
    final cancelled = Completer<void>();
    final chunks = StreamController<List<int>>(
      onListen: listened.complete,
      onCancel: cancelled.complete,
    );
    final router = PublicApiRouter()
      ..add(
        'GET',
        '/v1/events',
        (_) async => PublicApiResponse.stream(
          body: chunks.stream,
          contentType: ContentType('text', 'event-stream', charset: 'utf-8'),
        ),
      );
    final server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: const _HealthService(),
      router: router,
      newRequestId: () => _requestId,
    );
    addTearDown(server.close);
    addTearDown(chunks.close);
    await server.start();

    final client = await _connectRequest(
      socketPath,
      'GET',
      '/v1/events',
      closeConnection: false,
    );
    await listened.future;
    chunks.add(utf8.encode(': heartbeat\n\n'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    client.destroy();

    await cancelled.future.timeout(const Duration(milliseconds: 250));
  });

  test(
    'server close cancels an open stream without awaiting its source',
    () async {
      final listened = Completer<void>();
      final cancelStarted = Completer<void>();
      final cancelNeverFinishes = Completer<void>();
      final chunks = StreamController<List<int>>(
        onListen: listened.complete,
        onCancel: () {
          cancelStarted.complete();
          return cancelNeverFinishes.future;
        },
      );
      final router = PublicApiRouter()
        ..add(
          'GET',
          '/v1/events',
          (_) async => PublicApiResponse.stream(
            body: chunks.stream,
            contentType: ContentType('text', 'event-stream', charset: 'utf-8'),
          ),
        );
      final server = PublicApiServer(
        socketPath: socketPath,
        openApiDocument: const {'openapi': '3.1.0'},
        systemHealth: const _HealthService(),
        router: router,
        streamWriteDeadline: const Duration(milliseconds: 20),
        newRequestId: () => _requestId,
      );
      addTearDown(() {
        cancelNeverFinishes.complete();
        chunks.close();
        return server.close();
      });
      await server.start();

      final client = await _connectRequest(socketPath, 'GET', '/v1/events');
      addTearDown(client.destroy);
      await listened.future;

      await server.close().timeout(const Duration(milliseconds: 250));
      await cancelStarted.future;
      expect(server.isRunning, isFalse);
    },
  );

  test('slow client bounds each write and does not drain the source', () async {
    final cancelled = Completer<void>();
    var pulled = 0;
    Stream<List<int>> chunks() async* {
      try {
        while (true) {
          pulled++;
          yield Uint8List(4 * 1024 * 1024);
        }
      } finally {
        cancelled.complete();
      }
    }

    final router = PublicApiRouter()
      ..add(
        'GET',
        '/v1/events',
        (_) async => PublicApiResponse.stream(
          body: chunks(),
          contentType: ContentType('text', 'event-stream', charset: 'utf-8'),
        ),
      );
    final server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {'openapi': '3.1.0'},
      systemHealth: const _HealthService(),
      router: router,
      streamWriteDeadline: const Duration(milliseconds: 20),
      newRequestId: () => _requestId,
    );
    addTearDown(server.close);
    await server.start();

    final client = await _connectRequest(socketPath, 'GET', '/v1/events');
    addTearDown(client.destroy);

    await cancelled.future.timeout(const Duration(seconds: 1));
    expect(pulled, lessThanOrEqualTo(2));
  });
}

final _requestId = RequestId('req_01J00000000000000000000000');

final class _HealthService implements SystemHealthService {
  const _HealthService();

  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});

  @override
  Future<SystemHealthStatus> readiness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
}

final class _HttpResponse {
  const _HttpResponse(this.status, this.headers, this.body);

  final int status;
  final Map<String, String> headers;
  final List<int> body;
}

Future<_HttpResponse> _request(
  String socketPath,
  String method,
  String path,
) async {
  final socket = await _connectRequest(socketPath, method, path);
  final bytes = await socket.fold<List<int>>(<int>[], (out, chunk) {
    out.addAll(chunk);
    return out;
  });
  final split = _headerBoundary(bytes);
  final lines = ascii.decode(bytes.sublist(0, split)).split('\r\n');
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final separator = line.indexOf(':');
    if (separator < 0) continue;
    headers[line.substring(0, separator).toLowerCase()] = line
        .substring(separator + 1)
        .trim();
  }
  final rawBody = bytes.sublist(split + 4);
  return _HttpResponse(
    int.parse(lines.first.split(' ')[1]),
    headers,
    headers['transfer-encoding'] == 'chunked'
        ? _decodeChunked(rawBody)
        : rawBody,
  );
}

Future<Socket> _connectRequest(
  String socketPath,
  String method,
  String path, {
  bool closeConnection = true,
}) async {
  final socket = await Socket.connect(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  socket.write(
    '$method $path HTTP/1.1\r\n'
    'Host: localhost\r\n'
    '${closeConnection ? 'Connection: close\r\n' : ''}'
    '\r\n',
  );
  await socket.flush();
  return socket;
}

List<int> _decodeChunked(List<int> encoded) {
  final decoded = <int>[];
  var offset = 0;
  while (true) {
    final lineEnd = _indexOfCrlf(encoded, offset);
    final length = int.parse(
      ascii.decode(encoded.sublist(offset, lineEnd)),
      radix: 16,
    );
    offset = lineEnd + 2;
    if (length == 0) return decoded;
    decoded.addAll(encoded.sublist(offset, offset + length));
    offset += length + 2;
  }
}

int _indexOfCrlf(List<int> bytes, int start) {
  for (var index = start; index < bytes.length - 1; index++) {
    if (bytes[index] == 13 && bytes[index + 1] == 10) return index;
  }
  throw StateError('HTTP chunk had no line ending');
}

int _headerBoundary(List<int> bytes) {
  for (var index = 0; index <= bytes.length - 4; index++) {
    if (bytes[index] == 13 &&
        bytes[index + 1] == 10 &&
        bytes[index + 2] == 13 &&
        bytes[index + 3] == 10) {
      return index;
    }
  }
  throw StateError('HTTP response had no header boundary');
}
