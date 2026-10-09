import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart';
import 'package:test/test.dart';

void main() {
  test(
    'fresh metadata remains bound to the opened file across replacement',
    () async {
      final root = await Directory.systemTemp.createTemp('owned-stat-');
      addTearDown(() => root.delete(recursive: true));
      final original = await Directory('${root.path}/owned').create();
      final path = '${original.path}/payload';
      final source = await File(path).writeAsString('a');
      imageFileMode(path, 0x180);
      final directory = await OwnedImageDirectory.open(original);
      addTearDown(directory.close);
      final held = directory.file('payload');
      addTearDown(held.close);
      expect(held.size, 1);
      await source.writeAsString('bc', mode: FileMode.append);
      expect(
        held.stat().modifiedAt.millisecondsSinceEpoch,
        (await source.stat()).modified.millisecondsSinceEpoch,
      );
      // Dart 3.9's macOS timestamp setter uses utime, which stores whole seconds.
      // The actual write above exercises subsecond metadata independently.
      final modified = DateTime.utc(2020, 2, 3, 4, 5, 6);
      await source.setLastModified(modified);
      expect(
        (await source.stat()).modified.toUtc(),
        modified,
        reason: 'the fixture must store the expected timestamp',
      );
      final moved = await original.rename('${root.path}/moved');
      await Directory(original.path).create();
      await File(path).writeAsString('replacement bytes');
      final stat = held.stat();
      expect(stat.size, 3);
      expect(stat.modifiedAt, modified);
      expect(stat.mode & 0x1ff, 0x180);
      expect(stat.linkCount, 1);
      final linked = await Process.run('ln', [
        '${moved.path}/payload',
        '${root.path}/alias',
      ]);
      expect(linked.exitCode, 0, reason: '${linked.stderr}');
      expect(held.stat().linkCount, 2);
      await expectLater(
        held.verifyPathBinding(),
        throwsA(isA<FileSystemException>()),
      );
      held.close();
      expect(held.stat, throwsStateError);
    },
  );
  test(
    'owned file reads restart at byte zero after pathname replacement',
    () async {
      final root = await Directory.systemTemp.createTemp('owned-read-');
      addTearDown(() => root.delete(recursive: true));
      final original = await Directory('${root.path}/owned').create();
      final bytes = List<int>.generate(131079, (index) => index % 256);
      await File('${original.path}/payload').writeAsBytes(bytes);
      final held = await OwnedImageDirectory.open(original);
      addTearDown(held.close);
      final file = held.file('payload');
      addTearDown(file.close);
      expect(await file.openRead().expand((chunk) => chunk).toList(), bytes);
      await original.rename('${root.path}/moved');
      await Directory(original.path).create();
      await File('${original.path}/payload').writeAsString('replacement');
      expect(await file.openRead().expand((chunk) => chunk).toList(), bytes);
    },
  );
  test(
    'sealing targets the held output inode after pathname replacement',
    () async {
      final root = await Directory.systemTemp.createTemp('owned-seal-');
      addTearDown(() => root.delete(recursive: true));
      final original = await Directory('${root.path}/owned').create();
      final held = await OwnedImageDirectory.open(original);
      addTearDown(held.close);
      final output = held.createFile('payload');
      addTearDown(output.close);
      final writer = await output.openWrite();
      await writer.writeFrom([1, 2, 3]);
      await writer.close();
      await original.rename('${root.path}/moved');
      await Directory(original.path).create();
      final replacement = await File(
        '${original.path}/payload',
      ).writeAsString('replacement');
      imageFileMode(replacement.path, 0x180);
      await output.seal();
      final sealed = held.file('payload');
      addTearDown(sealed.close);
      expect(sealed.mode & 0x1ff, 0x100);
      expect(await sealed.readBounded(3), [1, 2, 3]);
      expect((await replacement.stat()).mode & 0x1ff, 0x180);
      expect(await replacement.readAsString(), 'replacement');
    },
  );
  test('sync uses the held file after its pathname becomes a link', () async {
    final root = await Directory.systemTemp.createTemp('owned-file-sync-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/payload';
    final original = await File(path).writeAsString('held bytes');
    final held = await OwnedImageFile.open(original);
    addTearDown(held.close);
    final moved = await original.rename('${root.path}/moved');
    await Link(path).create('${root.path}/missing');

    await held.sync();

    expect(await moved.readAsString(), 'held bytes');
    expect(await Link(path).target(), '${root.path}/missing');
    expect(await File('${root.path}/missing').exists(), isFalse);
    held.close();
    await expectLater(held.sync(), throwsStateError);
  });
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
  test('concurrent first-use lockers serialize a fresh lock', () async {
    final temporary = await Directory.systemTemp.createTemp('fresh-lock-');
    addTearDown(() => temporary.delete(recursive: true));
    for (var attempt = 0; attempt < 20; attempt++) {
      final directory = await Directory('${temporary.path}/$attempt').create();
      final held = await OwnedImageDirectory.open(directory);
      var holders = 0;
      var maxHolders = 0;
      try {
        await Future.wait(
          List.generate(2, (_) async {
            final lock = await held.acquireLock('shared.lock');
            try {
              holders++;
              if (holders > maxHolders) maxHolders = holders;
              await Future<void>.delayed(Duration.zero);
            } finally {
              holders--;
              lock.close();
            }
          }),
        );
        expect(maxHolders, 1);
        await held.verifyPathBinding();
        expect(
          (await File('${directory.path}/shared.lock').stat()).mode & 0x1ff,
          0x180,
        );
      } finally {
        held.close();
      }
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
