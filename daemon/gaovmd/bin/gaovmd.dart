import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/daemon_launch_configuration.dart';
import 'package:gaovmd/src/daemon_component_info.dart';
import 'package:gaovmd/src/macos_cold_validation.dart';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--component-info') {
    stdout.writeln(jsonEncode(daemonComponentInfo().toJson()));
    return;
  }
  if (args.contains('--help')) {
    stdout.writeln(
      'Usage: gaovmd [--state-dir PATH] [--socket-path PATH] '
      '[--driver-bin PATH] [--openapi-path PATH] '
      '[--max-running-vms N] [--max-concurrent-boots N] '
      '[--guest-development-acceptance true|false]\n'
      'Internal cold validation: --validate-upgrade with explicit app, state, '
      'work, inspection, release identity and catalog schema selectors.',
    );
    return;
  }
  if (!Platform.isMacOS) {
    stderr.writeln('gaovmd requires macOS.');
    exitCode = 2;
    return;
  }
  if (args.isNotEmpty && args.first == '--validate-upgrade') {
    try {
      final result = await runMacOsCandidateValidation([
        'validate-upgrade',
        ...args.skip(1),
      ]);
      stdout.writeln(jsonEncode(result));
    } catch (error) {
      final cause = error is ColdPublicationFailure ? error.cause : error;
      final refused = cause is FormatException || cause is StateError;
      stdout.writeln(
        jsonEncode({
          'format': 'gaovm.cold-validation-command.v1',
          'status': refused ? 'refused' : 'unverified',
          'stage': error is ColdPublicationFailure ? error.stage : 'inputs',
          'reason': cause is FormatException
              ? cause.message
              : 'validation did not complete; retain all inputs and outputs',
          'retain_inputs_and_outputs': true,
          'activation_authorized': false,
          'rollback_authorized': false,
          'committed': false,
        }),
      );
      exitCode = refused ? 2 : 3;
    }
    return;
  }
  DaemonApplication application;
  try {
    final config = DaemonLaunchConfiguration.parse(args);
    final openapi = await loadPublicOpenApiDocument(File(config.openapi));
    application = await DaemonApplication.start(
      stateDirectory: Directory(config.state),
      driverBinary: config.driver,
      socketPath: config.socket,
      openApiDocument: openapi,
      maxRunningVms: config.maxRunning,
      maxConcurrentBoots: config.maxBoots,
      guestDevelopmentAcceptance: config.guestDevelopmentAcceptance,
    );
  } catch (error) {
    stderr.writeln('gaovmd startup failed: $error');
    exitCode = 1;
    return;
  }
  final stopped = Completer<void>();
  Future<void>? stopping;
  void stop() {
    if (stopping != null || stopped.isCompleted) return;
    stopping = application.close().then<void>(
      (_) {
        stopped.complete();
      },
      onError: (Object error, StackTrace stack) {
        // Keep ownership/dependencies alive when teardown cannot be confirmed.
        // A subsequent signal retries shutdown; do not abandon native mutation.
        stderr.writeln('gaovmd shutdown failed: $error');
        stopping = null;
      },
    );
  }

  final signals = [
    ProcessSignal.sigint.watch().listen((_) => stop()),
    ProcessSignal.sigterm.watch().listen((_) => stop()),
  ];
  application.done.then<void>((_) {
    if (!stopped.isCompleted && stopping == null) {
      exitCode = 1;
      stop();
    }
  });
  stdout.writeln('gaovmd listening on unix:${application.socketPath}');
  await stopped.future;
  for (final signal in signals) await signal.cancel();
}
