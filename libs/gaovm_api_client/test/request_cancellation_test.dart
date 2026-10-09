import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:test/test.dart';

void main() {
  test(
    'an already cancelled request never attempts the public connection',
    () async {
      final cancellation = ApiRequestCancellation()
        ..cancel()
        ..cancel();
      await expectLater(
        GaoVmApiClient(
          socketPath: '/missing-api-cancel.sock',
        ).request('GET', '/v1/vms', cancellation: cancellation),
        throwsA(isA<ApiRequestCancelledException>()),
      );
      expect(cancellation.isCancelled, isTrue);
    },
  );

  test(
    'request cancellation releases an outstanding HTTP connection',
    () async {
      final root = await Directory.systemTemp.createTemp('api-cancel-');
      final socketPath = '${root.path}/api.sock';
      final listener = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      final sockets = <Socket>[];
      final received = Completer<void>();
      final peerClosed = Completer<void>();
      final subscription = listener.listen((socket) {
        sockets.add(socket);
        var headers = '';
        socket.listen(
          (bytes) {
            headers += utf8.decode(bytes);
            if (headers.contains('\r\n\r\n') && !received.isCompleted) {
              received.complete();
            }
          },
          onDone: () {
            if (!peerClosed.isCompleted) peerClosed.complete();
          },
        );
      });
      final cancellation = ApiRequestCancellation();
      try {
        final request = GaoVmApiClient(
          socketPath: socketPath,
        ).request('GET', '/v1/vms', cancellation: cancellation);
        final cancelled = expectLater(
          request,
          throwsA(isA<ApiRequestCancelledException>()),
        );
        await received.future.timeout(const Duration(seconds: 2));
        cancellation.cancel();
        await cancelled.timeout(const Duration(seconds: 2));
        await peerClosed.future.timeout(const Duration(seconds: 2));
        expect(cancellation.isCancelled, isTrue);
      } finally {
        cancellation.cancel();
        for (final socket in sockets) {
          socket.destroy();
        }
        await listener.close();
        await subscription.cancel();
        await root.delete(recursive: true);
      }
    },
  );
}
