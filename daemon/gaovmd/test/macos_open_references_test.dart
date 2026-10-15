import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_open_references.dart';
import 'package:test/test.dart';

void main() {
  test(
    'directory and file observations find an owned child until its file closes',
    () async {
      final created = await Directory.systemTemp.createTemp('gvm-open-refs-');
      final root = Directory(await created.resolveSymbolicLinks());
      imageFileMode(root.path, 0x1c0);
      final file = File('${root.path}/disk');
      await file.writeAsString('unchanged disk bytes');
      imageFileMode(file.path, 0x180);
      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/test/fixtures/hold_maintenance_file.dart',
        file.path,
      ]);
      final errors = child.stderr.drain<void>();
      try {
        expect(
          await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 10)),
          'held',
        );
        final observer = MacOsOpenReferences();
        expect(await observer.directory(root), contains(child.pid));
        expect(await observer.file(file), contains(child.pid));
        await child.stdin.close();
        expect(await child.exitCode.timeout(const Duration(seconds: 5)), 0);
        expect(await observer.directory(root), isNot(contains(child.pid)));
        expect(await observer.file(file), isNot(contains(child.pid)));
        expect(await file.readAsString(), 'unchanged disk bytes');
      } finally {
        child.kill(ProcessSignal.sigkill);
        // Retain the fixture if this owned child cannot be confirmed exited.
        await child.exitCode.timeout(const Duration(seconds: 5));
        await errors;
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a PID-only native record is incomplete, not an empty reference',
    () async {
      final created = await Directory.systemTemp.createTemp('gvm-open-refs-');
      final root = Directory(await created.resolveSymbolicLinks());
      imageFileMode(root.path, 0x1c0);
      try {
        final observer = MacOsOpenReferences(
          command: (_, _) async => ProcessResult(9876, 0, 'p$pid\x00\n', ''),
        );
        await expectLater(observer.directory(root), throwsFormatException);
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final evidence in [
    (code: 0, output: '', error: ''),
    (code: 2, output: '', error: ''),
    (code: 1, output: '', error: 'native warning'),
    (code: 0, output: 'p123\x00\nf8\x00', error: ''),
    (code: 0, output: 'p0\x00\nf8\x00\n', error: ''),
    (code: 0, output: 'p2147483648\x00\nf8\x00\n', error: ''),
    (code: 0, output: 'p123\x00\nfNOFD\x00\n', error: ''),
    (code: 0, output: 'p123\x00\nf8\x00\nxunknown\x00\n', error: ''),
  ].indexed) {
    test(
      'partial native evidence ${evidence.$1} cannot report no references',
      () async {
        final created = await Directory.systemTemp.createTemp('gvm-open-refs-');
        final root = Directory(await created.resolveSymbolicLinks());
        imageFileMode(root.path, 0x1c0);
        try {
          final value = evidence.$2;
          final observer = MacOsOpenReferences(
            command: (_, _) async =>
                ProcessResult(9876, value.code, value.output, value.error),
          );
          await expectLater(observer.directory(root), throwsFormatException);
        } finally {
          await root.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'a partial search retains occupied PIDs and excludes only its exited observer',
    () async {
      final created = await Directory.systemTemp.createTemp('gvm-open-refs-');
      final root = Directory(await created.resolveSymbolicLinks());
      imageFileMode(root.path, 0x1c0);
      try {
        final observer = MacOsOpenReferences(
          command: (executable, arguments) async {
            expect(executable, '/usr/sbin/lsof');
            expect(
              arguments,
              containsAll(['-a', '-u', '-F0p', '+D', root.path]),
            );
            return ProcessResult(
              9876,
              1,
              'p123\x00\nf8\x00\np9876\x00\nf9\x00\n',
              '',
            );
          },
        );
        expect(await observer.directory(root), {123});
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'only empty, diagnostic-free search miss reports no references',
    () async {
      final created = await Directory.systemTemp.createTemp('gvm-open-refs-');
      final root = Directory(await created.resolveSymbolicLinks());
      imageFileMode(root.path, 0x1c0);
      try {
        final observer = MacOsOpenReferences(
          command: (_, _) async => ProcessResult(9876, 1, '', ''),
        );
        expect(await observer.directory(root), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}
