import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File source;
  late Directory destination;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('gaovm-apfs-clone-');
    source = await File(
      '${temporary.path}/source.img',
    ).writeAsString('source blocks');
    imageFileMode(source.path, 0x1a4);
    destination = await Directory('${temporary.path}/destination').create();
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'APFS clone is private and preserves source permissions',
    () async {
      final ownedSource = await OwnedImageFile.open(source);
      final ownedDestination = await OwnedImageDirectory.open(destination);
      try {
        expect(
          await ownedSource.tryCloneTo(ownedDestination, 'disk.img'),
          isTrue,
        );
      } finally {
        ownedSource.close();
        ownedDestination.close();
      }

      final clone = File('${destination.path}/disk.img');
      expect(await clone.readAsString(), 'source blocks');
      expect((await source.stat()).mode & 0x1ff, 0x1a4);
      expect((await clone.stat()).mode & 0x1ff, 0x180);

      await clone.writeAsString('clone changed');
      expect(await source.readAsString(), 'source blocks');
      await source.writeAsString('source changed');
      expect(await clone.readAsString(), 'clone changed');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'existing destination is a hard failure and is not overwritten',
    () async {
      final existing = await File(
        '${destination.path}/disk.img',
      ).writeAsString('keep me');
      final ownedSource = await OwnedImageFile.open(source);
      final ownedDestination = await OwnedImageDirectory.open(destination);
      try {
        await expectLater(
          ownedSource.tryCloneTo(ownedDestination, 'disk.img'),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        ownedSource.close();
        ownedDestination.close();
      }

      expect(await existing.readAsString(), 'keep me');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'clone stays bound when the source pathname is replaced',
    () async {
      final ownedSource = await OwnedImageFile.open(source);
      final ownedDestination = await OwnedImageDirectory.open(destination);
      await source.rename('${source.path}.held');
      final replacement = await File(source.path).writeAsString('replacement');
      try {
        expect(
          await ownedSource.tryCloneTo(ownedDestination, 'disk.img'),
          isTrue,
        );
      } finally {
        ownedSource.close();
        ownedDestination.close();
      }

      expect(
        await File('${destination.path}/disk.img').readAsString(),
        'source blocks',
      );
      expect(await replacement.readAsString(), 'replacement');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'clone stays bound when the destination pathname is replaced',
    () async {
      final ownedSource = await OwnedImageFile.open(source);
      final ownedDestination = await OwnedImageDirectory.open(destination);
      final heldDestination = Directory('${destination.path}.held');
      await destination.rename(heldDestination.path);
      await destination.create();
      try {
        expect(
          await ownedSource.tryCloneTo(ownedDestination, 'disk.img'),
          isTrue,
        );
      } finally {
        ownedSource.close();
        ownedDestination.close();
      }

      expect(
        await File('${heldDestination.path}/disk.img').readAsString(),
        'source blocks',
      );
      expect(await destination.list().toList(), isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  test('clone child must be exactly one basename', () async {
    final ownedSource = await OwnedImageFile.open(source);
    final ownedDestination = await OwnedImageDirectory.open(destination);
    try {
      for (final name in ['', '.', '..', 'nested/disk', 'disk\u0000suffix']) {
        await expectLater(
          ownedSource.tryCloneTo(ownedDestination, name),
          throwsArgumentError,
          reason: name,
        );
      }
    } finally {
      ownedSource.close();
      ownedDestination.close();
    }
    expect(await destination.list().toList(), isEmpty);
  });

  test('closed source or destination handles reject cloning', () async {
    final closedSource = await OwnedImageFile.open(source);
    final openDestination = await OwnedImageDirectory.open(destination);
    closedSource.close();
    try {
      await expectLater(
        closedSource.tryCloneTo(openDestination, 'source-closed.img'),
        throwsStateError,
      );
    } finally {
      openDestination.close();
    }

    final openSource = await OwnedImageFile.open(source);
    final closedDestination = await OwnedImageDirectory.open(destination);
    closedDestination.close();
    try {
      await expectLater(
        openSource.tryCloneTo(closedDestination, 'destination-closed.img'),
        throwsStateError,
      );
    } finally {
      openSource.close();
    }
    expect(await destination.list().toList(), isEmpty);
  });

  test(
    'clone keeps independent descriptors across the isolate await',
    () async {
      final ownedSource = await OwnedImageFile.open(source);
      final ownedDestination = await OwnedImageDirectory.open(destination);

      final clone = ownedSource.tryCloneTo(ownedDestination, 'disk.img');
      ownedSource.close();
      ownedDestination.close();

      expect(await clone, isTrue);
      expect(
        await File('${destination.path}/disk.img').readAsString(),
        'source blocks',
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'Linux reports clone fallback without creating a destination',
    () async {
      final ownedSource = await OwnedImageFile.open(source);
      final ownedDestination = await OwnedImageDirectory.open(destination);
      try {
        expect(
          await ownedSource.tryCloneTo(ownedDestination, 'disk.img'),
          isFalse,
        );
      } finally {
        ownedSource.close();
        ownedDestination.close();
      }
      expect(await destination.list().toList(), isEmpty);
    },
    skip: !Platform.isLinux,
  );

  test(
    'created output remains anchored when destination path is replaced',
    () async {
      final ownedDestination = await OwnedImageDirectory.open(destination);
      final heldDestination = Directory('${destination.path}.held');
      await destination.rename(heldDestination.path);
      await destination.create();

      final output = ownedDestination.createFile('disk.img');
      try {
        final writer = await output.openWrite();
        await writer.writeString('copied blocks');
        await writer.flush();
        await writer.close();
        await ownedDestination.sync();
      } finally {
        output.close();
        ownedDestination.close();
      }

      final created = File('${heldDestination.path}/disk.img');
      expect(await created.readAsString(), 'copied blocks');
      expect((await created.stat()).mode & 0x1ff, 0x180);
      expect(await destination.list().toList(), isEmpty);
    },
  );

  test('output creation never overwrites an existing child', () async {
    final existing = await File(
      '${destination.path}/disk.img',
    ).writeAsString('keep me');
    final ownedDestination = await OwnedImageDirectory.open(destination);
    try {
      expect(
        () => ownedDestination.createFile('disk.img'),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      ownedDestination.close();
    }
    expect(await existing.readAsString(), 'keep me');
  });

  test('output removal stays anchored to the owned directory', () async {
    await File('${destination.path}/disk.img').writeAsString('owned child');
    final ownedDestination = await OwnedImageDirectory.open(destination);
    final heldDestination = Directory('${destination.path}.held');
    await destination.rename(heldDestination.path);
    await destination.create();
    final replacement = await File(
      '${destination.path}/disk.img',
    ).writeAsString('replacement child');
    try {
      ownedDestination.removeFile('disk.img');
      await ownedDestination.sync();
    } finally {
      ownedDestination.close();
    }

    expect(await File('${heldDestination.path}/disk.img').exists(), isFalse);
    expect(await replacement.readAsString(), 'replacement child');
  });

  test(
    'output writer remains bound when its child pathname is replaced',
    () async {
      final ownedDestination = await OwnedImageDirectory.open(destination);
      final output = ownedDestination.createFile('disk.img');
      final heldOutput = File('${destination.path}/disk-held.img');
      await File('${destination.path}/disk.img').rename(heldOutput.path);
      final replacement = await File(
        '${destination.path}/disk.img',
      ).writeAsString('replacement');
      try {
        final writer = await output.openWrite();
        await writer.writeString('owned output');
        await writer.flush();
        await writer.close();
        await ownedDestination.sync();
      } finally {
        output.close();
        ownedDestination.close();
      }

      expect(await heldOutput.readAsString(), 'owned output');
      expect(await replacement.readAsString(), 'replacement');
    },
  );

  test('output helpers reject invalid names and closed handles', () async {
    final ownedDestination = await OwnedImageDirectory.open(destination);
    for (final name in ['', '.', '..', 'nested/disk', 'disk\u0000suffix']) {
      expect(
        () => ownedDestination.createFile(name),
        throwsArgumentError,
        reason: name,
      );
      expect(
        () => ownedDestination.removeFile(name),
        throwsArgumentError,
        reason: name,
      );
    }
    final output = ownedDestination.createFile('disk.img');
    output.close();
    expect(output.openWrite, throwsStateError);
    ownedDestination.close();
    expect(
      () => ownedDestination.createFile('closed-create.img'),
      throwsStateError,
    );
    expect(() => ownedDestination.removeFile('disk.img'), throwsStateError);
    await expectLater(ownedDestination.sync(), throwsStateError);
  });

  test('directory sync keeps an independent descriptor across await', () async {
    final ownedDestination = await OwnedImageDirectory.open(destination);
    final synced = ownedDestination.sync();
    ownedDestination.close();
    await synced;
  });

  test(
    'available bytes stays bound after the directory path is moved',
    () async {
      final ownedDestination = await OwnedImageDirectory.open(destination);
      await destination.rename('${destination.path}.held');

      final available = ownedDestination.availableBytes();
      ownedDestination.close();

      expect(await available, greaterThan(0));
      expect(await destination.exists(), isFalse);
    },
  );
}
