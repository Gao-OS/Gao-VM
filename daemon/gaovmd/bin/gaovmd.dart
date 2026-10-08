import 'dart:async';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';

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
    final config = _Config.parse(args);
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

final class _Config {
  _Config(
    this.state,
    this.socket,
    this.driver,
    this.openapi,
    this.maxRunning,
    this.maxBoots,
  );
  final String state;
  final String? socket;
  final String driver;
  final String openapi;
  final int maxRunning;
  final int maxBoots;

  static _Config parse(List<String> args) {
    final values = <String, String>{};
    const allowed = {
      '--state-dir',
      '--socket-path',
      '--driver-bin',
      '--openapi-path',
      '--max-running-vms',
      '--max-concurrent-boots',
    };
    for (var i = 0; i < args.length; i += 2) {
      if (!allowed.contains(args[i]) || i + 1 >= args.length) {
        throw FormatException('unknown option or missing value: ${args[i]}');
      }
      values[args[i]] = args[i + 1];
    }
    String absolute(String path) => File(path).absolute.path;
    return _Config(
      absolute(values['--state-dir'] ?? 'state'),
      values['--socket-path'] == null
          ? null
          : absolute(values['--socket-path']!),
      absolute(
        values['--driver-bin'] ??
            Platform.environment['GAOVM_DRIVER_BIN'] ??
            '../../drivers/vz_macos/.build/debug/gaovm-driver-vz',
      ),
      absolute(
        values['--openapi-path'] ?? '../../schemas/openapi/gaovm-v1.yaml',
      ),
      int.parse(values['--max-running-vms'] ?? '8'),
      int.parse(values['--max-concurrent-boots'] ?? '2'),
    );
  }
}
