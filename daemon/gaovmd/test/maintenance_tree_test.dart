import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async {
    final created = await Directory.systemTemp.createTemp(
      'gvm-maintenance-tree-',
    );
    root = Directory(await created.resolveSymbolicLinks());
    imageFileMode(root.path, 0x1c0);
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'read-only tree capture binds every regular file and empty directory',
    () async {
      await Directory('${root.path}/empty').create();
      imageFileMode('${root.path}/empty', 0x1c0);
      final file = File('${root.path}/unknown.bin');
      final bytes = [0, 1, 255];
      await file.writeAsBytes(bytes);
      imageFileMode(file.path, 0x180);
      final tree = await MaintenanceTree.open(root);
      try {
        expect(await tree.capture(), {
          '': {'kind': 'directory', 'mode': 0x1c0},
          'empty': {'kind': 'directory', 'mode': 0x1c0},
          'unknown.bin': {
            'kind': 'file',
            'mode': 0x180,
            'size': bytes.length,
            'digest': 'sha256:${sha256.convert(bytes)}',
          },
        });
        expect(
          await root
              .list()
              .map(
                (entry) => entry.uri.pathSegments
                    .where((part) => part.isNotEmpty)
                    .last,
              )
              .toList(),
          unorderedEquals(['empty', 'unknown.bin']),
        );
        expect(await file.readAsBytes(), bytes);
      } finally {
        tree.close();
      }
    },
  );

  test(
    'verification refuses changed bytes, modes, added and missing entries',
    () async {
      final file = File('${root.path}/disk');
      await file.writeAsString('pre-upgrade bytes');
      imageFileMode(file.path, 0x180);
      final tree = await MaintenanceTree.open(root);
      try {
        final manifest = await tree.capture();
        await tree.verify(manifest);
        await file.writeAsString('post-upgrade byte');
        await expectLater(tree.verify(manifest), throwsFormatException);
        await file.writeAsString('pre-upgrade bytes');
        imageFileMode(file.path, 0x100);
        await expectLater(tree.verify(manifest), throwsFormatException);
        imageFileMode(file.path, 0x180);
        final unexpected = await Directory('${root.path}/unknown').create();
        imageFileMode(unexpected.path, 0x1c0);
        await expectLater(tree.verify(manifest), throwsFormatException);
        await unexpected.delete();
        await file.delete();
        await expectLater(tree.verify(manifest), throwsFormatException);
      } finally {
        tree.close();
      }
    },
  );

  test(
    'links and writable-by-other-user entries never produce a manifest',
    () async {
      final file = File('${root.path}/disk');
      await file.writeAsString('external bytes');
      imageFileMode(file.path, 0x180);
      final tree = await MaintenanceTree.open(root);
      try {
        final link = await Link('${root.path}/link').create(file.path);
        await expectLater(tree.capture(), throwsFormatException);
        await link.delete();
        imageFileMode(file.path, 0x190);
        await expectLater(tree.capture(), throwsFormatException);
        imageFileMode(file.path, 0x180);
        await Directory('${root.path}/shared').create();
        imageFileMode('${root.path}/shared', 0x1d0);
        await expectLater(tree.capture(), throwsFormatException);
      } finally {
        tree.close();
      }
    },
  );

  test('held tree refuses a substituted root inode', () async {
    final original = await Directory('${root.path}/source').create();
    imageFileMode(original.path, 0x1c0);
    final tree = await MaintenanceTree.open(original);
    try {
      final manifest = await tree.capture();
      await original.rename('${root.path}/retained');
      await Directory(original.path).create();
      imageFileMode(original.path, 0x1c0);
      await expectLater(
        tree.verify(manifest),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      tree.close();
    }
  });

  test(
    'hardlinks and named pipes cannot enter a maintenance manifest',
    () async {
      final file = File('${root.path}/disk');
      await file.writeAsString('retained bytes');
      imageFileMode(file.path, 0x180);
      final tree = await MaintenanceTree.open(root);
      try {
        expect(
          (await runMaintenanceCommand('/bin/ln', [
            file.path,
            '${root.path}/linked',
          ])).exitCode,
          0,
        );
        await expectLater(tree.capture(), throwsFormatException);
        await File('${root.path}/linked').delete();
        expect(
          (await runMaintenanceCommand('/usr/bin/mkfifo', [
            '${root.path}/pipe',
          ])).exitCode,
          0,
        );
        await expectLater(tree.capture(), throwsFormatException);
        expect(await file.readAsString(), 'retained bytes');
      } finally {
        tree.close();
      }
    },
  );
}
