import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/macos_dart_signing_policy.dart';
import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  group('packaged daemon launch paths', () {
    late Directory root;
    late File executable;
    final children = <OwnedTestProcess>[];

    Future<ProcessResult> run(
      String command,
      List<String> args, {
      bool isolated = false,
      Duration timeout = const Duration(seconds: 10),
    }) async {
      if (children.any((child) => !child.exitConfirmed)) {
        throw StateError('an earlier fixture process has not exited');
      }
      final child = OwnedTestProcess(
        await Process.start(
          command,
          args,
          workingDirectory: isolated ? root.path : null,
          includeParentEnvironment: !isolated,
          environment: isolated ? const {} : null,
        ),
      );
      children.add(child);
      return child.result(timeout: timeout);
    }

    setUpAll(() async {
      root = await Directory('/private/tmp').createTemp('gvm-pkg-daemon-');
      imageFileMode(root.path, 0x1c0);
      final macos = await Directory(
        '${root.path}/Renamed GaoVM.app/Contents/MacOS',
      ).create(recursive: true);
      executable = File('${macos.path}/gaovmd');
      final compiled = await run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        'bin/gaovmd.dart',
        '-o',
        executable.path,
      ], timeout: const Duration(minutes: 2));
      expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
      final entitlements = await File(
        '${root.path}/dart-runtime-entitlements.plist',
      ).writeAsString(macOsDartRuntimeEntitlements);
      final signed = await run('/usr/bin/codesign', [
        '--force',
        '--sign',
        '-',
        '--options',
        'runtime',
        '--timestamp=none',
        '--entitlements',
        entitlements.path,
        executable.path,
      ]);
      expect(signed.exitCode, 0, reason: '${signed.stderr}');
    });

    tearDownAll(() async {
      for (final child in children.where((child) => !child.exitConfirmed)) {
        await child.terminate();
      }
      if (children.any((child) => !child.exitConfirmed)) {
        throw StateError('retaining live executable fixture: ${root.path}');
      }
      await root.delete(recursive: true);
    });

    Future<ProcessResult> invoke(List<String> args) =>
        run(executable.path, args, isolated: true);

    test(
      'requires HOME or explicit state instead of using cwd state',
      () async {
        final result = await invoke(const []);
        expect(result.exitCode, 1, reason: '${result.stderr}');
        expect(result.stderr, contains('absolute HOME or --state-dir'));
        expect(await Directory('${root.path}/state').exists(), isFalse);
      },
    );

    test(
      'missing bundled schema is not replaced by a source-tree path',
      () async {
        final state = '${root.path}/explicit-state';
        final result = await invoke(['--state-dir', state]);
        expect(result.exitCode, 1, reason: '${result.stderr}');
        expect(
          result.stderr,
          contains(
            '${executable.parent.parent.path}/Resources/schemas/openapi/gaovm-v1.yaml',
          ),
        );
        // Loading the schema precedes state creation and native census. This
        // fixture intentionally cannot reach VM/process startup.
        expect(await Directory(state).exists(), isFalse);
      },
    );

    test('help requires neither HOME nor packaged resources', () async {
      final result = await invoke(['--help']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('--openapi-path PATH'));
      expect(result.stderr, isEmpty);
    });
  }, skip: !Platform.isMacOS);
}
