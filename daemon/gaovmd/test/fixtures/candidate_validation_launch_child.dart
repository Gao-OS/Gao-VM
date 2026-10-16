import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/candidate_validation_launch.dart';

Future<void> main(List<String> arguments) async {
  try {
    final grant = await readValidationLaunchGrant(stdin);
    if (grant.process.pid != pid ||
        grant.process.executablePath !=
            await File(Platform.resolvedExecutable).resolveSymbolicLinks()) {
      throw const FormatException('wrong owned child');
    }
    if (arguments.single == 'stderr-overflow') {
      stderr.write('x' * 16385);
    }
    if (arguments.single == 'invalid-utf8') stdout.add([0xff]);
    stdout.writeln(
      jsonEncode({
        'pid': pid,
        'grant_digest': grant.digest,
        'environment_keys': Platform.environment.keys.toList()..sort(),
        'arguments': arguments,
      }),
    );
  } catch (_) {
    stdout.writeln('{"status":"refused"}');
    exitCode = 2;
  }
}
