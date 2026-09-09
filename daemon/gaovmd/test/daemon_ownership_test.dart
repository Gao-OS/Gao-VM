import 'dart:io';
import 'dart:convert';

import 'package:gaovmd/src/daemon_ownership.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:test/test.dart';

void main() {
  test(
    'ownership verification rejects a state directory made public',
    () async {
      final temp = await Directory.systemTemp.createTemp('daemon-owner-');
      final root = await OwnedImageDirectory.open(temp);
      final owner = (await DaemonOwnership.tryAcquire(root))!;
      try {
        imageFileMode(temp.path, 0x1ed);
        await expectLater(owner.verify(), throwsFormatException);
      } finally {
        imageFileMode(temp.path, 0x1c0);
        owner.close();
        root.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test('ownership verification rejects a replaced lock pathname', () async {
    final temp = await Directory.systemTemp.createTemp('daemon-owner-');
    final root = await OwnedImageDirectory.open(temp);
    final owner = (await DaemonOwnership.tryAcquire(root))!;
    try {
      final file = File('${temp.path}/.gaovmd.lock');
      await file.rename('${temp.path}/old-lock');
      await file.writeAsString('replacement');
      await expectLater(owner.verify(), throwsA(isA<FileSystemException>()));
    } finally {
      owner.close();
      root.close();
      await temp.delete(recursive: true);
    }
  });

  test('kernel releases ownership after the owning process crashes', () async {
    final temp = await Directory.systemTemp.createTemp('daemon-owner-');
    final root = await OwnedImageDirectory.open(temp);
    final child = await Process.start(Platform.resolvedExecutable, [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      '${Directory.current.path}/test/fixtures/hold_daemon_ownership.dart',
      temp.path,
    ]);
    final errors = child.stderr.drain<void>();
    DaemonOwnership? recovered;
    try {
      expect(
        await child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10)),
        'owned',
      );
      expect(await DaemonOwnership.tryAcquire(root), isNull);
      expect(child.kill(ProcessSignal.sigkill), isTrue);
      await child.exitCode.timeout(const Duration(seconds: 5));
      recovered = await DaemonOwnership.tryAcquire(root);
      expect(recovered, isNotNull);
      await recovered!.verify();
    } finally {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
      await errors;
      recovered?.close();
      root.close();
      await temp.delete(recursive: true);
    }
  });

  test('one state directory has one owner until release', () async {
    final temp = await Directory.systemTemp.createTemp('daemon-owner-');
    final firstRoot = await OwnedImageDirectory.open(temp);
    final secondRoot = await OwnedImageDirectory.open(temp);
    DaemonOwnership? first;
    DaemonOwnership? next;
    try {
      first = await DaemonOwnership.tryAcquire(firstRoot);
      expect(first, isNotNull);
      expect(
        await DaemonOwnership.tryAcquire(
          secondRoot,
        ).timeout(const Duration(seconds: 2)),
        isNull,
      );
      await first!.verify();
      first.close();
      await expectLater(first.verify(), throwsStateError);
      next = await DaemonOwnership.tryAcquire(secondRoot);
      expect(next, isNotNull);
      await next!.verify();
      expect(await File('${temp.path}/.gaovmd.lock').exists(), isTrue);
    } finally {
      first?.close();
      next?.close();
      firstRoot.close();
      secondRoot.close();
      await temp.delete(recursive: true);
    }
  });
}
