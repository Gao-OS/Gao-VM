import 'dart:io';

import 'package:gaovmd/src/driver_rpc_channel.dart';
import 'package:test/test.dart';

void main() {
  test('fallible request builders never install pending correlation', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = listener.first;
    final client = await Socket.connect(listener.address, listener.port);
    final peer = await accepted;
    final channel = DriverRpcChannel(
      client,
      onRequest: (_) async => null,
      onNotification: (_) {},
    );

    expect(
      () => channel.sendRequest((_) => throw StateError('builder failed')),
      throwsStateError,
    );
    expect(channel.pendingRequestCount, 0);

    await channel.close();
    await peer.close();
    await listener.close();
  });
}
