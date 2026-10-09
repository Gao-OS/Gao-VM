import 'dart:io';

import 'package:gaovmd/src/macos_app_package.dart';

const _usage =
    'Usage: package_macos.dart --daemon PATH --cli PATH --driver PATH '
    '--schemas PATH --driver-entitlements PATH --output-dir PATH '
    '--bundle-id ID --version X.Y.Z --sign IDENTITY\n'
    'Use --sign - only for an explicitly development/ad-hoc signed package.';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--help') {
    stdout.writeln(_usage);
    return;
  }
  try {
    const allowed = {
      '--daemon',
      '--cli',
      '--driver',
      '--schemas',
      '--driver-entitlements',
      '--output-dir',
      '--bundle-id',
      '--version',
      '--sign',
    };
    final values = <String, String>{};
    for (var i = 0; i < args.length; i += 2) {
      if (!allowed.contains(args[i]) ||
          i + 1 >= args.length ||
          args[i + 1].isEmpty ||
          args[i + 1].startsWith('--') ||
          values.containsKey(args[i])) {
        throw const FormatException('unknown, repeated or incomplete option');
      }
      values[args[i]] = args[i + 1];
    }
    if (values.length != allowed.length) {
      throw const FormatException('all package inputs are required');
    }
    final bundle = await MacOsAppPackageBuilder(
      daemon: File(values['--daemon']!),
      cli: File(values['--cli']!),
      driver: File(values['--driver']!),
      schemas: Directory(values['--schemas']!),
      driverEntitlements: File(values['--driver-entitlements']!),
      outputDirectory: Directory(values['--output-dir']!),
      bundleIdentifier: values['--bundle-id']!,
      version: values['--version']!,
      signingIdentity: values['--sign']!,
    ).build();
    stdout.writeln(bundle.path);
  } on FormatException catch (error) {
    stderr.writeln('package failed: ${error.message}');
    exitCode = 2;
  } on UnsupportedError catch (error) {
    stderr.writeln('package failed: ${error.message}');
    exitCode = 2;
  } catch (error) {
    stderr.writeln('package failed: $error');
    exitCode = 1;
  }
}
