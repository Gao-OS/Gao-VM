import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/macos_release_inspection.dart';
import 'package:gaovmd/src/maintenance_command.dart';

const _usage =
    'Usage: inspect_macos_release.dart --app PATH --bundle-id ID '
    '--version X.Y.Z --team-id TEAMID --catalog-schema N\n'
    'Read-only Developer ID release evidence. The catalog number is an explicit '
    'compatibility input, not an observed database version. No service action or VM boot occurs.';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--help') {
    stdout.writeln(_usage);
    return;
  }
  void failure(
    String status,
    String stage,
    String reason, {
    int? pid,
    bool? exitConfirmed,
  }) {
    stdout.writeln(
      jsonEncode({
        'format': 'gaovm.release-inspection.v1',
        'status': status,
        'stage': stage,
        'reason': reason,
        if (pid != null) 'child_pid': pid,
        if (exitConfirmed != null) 'child_exit_confirmed': exitConfirmed,
      }),
    );
    exitCode = status == 'incompatible' ? 2 : 3;
  }

  try {
    const allowed = {
      '--app',
      '--bundle-id',
      '--version',
      '--team-id',
      '--catalog-schema',
    };
    final values = <String, String>{};
    for (var i = 0; i < arguments.length; i += 2) {
      if (!allowed.contains(arguments[i]) ||
          i + 1 >= arguments.length ||
          arguments[i + 1].isEmpty ||
          arguments[i + 1].startsWith('--') ||
          values.containsKey(arguments[i])) {
        throw const FormatException(
          'unknown, repeated or incomplete inspection option',
        );
      }
      values[arguments[i]] = arguments[i + 1];
    }
    if (values.length != allowed.length ||
        !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(values['--catalog-schema']!)) {
      throw const FormatException(
        'all explicit release and catalog compatibility inputs are required',
      );
    }
    final schema = int.tryParse(values['--catalog-schema']!);
    if (schema == null)
      throw const FormatException('invalid catalog schema number');
    final report = await inspectMacOsRelease(
      Directory(values['--app']!),
      bundleIdentifier: values['--bundle-id']!,
      version: values['--version']!,
      teamIdentifier: values['--team-id']!,
      catalogSchema: schema,
    );
    stdout.writeln(jsonEncode(report));
  } on FormatException catch (error) {
    failure('incompatible', 'inputs', error.message);
  } on ReleaseInspectionFailure catch (error) {
    failure(error.status, error.stage, error.reason);
  } on MaintenanceCommandFailure catch (error) {
    failure(
      'unverified',
      'child',
      error.reason,
      pid: error.pid,
      exitConfirmed: error.exitConfirmed,
    );
  } on ProcessException {
    failure(
      'unverified',
      'native',
      'required native inspection command could not run',
    );
  } catch (_) {
    failure(
      'unverified',
      'inspection',
      'release inspection did not complete; retain all inputs',
    );
  }
}
