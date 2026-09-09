import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('runtime-path-binding-');
  });
  tearDown(() async => temporary.delete(recursive: true));

  test(
    'unchanged directory and file paths identify their held descriptors',
    () async {
      final directory = await OwnedImageDirectory.open(temporary);
      final file = await OwnedImageFile.open(
        await File('${temporary.path}/disk').writeAsString('disk'),
      );
      try {
        await directory.verifyPathBinding();
        await file.verifyPathBinding();
      } finally {
        file.close();
        directory.close();
      }
    },
  );

  for (final symlink in [false, true]) {
    test(
      'replaced parent pathname rejects directory and file bindings (symlink=$symlink)',
      () async {
        final root = await Directory('${temporary.path}/root').create();
        final child = await Directory('${root.path}/child').create();
        await File('${child.path}/disk').writeAsString('original');
        final directory = await OwnedImageDirectory.open(root);
        final nested = directory.directory('child');
        final file = nested.file('disk');
        try {
          await root.rename('${temporary.path}/retained');
          final replacement = await Directory(
            '${temporary.path}/replacement/child',
          ).create(recursive: true);
          await File('${replacement.path}/disk').writeAsString('replacement');
          if (symlink) {
            await Link(root.path).create('${temporary.path}/replacement');
          } else {
            await Directory('${temporary.path}/replacement').rename(root.path);
          }
          await expectLater(
            directory.verifyPathBinding(),
            throwsA(isA<FileSystemException>()),
          );
          await expectLater(
            nested.verifyPathBinding(),
            throwsA(isA<FileSystemException>()),
          );
          await expectLater(
            file.verifyPathBinding(),
            throwsA(isA<FileSystemException>()),
          );
          expect(
            await file.openRead().expand((bytes) => bytes).toList(),
            'original'.codeUnits,
          );
        } finally {
          file.close();
          nested.close();
          directory.close();
        }
      },
    );
  }

  for (final symlink in [false, true]) {
    test('replaced file pathname rejects binding (symlink=$symlink)', () async {
      final original = await File(
        '${temporary.path}/disk',
      ).writeAsString('original');
      final file = await OwnedImageFile.open(original);
      try {
        await original.rename('${temporary.path}/retained');
        if (symlink) {
          final replacement = await File(
            '${temporary.path}/replacement',
          ).writeAsString('replacement');
          await Link(original.path).create(replacement.path);
        } else {
          await original.writeAsString('replacement');
        }
        await expectLater(
          file.verifyPathBinding(),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        file.close();
      }
    });
  }

  test(
    'closed descriptors reject pathname verification and mode reads',
    () async {
      final directory = await OwnedImageDirectory.open(temporary);
      final file = await OwnedImageFile.open(
        await File('${temporary.path}/disk').writeAsString('disk'),
      );
      file.close();
      directory.close();
      await expectLater(file.verifyPathBinding(), throwsStateError);
      await expectLater(directory.verifyPathBinding(), throwsStateError);
      expect(() => directory.mode, throwsStateError);
    },
  );

  test(
    'directory mode stays bound to held inode after pathname replacement',
    () async {
      final root = await Directory('${temporary.path}/root').create();
      imageFileMode(root.path, 0x1c0);
      final directory = await OwnedImageDirectory.open(root);
      try {
        expect(directory.mode & 0x1ff, 0x1c0);
        await root.rename('${temporary.path}/retained');
        await root.create();
        imageFileMode(root.path, 0x1ed);
        expect(directory.mode & 0x1ff, 0x1c0);
        expect(directory.mode & 0x3f, 0);
        await expectLater(
          directory.verifyPathBinding(),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        directory.close();
      }
    },
  );
}
