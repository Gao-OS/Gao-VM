import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/maintenance_state_fence.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  late Directory temporary, current, old;
  late OwnedImageDirectory storage;
  late ColdStateLease currentLease, oldLease;
  late _Host currentHost;
  MaintenanceStateFence? fence;
  PreservedColdState? preserved;
  var retainInputs = false;
  var recoveredHostOpens = 0;
  final children = <OwnedTestProcess>[];

  setUp(() async {
    temporary = Directory(
      await (await Directory(
        '/private/tmp',
      ).createTemp('gvm-restore-')).resolveSymbolicLinks(),
    );
    imageFileMode(temporary.path, 0x1c0);
    final parent = await OwnedImageDirectory.open(temporary);
    try {
      storage = parent.createDirectory('work');
      for (final name in ['state', 'old-state', 'Current.app', 'Old.app']) {
        parent.createDirectory(name).close();
      }
    } finally {
      parent.close();
    }
    current = Directory('${temporary.path}/state');
    old = Directory('${temporary.path}/old-state');
    for (final directory in [current, old]) {
      final db = await GaoVmDatabase.open('${directory.path}/gaovm.db');
      db.close();
      imageFileMode('${directory.path}/gaovm.db', 0x180);
    }
    currentHost = _Host('${temporary.path}/Current.app');
    currentLease = await ColdStateLease.acquire(
      current,
      bundleIdentifier: 'org.gaovm.tests.Restore',
      host: currentHost,
    );
    oldLease = await ColdStateLease.acquire(
      old,
      bundleIdentifier: 'org.gaovm.tests.Restore',
      host: _Host('${temporary.path}/Old.app'),
    );
    fence = null;
    preserved = null;
    retainInputs = false;
    recoveredHostOpens = 0;
    children.clear();
  });

  tearDown(() async {
    for (final child in children) {
      if (!await child.terminate()) {
        fail(
          'retaining unconfirmed state restoration child: ${temporary.path}',
        );
      }
    }
    preserved?.close();
    oldLease.close();
    currentLease.close();
    fence?.close();
    storage.close();
    if (retainInputs)
      fail('retaining state restoration fixture: ${temporary.path}');
    await temporary.delete(recursive: true);
  });

  Future<void> assertOwners(Iterable<Directory> directories) async {
    for (final directory in directories) {
      final root = await OwnedImageDirectory.open(directory);
      try {
        final contender = await root.tryAcquireMaintenanceLock(
          '.gaovmd.lock',
          create: false,
        );
        try {
          expect(contender, isNull);
        } finally {
          contender?.close();
        }
      } finally {
        root.close();
      }
    }
  }

  Future<Map<String, Object?>> restoreAndClose() async {
    fence = await MaintenanceStateFence.begin(currentLease);
    preserved = await currentLease.preserveForRollback(
      fence!,
      storage,
      'retained-current',
      verifyPreparedInputs: () async {},
    );
    final restored = await oldLease.restoreForRollback(
      preserved!,
      storage,
      'restore-old-state',
      verifyPreparedInputs: () async {},
    );
    try {
      return restored.toJson();
    } finally {
      restored.close();
    }
  }

  Future<ColdStateRestoration> reopen() => ColdStateRestoration.open(
    storage,
    'restore-old-state',
    stagedOldState: old,
    oldApp: Directory('${temporary.path}/Old.app'),
    retainedApp: Directory('${temporary.path}/Current.app'),
    installationApp: Directory('${temporary.path}/Current.app'),
    original: fence!,
    preservation: (storage: storage, name: 'retained-current'),
    bundleIdentifier: 'org.gaovm.tests.Restore',
    verifyPreparedInputs: () async {},
    openOldHost: (_) async {
      recoveredHostOpens++;
      return _Host('${temporary.path}/Old.app');
    },
    openCurrentHost: (_, __) async {
      recoveredHostOpens++;
      return currentHost;
    },
  );

  test(
    'restore the whole old state behind the unchanged original fence and keep both real owners',
    () async {
      ColdStateRestoration? restored;
      MaintenanceTree? failedTree, oldTree, restoredTree;
      try {
        await File(
          '${current.path}/gaovm.db',
        ).writeAsString('retain failed migration', flush: true);
        final disk = await File(
          '${old.path}/writable-disk',
        ).writeAsBytes([0, 255, 7], flush: true);
        imageFileMode(disk.path, 0x180);
        final oldRoot = await OwnedImageDirectory.open(old);
        try {
          for (final name in [
            'images',
            'vms',
            'nvram',
            'artifacts',
            'logs',
            'legacy',
            'run',
          ]) {
            final child = oldRoot.createDirectory(name);
            try {
              final file = child.createFile('retained-bytes');
              try {
                final writer = await file.openWrite();
                try {
                  await writer.writeFrom(utf8.encode(name));
                  await writer.flush();
                } finally {
                  await writer.close();
                }
              } finally {
                file.close();
              }
            } finally {
              child.close();
            }
          }
        } finally {
          oldRoot.close();
        }
        oldTree = await MaintenanceTree.open(old);
        final oldBefore = await oldTree.capture(nativeMetadata: true);
        fence = await MaintenanceStateFence.begin(currentLease);
        final marker = await File('${fence!.path}/intent.json').readAsBytes();
        preserved = await currentLease.preserveForRollback(
          fence!,
          storage,
          'retained-current',
          verifyPreparedInputs: () async {},
        );
        final retainedPath = preserved!.path;
        failedTree = await MaintenanceTree.open(Directory(retainedPath));
        final failedBefore = await failedTree.capture(nativeMetadata: true);
        restored = await oldLease.restoreForRollback(
          preserved!,
          storage,
          'restore-old-state',
          verifyPreparedInputs: () async {
            await oldTree!.verify(oldBefore, nativeMetadata: true);
            await failedTree!.verify(failedBefore, nativeMetadata: true);
          },
        );
        expect(restored.path, current.path);
        expect(restored.toJson()['canonical_state_restored'], true);
        expect(restored.toJson()['installed_pair_restored'], false);
        expect(restored.toJson()['committed'], false);
        expect(restored.toJson()['startup_allowed'], false);
        expect(await old.exists(), false);
        expect(await File('${fence!.path}/intent.json').readAsBytes(), marker);
        restoredTree = await MaintenanceTree.open(current);
        await restoredTree.verify(oldBefore, nativeMetadata: true);
        await failedTree.verify(failedBefore, nativeMetadata: true);
        await expectLater(oldLease.verify(), throwsStateError);
        await expectLater(preserved!.verify(), throwsStateError);
        oldLease.close();
        preserved!.close();
        await restored.verify();
        for (final directory in [current, Directory(retainedPath)]) {
          final actual = await OwnedImageDirectory.open(directory);
          try {
            final contender = await actual.tryAcquireMaintenanceLock(
              '.gaovmd.lock',
              create: false,
            );
            try {
              expect(contender, isNull);
            } finally {
              contender?.close();
            }
            await expectLater(
              DaemonOwnership.tryAcquire(actual),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          } finally {
            actual.close();
          }
        }
        restored.close();
        for (final directory in [current, Directory(retainedPath)]) {
          await expectLater(
            MaintenanceStateFence.requireUnfenced(directory),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        }
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        restored?.close();
        restoredTree?.close();
        failedTree?.close();
        oldTree?.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'pending restoration cannot release either owner before its original future settles',
    () async {
      ColdStateRestoration? restored;
      try {
        fence = await MaintenanceStateFence.begin(currentLease);
        preserved = await currentLease.preserveForRollback(
          fence!,
          storage,
          'retained-current',
          verifyPreparedInputs: () async {},
        );
        final retained = Directory(preserved!.path);
        final entered = Completer<void>(), release = Completer<void>();
        final pending = oldLease.restoreForRollback(
          preserved!,
          storage,
          'restore-old-state',
          verifyPreparedInputs: () async {
            entered.complete();
            await release.future;
          },
        );
        try {
          await entered.future;
          expect(oldLease.close, throwsStateError);
          expect(preserved!.close, throwsStateError);
          await expectLater(preserved!.verify(), throwsStateError);
          await expectLater(
            oldLease.restoreForRollback(
              preserved!,
              storage,
              'another-attempt',
              verifyPreparedInputs: () async {},
            ),
            throwsStateError,
          );
          await assertOwners([old, retained]);
          expect(await current.exists(), false);
        } finally {
          release.complete();
          restored = await pending;
        }
        oldLease.close();
        preserved!.close();
        await restored.verify();
        await assertOwners([current, retained]);
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        restored?.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a late native observation cannot change the restored state and still report success',
    () async {
      MaintenanceTree? retainedTree;
      try {
        final disk = await File(
          '${old.path}/writable-disk',
        ).writeAsBytes([1, 2, 3], flush: true);
        imageFileMode(disk.path, 0x180);
        fence = await MaintenanceStateFence.begin(currentLease);
        final originalMarker = await File(
          '${fence!.path}/intent.json',
        ).readAsBytes();
        preserved = await currentLease.preserveForRollback(
          fence!,
          storage,
          'retained-current',
          verifyPreparedInputs: () async {},
        );
        final retained = Directory(preserved!.path);
        retainedTree = await MaintenanceTree.open(retained);
        final retainedBefore = await retainedTree.capture(nativeMetadata: true);
        var changed = false;
        currentHost.onService = () async {
          if (!changed && await current.exists()) {
            changed = true;
            await File(
              '${current.path}/writable-disk',
            ).writeAsBytes([9, 8, 7], flush: true);
          }
        };
        await expectLater(
          oldLease.restoreForRollback(
            preserved!,
            storage,
            'restore-old-state',
            verifyPreparedInputs: () async {},
          ),
          throwsFormatException,
        );
        expect(changed, true);
        expect(await old.exists(), false);
        expect(await File('${current.path}/writable-disk').readAsBytes(), [
          9,
          8,
          7,
        ]);
        expect(
          await File('${fence!.path}/intent.json').readAsBytes(),
          originalMarker,
        );
        await retainedTree.verify(retainedBefore, nativeMetadata: true);
        await assertOwners([current, retained]);
        await expectLater(
          oldLease.restoreForRollback(
            preserved!,
            storage,
            'blind-retry',
            verifyPreparedInputs: () async {},
          ),
          throwsStateError,
        );
        expect(await Directory('${storage.path}/blind-retry').exists(), false);
        for (final directory in [current, retained]) {
          await expectLater(
            MaintenanceStateFence.requireUnfenced(directory),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        }
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        retainedTree?.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a newly occupied original slot is never overwritten or adopted during restoration',
    () async {
      MaintenanceTree? retainedTree, oldTree;
      try {
        fence = await MaintenanceStateFence.begin(currentLease);
        preserved = await currentLease.preserveForRollback(
          fence!,
          storage,
          'retained-current',
          verifyPreparedInputs: () async {},
        );
        final retained = Directory(preserved!.path);
        retainedTree = await MaintenanceTree.open(retained);
        oldTree = await MaintenanceTree.open(old);
        final retainedBefore = await retainedTree.capture(nativeMetadata: true);
        final oldBefore = await oldTree.capture(nativeMetadata: true);
        await expectLater(
          oldLease.restoreForRollback(
            preserved!,
            storage,
            'restore-old-state',
            verifyPreparedInputs: () async {
              await current.create();
              imageFileMode(current.path, 0x1c0);
              final stranger = await File(
                '${current.path}/foreign-state',
              ).writeAsString('do not overwrite', flush: true);
              imageFileMode(stranger.path, 0x180);
            },
          ),
          throwsFormatException,
        );
        expect(
          await File('${current.path}/foreign-state').readAsString(),
          'do not overwrite',
        );
        await oldTree.verify(oldBefore, nativeMetadata: true);
        await retainedTree.verify(retainedBefore, nativeMetadata: true);
        await assertOwners([old, retained]);
        expect(
          await Directory(
            '${storage.path}/restore-old-state/completed',
          ).exists(),
          false,
        );
        for (final directory in [current, retained]) {
          await expectLater(
            MaintenanceStateFence.requireUnfenced(directory),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        }
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        oldTree?.close();
        retainedTree?.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'typed restored-state verification keeps both owners until its original future settles',
    () async {
      ColdStateRestoration? restored;
      OwnedImageDirectory? actual;
      try {
        fence = await MaintenanceStateFence.begin(currentLease);
        preserved = await currentLease.preserveForRollback(
          fence!,
          storage,
          'retained-current',
          verifyPreparedInputs: () async {},
        );
        final retained = Directory(preserved!.path);
        restored = await oldLease.restoreForRollback(
          preserved!,
          storage,
          'restore-old-state',
          verifyPreparedInputs: () async {},
        );
        actual = await OwnedImageDirectory.open(current);
        final pending = restored.verifyFor(actual);
        try {
          expect(restored.close, throwsStateError);
        } finally {
          await pending;
        }
        await assertOwners([current, retained]);
        await restored.verify();
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        actual?.close();
        restored?.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'fixed completed restoration reopens both real owners without changing either generation or checkpoint',
    () async {
      ColdStateRestoration? restored, reopened;
      MaintenanceTree? tree;
      try {
        fence = await MaintenanceStateFence.begin(currentLease);
        preserved = await currentLease.preserveForRollback(
          fence!,
          storage,
          'retained-current',
          verifyPreparedInputs: () async {},
        );
        final retained = Directory(preserved!.path);
        restored = await oldLease.restoreForRollback(
          preserved!,
          storage,
          'restore-old-state',
          verifyPreparedInputs: () async {},
        );
        final expected = restored.toJson();
        restored.close();
        fence!.close();
        fence = await MaintenanceStateFence.open(current);
        tree = await MaintenanceTree.open(temporary);
        final before = await tree.capture(nativeMetadata: true);
        reopened = await ColdStateRestoration.open(
          storage,
          'restore-old-state',
          stagedOldState: old,
          oldApp: Directory('${temporary.path}/Old.app'),
          retainedApp: Directory('${temporary.path}/Current.app'),
          installationApp: Directory('${temporary.path}/Current.app'),
          original: fence!,
          preservation: (storage: storage, name: 'retained-current'),
          bundleIdentifier: 'org.gaovm.tests.Restore',
          verifyPreparedInputs: () async {},
          openOldHost: (_) async => _Host('${temporary.path}/Old.app'),
          openCurrentHost: (_, __) async => currentHost,
        );
        expect(reopened.toJson(), expected);
        await reopened.verify();
        await assertOwners([current, retained]);
        for (final directory in [current, retained]) {
          final process = await Process.start(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/test/fixtures/hold_existing_state_lock.dart',
            directory.path,
          ]);
          final child = OwnedTestProcess(process);
          children.add(child);
          await process.stdin.close();
          final result = await child.result();
          expect(result.exitCode, 3);
          expect((result.stdout as String).trim(), 'busy');
          expect(child.exitConfirmed, true);
        }
        await tree.verify(before, nativeMetadata: true);
        for (final directory in [current, retained]) {
          await expectLater(
            MaintenanceStateFence.requireUnfenced(directory),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        }
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        reopened?.close();
        restored?.close();
        tree?.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'fixed post-move restoration can finish a missing completion only after cold revalidation',
    () async {
      ColdStateRestoration? reopened;
      MaintenanceTree? oldTree, retainedTree;
      try {
        final expected = await restoreAndClose();
        await Directory(
          '${storage.path}/restore-old-state/completed',
        ).delete(recursive: true);
        oldTree = await MaintenanceTree.open(current);
        retainedTree = await MaintenanceTree.open(Directory(preserved!.path));
        final oldBefore = await oldTree.capture(nativeMetadata: true);
        final retainedBefore = await retainedTree.capture(nativeMetadata: true);
        reopened = await reopen();
        expect(reopened.toJson(), expected);
        await oldTree.verify(oldBefore, nativeMetadata: true);
        await retainedTree.verify(retainedBefore, nativeMetadata: true);
        await assertOwners([current, Directory(preserved!.path)]);
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        reopened?.close();
        retainedTree?.close();
        oldTree?.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'fixed restoration promotes an exact sealed staged completion without rewriting its inode or bytes',
    () async {
      ColdStateRestoration? reopened;
      MaintenanceTree? completion;
      try {
        final expected = await restoreAndClose();
        final complete = Directory(
          '${storage.path}/restore-old-state/completed',
        );
        completion = await MaintenanceTree.open(complete);
        final before = await completion.capture(nativeMetadata: true);
        await complete.rename(
          '${storage.path}/restore-old-state/.completed.partial',
        );
        reopened = await reopen();
        expect(reopened.toJson(), expected);
        await completion.verify(before, nativeMetadata: true);
        expect(
          await Directory(
            '${storage.path}/restore-old-state/.completed.partial',
          ).exists(),
          false,
        );
        await assertOwners([current, Directory(preserved!.path)]);
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        reopened?.close();
        completion?.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final changed in [
    'restored_bytes',
    'retained_bytes',
    'restored_copy',
    'retained_copy',
    'old_app',
    'retained_app',
    'completion_flags',
    'intent_selector',
    'old_slot_occupied',
    'prepared_record',
    'unknown_entry',
    'restored_lock_missing',
    'retained_lock_missing',
    'restored_lock_mode',
    'retained_lock_mode',
    'namespace_lock_missing',
    'preservation_lock_missing',
    'namespace_lock_bytes',
    'incomplete_completion',
    'ambiguous_completion',
  ]) {
    test(
      'restoration recovery refuses $changed before cold helpers and leaves the damaged input unchanged',
      () async {
        MaintenanceTree? tree;
        try {
          await restoreAndClose();
          final checkpoint = '${storage.path}/restore-old-state';
          final retained = preserved!.path;
          Future<void> write(
            String path,
            String content, {
            bool sealed = false,
          }) async {
            if (await File(path).exists()) imageFileMode(path, 0x180);
            await File(path).writeAsString(content, flush: true);
            imageFileMode(path, sealed ? 0x100 : 0x180);
          }

          Future<void> changeRecord(
            String path,
            String key,
            Object value,
          ) async {
            final record =
                jsonDecode(await File(path).readAsString())
                    as Map<String, Object?>;
            record[key] = value;
            await write(path, '${jsonEncode(record)}\n', sealed: true);
          }

          switch (changed) {
            case 'restored_bytes':
              await write(
                '${current.path}/gaovm.db',
                'retain changed old catalog',
              );
            case 'retained_bytes':
              await write(
                '$retained/gaovm.db',
                'retain changed current catalog',
              );
            case 'restored_copy':
            case 'retained_copy':
              final target = changed == 'restored_copy'
                  ? current
                  : Directory(retained);
              final parent = await OwnedImageDirectory.open(temporary);
              final copies = parent.createDirectory('copies');
              final source = await MaintenanceTree.open(target);
              try {
                await source.snapshotTo(copies, 'copy');
                await target.rename('${temporary.path}/displaced-state');
                await Directory(
                  '${copies.path}/copy/payload',
                ).rename(target.path);
              } finally {
                source.close();
                copies.close();
                parent.close();
              }
            case 'old_app':
              await write(
                '${temporary.path}/Old.app/unknown',
                'keep old app change',
              );
            case 'retained_app':
              await write(
                '${temporary.path}/Current.app/unknown',
                'keep current app change',
              );
            case 'completion_flags':
              await changeRecord(
                '$checkpoint/completed/record.json',
                'startup_allowed',
                true,
              );
            case 'intent_selector':
              await changeRecord(
                '$checkpoint/intent.json',
                'source_state',
                '${temporary.path}/foreign-source',
              );
            case 'old_slot_occupied':
              await old.create();
              imageFileMode(old.path, 0x1c0);
              await write(
                '${old.path}/foreign',
                'keep unrelated reused source',
              );
            case 'prepared_record':
              await changeRecord(
                '$checkpoint/prepared/record.json',
                'phase',
                'unknown',
              );
            case 'unknown_entry':
              await write(
                '$checkpoint/foreign',
                'keep unknown checkpoint bytes',
              );
            case 'restored_lock_missing':
              await File('${current.path}/.gaovmd.lock').delete();
            case 'retained_lock_missing':
              await File('$retained/.gaovmd.lock').delete();
            case 'restored_lock_mode':
              imageFileMode('${current.path}/.gaovmd.lock', 0x1a4);
            case 'retained_lock_mode':
              imageFileMode('$retained/.gaovmd.lock', 0x1a4);
            case 'namespace_lock_missing':
              await File(
                '${storage.path}/.gaovm-state-restoration.lock',
              ).delete();
            case 'preservation_lock_missing':
              await File(
                '${storage.path}/.gaovm-state-preservation.lock',
              ).delete();
            case 'namespace_lock_bytes':
              await write(
                '${storage.path}/.gaovm-state-restoration.lock',
                'keep lock bytes',
              );
            case 'incomplete_completion':
              await Directory(
                '$checkpoint/completed',
              ).rename('$checkpoint/.completed.partial');
              await File('$checkpoint/.completed.partial/record.json').delete();
            case 'ambiguous_completion':
              final partial = await Directory(
                '$checkpoint/.completed.partial',
              ).create();
              imageFileMode(partial.path, 0x1c0);
              await write(
                '${partial.path}/record.json',
                await File('$checkpoint/completed/record.json').readAsString(),
                sealed: true,
              );
          }
          tree = await MaintenanceTree.open(temporary);
          final damaged = await tree.capture(nativeMetadata: true);
          await expectLater(
            reopen(),
            throwsA(anyOf(isA<FormatException>(), isA<FileSystemException>())),
          );
          expect(recoveredHostOpens, 0);
          await tree.verify(damaged, nativeMetadata: true);
          for (final directory in [current, Directory(retained)]) {
            await expectLater(
              MaintenanceStateFence.requireUnfenced(directory),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          tree?.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  for (final retainOwner in [false, true]) {
    test(
      'restoration recovery refuses a real ${retainOwner ? 'retained' : 'restored'} owner before helpers without leaking the other lock',
      () async {
        OwnedImageDirectory? heldRoot;
        OwnedImageLock? held;
        MaintenanceTree? tree;
        try {
          await restoreAndClose();
          final retained = Directory(preserved!.path);
          heldRoot = await OwnedImageDirectory.open(
            retainOwner ? retained : current,
          );
          held = await heldRoot.tryAcquireMaintenanceLock(
            '.gaovmd.lock',
            create: false,
          );
          expect(held, isNotNull);
          tree = await MaintenanceTree.open(temporary);
          final before = await tree.capture(nativeMetadata: true);
          await expectLater(reopen(), throwsA(isA<ColdStateFailure>()));
          expect(recoveredHostOpens, 0);
          held!.verifyPathBinding();
          for (final directory in [current, retained]) {
            final root = await OwnedImageDirectory.open(directory);
            try {
              final contender = await root.tryAcquireMaintenanceLock(
                '.gaovmd.lock',
                create: false,
              );
              try {
                expect(contender == null, directory.path == heldRoot.path);
              } finally {
                contender?.close();
              }
            } finally {
              root.close();
            }
          }
          await tree.verify(before, nativeMetadata: true);
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          tree?.close();
          held?.close();
          heldRoot?.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'pending recovery owns both states before a host callback and cannot be closed or reported complete early',
    () async {
      ColdStateRestoration? reopened, borrowed;
      try {
        await restoreAndClose();
        final entered = Completer<void>(), release = Completer<void>();
        final pending = ColdStateRestoration.open(
          storage,
          'restore-old-state',
          stagedOldState: old,
          oldApp: Directory('${temporary.path}/Old.app'),
          retainedApp: Directory('${temporary.path}/Current.app'),
          installationApp: Directory('${temporary.path}/Current.app'),
          original: fence!,
          preservation: (storage: storage, name: 'retained-current'),
          bundleIdentifier: 'org.gaovm.tests.Restore',
          verifyPreparedInputs: () async {},
          openOldHost: (proof) async {
            borrowed = proof;
            entered.complete();
            await release.future;
            return _Host('${temporary.path}/Old.app');
          },
          openCurrentHost: (_, __) async => currentHost,
        );
        unawaited(
          pending.then<void>(
            (_) {
              if (!entered.isCompleted)
                entered.completeError(StateError('missing host callback'));
            },
            onError: (Object error, StackTrace stack) {
              if (!entered.isCompleted) entered.completeError(error, stack);
            },
          ),
        );
        try {
          await entered.future;
          expect(borrowed!.close, throwsStateError);
          expect(borrowed!.toJson, throwsStateError);
          await expectLater(borrowed!.verify(), throwsStateError);
          await expectLater(reopen(), throwsStateError);
          await assertOwners([current, Directory(preserved!.path)]);
        } finally {
          release.complete();
          reopened = await pending;
        }
        await reopened.verify();
        await assertOwners([current, Directory(preserved!.path)]);
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        reopened?.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final late in ['registered', 'unresolved_driver', 'old_bytes']) {
    test(
      'restoration recovery cannot finish a missing completion after late $late',
      () async {
        MaintenanceTree? checkpoint, retainedTree, oldTree;
        try {
          await restoreAndClose();
          final path = '${storage.path}/restore-old-state';
          await Directory('$path/completed').delete(recursive: true);
          checkpoint = await MaintenanceTree.open(Directory(path));
          retainedTree = await MaintenanceTree.open(Directory(preserved!.path));
          oldTree = await MaintenanceTree.open(current);
          final checkpointBefore = await checkpoint.capture(
            nativeMetadata: true,
          );
          final retainedBefore = await retainedTree.capture(
            nativeMetadata: true,
          );
          final oldBefore = await oldTree.capture(nativeMetadata: true);
          if (late == 'registered') currentHost.registered = true;
          if (late == 'unresolved_driver') currentHost.unresolvedDriver = true;
          if (late == 'old_bytes') {
            currentHost.onService = () => File(
              '${current.path}/gaovm.db',
            ).writeAsString('retain late old-state mutation', flush: true);
          }
          await expectLater(
            reopen(),
            throwsA(anyOf(isA<ColdStateFailure>(), isA<FormatException>())),
          );
          expect(recoveredHostOpens, 2);
          expect(await Directory('$path/completed').exists(), false);
          expect(await Directory('$path/.completed.partial').exists(), false);
          await checkpoint.verify(checkpointBefore, nativeMetadata: true);
          await retainedTree.verify(retainedBefore, nativeMetadata: true);
          if (late == 'old_bytes') {
            expect(
              await File('${current.path}/gaovm.db').readAsString(),
              'retain late old-state mutation',
            );
          } else {
            await oldTree.verify(oldBefore, nativeMetadata: true);
          }
          for (final directory in [current, Directory(preserved!.path)]) {
            await expectLater(
              MaintenanceStateFence.requireUnfenced(directory),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          oldTree?.close();
          retainedTree?.close();
          checkpoint?.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }
}

final class _Host implements ColdStateHost {
  _Host(this.appPath);
  @override
  final String appPath;
  Future<void> Function()? onService;
  bool registered = false, unresolvedDriver = false;
  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async =>
      DriverInventorySnapshot(
        processes: [],
        unresolvedProcessIds: unresolvedDriver && driver ? [pid + 51] : [],
      );
  @override
  Future<Set<int>> stateReferences(Directory state) async => {pid};
  @override
  Future<ProcessResult> serviceStatus() async {
    await onService?.call();
    return ProcessResult(
      pid,
      0,
      jsonEncode({
        'action': 'status',
        'bundle_identifier': 'org.gaovm.tests.Restore',
        'plist_name': 'gaovmd.plist',
        'authorization_state': registered ? 'enabled' : 'notRegistered',
        'native_status': registered ? 1 : 0,
        'outcome': 'observed',
        'error_code': null,
      }),
      '',
    );
  }
}
