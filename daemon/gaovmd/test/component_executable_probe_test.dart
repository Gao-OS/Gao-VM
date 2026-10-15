import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/component_executable_probe.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  late Directory root;
  late File executable;
  OwnedTestProcess? compiler;
  var retain = false;
  setUpAll(() async {
    final temporary = await Directory.systemTemp.createTemp(
      'gvm-component-probe-',
    );
    root = Directory(await temporary.resolveSymbolicLinks());
    imageFileMode(root.path, 0x1c0);
    executable = File('${root.path}/component');
    compiler = OwnedTestProcess(
      await Process.start(Platform.resolvedExecutable, [
        'compile',
        'exe',
        'test/fixtures/component_probe_fixture.dart',
        '-o',
        executable.path,
      ]),
    );
    final result = await compiler!.result(timeout: const Duration(minutes: 2));
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });
  tearDownAll(() async {
    if (retain || compiler != null && !await compiler!.terminate()) {
      throw StateError('retaining component probe fixture at ${root.path}');
    }
    await root.delete(recursive: true);
  });
  Future<ComponentExecutableEvidence> probe(File file) async {
    try {
      return await probeComponentExecutable(
        file,
        expectedRole: ComponentRole.cli,
      );
    } on MaintenanceCommandFailure catch (error) {
      if (!error.exitConfirmed) retain = true;
      rethrow;
    }
  }

  test(
    'actual component output is bound to unchanged owned executable bytes',
    () async {
      final digest = 'sha256:${await sha256.bind(executable.openRead()).first}';
      final result = await probe(executable);
      expect(result.info.role, ComponentRole.cli);
      expect(result.info.version, '0.1.0');
      expect(result.digest, digest);
      expect(result.path, executable.path);
      expect(
        'sha256:${await sha256.bind(executable.openRead()).first}',
        digest,
      );
    },
  );

  for (final name in ['legacy', 'foreign', 'noisy']) {
    test(
      'rejects $name executable output without changing the input',
      () async {
        final file = await executable.copy('${root.path}/$name');
        imageFileMode(file.path, 0x1c0);
        final digest = await sha256.bind(file.openRead()).first;
        await expectLater(probe(file), throwsFormatException);
        expect(await sha256.bind(file.openRead()).first, digest);
      },
    );
  }

  test(
    'rejects a symlink or group-writable executable before running it',
    () async {
      final alias = Link('${root.path}/alias');
      await alias.create(executable.path);
      await expectLater(probe(File(alias.path)), throwsFormatException);
      final writable = await executable.copy('${root.path}/writable');
      imageFileMode(writable.path, 0x1f0);
      await expectLater(probe(writable), throwsFormatException);
    },
  );
}
