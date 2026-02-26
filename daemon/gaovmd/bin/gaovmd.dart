import 'dart:async';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isMacOS) {
    stderr.writeln('gaovmd v1.2 bootstrap is macOS-only.');
    exitCode = 2;
    return;
  }

  final config = _parseArgs(args);
  final logger = RotatingLogger(path: '${config.stateDir}/logs/gaovmd.log');
  final supervisor = DriverSupervisor(
    driverBinary: config.driverBinary,
    stateDir: config.stateDir,
    logger: logger,
  );
  final configStore = VmConfigStore(stateDir: config.stateDir);
  final server = DaemonRpcServer(
    socketPath: config.socketPath,
    supervisor: supervisor,
    configStore: configStore,
    logger: logger,
  );
  await supervisor.restoreDesiredState();

  ProcessSignal.sigint.watch().listen((_) async {
    await logger.info('Received SIGINT, stopping daemon');
    await server.stop();
    exit(0);
  });
  ProcessSignal.sigterm.watch().listen((_) async {
    await logger.info('Received SIGTERM, stopping daemon');
    await server.stop();
    exit(0);
  });

  await server.start();
  await logger.info('gaovmd listening on unix:${config.socketPath}');
  stdout.writeln('gaovmd listening on unix:${config.socketPath}');
  stdout.writeln('driver binary: ${config.driverBinary}');
  stdout.writeln('state dir: ${config.stateDir}');

  await Completer<void>().future;
}

class _Config {
  _Config({
    required this.socketPath,
    required this.stateDir,
    required this.driverBinary,
  });

  final String socketPath;
  final String stateDir;
  final String driverBinary;
}

_Config _parseArgs(List<String> args) {
  var stateDir = Directory.current.uri.resolve('state').toFilePath();
  var socketPath = Directory.current.uri.resolve('state/run/daemon.sock').toFilePath();
  var driverBinary = Platform.environment['GAOVM_DRIVER_BIN'] ??
      Directory.current.uri
          .resolve('../../drivers/vz_macos/.build/debug/vz_macos')
          .toFilePath();

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--host':
        final host = args[++i];
        stderr.writeln('--host is no longer supported (use --socket-path). Ignoring: $host');
      case '--port':
        final port = args[++i];
        stderr.writeln('--port is no longer supported (use --socket-path). Ignoring: $port');
      case '--socket-path':
        socketPath = args[++i];
      case '--state-dir':
        stateDir = args[++i];
        socketPath = '$stateDir/run/daemon.sock';
      case '--driver-bin':
        driverBinary = args[++i];
      case '--help':
        stdout.writeln('Usage: gaovmd [--socket-path PATH] [--state-dir PATH] [--driver-bin PATH]');
        exit(0);
    }
  }

  return _Config(
    socketPath: socketPath,
    stateDir: stateDir,
    driverBinary: driverBinary,
  );
}
