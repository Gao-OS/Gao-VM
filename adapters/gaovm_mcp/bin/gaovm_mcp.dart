import 'dart:async';
import 'dart:io';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_mcp/gaovm_mcp.dart';

const _usage =
    'Usage: gaovm-mcp --socket-path /absolute/path/to/public-api.sock';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 &&
      const ['--help', '-h'].contains(arguments.single)) {
    stderr.writeln(_usage);
    return;
  }
  if (arguments.length != 2 ||
      arguments.first != '--socket-path' ||
      !arguments[1].startsWith('/') ||
      arguments[1].contains('\u0000')) {
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }
  final protocolOutput = stdout.nonBlocking;
  Object? outputError;
  unawaited(
    protocolOutput.done.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        outputError = error;
      },
    ),
  );
  try {
    final server = GaoVmMcpServer(
      api: GaoVmApiClient(socketPath: arguments[1]),
    );
    await server.serve(stdin, (message) async {
      if (outputError != null) throw outputError!;
      protocolOutput.writeln(message);
      await protocolOutput.flush();
      if (outputError != null) throw outputError!;
    });
    await protocolOutput.close().timeout(const Duration(seconds: 5));
  } catch (error) {
    final diagnostics = stderr.nonBlocking;
    unawaited(
      diagnostics.done.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
    try {
      diagnostics.writeln('gaovm-mcp: $error');
      await diagnostics.flush().timeout(const Duration(milliseconds: 250));
    } catch (_) {
      // A failed/unread diagnostics pipe must not retain the failed process.
    }
    // serve has released local HTTP ownership. A stalled pipe can still own a
    // native write: terminate with failure, never mask it as graceful exit(0).
    exit(1);
  }
}
