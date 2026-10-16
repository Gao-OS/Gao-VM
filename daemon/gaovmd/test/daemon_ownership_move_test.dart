import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/daemon_ownership.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:gaovmd/src/maintenance_state_fence.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  group('maintenance state ownership move', () {
    late Directory temporary;
    late OwnedImageDirectory parent, storage, source;
    late DaemonOwnership owner;
    OwnedImageDirectory? moved;
    var active = 0, retainInputs = false;
    final children = <OwnedTestProcess>[];

    Future<void> assertOwned(OwnedImageDirectory root) async {
      final contender = await DaemonOwnership.tryAcquire(root);
      try {
        expect(contender, isNull);
      } finally {
        contender?.close();
      }
    }

    Future<void> checking(Future<void> Function() action) async {
      active++;
      try {
        await action();
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        active--;
      }
    }

    setUp(() async {
      temporary = Directory(
        await (await Directory(
          '/private/tmp',
        ).createTemp('gvm-owner-move-')).resolveSymbolicLinks(),
      );
      imageFileMode(temporary.path, 0x1c0);
      parent = await OwnedImageDirectory.open(temporary);
      storage = parent.createDirectory('retained');
      source = parent.createDirectory('state');
      final data = File('${source.path}/unknown-state');
      await data.writeAsBytes([0, 1, 255, 42], flush: true);
      imageFileMode(data.path, 0x180);
      owner = (await DaemonOwnership.tryAcquire(source))!;
      moved = null;
      active = 0;
      retainInputs = false;
      children.clear();
    });
    tearDown(() async {
      if (active != 0) {
        throw StateError('retaining pending ownership move ${temporary.path}');
      }
      for (final child in children) {
        if (!await child.terminate()) {
          throw StateError(
            'retaining pending ownership child ${temporary.path}',
          );
        }
      }
      owner.close();
      moved?.close();
      source.close();
      storage.close();
      parent.close();
      if (retainInputs) {
        throw StateError('retaining failed ownership move ${temporary.path}');
      }
      await temporary.delete(recursive: true);
    });

    test('the same real owner survives a state move without unlocking', () {
      return checking(() async {
        final original = await MaintenanceTree.open(Directory(source.path));
        try {
          final before = await original.capture(nativeMetadata: true);
          final identity = await source.maintenanceIdentity();
          moved = await source.moveForMaintenanceTo(
            parent,
            storage,
            'post-upgrade-state',
          );
          await expectLater(
            owner.verify(),
            throwsA(isA<FileSystemException>()),
          );
          await assertOwned(moved!);
          await owner.rebindAfterMaintenanceMove(moved!);
          expect(owner.stateDirectoryPath, moved!.path);
          source.close();
          await owner.verify();
          expect(await moved!.maintenanceIdentity(), identity);
          await assertOwned(moved!);
          final process = await Process.start(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/test/fixtures/hold_daemon_ownership.dart',
            moved!.path,
          ]);
          final child = OwnedTestProcess(process);
          children.add(child);
          await process.stdin.close();
          final probe = await child.result();
          expect(probe.exitCode, 3);
          expect((probe.stdout as String).trim(), 'busy');
          expect(child.exitConfirmed, true);
          final retained = await MaintenanceTree.open(Directory(moved!.path));
          try {
            await retained.verify(before, nativeMetadata: true);
          } finally {
            retained.close();
          }
          owner.close();
          final next = await DaemonOwnership.tryAcquire(moved!);
          try {
            expect(next, isNotNull);
            await next!.verify();
          } finally {
            next?.close();
          }
        } finally {
          original.close();
        }
      });
    });

    test(
      'reusing the old slot does not transfer ownership of the foreign state',
      () {
        return checking(() async {
          moved = await source.moveForMaintenanceTo(
            parent,
            storage,
            'post-upgrade-state',
          );
          final foreign = parent.createDirectory('state');
          final foreignOwner = (await DaemonOwnership.tryAcquire(foreign))!;
          final retained = await MaintenanceTree.open(temporary);
          try {
            final before = await retained.capture(nativeMetadata: true);
            await owner.rebindAfterMaintenanceMove(moved!);
            expect(owner.stateDirectoryPath, moved!.path);
            await owner.verify();
            await foreignOwner.verify();
            await assertOwned(moved!);
            await assertOwned(foreign);
            await retained.verify(before, nativeMetadata: true);
          } finally {
            retained.close();
            foreignOwner.close();
            foreign.close();
          }
        });
      },
    );

    test(
      'a pending rebind retains its owner until the original future settles',
      () {
        return checking(() async {
          moved = await source.moveForMaintenanceTo(
            parent,
            storage,
            'post-upgrade-state',
          );
          Object? failure;
          final pending = owner.rebindAfterMaintenanceMove(moved!);
          final settled = pending.then<void>(
            (_) {},
            onError: (Object error, StackTrace stack) {
              failure = error;
            },
          );
          try {
            expect(owner.close, throwsStateError);
            await expectLater(
              owner.rebindAfterMaintenanceMove(moved!),
              throwsStateError,
            );
            await assertOwned(moved!);
            await settled;
            expect(failure, isNull);
            await owner.verify();
            await assertOwned(moved!);
          } finally {
            await settled;
          }
        });
      },
    );

    for (final change in [
      'closed owner',
      'closed source',
      'closed target',
      'public target',
    ]) {
      test('rebinding refuses $change without changing either tree', () {
        return checking(() async {
          moved = await source.moveForMaintenanceTo(
            parent,
            storage,
            'post-upgrade-state',
          );
          switch (change) {
            case 'closed owner':
              owner.close();
            case 'closed source':
              source.close();
            case 'closed target':
              moved!.close();
            case 'public target':
              imageFileMode(moved!.path, 0x1ed);
          }
          final retained = await MaintenanceTree.open(temporary);
          try {
            final before = await retained.capture(nativeMetadata: true);
            await expectLater(
              owner.rebindAfterMaintenanceMove(moved!),
              change == 'public target'
                  ? throwsFormatException
                  : throwsStateError,
            );
            expect(owner.stateDirectoryPath, source.path);
            await retained.verify(before, nativeMetadata: true);
            if (change == 'public target') {
              imageFileMode(moved!.path, 0x1c0);
              await owner.rebindAfterMaintenanceMove(moved!);
              await owner.verify();
            } else {
              final actual = await OwnedImageDirectory.open(
                Directory(moved!.path),
              );
              final contender = await actual.tryAcquireMaintenanceLock(
                '.gaovmd.lock',
                create: false,
              );
              try {
                expect(
                  contender,
                  change == 'closed owner' ? isNotNull : isNull,
                );
              } finally {
                contender?.close();
                actual.close();
              }
            }
          } finally {
            retained.close();
          }
        });
      });
    }

    test('an unmoved owner cannot reset its binding through maintenance', () {
      return checking(() async {
        final retained = await MaintenanceTree.open(temporary);
        try {
          final before = await retained.capture(nativeMetadata: true);
          await expectLater(
            owner.rebindAfterMaintenanceMove(source),
            throwsFormatException,
          );
          await owner.verify();
          await assertOwned(source);
          await retained.verify(before, nativeMetadata: true);
        } finally {
          retained.close();
        }
      });
    });

    test('a substituted destination directory cannot adopt the real owner', () {
      return checking(() async {
        moved = await source.moveForMaintenanceTo(
          parent,
          storage,
          'post-upgrade-state',
        );
        await storage.renameDirectoryNoReplace(
          'post-upgrade-state',
          'actual-state',
        );
        final foreign = storage.createDirectory('post-upgrade-state');
        final actual = storage.directory('actual-state');
        final retained = await MaintenanceTree.open(temporary);
        try {
          final before = await retained.capture(nativeMetadata: true);
          await expectLater(
            owner.rebindAfterMaintenanceMove(moved!),
            throwsA(isA<FileSystemException>()),
          );
          expect(owner.stateDirectoryPath, source.path);
          await assertOwned(actual);
          await retained.verify(before, nativeMetadata: true);
          await owner.rebindAfterMaintenanceMove(actual);
          await owner.verify();
        } finally {
          retained.close();
          foreign.close();
          actual.close();
        }
      });
    });

    test(
      'a substituted moved lock is retained and cannot replace the real owner',
      () {
        return checking(() async {
          moved = await source.moveForMaintenanceTo(
            parent,
            storage,
            'post-upgrade-state',
          );
          final lock = File('${moved!.path}/.gaovmd.lock');
          await lock.rename('${moved!.path}/original-lock');
          await lock.writeAsString('', flush: true);
          imageFileMode(lock.path, 0x180);
          final retained = await MaintenanceTree.open(temporary);
          try {
            final before = await retained.capture(nativeMetadata: true);
            await expectLater(
              owner.rebindAfterMaintenanceMove(moved!),
              throwsA(isA<FileSystemException>()),
            );
            expect(owner.stateDirectoryPath, source.path);
            final original = await moved!.tryAcquireMaintenanceLock(
              'original-lock',
              create: false,
            );
            final foreign = await moved!.tryAcquireMaintenanceLock(
              '.gaovmd.lock',
              create: false,
            );
            try {
              expect(original, isNull);
              expect(foreign, isNotNull);
            } finally {
              original?.close();
              foreign?.close();
            }
            await retained.verify(before, nativeMetadata: true);
          } finally {
            retained.close();
          }
        });
      },
    );

    test('a copied state and lock file cannot adopt the original owner', () {
      return checking(() async {
        moved = await source.moveForMaintenanceTo(
          parent,
          storage,
          'post-upgrade-state',
        );
        final tree = await MaintenanceTree.open(Directory(moved!.path));
        OwnedImageDirectory? wrapper, copy;
        try {
          await tree.snapshotTo(storage, 'copy');
          wrapper = storage.directory('copy');
          copy = wrapper.directory('payload');
          final retained = await MaintenanceTree.open(temporary);
          try {
            final before = await retained.capture(nativeMetadata: true);
            await expectLater(
              owner.rebindAfterMaintenanceMove(copy),
              throwsFormatException,
            );
            expect(owner.stateDirectoryPath, source.path);
            await assertOwned(moved!);
            final unrelated = await DaemonOwnership.tryAcquire(copy);
            try {
              expect(unrelated, isNotNull);
              await unrelated!.verify();
            } finally {
              unrelated?.close();
            }
            await retained.verify(before, nativeMetadata: true);
            await owner.rebindAfterMaintenanceMove(moved!);
            await owner.verify();
          } finally {
            retained.close();
          }
        } finally {
          copy?.close();
          wrapper?.close();
          tree.close();
        }
      });
    });

    test('rebinding cannot bypass an existing destination startup fence', () {
      return checking(() async {
        final target = storage.createDirectory('post-upgrade-state');
        ColdStateLease? targetLease;
        MaintenanceStateFence? fence;
        OwnedImageDirectory? foreign;
        try {
          targetLease = await ColdStateLease.acquire(
            Directory(target.path),
            bundleIdentifier: 'org.gaovm.tests.OwnerMove',
            host: _Host('${temporary.path}/GaoVM.app'),
          );
          fence = await MaintenanceStateFence.begin(targetLease);
          final marker = fence.path;
          fence.close();
          targetLease.close();
          foreign = await target.moveForMaintenanceTo(
            storage,
            storage,
            'original-fenced-state',
          );
          moved = await source.moveForMaintenanceTo(
            parent,
            storage,
            'post-upgrade-state',
          );
          final retained = await MaintenanceTree.open(temporary);
          try {
            final before = await retained.capture(nativeMetadata: true);
            await expectLater(
              owner.rebindAfterMaintenanceMove(moved!),
              throwsA(isA<MaintenanceFenceActive>()),
            );
            expect(owner.stateDirectoryPath, source.path);
            expect(await Directory(marker).exists(), true);
            final contender = await moved!.tryAcquireMaintenanceLock(
              '.gaovmd.lock',
              create: false,
            );
            try {
              expect(contender, isNull);
            } finally {
              contender?.close();
            }
            await retained.verify(before, nativeMetadata: true);
          } finally {
            retained.close();
          }
        } finally {
          foreign?.close();
          fence?.close();
          targetLease?.close();
          target.close();
        }
      });
    });
  }, skip: !Platform.isMacOS);
}

final class _Host implements ColdStateHost {
  _Host(this.appPath);
  @override
  final String appPath;
  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async =>
      DriverInventorySnapshot(processes: [], unresolvedProcessIds: []);
  @override
  Future<Set<int>> stateReferences(Directory state) async => {pid};
  @override
  Future<ProcessResult> serviceStatus() async => ProcessResult(
    pid,
    0,
    jsonEncode({
      'action': 'status',
      'bundle_identifier': 'org.gaovm.tests.OwnerMove',
      'plist_name': 'gaovmd.plist',
      'authorization_state': 'notRegistered',
      'native_status': 0,
      'outcome': 'observed',
      'error_code': null,
    }),
    '',
  );
}
