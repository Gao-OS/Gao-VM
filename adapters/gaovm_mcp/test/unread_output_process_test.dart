import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../daemon/gaovmd/test/helpers/owned_test_process.dart';

void main() {
  test(
    'unread stdout releases pending HTTP and exits with a transport failure',
    () async {
      final root = await Directory.systemTemp.createTemp('mcp-unread-output-');
      final executable = '${root.path}/gaovm-mcp';
      final socketPath = '${root.path}/held.sock';
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
            if (headers.contains('\r\n\r\n') && !received.isCompleted)
              received.complete();
          },
          onDone: () {
            if (!peerClosed.isCompleted) peerClosed.complete();
          },
        );
      });
      OwnedTestProcess? compiler;
      Process? child;
      Future<int>? childExit;
      var exitConfirmed = false;
      try {
        compiler = OwnedTestProcess(
          await Process.start(Platform.resolvedExecutable, [
            'compile',
            'exe',
            'bin/gaovm_mcp.dart',
            '-o',
            executable,
          ]),
        );
        final compiled = await compiler.result(
          timeout: const Duration(minutes: 2),
        );
        expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
        expect(compiler.exitConfirmed, isTrue);
        child = await Process.start(executable, ['--socket-path', socketPath]);
        childExit = child.exitCode.then((code) {
          exitConfirmed = true;
          return code;
        });
        final diagnostics = child.stderr.transform(utf8.decoder).join();
        // Intentionally leave stdout unread until exit. OwnedTestProcess would
        // consume it, hiding the actual pipe backpressure this test must exercise.
        child.stdin.writeln(
          _request('held', 'tools/call', {'name': 'vm_list'}),
        );
        await child.stdin.flush().timeout(const Duration(seconds: 2));
        await received.future.timeout(const Duration(seconds: 3));
        for (var i = 0; i < 4; i++) {
          child.stdin.writeln(_request('catalog-$i', 'tools/list'));
        }
        await child.stdin.flush().timeout(const Duration(seconds: 2));
        final code = await childExit.timeout(const Duration(seconds: 8));
        expect(code, 1);
        await peerClosed.future.timeout(const Duration(seconds: 2));
        expect(
          await diagnostics.timeout(const Duration(seconds: 2)),
          contains('Protocol output did not drain'),
        );
        expect(exitConfirmed, isTrue);
      } finally {
        if (child != null && !exitConfirmed) {
          for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigkill]) {
            child.kill(signal);
            try {
              await childExit!.timeout(const Duration(seconds: 2));
              break;
            } on TimeoutException {
              // Sending a signal is not an exit acknowledgement.
            }
          }
        }
        for (final socket in sockets) {
          socket.destroy();
        }
        await listener.close();
        await subscription.cancel();
        if (compiler != null && !compiler.exitConfirmed)
          await compiler.terminate();
        if (child != null && !exitConfirmed ||
            compiler != null && !compiler.exitConfirmed) {
          throw StateError(
            'retaining live unread-output fixture: ${root.path}',
          );
        }
        if (child != null) {
          await child.stdin.close().timeout(const Duration(seconds: 2));
          await child.stdout.drain<void>().timeout(const Duration(seconds: 2));
        }
        await root.delete(recursive: true);
      }
    },
  );
}

String _request(
  String id,
  String method, [
  Map<String, Object?> params = const {},
]) => jsonEncode({
  'jsonrpc': '2.0',
  'id': id,
  'method': method,
  'params': {
    '_meta': {
      'io.modelcontextprotocol/protocolVersion': '2026-07-28',
      'io.modelcontextprotocol/clientCapabilities': {},
    },
    ...params,
  },
});
