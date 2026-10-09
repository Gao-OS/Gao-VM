import 'dart:io';

/// Launch paths only. Runtime ownership and validation remain in the daemon.
final class DaemonLaunchConfiguration {
  const DaemonLaunchConfiguration._(
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

  static DaemonLaunchConfiguration parse(
    List<String> args, {
    String? executablePath,
    Map<String, String>? environment,
  }) {
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

    final env = environment ?? Platform.environment;
    final executable = File(executablePath ?? Platform.resolvedExecutable);
    final contents = executable.parent.parent;
    final packaged =
        executable.uri.pathSegments.last == 'gaovmd' &&
        executable.parent.path.endsWith('/Contents/MacOS') &&
        contents.parent.path.endsWith('.app');
    String absolute(String path) => File(path).absolute.path;

    return DaemonLaunchConfiguration._(
      absolute(
        values['--state-dir'] ?? (packaged ? _packagedState(env) : 'state'),
      ),
      values['--socket-path'] == null
          ? null
          : absolute(values['--socket-path']!),
      absolute(
        values['--driver-bin'] ??
            env['GAOVM_DRIVER_BIN'] ??
            (packaged
                ? '${contents.path}/Helpers/gaovm-driver-vz'
                : '../../drivers/vz_macos/.build/debug/gaovm-driver-vz'),
      ),
      absolute(
        values['--openapi-path'] ??
            (packaged
                ? '${contents.path}/Resources/schemas/openapi/gaovm-v1.yaml'
                : '../../schemas/openapi/gaovm-v1.yaml'),
      ),
      int.parse(values['--max-running-vms'] ?? '8'),
      int.parse(values['--max-concurrent-boots'] ?? '2'),
    );
  }
}

String _packagedState(Map<String, String> environment) {
  final home = environment['HOME'];
  if (home == null || home.isEmpty || !Directory(home).isAbsolute) {
    throw const FormatException(
      'packaged gaovmd requires an absolute HOME or --state-dir',
    );
  }
  return '$home/Library/Application Support/GaoVM';
}
