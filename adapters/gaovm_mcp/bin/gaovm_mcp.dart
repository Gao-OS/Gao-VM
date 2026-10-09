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
  try {
    final server = GaoVmMcpServer(
      api: GaoVmApiClient(socketPath: arguments[1]),
    );
    await server.serve(stdin, stdout.writeln);
    await stdout.flush();
  } catch (error) {
    stderr.writeln('gaovm-mcp: $error');
    exitCode = 1;
  }
}
