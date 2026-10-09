part of '../gaovm_mcp.dart';

final class _McpFrame {
  const _McpFrame.line(this.line) : code = null, detail = null;
  const _McpFrame.error(this.code, this.detail) : line = null;

  final String? line;
  final int? code;
  final String? detail;
}

/// Buffer bytes, not decoded characters: UTF-8 can straddle input chunks.
Stream<_McpFrame> _mcpFrames(Stream<List<int>> input) {
  const maximum = 1024 * 1024;
  final buffer = BytesBuilder(copy: false);
  var discarding = false;
  return input.transform(
    StreamTransformer<List<int>, _McpFrame>.fromHandlers(
      handleData: (chunk, sink) {
        var offset = 0;
        for (var end = 0; end <= chunk.length; end++) {
          if (end < chunk.length && chunk[end] != 10) continue;
          if (!discarding) {
            if (buffer.length + end - offset > maximum) {
              buffer.clear();
              discarding = true;
              sink.add(
                const _McpFrame.error(-32600, 'Stdio frame exceeds 1 MiB'),
              );
            } else if (end > offset) {
              buffer.add(chunk.sublist(offset, end));
            }
          }
          if (end < chunk.length) {
            if (!discarding) {
              try {
                sink.add(_McpFrame.line(utf8.decode(buffer.takeBytes())));
              } on FormatException {
                sink.add(const _McpFrame.error(-32700, 'Invalid UTF-8 frame'));
              }
            }
            discarding = false;
          }
          offset = end + 1;
        }
      },
      handleDone: (sink) {
        if (buffer.length != 0) {
          sink.add(
            const _McpFrame.error(-32700, 'Incomplete stdio frame at EOF'),
          );
        }
        sink.close();
      },
    ),
  );
}
