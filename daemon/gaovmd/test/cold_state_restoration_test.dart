import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/maintenance_state_fence.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary, current, old;
  late OwnedImageDirectory storage;
  late ColdStateLease currentLease, oldLease;
  late _Host currentHost;
  MaintenanceStateFence? fence;
  PreservedColdState? preserved;
  var retainInputs = false;

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
  });

  tearDown(() async {
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
}

final class _Host implements ColdStateHost {
  _Host(this.appPath);
  @override
  final String appPath;
  Future<void> Function()? onService;
  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async =>
      DriverInventorySnapshot(processes: [], unresolvedProcessIds: []);
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
        'authorization_state': 'notRegistered',
        'native_status': 0,
        'outcome': 'observed',
        'error_code': null,
      }),
      '',
    );
  }
}
