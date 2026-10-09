import 'dart:io';

/// Uses the daemon's installed state root only for the packaged executable.
String defaultGaovmSocketPath({
  String? executablePath,
  Map<String, String>? environment,
}) {
  final executable = File(executablePath ?? Platform.resolvedExecutable);
  final contents = executable.parent.parent;
  final packaged =
      executable.uri.pathSegments.last == 'gaovm' &&
      executable.parent.path.endsWith('/Contents/MacOS') &&
      contents.parent.path.endsWith('.app');
  if (!packaged) return File('state/run/api.sock').absolute.path;

  final home = (environment ?? Platform.environment)['HOME'];
  if (home == null || home.isEmpty || !Directory(home).isAbsolute) {
    throw const FormatException(
      'packaged gaovm requires an absolute HOME or --socket-path',
    );
  }
  return File(
    '$home/Library/Application Support/GaoVM/run/api.sock',
  ).absolute.path;
}
