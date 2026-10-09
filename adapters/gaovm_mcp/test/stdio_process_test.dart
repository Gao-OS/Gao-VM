import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../daemon/gaovmd/test/helpers/owned_test_process.dart';

void main() {
  late Directory root;
  late File executable;
  final children = <OwnedTestProcess>[];

  Future<ProcessResult> run(List<String> arguments, {String? input}) async {
    if (children.any((child) => !child.exitConfirmed)) {
      throw StateError('retaining an earlier live MCP fixture');
    }
    final process = await Process.start(executable.path, arguments);
    final child = OwnedTestProcess(process);
    children.add(child);
    if (input != null) process.stdin.write(input);
    await process.stdin.close();
    return child.result();
  }

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('gvm-mcp-process-');
    executable = File('${root.path}/gaovm-mcp');
    final compiler = OwnedTestProcess(
      await Process.start(Platform.resolvedExecutable, [
        'compile',
        'exe',
        'bin/gaovm_mcp.dart',
        '-o',
        executable.path,
      ]),
    );
    children.add(compiler);
    final compiled = await compiler.result(timeout: const Duration(minutes: 2));
    expect(compiled.exitCode, 0, reason: compiled.stderr.toString());
    // No hardened signing or launchd registration: this is a stdio executable
    // fixture, not the blocked production packaging probe.
  });

  tearDownAll(() async {
    for (final child in children.where((child) => !child.exitConfirmed)) {
      await child.terminate();
    }
    if (children.any((child) => !child.exitConfirmed)) {
      throw StateError('retaining live MCP executable fixture: ${root.path}');
    }
    await root.delete(recursive: true);
  });

  test('help and invalid arguments never pollute protocol stdout', () async {
    final help = await run(['--help']);
    expect(help.exitCode, 0);
    expect(help.stdout, isEmpty);
    expect(help.stderr, contains('--socket-path'));
    final invalid = await run([]);
    expect(invalid.exitCode, 2);
    expect(invalid.stdout, isEmpty);
    expect(invalid.stderr, contains('--socket-path'));
  });

  test(
    'compiled discovery emits one JSON frame and naturally exits on EOF',
    () async {
      final result = await run(
        ['--socket-path', '${root.path}/unused.sock'],
        input:
            '${jsonEncode({
              'jsonrpc': '2.0',
              'id': 'discover-1',
              'method': 'server/discover',
              'params': {
                '_meta': {'io.modelcontextprotocol/protocolVersion': '2026-07-28', 'io.modelcontextprotocol/clientCapabilities': {}},
              },
            })}\n',
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stderr, isEmpty);
      final lines = const LineSplitter().convert(result.stdout as String);
      expect(lines, hasLength(1));
      final response = jsonDecode(lines.single) as Map;
      expect(response['jsonrpc'], '2.0');
      expect(response['id'], 'discover-1');
      expect(response['result']['resultType'], 'complete');
      expect(response['result']['capabilities'], {'tools': {}});
      expect(children.every((child) => child.exitConfirmed), isTrue);
    },
  );

  test(
    'compiled EOF closes a pending API connection and exits naturally',
    () async {
      if (children.any((child) => !child.exitConfirmed)) {
        throw StateError('retaining an earlier live MCP fixture');
      }
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
      final process = await Process.start(executable.path, [
        '--socket-path',
        socketPath,
      ]);
      final child = OwnedTestProcess(process);
      children.add(child);
      try {
        process.stdin.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'held-1',
            'method': 'tools/call',
            'params': {
              '_meta': {
                'io.modelcontextprotocol/protocolVersion': '2026-07-28',
                'io.modelcontextprotocol/clientCapabilities': {},
              },
              'name': 'vm_list',
              'arguments': {},
            },
          }),
        );
        await process.stdin.flush();
        await received.future.timeout(const Duration(seconds: 3));
        await process.stdin.close();
        await peerClosed.future.timeout(const Duration(seconds: 3));
        final result = await child.result(timeout: const Duration(seconds: 3));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, isEmpty);
        expect(result.stderr, isEmpty);
        expect(child.exitConfirmed, isTrue);
      } finally {
        if (!child.exitConfirmed) await child.terminate();
        for (final socket in sockets) {
          socket.destroy();
        }
        await listener.close();
        await subscription.cancel();
      }
    },
  );
}
