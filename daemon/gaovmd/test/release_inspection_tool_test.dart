import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  test(
    'release inspection help needs no HOME, app, catalog or running service',
    () async {
      final root = await Directory.systemTemp.createTemp('gvm-release-tool-');
      OwnedTestProcess? child;
      try {
        child = OwnedTestProcess(
          await Process.start(
            Platform.resolvedExecutable,
            [
              '--packages=${Directory.current.path}/.dart_tool/package_config.json',
              '${Directory.current.path}/tool/inspect_macos_release.dart',
              '--help',
            ],
            workingDirectory: root.path,
            includeParentEnvironment: false,
            environment: const {},
          ),
        );
        final result = await child.result();
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stdout, contains('--team-id'));
        expect(result.stderr, isEmpty);
        expect(await root.list().toList(), isEmpty);
      } finally {
        if (child != null && !await child.terminate()) {
          throw StateError('retaining live inspection fixture: ${root.path}');
        }
        await root.delete(recursive: true);
      }
    },
  );

  for (final arguments in <List<String>>[
    [],
    ['--app', '/missing/GaoVM.app', '--app', '/other/GaoVM.app'],
    [
      '--app',
      '/missing/GaoVM.app',
      '--bundle-id',
      'org.gaovm.tests.Release',
      '--version',
      '0.1.0',
      '--team-id',
      'ABCDEFGHIJ',
      '--catalog-schema',
      '021',
    ],
  ]) {
    test(
      'malformed inspection arguments fail before reading any app: $arguments',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'gvm-release-invalid-',
        );
        OwnedTestProcess? child;
        try {
          child = OwnedTestProcess(
            await Process.start(
              Platform.resolvedExecutable,
              [
                '--packages=${Directory.current.path}/.dart_tool/package_config.json',
                '${Directory.current.path}/tool/inspect_macos_release.dart',
                ...arguments,
              ],
              workingDirectory: root.path,
              includeParentEnvironment: false,
              environment: const {},
            ),
          );
          final result = await child.result();
          expect(result.exitCode, 2, reason: '${result.stderr}');
          expect(result.stderr, isEmpty);
          final report = jsonDecode(result.stdout as String) as Map;
          expect(report['status'], 'incompatible');
          expect(report['stage'], 'inputs');
          expect(await root.list().toList(), isEmpty);
        } finally {
          if (child != null && !await child.terminate()) {
            throw StateError('retaining live inspection fixture: ${root.path}');
          }
          await root.delete(recursive: true);
        }
      },
    );
  }
}
