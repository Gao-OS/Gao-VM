import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart';
import 'package:test/test.dart';

void main() {
  test('child operations reject invalid basenames including NUL', () async {
    final root = await Directory.systemTemp.createTemp('bundle-names-');
    addTearDown(() => root.delete(recursive: true));
    final held = await OwnedImageDirectory.open(root);
    addTearDown(held.close);
    for (final name in ['', '.', '..', 'a/b', 'a\u0000b']) {
      for (final operation in <void Function()>[
        () => held.createDirectory(name),
        () => held.removeDirectory(name),
        () => held.directory(name),
        () => held.file(name),
        () => held.directoryOrNull(name),
        () => held.fileOrNull(name),
      ]) {
        expect(operation, throwsArgumentError);
      }
      await expectLater(
        held.renameDirectoryNoReplace(name, 'dest'),
        throwsArgumentError,
      );
      await expectLater(
        held.renameDirectoryNoReplace('source', name),
        throwsArgumentError,
      );
      await expectLater(held.acquireLock(name), throwsArgumentError);
    }
  });
  test(
    'independent held locks wait until release across parent path replacement',
    () async {
      final root = await Directory.systemTemp.createTemp('bundle-lock-');
      addTearDown(() => root.delete(recursive: true));
      final original = await Directory('${root.path}/owned').create();
      final held = await OwnedImageDirectory.open(original);
      addTearDown(held.close);
      await File('${original.path}/vm.lock').writeAsString('retained');
      final first = await held.acquireLock('vm.lock');
      addTearDown(first.close);
      await original.rename('${root.path}/moved');
      await Directory(original.path).create();
      var acquired = false;
      final waiting = held.acquireLock('vm.lock').then((lock) {
        acquired = true;
        return lock;
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(acquired, isFalse);
      first.close();
      final second = await waiting.timeout(const Duration(seconds: 5));
      second.close();
      expect(await File('${root.path}/moved/vm.lock').exists(), isTrue);
      expect(
        await File('${root.path}/moved/vm.lock').readAsString(),
        'retained',
      );
      expect(await File('${original.path}/vm.lock').exists(), isFalse);
      expect(
        (await File('${root.path}/moved/vm.lock').stat()).mode & 0x1ff,
        0x180,
      );
      await Link('${root.path}/moved/link').create('vm.lock');
      await expectLater(
        held.acquireLock('link'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
  test(
    'bounded cleanup rejects nonempty directories and nullable opens reject links',
    () async {
      final root = await Directory.systemTemp.createTemp('bundle-cleanup-');
      addTearDown(() => root.delete(recursive: true));
      final held = await OwnedImageDirectory.open(root);
      addTearDown(held.close);
      expect(held.directoryOrNull('missing'), isNull);
      expect(held.fileOrNull('missing'), isNull);
      held.createDirectory('stage').close();
      await File('${root.path}/stage/keep').writeAsString('safe');
      expect(
        () => held.removeDirectory('stage'),
        throwsA(isA<FileSystemException>()),
      );
      await Link('${root.path}/link').create('missing');
      expect(
        () => held.directoryOrNull('link'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => held.fileOrNull('link'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => held.removeDirectory('link'),
        throwsA(isA<FileSystemException>()),
      );
      final stage = held.directoryOrNull('stage')!;
      stage.removeFile('keep');
      stage.close();
      held.removeDirectory('stage');
      expect(held.directoryOrNull('stage'), isNull);
      expect(
        () => held.removeDirectory('missing'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
  test(
    'publication is exclusive and remains bound after root pathname swap',
    () async {
      final root = await Directory.systemTemp.createTemp('bundle-publish-');
      addTearDown(() => root.delete(recursive: true));
      final original = await Directory('${root.path}/owned').create();
      final held = await OwnedImageDirectory.open(original);
      addTearDown(held.close);
      held.createDirectory('staging').close();
      held.createDirectory('existing').close();
      held.createDirectory('empty').close();
      await File('${original.path}/staging/proof').writeAsString('new');
      await File('${original.path}/existing/proof').writeAsString('old');
      await expectLater(
        held.renameDirectoryNoReplace('staging', 'existing'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        held.renameDirectoryNoReplace('staging', 'empty'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await File('${original.path}/existing/proof').readAsString(),
        'old',
      );
      await original.rename('${root.path}/moved');
      await Directory(original.path).create();
      await held.renameDirectoryNoReplace('staging', 'published');
      expect(
        await File('${root.path}/moved/published/proof').readAsString(),
        'new',
      );
      expect(await Directory('${original.path}/published').exists(), isFalse);
      expect(await Directory('${root.path}/moved/staging').exists(), isFalse);
    },
  );
  test(
    'creates private held directory exclusively and preserves existing data',
    () async {
      final root = await Directory.systemTemp.createTemp('bundle-fs-');
      addTearDown(() => root.delete(recursive: true));
      final held = await OwnedImageDirectory.open(root);
      addTearDown(held.close);
      final child = held.createDirectory('staging');
      addTearDown(child.close);
      await File('${root.path}/staging/keep').writeAsString('retained');
      expect(
        () => held.createDirectory('staging'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await File('${root.path}/staging/keep').readAsString(),
        'retained',
      );
      expect(
        (await Directory('${root.path}/staging').stat()).mode & 0x1ff,
        0x1c0,
      );
      final file = child.file('keep');
      addTearDown(file.close);
      expect(file.size, 8);
    },
  );
}
