import 'dart:io';

import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late OwnedImageDirectory sourceParent;
  late OwnedImageDirectory destinationParent;
  late OwnedImageDirectory source;
  var activeMoves = 0, retainInputs = false;
  Future<T> moving<T>(Future<T> operation) async {
    activeMoves++;
    try {
      return await operation;
    } finally {
      activeMoves--;
    }
  }

  Future<ProcessResult> command(
    String executable,
    List<String> arguments,
  ) async {
    try {
      return await runMaintenanceCommand(executable, arguments);
    } on MaintenanceCommandFailure catch (error) {
      if (!error.exitConfirmed) retainInputs = true;
      rethrow;
    }
  }

  setUp(() async {
    activeMoves = 0;
    retainInputs = false;
    final created = await Directory.systemTemp.createTemp(
      'gvm-maintenance-move-',
    );
    temporary = Directory(await created.resolveSymbolicLinks());
    imageFileMode(temporary.path, 0x1c0);
    for (final name in ['private-staging', 'applications']) {
      final directory = await Directory('${temporary.path}/$name').create();
      imageFileMode(directory.path, 0x1c0);
    }
    sourceParent = await OwnedImageDirectory.open(
      Directory('${temporary.path}/private-staging'),
    );
    destinationParent = await OwnedImageDirectory.open(
      Directory('${temporary.path}/applications'),
    );
    source = sourceParent.createDirectory('Candidate.app');
    final file = File('${source.path}/unknown-resource');
    await file.writeAsString('preserve candidate bytes');
    imageFileMode(file.path, 0x180);
  });
  tearDown(() async {
    if (activeMoves != 0 || retainInputs) {
      throw StateError(
        'retaining unconfirmed move/native fixture: ${temporary.path}',
      );
    }
    source.close();
    sourceParent.close();
    destinationParent.close();
    await temporary.delete(recursive: true);
  });

  test(
    'cross-parent maintenance move retains the exact directory and native tree',
    () async {
      final original = await MaintenanceTree.open(Directory(source.path));
      OwnedImageDirectory? moved;
      try {
        final identity = await source.maintenanceIdentity();
        final before = await original.capture(nativeMetadata: true);
        moved = await moving<OwnedImageDirectory>(
          source.moveForMaintenanceTo(
            sourceParent,
            destinationParent,
            'GaoVM.app',
          ),
        );
        expect(moved.path, '${destinationParent.path}/GaoVM.app');
        expect(await moved.maintenanceIdentity(), identity);
        final published = await MaintenanceTree.open(Directory(moved.path));
        try {
          await published.verify(before, nativeMetadata: true);
        } finally {
          published.close();
        }
        expect(maintenancePathEntryExists(source.path), false);
        await expectLater(
          source.verifyPathBinding(),
          throwsA(isA<FileSystemException>()),
        );
        await sourceParent.verifyPathBinding();
        await destinationParent.verifyPathBinding();
      } finally {
        original.close();
        moved?.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final kind in ['directory', 'empty directory', 'file', 'symlink']) {
    test(
      'cross-parent move never replaces an existing $kind',
      () async {
        final target = '${destinationParent.path}/GaoVM.app';
        final foreign = File('${temporary.path}/foreign');
        await foreign.writeAsString('unrelated owner bytes');
        Map<String, Object?>? targetIdentity;
        if (kind == 'directory' || kind == 'empty directory') {
          await Directory(target).create();
          if (kind == 'directory')
            await File('$target/kept').writeAsString('existing app bytes');
          final existing = await OwnedImageDirectory.open(Directory(target));
          try {
            targetIdentity = await existing.maintenanceIdentity();
          } finally {
            existing.close();
          }
        } else if (kind == 'file') {
          await File(target).writeAsString('existing file bytes');
        } else {
          await Link(target).create(foreign.path);
        }
        final tree = await MaintenanceTree.open(Directory(source.path));
        try {
          final before = await tree.capture(nativeMetadata: true);
          await expectLater(
            moving(
              source.moveForMaintenanceTo(
                sourceParent,
                destinationParent,
                'GaoVM.app',
              ),
            ),
            throwsA(
              isA<MaintenanceDirectoryMoveFailure>()
                  .having((e) => e.sourcePath, 'original source', source.path)
                  .having(
                    (e) => e.destinationPath,
                    'requested destination',
                    target,
                  ),
            ),
          );
          await tree.verify(before, nativeMetadata: true);
          await source.verifyPathBinding();
          expect(await foreign.readAsString(), 'unrelated owner bytes');
          if (kind == 'directory') {
            expect(
              await File('$target/kept').readAsString(),
              'existing app bytes',
            );
          } else if (kind == 'empty directory') {
            expect(await Directory(target).list().isEmpty, true);
          } else if (kind == 'file') {
            expect(await File(target).readAsString(), 'existing file bytes');
          } else {
            expect(await Link(target).target(), foreign.path);
          }
          if (targetIdentity != null) {
            final existing = await OwnedImageDirectory.open(Directory(target));
            try {
              expect(await existing.maintenanceIdentity(), targetIdentity);
            } finally {
              existing.close();
            }
          }
        } finally {
          tree.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'maintenance tree relocation returns a freshly verified tree without rebasing the old reader',
    () async {
      final original = await MaintenanceTree.open(Directory(source.path));
      MaintenanceTree? moved;
      try {
        final before = await original.capture(nativeMetadata: true);
        moved = await moving<MaintenanceTree>(
          original.moveForMaintenanceTo(
            sourceParent,
            destinationParent,
            'staged.app',
          ),
        );
        expect(original.path, source.path);
        expect(moved.path, '${destinationParent.path}/staged.app');
        await moved.verify(before, nativeMetadata: true);
        await expectLater(
          original.capture(),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        moved?.close();
        original.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final changed in ['source', 'source parent', 'destination parent']) {
    test(
      'move refuses a substituted $changed inode without moving either generation',
      () async {
        final originalPath = changed == 'source'
            ? source.path
            : changed == 'source parent'
            ? sourceParent.path
            : destinationParent.path;
        final retained = '${temporary.path}/retained';
        Directory(originalPath).renameSync(retained);
        Directory(originalPath).createSync();
        imageFileMode(originalPath, 0x1c0);
        await File(
          '$originalPath/foreign',
        ).writeAsString('preserve substituted namespace');
        await expectLater(
          moving(
            source.moveForMaintenanceTo(
              sourceParent,
              destinationParent,
              'GaoVM.app',
            ),
          ),
          throwsA(isA<MaintenanceDirectoryMoveFailure>()),
        );
        expect(
          await File('$originalPath/foreign').readAsString(),
          'preserve substituted namespace',
        );
        final originalBytes = changed == 'source'
            ? '$retained/unknown-resource'
            : changed == 'source parent'
            ? '$retained/Candidate.app/unknown-resource'
            : '${source.path}/unknown-resource';
        expect(
          await File(originalBytes).readAsString(),
          'preserve candidate bytes',
        );
        expect(
          maintenancePathEntryExists('${destinationParent.path}/GaoVM.app'),
          false,
        );
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'a parent replaced after invocation is refused before namespace writes',
    () async {
      final pending = moving(
        source.moveForMaintenanceTo(
          sourceParent,
          destinationParent,
          'GaoVM.app',
        ),
      );
      Directory(
        destinationParent.path,
      ).renameSync('${temporary.path}/retired-applications');
      Directory(destinationParent.path).createSync();
      imageFileMode(destinationParent.path, 0x1c0);
      await expectLater(
        pending,
        throwsA(isA<MaintenanceDirectoryMoveFailure>()),
      );
      expect(await Directory(destinationParent.path).list().isEmpty, true);
      expect(
        await Directory(
          '${temporary.path}/retired-applications',
        ).list().isEmpty,
        true,
      );
      expect(
        await File('${source.path}/unknown-resource').readAsString(),
        'preserve candidate bytes',
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'canonical owner-only-write 0755 app namespaces and same-parent retirement work',
    () async {
      imageFileMode(sourceParent.path, 0x1ed);
      imageFileMode(source.path, 0x1ed);
      final identity = await source.maintenanceIdentity();
      final moved = await moving(
        source.moveForMaintenanceTo(
          sourceParent,
          sourceParent,
          '.retained.app',
        ),
      );
      try {
        expect(await moved.maintenanceIdentity(), identity);
        expect(moved.mode & 0xfff, 0x1ed);
        expect(sourceParent.mode & 0xfff, 0x1ed);
        expect(
          await File('${moved.path}/unknown-resource').readAsString(),
          'preserve candidate bytes',
        );
        imageFileMode(destinationParent.path, 0x1ed);
        final published = await moving(
          moved.moveForMaintenanceTo(
            sourceParent,
            destinationParent,
            'GaoVM.app',
          ),
        );
        try {
          expect(await published.maintenanceIdentity(), identity);
          expect(destinationParent.mode & 0xfff, 0x1ed);
          expect(published.mode & 0xfff, 0x1ed);
        } finally {
          published.close();
        }
      } finally {
        moved.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final parent in ['source', 'destination']) {
    for (final mode in [0x1d0, 0x1c2, 0x3c0]) {
      test(
        '$parent parent mode $mode refuses without permission normalization',
        () async {
          final changed = parent == 'source' ? sourceParent : destinationParent;
          imageFileMode(changed.path, mode);
          await expectLater(
            moving(
              source.moveForMaintenanceTo(
                sourceParent,
                destinationParent,
                'GaoVM.app',
              ),
            ),
            throwsA(isA<MaintenanceDirectoryMoveFailure>()),
          );
          expect(changed.mode & 0xfff, mode);
          expect(
            await File('${source.path}/unknown-resource').readAsString(),
            'preserve candidate bytes',
          );
          expect(
            maintenancePathEntryExists('${destinationParent.path}/GaoVM.app'),
            false,
          );
        },
        skip: !Platform.isMacOS,
      );
    }
  }

  test(
    'move preserves source xattrs ACL and flags rather than normalizing payload metadata',
    () async {
      final user = (await command('/usr/bin/id', [
        '-un',
      ])).stdout.toString().trim();
      expect(
        (await command('/bin/chmod', [
          '+a',
          'user:$user allow read',
          source.path,
        ])).exitCode,
        0,
      );
      expect(
        (await command('/usr/bin/xattr', [
          '-wx',
          'org.gaovm.move',
          '00ff01',
          '${source.path}/unknown-resource',
        ])).exitCode,
        0,
      );
      expect(
        (await command('/usr/bin/chflags', [
          'nodump',
          '${source.path}/unknown-resource',
        ])).exitCode,
        0,
      );
      final tree = await MaintenanceTree.open(Directory(source.path));
      MaintenanceTree? moved;
      try {
        final before = await tree.capture(nativeMetadata: true);
        expect(((before[''] as Map)['metadata'] as Map)['has_acl'], true);
        expect(
          ((before['unknown-resource'] as Map)['metadata'] as Map)['flags'],
          1,
        );
        moved = await moving<MaintenanceTree>(
          tree.moveForMaintenanceTo(
            sourceParent,
            destinationParent,
            'GaoVM.app',
          ),
        );
        await moved.verify(before, nativeMetadata: true);
      } finally {
        moved?.close();
        tree.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final selected in ['source', 'destination']) {
    test(
      '$selected parent ACL grants refuse without changing the ACL',
      () async {
        final parent = selected == 'source' ? sourceParent : destinationParent;
        final user = (await command('/usr/bin/id', [
          '-un',
        ])).stdout.toString().trim();
        expect(
          (await command('/bin/chmod', [
            '+a',
            'user:$user allow read',
            parent.path,
          ])).exitCode,
          0,
        );
        final metadata = await parent.maintenanceMetadata();
        expect(metadata['has_acl'], true);
        await expectLater(
          moving(
            source.moveForMaintenanceTo(
              sourceParent,
              destinationParent,
              'GaoVM.app',
            ),
          ),
          throwsA(isA<MaintenanceDirectoryMoveFailure>()),
        );
        expect(await parent.maintenanceMetadata(), metadata);
        expect(
          await File('${source.path}/unknown-resource').readAsString(),
          'preserve candidate bytes',
        );
        expect(
          maintenancePathEntryExists('${destinationParent.path}/GaoVM.app'),
          false,
        );
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'overlapping targets wrong source parent and invalid names cannot mutate a tree',
    () async {
      final nested = source.createDirectory('nested');
      final tree = await MaintenanceTree.open(Directory(source.path));
      try {
        final before = await tree.capture(nativeMetadata: true);
        for (final attempt in <Future<OwnedImageDirectory> Function()>[
          () => source.moveForMaintenanceTo(sourceParent, source, 'child'),
          () => source.moveForMaintenanceTo(sourceParent, nested, 'child'),
          () => source.moveForMaintenanceTo(
            sourceParent,
            sourceParent,
            'Candidate.app',
          ),
          () => source.moveForMaintenanceTo(
            destinationParent,
            destinationParent,
            'GaoVM.app',
          ),
          for (final name in ['', '.', '..', 'child/name', '\x00'])
            () => source.moveForMaintenanceTo(
              sourceParent,
              destinationParent,
              name,
            ),
        ]) {
          await expectLater(
            moving(attempt()),
            throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
          );
        }
        await tree.verify(before, nativeMetadata: true);
        expect(await Directory(destinationParent.path).list().isEmpty, true);
      } finally {
        tree.close();
        nested.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final closed in ['source', 'source parent', 'destination parent']) {
    test(
      'closed $closed handle refuses without recreating a namespace',
      () async {
        (closed == 'source'
                ? source
                : closed == 'source parent'
                ? sourceParent
                : destinationParent)
            .close();
        await expectLater(
          moving(
            source.moveForMaintenanceTo(
              sourceParent,
              destinationParent,
              'GaoVM.app',
            ),
          ),
          throwsStateError,
        );
        expect(
          await File('${source.path}/unknown-resource').readAsString(),
          'preserve candidate bytes',
        );
        expect(await Directory(destinationParent.path).list().isEmpty, true);
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'competing real moves publish exactly one inode without overwriting the winner',
    () async {
      final second = sourceParent.createDirectory('Second.app');
      await File(
        '${second.path}/unknown-resource',
      ).writeAsString('preserve second candidate');
      imageFileMode('${second.path}/unknown-resource', 0x180);
      final identities = [
        await source.maintenanceIdentity(),
        await second.maintenanceIdentity(),
      ];
      Future<OwnedImageDirectory?> attempt(OwnedImageDirectory input) async {
        try {
          return await moving(
            input.moveForMaintenanceTo(
              sourceParent,
              destinationParent,
              'GaoVM.app',
            ),
          );
        } on MaintenanceDirectoryMoveFailure {
          return null;
        }
      }

      final results = await Future.wait([attempt(source), attempt(second)]);
      try {
        expect(results.whereType<OwnedImageDirectory>().length, 1);
        final winner = results.indexWhere((result) => result != null);
        expect(
          await results[winner]!.maintenanceIdentity(),
          identities[winner],
        );
        final loser = winner == 0 ? second : source;
        await loser.verifyPathBinding();
        expect(
          await File('${loser.path}/unknown-resource').readAsString(),
          winner == 0
              ? 'preserve second candidate'
              : 'preserve candidate bytes',
        );
        expect(
          await File(
            '${destinationParent.path}/GaoVM.app/unknown-resource',
          ).readAsString(),
          winner == 0
              ? 'preserve candidate bytes'
              : 'preserve second candidate',
        );
        expect(await Directory(destinationParent.path).list().length, 1);
      } finally {
        for (final result in results) {
          result?.close();
        }
        second.close();
      }
    },
    skip: !Platform.isMacOS,
  );
}
