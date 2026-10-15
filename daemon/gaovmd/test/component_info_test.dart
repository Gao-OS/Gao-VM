import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  test(
    'daemon component probe exits without HOME, state, a driver or listener',
    () async {
      final root = await Directory.systemTemp.createTemp('gvm-component-');
      OwnedTestProcess? child;
      try {
        child = OwnedTestProcess(
          await Process.start(
            Platform.resolvedExecutable,
            [
              '--packages=${Directory.current.path}/.dart_tool/package_config.json',
              '${Directory.current.path}/bin/gaovmd.dart',
              '--component-info',
            ],
            workingDirectory: root.path,
            includeParentEnvironment: false,
            environment: const {},
          ),
        );
        final result = await child.result();
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(result.stderr, isEmpty);
        final json = jsonDecode(result.stdout as String) as Map;
        expect(json['format'], 'gaovm.component.v1');
        expect(json['role'], 'daemon');
        expect(json['version'], '0.1.0');
        expect(json['public_api'], 'v1');
        expect(json['vm_spec'], 'gaovm.io/v1alpha1');
        expect(json['driver_protocol'], 'gaovm.driver.v2');
        expect(json['catalog_schema'], {'minimum': 0, 'maximum': 21});
        expect(
          (json['capabilities'] as Map)['required'],
          contains('runtime.configure'),
        );
        expect(await root.list().toList(), isEmpty);
      } finally {
        if (child != null && !await child.terminate()) {
          throw StateError('retaining live probe fixture: ${root.path}');
        }
        await root.delete(recursive: true);
      }
    },
  );
}
