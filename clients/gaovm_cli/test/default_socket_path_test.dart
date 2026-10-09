import 'dart:io';

import 'package:gaovm_cli/src/default_socket_path.dart';
import 'package:test/test.dart';

void main() {
  test('packaged CLI selects the canonical per-user daemon socket', () {
    expect(
      defaultGaovmSocketPath(
        executablePath: '/Applications/Renamed GaoVM.app/Contents/MacOS/gaovm',
        environment: const {'HOME': '/Users/package-user'},
      ),
      '/Users/package-user/Library/Application Support/GaoVM/run/api.sock',
    );
  });

  test('source and non-app CLI paths retain the development socket', () {
    for (final path in [
      '/sdk/bin/dart',
      '/build/gaovm',
      '/not-an-app/Contents/MacOS/gaovm',
      '/Applications/GaoVM.app/Contents/Helpers/gaovm',
      '/Applications/GaoVM.app/Contents/MacOS/dart',
    ]) {
      expect(
        defaultGaovmSocketPath(executablePath: path, environment: const {}),
        File('state/run/api.sock').absolute.path,
        reason: path,
      );
    }
  });

  test('packaged default socket rejects missing, empty or relative HOME', () {
    for (final environment in [
      <String, String>{},
      {'HOME': ''},
      {'HOME': 'relative-home'},
    ]) {
      expect(
        () => defaultGaovmSocketPath(
          executablePath: '/Applications/GaoVM.app/Contents/MacOS/gaovm',
          environment: environment,
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
