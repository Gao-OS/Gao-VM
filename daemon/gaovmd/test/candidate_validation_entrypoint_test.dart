import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  test(
    'private launch stdin refuses malformed grants without opening state or echoing input',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'gvm-validation-grant-entry-',
      );
      final root = await temporary.resolveSymbolicLinks();
      final nonce = 'ab' * 32;
      OwnedTestProcess? child;
      try {
        final process = await Process.start(
          Platform.resolvedExecutable,
          [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/bin/gaovmd.dart',
            '--validate-upgrade',
            '--launch-grant-stdin',
            '--state-dir',
            '$root/state',
          ],
          includeParentEnvironment: false,
          environment: const {'PATH': '/usr/bin:/bin'},
        );
        child = OwnedTestProcess(process);
        process.stdin.write('{"nonce":"$nonce",invalid}');
        await process.stdin.close();
        final result = await child.result(timeout: const Duration(seconds: 30));
        expect(result.exitCode, 2, reason: '${result.stderr}');
        expect(result.stderr, isEmpty);
        expect(result.stdout, isNot(contains(nonce)));
        final report = jsonDecode(result.stdout as String) as Map;
        expect(report['status'], 'refused');
        expect(report['stage'], 'inputs');
        expect(report['reason'], 'invalid private validation launch grant');
        expect(report['committed'], false);
        expect(await temporary.list().toList(), isEmpty);
      } finally {
        if (child != null && !await child.terminate()) {
          throw StateError('retain fixture $root');
        }
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'validation entry refuses source execution without opening state',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'gvm-validation-entry-',
      );
      final root = await temporary.resolveSymbolicLinks();
      final child = OwnedTestProcess(
        await Process.start(
          Platform.resolvedExecutable,
          [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/bin/gaovmd.dart',
            '--validate-upgrade',
            '--app',
            '$root/GaoVM.app',
            '--state-dir',
            '$root/state',
            '--work-dir',
            '$root/work',
            '--inspection-dir',
            '$root/inspection',
            '--bundle-id',
            'org.gaovm.tests.Release',
            '--old-version',
            '0.1.0',
            '--new-version',
            '0.1.0',
            '--team-id',
            'ABCDEFGHIJ',
            '--catalog-schema',
            '21',
          ],
          includeParentEnvironment: false,
          environment: const {'PATH': '/usr/bin:/bin'},
        ),
      );
      try {
        final result = await child.result(timeout: const Duration(seconds: 30));
        expect(result.exitCode, 2, reason: '${result.stderr}');
        final report = jsonDecode(result.stdout as String) as Map;
        expect(report['status'], 'refused');
        expect(report['stage'], 'candidate_admission');
        expect(
          report['reason'],
          'validation must execute the installed candidate daemon',
        );
        expect(report['committed'], false);
        expect(await temporary.list().toList(), isEmpty);
      } finally {
        if (!await child.terminate()) throw StateError('retain fixture $root');
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}
