import 'dart:io';

import 'package:gaovm_cli/gaovm_cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
