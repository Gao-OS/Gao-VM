import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory source;
  late OwnedImageDirectory parent;
  late MaintenanceTree tree;
  setUp(() async {
    final created = await Directory.systemTemp.createTemp('gvm-tree-snapshot-');
    temporary = Directory(await created.resolveSymbolicLinks());
    imageFileMode(temporary.path, 0x1c0);
    source = await Directory('${temporary.path}/state').create();
    imageFileMode(source.path, 0x1c0);
    for (final name in [
      'gaovm.db',
      'gaovm.db-wal',
      'gaovm.db-shm',
      'unknown',
    ]) {
      await File('${source.path}/$name').writeAsString('retained $name');
      imageFileMode('${source.path}/$name', 0x180);
    }
    await Directory('${source.path}/empty').create();
    imageFileMode('${source.path}/empty', 0x140);
    parent = await OwnedImageDirectory.open(temporary);
    tree = await MaintenanceTree.open(source);
  });
  tearDown(() async {
    tree.close();
    parent.close();
    await temporary.delete(recursive: true);
  });

  test(
    'complete tree snapshots preserve unknown entries and native metadata durably',
    () async {
      final before = await tree.capture(nativeMetadata: true);
      final receipt = await tree.snapshotTo(parent, 'before-upgrade');
      expect(receipt['format'], 'gaovm.tree-snapshot.v1');
      final saved = Directory('${parent.path}/before-upgrade/payload');
      final copied = await MaintenanceTree.open(saved);
      try {
        expect(await copied.capture(nativeMetadata: true), before);
        await tree.verify(before, nativeMetadata: true);
        expect(
          await File('${saved.path}/unknown').readAsString(),
          'retained unknown',
        );
        expect(await Directory('${saved.path}/empty').list().length, 0);
      } finally {
        copied.close();
      }
      expect(
        await Directory('${parent.path}/.before-upgrade.partial').exists(),
        isFalse,
      );
      expect(
        jsonDecode(
          await File(
            '${parent.path}/before-upgrade/receipt.json',
          ).readAsString(),
        ),
        receipt,
      );
      expect(
        (await Directory('${parent.path}/before-upgrade').stat()).mode & 0x3f,
        0,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'directory xattrs and ACLs and file flags are verified in snapshots',
    () async {
      final user = (await command('/usr/bin/id', [
        '-un',
      ])).stdout.toString().trim();
      for (final path in [source.path, '${source.path}/empty']) {
        imageFileMode(path, 0x1c0);
        await command('/usr/bin/xattr', [
          '-wx',
          'org.gaovm.directory',
          '00ff01',
          path,
        ]);
        await command('/bin/chmod', ['+a', 'user:$user allow read', path]);
      }
      imageFileMode('${source.path}/empty', 0x140);
      await command('/usr/bin/chflags', ['nodump', '${source.path}/unknown']);
      final before = await tree.capture(nativeMetadata: true);
      expect(((before[''] as Map)['metadata'] as Map)['has_acl'], isTrue);
      expect(((before['unknown'] as Map)['metadata'] as Map)['flags'], 1);
      await tree.snapshotTo(parent, 'metadata');
      final saved = await MaintenanceTree.open(
        Directory('${parent.path}/metadata/payload'),
      );
      try {
        expect(await saved.capture(nativeMetadata: true), before);
        await tree.verify(before, nativeMetadata: true);
      } finally {
        saved.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'native metadata failure retains partial output and all source bytes',
    () async {
      final user = (await command('/usr/bin/id', [
        '-un',
      ])).stdout.toString().trim();
      // Reading is permitted, but the copied ACL denies the native metadata write.
      await command('/bin/chmod', [
        '+a',
        'user:$user deny writeattr',
        '${source.path}/unknown',
      ]);
      final before = await tree.capture(nativeMetadata: true);
      await expectLater(
        tree.snapshotTo(parent, 'failed'),
        throwsA(
          isA<MaintenanceSnapshotFailure>()
              .having(
                (failure) => failure.stagingPath,
                'retained staging',
                '${parent.path}/.failed.partial',
              )
              .having(
                (failure) => failure.snapshotPath,
                'unused final',
                '${parent.path}/failed',
              )
              .having(
                (failure) => failure.cause,
                'native failure',
                isA<FileSystemException>(),
              ),
        ),
      );
      expect(await Directory('${parent.path}/failed').exists(), isFalse);
      expect(
        await File(
          '${parent.path}/.failed.partial/payload/unknown',
        ).readAsString(),
        'retained unknown',
      );
      await tree.verify(before, nativeMetadata: true);
      // A retry never removes or reuses the retained failed generation.
      await expectLater(
        tree.snapshotTo(parent, 'failed'),
        throwsFormatException,
      );
      expect(
        await File(
          '${parent.path}/.failed.partial/payload/unknown',
        ).readAsString(),
        'retained unknown',
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'closed SQLite database and retained WAL sidecars are copied together',
    () async {
      for (final name in ['gaovm.db', 'gaovm.db-wal', 'gaovm.db-shm']) {
        await File('${source.path}/$name').delete();
      }
      await command('/usr/bin/sqlite3', [
        '${source.path}/gaovm.db',
        'PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;',
        '.filectrl persist_wal 1',
        '.dbconfig no_ckpt_on_close on',
        'CREATE TABLE evidence (id TEXT PRIMARY KEY, payload TEXT NOT NULL); '
            "INSERT INTO evidence VALUES ('kept-id', 'committed WAL bytes'); "
            'PRAGMA user_version=21;',
      ]);
      for (final name in ['gaovm.db', 'gaovm.db-wal', 'gaovm.db-shm']) {
        expect(
          await File('${source.path}/$name').length(),
          greaterThan(0),
          reason: name,
        );
        imageFileMode('${source.path}/$name', 0x180);
      }
      final before = await tree.capture(nativeMetadata: true);
      await tree.snapshotTo(parent, 'sqlite');
      final saved = '${parent.path}/sqlite/payload/gaovm.db';
      final result = await command('/usr/bin/sqlite3', [
        '-readonly',
        saved,
        'PRAGMA integrity_check; PRAGMA foreign_key_check; PRAGMA user_version; '
            'SELECT id, payload FROM evidence;',
      ]);
      expect(result.stdout, 'ok\n21\nkept-id|committed WAL bytes\n');
      // Only the copy was opened. Inspection must not migrate/checkpoint inputs.
      await tree.verify(before, nativeMetadata: true);
    },
    skip: !Platform.isMacOS,
  );

  for (final name in ['occupied', '.occupied.partial']) {
    for (final directory in [false, true]) {
      test(
        'existing ${directory ? 'directory' : 'file'} $name is never overwritten',
        () async {
          final path = '${parent.path}/$name';
          if (directory) {
            await Directory(path).create();
            imageFileMode(path, 0x1c0);
          }
          final retained = File(directory ? '$path/retained' : path);
          await retained.writeAsString('operator-owned bytes');
          imageFileMode(retained.path, 0x180);
          final before = await tree.capture(nativeMetadata: true);
          await expectLater(
            tree.snapshotTo(parent, 'occupied'),
            directory
                ? throwsFormatException
                : throwsA(isA<FileSystemException>()),
          );
          expect(await retained.readAsString(), 'operator-owned bytes');
          await tree.verify(before, nativeMetadata: true);
          expect(
            await File('${parent.path}/.gaovm-maintenance.lock').exists(),
            isFalse,
          );
        },
        skip: !Platform.isMacOS,
      );
    }
  }

  test(
    'snapshot namespace contention refuses without staging or source mutation',
    () async {
      final held = await parent.tryAcquireLock('.gaovm-maintenance.lock');
      expect(held, isNotNull);
      final before = await tree.capture(nativeMetadata: true);
      try {
        await expectLater(tree.snapshotTo(parent, 'busy'), throwsStateError);
        expect(
          await Directory('${parent.path}/.busy.partial').exists(),
          isFalse,
        );
        await tree.verify(before, nativeMetadata: true);
      } finally {
        held!.close();
      }
      await tree.snapshotTo(parent, 'busy');
      expect(await File('${parent.path}/busy/receipt.json').exists(), isTrue);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'overlapping source and destination refuse before creating staging',
    () async {
      final input = await OwnedImageDirectory.open(source);
      try {
        await expectLater(
          tree.snapshotTo(input, 'nested'),
          throwsFormatException,
        );
        expect(
          await Directory('${source.path}/.nested.partial').exists(),
          isFalse,
        );
        expect(
          await File('${source.path}/.gaovm-maintenance.lock').exists(),
          isFalse,
        );
      } finally {
        input.close();
      }
      await expectLater(
        tree.snapshotTo(parent, 'state'),
        throwsFormatException,
      );
      expect(
        await File('${source.path}/unknown').readAsString(),
        'retained unknown',
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'snapshot storage rejects group access and ACL grants before copying',
    () async {
      final before = await tree.capture(nativeMetadata: true);
      try {
        imageFileMode(parent.path, 0x1d0);
        await expectLater(
          tree.snapshotTo(parent, 'shared'),
          throwsFormatException,
        );
        imageFileMode(parent.path, 0x1c0);
        final user = (await command('/usr/bin/id', [
          '-un',
        ])).stdout.toString().trim();
        await command('/bin/chmod', [
          '+a',
          'user:$user allow read',
          parent.path,
        ]);
        await expectLater(
          tree.snapshotTo(parent, 'shared'),
          throwsFormatException,
        );
      } finally {
        imageFileMode(parent.path, 0x1c0);
        await command('/bin/chmod', ['-N', parent.path]);
      }
      await tree.verify(before, nativeMetadata: true);
      expect(
        await Directory('${parent.path}/.shared.partial').exists(),
        isFalse,
      );
      expect(
        await File('${parent.path}/.gaovm-maintenance.lock').exists(),
        isFalse,
      );
    },
    skip: !Platform.isMacOS,
  );

  test('a substituted snapshot parent never receives output', () async {
    final folder = await Directory('${temporary.path}/storage').create();
    imageFileMode(folder.path, 0x1c0);
    final held = await OwnedImageDirectory.open(folder);
    try {
      await folder.rename('${temporary.path}/retained-storage');
      await folder.create();
      imageFileMode(folder.path, 0x1c0);
      await expectLater(
        tree.snapshotTo(held, 'replaced'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await folder.list().toList(), isEmpty);
      expect(
        await Directory('${temporary.path}/retained-storage').list().toList(),
        isEmpty,
      );
      expect(
        await File('${source.path}/unknown').readAsString(),
        'retained unknown',
      );
    } finally {
      held.close();
    }
  }, skip: !Platform.isMacOS);

  test(
    'metadata-only source changes invalidate native evidence',
    () async {
      final before = await tree.capture(nativeMetadata: true);
      await command('/usr/bin/xattr', [
        '-wx',
        'org.gaovm.changed',
        '0001',
        '${source.path}/unknown',
      ]);
      await expectLater(
        tree.verify(before, nativeMetadata: true),
        throwsFormatException,
      );
      expect(
        await File('${source.path}/unknown').readAsString(),
        'retained unknown',
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'app payload keeps its extension and modes behind private storage',
    () async {
      final app = await Directory('${temporary.path}/GaoVM.app').create();
      imageFileMode(app.path, 0x1ed);
      await File(
        '${app.path}/executable',
      ).writeAsString('component fixture only');
      imageFileMode('${app.path}/executable', 0x1ed);
      final input = await MaintenanceTree.open(app);
      try {
        final before = await input.capture(nativeMetadata: true);
        final receipt = await input.snapshotTo(parent, 'app');
        expect(receipt['payload_name'], 'payload.app');
        final saved = await MaintenanceTree.open(
          Directory('${parent.path}/app/payload.app'),
        );
        try {
          expect(await saved.capture(nativeMetadata: true), before);
        } finally {
          saved.close();
        }
        expect(
          (await Directory('${parent.path}/app').stat()).mode & 0xfff,
          0x1c0,
        );
        await input.verify(before, nativeMetadata: true);
      } finally {
        input.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'an unknown namespace lock is refused without changing its mode',
    () async {
      final foreign = await File(
        '${parent.path}/.gaovm-maintenance.lock',
      ).writeAsString('');
      imageFileMode(foreign.path, 0x1c0);
      await expectLater(
        tree.snapshotTo(parent, 'foreign-lock'),
        throwsFormatException,
      );
      expect((await foreign.stat()).mode & 0xfff, 0x1c0);
      expect(
        await Directory('${parent.path}/.foreign-lock.partial').exists(),
        isFalse,
      );
      expect(
        await File('${source.path}/unknown').readAsString(),
        'retained unknown',
      );
    },
    skip: !Platform.isMacOS,
  );

  for (final hardlink in [false, true]) {
    test(
      'namespace lock with ${hardlink ? 'extra hardlinks' : 'data'} is retained untouched',
      () async {
        final foreign = await File(
          '${parent.path}/operator-file',
        ).writeAsString(hardlink ? '' : 'operator bytes');
        imageFileMode(foreign.path, 0x180);
        final lockPath = '${parent.path}/.gaovm-maintenance.lock';
        if (hardlink) {
          await command('/bin/ln', [foreign.path, lockPath]);
        } else {
          await foreign.rename(lockPath);
        }
        await expectLater(
          tree.snapshotTo(parent, 'invalid-lock'),
          throwsFormatException,
        );
        expect(
          await File(lockPath).readAsString(),
          hardlink ? '' : 'operator bytes',
        );
        expect((await File(lockPath).stat()).mode & 0xfff, 0x180);
        expect(
          await Directory('${parent.path}/.invalid-lock.partial').exists(),
          isFalse,
        );
        if (hardlink) expect(await foreign.readAsString(), '');
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'snapshot name cannot collide with the persistent namespace lock',
    () async {
      await expectLater(
        tree.snapshotTo(parent, '.gaovm-maintenance.lock'),
        throwsArgumentError,
      );
      expect(
        await File('${parent.path}/.gaovm-maintenance.lock').exists(),
        isFalse,
      );
      expect(
        await Directory(
          '${parent.path}/..gaovm-maintenance.lock.partial',
        ).exists(),
        isFalse,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'zero-byte ownership records copy without transferring the source lock',
    () async {
      final original = await OwnedImageDirectory.open(source);
      OwnedImageLock? sourceLock;
      try {
        sourceLock = await original.tryAcquireLock('.gaovmd.lock');
        expect(sourceLock, isNotNull);
        final before = await tree.capture(nativeMetadata: true);
        expect((before['.gaovmd.lock'] as Map)['size'], 0);
        await tree.snapshotTo(parent, 'held-state');
        final contender = await original.tryAcquireLock('.gaovmd.lock');
        try {
          expect(contender, isNull);
        } finally {
          contender?.close();
        }
        final saved = await OwnedImageDirectory.open(
          Directory('${parent.path}/held-state/payload'),
        );
        OwnedImageLock? copiedLock;
        try {
          copiedLock = await saved.tryAcquireLock('.gaovmd.lock');
          expect(copiedLock, isNotNull);
          await tree.verify(before, nativeMetadata: true);
        } finally {
          copiedLock?.close();
          saved.close();
        }
      } finally {
        sourceLock?.close();
        original.close();
      }
    },
    skip: !Platform.isMacOS,
  );
}

Future<ProcessResult> command(String executable, List<String> arguments) async {
  final result = await runMaintenanceCommand(executable, arguments);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return result;
}
