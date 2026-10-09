import 'dart:io';

import 'package:gaovmd/src/daemon_launch_configuration.dart';
import 'package:test/test.dart';

void main() {
  test('packaged daemon resolves state and assets without the source cwd', () {
    final config = DaemonLaunchConfiguration.parse(
      const [],
      executablePath: '/Applications/Renamed GaoVM.app/Contents/MacOS/gaovmd',
      environment: const {'HOME': '/Users/package-user'},
    );

    expect(
      config.state,
      '/Users/package-user/Library/Application Support/GaoVM',
    );
    expect(config.socket, isNull);
    expect(
      config.driver,
      '/Applications/Renamed GaoVM.app/Contents/Helpers/gaovm-driver-vz',
    );
    expect(
      config.openapi,
      '/Applications/Renamed GaoVM.app/Contents/Resources/schemas/openapi/gaovm-v1.yaml',
    );
    expect(config.maxRunning, 8);
    expect(config.maxBoots, 2);
  });

  test('explicit launch paths override packaged defaults without HOME', () {
    final config = DaemonLaunchConfiguration.parse(
      const [
        '--state-dir',
        'custom-state',
        '--socket-path',
        'custom-api.sock',
        '--driver-bin',
        'custom-driver',
        '--openapi-path',
        'custom-openapi.yaml',
        '--max-running-vms',
        '4',
        '--max-concurrent-boots',
        '1',
      ],
      executablePath: '/Applications/GaoVM.app/Contents/MacOS/gaovmd',
      environment: const {'GAOVM_DRIVER_BIN': '/ignored/environment-driver'},
    );

    expect(config.state, File('custom-state').absolute.path);
    expect(config.socket, File('custom-api.sock').absolute.path);
    expect(config.driver, File('custom-driver').absolute.path);
    expect(config.openapi, File('custom-openapi.yaml').absolute.path);
    expect(config.maxRunning, 4);
    expect(config.maxBoots, 1);
  });

  test('source and non-app executables retain development defaults', () {
    for (final path in [
      '/sdk/bin/dart',
      '/build/gaovmd',
      '/not-an-app/Contents/MacOS/gaovmd',
      '/Applications/GaoVM.app/Contents/Helpers/gaovmd',
      '/Applications/GaoVM.app/Contents/MacOS/dart',
    ]) {
      final config = DaemonLaunchConfiguration.parse(
        const [],
        executablePath: path,
        environment: const {},
      );
      expect(config.state, File('state').absolute.path, reason: path);
      expect(config.socket, isNull);
      expect(
        config.driver,
        File(
          '../../drivers/vz_macos/.build/debug/gaovm-driver-vz',
        ).absolute.path,
        reason: path,
      );
      expect(
        config.openapi,
        File('../../schemas/openapi/gaovm-v1.yaml').absolute.path,
        reason: path,
      );
    }
  });

  test('an explicit driver environment value still overrides the bundle', () {
    final config = DaemonLaunchConfiguration.parse(
      const ['--state-dir', '/private/custom-state'],
      executablePath: '/Applications/GaoVM.app/Contents/MacOS/gaovmd',
      environment: const {'GAOVM_DRIVER_BIN': 'environment-driver'},
    );
    expect(config.driver, File('environment-driver').absolute.path);
    expect(config.state, '/private/custom-state');
  });

  test('packaged defaults reject missing, empty or relative HOME', () {
    for (final environment in [
      <String, String>{},
      {'HOME': ''},
      {'HOME': 'relative-home'},
    ]) {
      expect(
        () => DaemonLaunchConfiguration.parse(
          const [],
          executablePath: '/Applications/GaoVM.app/Contents/MacOS/gaovmd',
          environment: environment,
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('unknown options and missing values remain usage errors', () {
    for (final args in [
      ['--unknown', 'value'],
      ['--state-dir'],
    ]) {
      expect(
        () => DaemonLaunchConfiguration.parse(
          args,
          executablePath: '/sdk/bin/dart',
          environment: const {},
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });
}
