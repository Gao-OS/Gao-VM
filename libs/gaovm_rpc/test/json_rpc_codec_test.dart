import 'dart:async';
import 'dart:typed_data';

import 'package:gaovm_rpc/gaovm_rpc.dart';
import 'package:test/test.dart';

void main() {
  const codec = LengthPrefixedJsonRpcCodec();

  group('LengthPrefixedJsonRpcCodec', () {
    test('encodes 4-byte big-endian length prefix', () {
      final frame = codec.encodeObject({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'ping',
      });

      expect(frame.length, greaterThan(4));
      final header = ByteData.sublistView(frame, 0, 4);
      final payloadLength = header.getUint32(0, Endian.big);
      expect(payloadLength, frame.length - 4);
    });

    test('round-trips fragmented and concatenated frames', () async {
      final first = JsonRpcProtocol.request(id: 1, method: 'ping');
      final second = JsonRpcProtocol.result(id: 1, result: {'ok': true});

      final firstFrame = codec.encodeObject(first);
      final secondFrame = codec.encodeObject(second);

      final controller = StreamController<List<int>>();
      final decodedFuture = codec.decodeObjectStream(controller.stream).toList();

      controller.add(firstFrame.sublist(0, 2));
      controller.add(firstFrame.sublist(2, 7));
      controller.add(Uint8List.fromList([
        ...firstFrame.sublist(7),
        ...secondFrame,
      ]));
      await controller.close();

      final decoded = await decodedFuture;
      expect(decoded, hasLength(2));
      expect(decoded[0], first);
      expect(decoded[1], second);
    });

    test('rejects JSON-RPC batch payloads', () async {
      final payload = '[{"jsonrpc":"2.0","id":1,"method":"ping"}]'.codeUnits;
      final header = Uint8List(4);
      ByteData.sublistView(header).setUint32(0, payload.length, Endian.big);
      final frame = Uint8List.fromList([...header, ...payload]);

      final stream = Stream<List<int>>.value(frame);
      expect(
        codec.decodeObjectStream(stream).drain<void>(),
        throwsA(isA<JsonRpcFrameException>()),
      );
    });
  });
}
