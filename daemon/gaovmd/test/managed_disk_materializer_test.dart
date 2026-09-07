import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/managed_disk_materializer.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File base;
  late OwnedImageFile source;
  late OwnedImageDirectory target;
  final bytes = List<int>.generate(128 * 1024, (index) => index % 251);
  final digest = 'sha256:${sha256.convert(bytes)}';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('disk-materialize-');
    base = await File(
      '${directory.path}/base',
    ).writeAsBytes(bytes, flush: true);
    source = await OwnedImageFile.open(base);
    final destination = await Directory('${directory.path}/stage').create();
    target = await OwnedImageDirectory.open(destination);
  });
  tearDown(() async {
    target.close();
    source.close();
    await directory.delete(recursive: true);
  });

  test('fallback creates an isolated disk from the pinned source', () async {
    final materializer = ManagedDiskMaterializer(
      clone: (_, __, ___) async => false,
      availableBytes: (_) async => 2 * 1024 * 1024,
    );
    final result = await materializer.materialize(
      source: source,
      destination: target,
      name: 'root.raw',
      expectedSize: bytes.length,
      expectedDigest: digest,
    );
    expect(result.cloned, isFalse);
    expect(result.bytes, bytes.length);
    final disk = File('${target.path}/root.raw');
    expect(await disk.readAsBytes(), bytes);
    final writer = await disk.open(mode: FileMode.writeOnly);
    await writer.writeByte(99);
    await writer.close();
    expect(await base.readAsBytes(), bytes);
  });

  test('digest mismatch removes only the newly materialized child', () async {
    final preserved = await File(
      '${target.path}/preserved',
    ).writeAsString('keep');
    final materializer = ManagedDiskMaterializer(
      clone: (_, __, ___) async => false,
      availableBytes: (_) async => 2 * 1024 * 1024,
    );
    await expectLater(
      materializer.materialize(
        source: source,
        destination: target,
        name: 'root.raw',
        expectedSize: bytes.length,
        expectedDigest: 'sha256:${'0' * 64}',
      ),
      throwsFormatException,
    );
    expect(await File('${target.path}/root.raw').exists(), isFalse);
    expect(await preserved.readAsString(), 'keep');
    expect(await base.readAsBytes(), bytes);
  });

  test(
    'cancellation during copy removes partial output and preserves source',
    () async {
      var cancelled = false;
      final materializer = ManagedDiskMaterializer(
        clone: (_, __, ___) async => false,
        availableBytes: (_) async => 2 * 1024 * 1024,
      );
      await expectLater(
        materializer.materialize(
          source: source,
          destination: target,
          name: 'root.raw',
          expectedSize: bytes.length,
          expectedDigest: digest,
          isCancelled: () => cancelled,
          onProgress: (_) => cancelled = true,
        ),
        throwsA(isA<ManagedDiskCancelled>()),
      );
      expect(await File('${target.path}/root.raw').exists(), isFalse);
      expect(await base.readAsBytes(), bytes);
    },
  );

  test('cancellation at clone completion removes the cloned output', () async {
    var cancelled = false;
    final materializer = ManagedDiskMaterializer(
      clone: (_, destination, name) async {
        final output = destination.createFile(name);
        try {
          final writer = await output.openWrite();
          try {
            await writer.writeFrom(bytes);
            await writer.flush();
          } finally {
            await writer.close();
          }
        } finally {
          output.close();
        }
        return true;
      },
      availableBytes: (_) async => 2 * 1024 * 1024,
    );
    await expectLater(
      materializer.materialize(
        source: source,
        destination: target,
        name: 'root.raw',
        expectedSize: bytes.length,
        expectedDigest: digest,
        isCancelled: () => cancelled,
        onProgress: (_) => cancelled = true,
      ),
      throwsA(isA<ManagedDiskCancelled>()),
    );
    expect(await File('${target.path}/root.raw').exists(), isFalse);
    expect(await base.readAsBytes(), bytes);
  });

  test('low space fails before cloning or creating output', () async {
    var attempted = false;
    final materializer = ManagedDiskMaterializer(
      clone: (_, __, ___) async {
        attempted = true;
        return false;
      },
      availableBytes: (_) async => bytes.length,
    );
    await expectLater(
      materializer.materialize(
        source: source,
        destination: target,
        name: 'root.raw',
        expectedSize: bytes.length,
        expectedDigest: digest,
      ),
      throwsA(isA<ManagedDiskInsufficientSpace>()),
    );
    expect(attempted, isFalse);
    expect(await Directory(target.path).list().toList(), isEmpty);
  });

  test(
    'default clone/copy remains bound across source and destination path swaps',
    () async {
      final moved = '${directory.path}/moved-stage';
      final materializer = ManagedDiskMaterializer(
        availableBytes: (_) async {
          await base.rename('${directory.path}/original-base');
          await base.writeAsString('replacement');
          await Directory(target.path).rename(moved);
          await Directory(target.path).create();
          return 2 * 1024 * 1024;
        },
      );
      final result = await materializer.materialize(
        source: source,
        destination: target,
        name: 'root.raw',
        expectedSize: bytes.length,
        expectedDigest: digest,
      );
      expect(result.bytes, bytes.length);
      expect(await File('$moved/root.raw').readAsBytes(), bytes);
      expect(await Directory(target.path).list().toList(), isEmpty);
      expect(await base.readAsString(), 'replacement');
      expect(
        await File('${directory.path}/original-base').readAsBytes(),
        bytes,
      );
    },
  );

  test('an existing destination survives fallback creation failure', () async {
    final existing = await File(
      '${target.path}/root.raw',
    ).writeAsString('keep');
    final materializer = ManagedDiskMaterializer(
      clone: (_, __, ___) async => false,
      availableBytes: (_) async => 2 * 1024 * 1024,
    );
    await expectLater(
      materializer.materialize(
        source: source,
        destination: target,
        name: 'root.raw',
        expectedSize: bytes.length,
        expectedDigest: digest,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await existing.readAsString(), 'keep');
    expect(await base.readAsBytes(), bytes);
  });

  test(
    'default capacity check uses the moved destination descriptor',
    () async {
      final moved = '${directory.path}/moved-stage';
      await Directory(target.path).rename(moved);
      final result = await ManagedDiskMaterializer().materialize(
        source: source,
        destination: target,
        name: 'root.raw',
        expectedSize: bytes.length,
        expectedDigest: digest,
      );
      expect(result.bytes, bytes.length);
      expect(await File('$moved/root.raw').readAsBytes(), bytes);
      expect(
        await FileSystemEntity.type(target.path),
        FileSystemEntityType.notFound,
      );
    },
  );
}
