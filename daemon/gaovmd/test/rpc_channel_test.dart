import 'dart:async';
import 'dart:io';

import 'package:gaovm_rpc/gaovm_rpc.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

/// Creates a pair of connected RpcChannels over a local TCP socket.
Future<(RpcChannel, RpcChannel)> _createChannelPair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final clientSocket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
  );
  final serverSocket = await server.first;
  await server.close();
  return (RpcChannel(clientSocket), RpcChannel(serverSocket));
}

void main() {
  group('RpcChannel', () {
    test('sends request and receives response', () async {
      final (client, server) = await _createChannelPair();
      addTearDown(client.close);
      addTearDown(server.close);

      server.onRequest = (request) async {
        if (request['method'] == 'test') {
          return JsonRpcProtocol.result(
            id: request['id'],
            result: {'echo': 'ok'},
          );
        }
        return null;
      };

      final response = await client.sendRequest('test');
      expect(response['error'], isNull);
      final result = Map<String, Object?>.from(response['result']! as Map);
      expect(result['echo'], 'ok');
    });

    test('sends notification (no response expected)', () async {
      final (client, server) = await _createChannelPair();
      addTearDown(client.close);
      addTearDown(server.close);

      final received = Completer<String>();
      server.onRequest = (request) async {
        if (request['method'] == 'notify') {
          received.complete('got it');
        }
        return null;
      };

      await client.sendNotification('notify', params: {'data': 1});
      final result =
          await received.future.timeout(const Duration(seconds: 2));
      expect(result, 'got it');
    });

    test('waitForRequest resolves when matching request arrives', () async {
      final (client, server) = await _createChannelPair();
      addTearDown(client.close);
      addTearDown(server.close);

      // Server waits for a specific method.
      final waiting = server.waitForRequest('special');

      // Client sends the request. Don't await — it would block waiting for response.
      final clientFuture = client.sendRequest('special', params: {'key': 'value'});

      final request = await waiting.timeout(const Duration(seconds: 2));
      expect(request['method'], 'special');
      final params = Map<String, Object?>.from(request['params'] as Map);
      expect(params['key'], 'value');

      // Send response back to unblock the client's sendRequest future.
      await server.sendResult(id: request['id'], result: {'ok': true});
      await clientFuture;
    });

    test('waitForRequest times out when no matching request', () async {
      final (client, server) = await _createChannelPair();
      addTearDown(client.close);
      addTearDown(server.close);

      expect(
        server.waitForRequest('never',
            timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('done completes when channel closes', () async {
      final (client, server) = await _createChannelPair();
      addTearDown(server.close);

      final doneFuture = client.done;
      await client.close();
      await doneFuture.timeout(const Duration(seconds: 2));
    });

    test('handler error returns internalError to caller', () async {
      final (client, server) = await _createChannelPair();
      addTearDown(client.close);
      addTearDown(server.close);

      server.onRequest = (request) async {
        throw StateError('handler crashed');
      };

      final response = await client.sendRequest('crash');
      expect(response['error'], isNotNull);
      final error = Map<String, Object?>.from(response['error']! as Map);
      expect(error['code'], JsonRpcErrorCode.internalError);
    });

    test('multiple concurrent requests resolve correctly', () async {
      final (client, server) = await _createChannelPair();
      addTearDown(client.close);
      addTearDown(server.close);

      server.onRequest = (request) async {
        final method = request['method'] as String;
        return JsonRpcProtocol.result(
          id: request['id'],
          result: {'method': method},
        );
      };

      final results = await Future.wait([
        client.sendRequest('alpha'),
        client.sendRequest('beta'),
        client.sendRequest('gamma'),
      ]);

      final methods = results.map((r) {
        final result = Map<String, Object?>.from(r['result']! as Map);
        return result['method'];
      }).toList();
      expect(methods, containsAll(['alpha', 'beta', 'gamma']));
    });

    test('no handler returns methodNotFound for requests with id', () async {
      final (client, server) = await _createChannelPair();
      addTearDown(client.close);
      addTearDown(server.close);

      // Don't set onRequest handler.
      final response = await client.sendRequest('unhandled');
      expect(response['error'], isNotNull);
      final error = Map<String, Object?>.from(response['error']! as Map);
      expect(error['code'], JsonRpcErrorCode.methodNotFound);
    });

    test('bidirectional requests work', () async {
      final (client, server) = await _createChannelPair();
      addTearDown(client.close);
      addTearDown(server.close);

      // Both sides can handle requests.
      client.onRequest = (request) async {
        return JsonRpcProtocol.result(
          id: request['id'],
          result: {'from': 'client'},
        );
      };
      server.onRequest = (request) async {
        return JsonRpcProtocol.result(
          id: request['id'],
          result: {'from': 'server'},
        );
      };

      // Client sends to server.
      final r1 = await client.sendRequest('ping');
      expect(
          (Map<String, Object?>.from(r1['result']! as Map))['from'], 'server');

      // Server sends to client.
      final r2 = await server.sendRequest('ping');
      expect(
          (Map<String, Object?>.from(r2['result']! as Map))['from'], 'client');
    });
  });
}
