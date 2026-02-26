import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class JsonRpcFrameException implements Exception {
  JsonRpcFrameException(this.message);

  final String message;

  @override
  String toString() => 'JsonRpcFrameException: $message';
}

class LengthPrefixedJsonRpcCodec {
  const LengthPrefixedJsonRpcCodec();

  Uint8List encodeObject(Map<String, Object?> object) {
    final payload = utf8.encode(jsonEncode(object));
    final out = Uint8List(4 + payload.length);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, payload.length, Endian.big);
    out.setRange(4, out.length, payload);
    return out;
  }

  Stream<Map<String, Object?>> decodeObjectStream(Stream<List<int>> byteStream) async* {
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in byteStream) {
      if (chunk.isEmpty) {
        continue;
      }
      buffer.add(chunk);
      while (true) {
        final bytes = buffer.toBytes();
        if (bytes.length < 4) {
          break;
        }
        final header = ByteData.sublistView(bytes, 0, 4);
        final length = header.getUint32(0, Endian.big);
        if (length == 0) {
          throw JsonRpcFrameException('Zero-length frame is not allowed.');
        }
        if (bytes.length < 4 + length) {
          break;
        }
        final payload = bytes.sublist(4, 4 + length);
        final remaining = bytes.sublist(4 + length);
        buffer.clear();
        if (remaining.isNotEmpty) {
          buffer.add(remaining);
        }
        final decoded = jsonDecode(utf8.decode(payload));
        if (decoded is List) {
          throw JsonRpcFrameException('JSON-RPC batch requests are not supported.');
        }
        if (decoded is! Map) {
          throw JsonRpcFrameException('Top-level JSON value must be an object.');
        }
        yield Map<String, Object?>.from(decoded);
      }
    }
  }
}
