import 'dart:async';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/daemon_launch_configuration.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln(
      'Usage: gaovmd [--state-dir PATH] [--socket-path PATH] '
      '[--driver-bin PATH] [--openapi-path PATH] '
      '[--max-running-vms N] [--max-concurrent-boots N]',
    );
    return;
  }
  if (!Platform.isMacOS) {
    stderr.writeln('gaovmd requires macOS.');
    exitCode = 2;
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
