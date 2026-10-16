import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/maintenance_state_fence.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  late Directory temporary;
  late Directory state;
  late ColdStateLease lease;
  late _Host initialHost;
  MaintenanceStateFence? fence;
  var retainInputs = false;
  final children = <OwnedTestProcess>[];
  Future<ProcessResult> command(String executable, List<String> args) async {
    final child = OwnedTestProcess(await Process.start(executable, args));
    children.add(child);
    return child.result();
  }

  setUp(() async {
    temporary = Directory(
      await (await Directory(
        '/private/tmp',
      ).createTemp('gvm-mf-')).resolveSymbolicLinks(),
    );
    imageFileMode(temporary.path, 0x1c0);
    state = await Directory('${temporary.path}/state').create();
    imageFileMode(state.path, 0x1c0);
    final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    database.close();
    imageFileMode('${state.path}/gaovm.db', 0x180);
    final app = await Directory('${temporary.path}/GaoVM.app').create();
    imageFileMode(app.path, 0x1c0);
    initialHost = _Host(app.path);
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: 'org.gaovm.tests.Fence',
      host: initialHost,
    );
    fence = null;
    retainInputs = false;
    children.clear();
  });
  tearDown(() async {
    var exitsConfirmed = true;
    for (final child in children) {
      exitsConfirmed = await child.terminate() && exitsConfirmed;
    }
    try {
      fence?.close();
      lease.close();
    } finally {
      if (exitsConfirmed && !retainInputs)
        await temporary.delete(recursive: true);
    }
    if (!exitsConfirmed || retainInputs)
      fail('retaining cold fence fixture: ${temporary.path}');
  });

  test(
    'relocation keeps both state paths fenced and the same real owner across a move',
    () async {
      final parent = await OwnedImageDirectory.open(temporary);
      final storage = parent.createDirectory('preserved');
      final original = await OwnedImageDirectory.open(state);
      final tree = await MaintenanceTree.open(state);
      MaintenanceStateFence? reservation;
      OwnedImageDirectory? moved;
      DaemonOwnership? owner;
      try {
        fence = await MaintenanceStateFence.begin(lease);
        final before = await tree.capture(nativeMetadata: true);
        final identity = await original.maintenanceIdentity();
        reservation = await MaintenanceStateFence.reserveRelocation(
          lease,
          fence!,
          storage,
          'post-upgrade-state',
        );
        final target = Directory('${storage.path}/post-upgrade-state');
        expect(await target.exists(), false);
        for (final path in [state, target]) {
          await expectLater(
            MaintenanceStateFence.requireUnfenced(path),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        }
        lease.close();
        owner = await DaemonOwnership.tryAcquireForMaintenance(
          original,
          fence!,
        );
        expect(owner, isNotNull);
        moved = await original.moveForMaintenanceTo(
          parent,
          storage,
          'post-upgrade-state',
        );
        await owner!.rebindAfterMaintenanceMove(
          moved,
          maintenanceFence: reservation,
        );
        await owner.verify();
        expect(await moved.maintenanceIdentity(), identity);
        final competing = await moved.tryAcquireMaintenanceLock(
          '.gaovmd.lock',
          create: false,
        );
        try {
          expect(competing, isNull);
        } finally {
          competing?.close();
        }
        final retained = await MaintenanceTree.open(target);
        try {
          await retained.verify(before, nativeMetadata: true);
        } finally {
          retained.close();
        }
        await reservation.verifyFor(moved);
        await fence!.verify();
        owner.close();
        reservation.close();
        reservation = await MaintenanceStateFence.open(target);
        lease = await ColdStateLease.acquire(
          target,
          bundleIdentifier: 'org.gaovm.tests.Fence',
          host: initialHost,
          maintenanceFence: reservation,
        );
        await lease.verify();
        lease.close();
        for (final path in [state, target]) {
          await expectLater(
            MaintenanceStateFence.requireUnfenced(path),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        }
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        owner?.close();
        reservation?.close();
        tree.close();
        moved?.close();
        original.close();
        storage.close();
        parent.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'relocation refuses storage made non-private after fence publication',
    () async {
      final parent = await OwnedImageDirectory.open(temporary);
      final storage = parent.createDirectory('preserved');
      final tree = await MaintenanceTree.open(state);
      MaintenanceStateFence? reservation;
      try {
        fence = await MaintenanceStateFence.begin(lease);
        final before = await tree.capture(nativeMetadata: true);
        final target = '${storage.path}/post-upgrade-state';
        final marker =
            '${storage.path}/.gaovmd-maintenance-${sha256.convert(utf8.encode(target))}';
        var changed = false;
        initialHost.onStatus = () async {
          if (!changed && Directory(marker).existsSync()) {
            changed = true;
            imageFileMode(storage.path, 0x1ed);
          }
        };
        await expectLater(() async {
          reservation = await MaintenanceStateFence.reserveRelocation(
            lease,
            fence!,
            storage,
            'post-upgrade-state',
          );
        }, throwsFormatException);
        expect(changed, true);
        expect(storage.mode & 0xfff, 0x1ed);
        expect(await Directory(marker).exists(), true);
        expect(await Directory(target).exists(), false);
        await tree.verify(before, nativeMetadata: true);
        await fence!.verify();
        await lease.verify();
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        initialHost.onStatus = null;
        reservation?.close();
        tree.close();
        storage.close();
        parent.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'preserving the post-upgrade generation moves all state under two persistent fences',
    () async {
      final parent = await OwnedImageDirectory.open(temporary);
      final storage = parent.createDirectory('preservation-work');
      final tree = await MaintenanceTree.open(state);
      PreservedColdState? preserved;
      try {
        for (final relative in [
          'vms',
          'vms/failed-vm',
          'artifacts',
          'artifacts/failed-run',
          'logs',
          '.staging',
          '.staging/interrupted',
          'run',
        ]) {
          final directory = await Directory('${state.path}/$relative').create();
          imageFileMode(directory.path, 0x1c0);
        }
        for (final entry in {
          'vms/failed-vm/disk.raw': [0, 255, 2, 127],
          'vms/failed-vm/nvram.bin': [3, 0, 254],
          'artifacts/failed-run/diagnostic': utf8.encode(
            'retain failed output',
          ),
          'logs/serial.log': utf8.encode('retain serial history'),
          '.staging/interrupted/unknown': utf8.encode('never discard staging'),
          'run/retained-metadata': utf8.encode(
            'included, not snapshot-excluded',
          ),
        }.entries) {
          final file = await File(
            '${state.path}/${entry.key}',
          ).writeAsBytes(entry.value, flush: true);
          imageFileMode(file.path, 0x180);
        }
        fence = await MaintenanceStateFence.begin(lease);
        final before = await tree.capture(nativeMetadata: true);
        var checked = false;
        preserved = await lease.preserveForRollback(
          fence!,
          storage,
          'retained-current',
          verifyPreparedInputs: () async {
            checked = true;
            await tree.verify(before, nativeMetadata: true);
          },
        );
        expect(checked, true);
        expect(preserved.path, '${storage.path}/retained-current/state');
        expect(preserved.toJson()['phase'], 'current_state_preserved');
        expect(preserved.toJson()['committed'], false);
        expect(preserved.toJson()['startup_allowed'], false);
        await expectLater(lease.verify(), throwsStateError);
        lease.close();
        await preserved.verify();
        final root = await OwnedImageDirectory.open(Directory(preserved.path));
        final competing = await root.tryAcquireMaintenanceLock(
          '.gaovmd.lock',
          create: false,
        );
        try {
          expect(competing, isNull);
        } finally {
          competing?.close();
          root.close();
        }
        final retained = await MaintenanceTree.open(Directory(preserved.path));
        try {
          await retained.verify(before, nativeMetadata: true);
          expect(
            await File(
              '${preserved.path}/run/retained-metadata',
            ).readAsString(),
            'included, not snapshot-excluded',
          );
        } finally {
          retained.close();
        }
        for (final path in [state, Directory(preserved.path)]) {
          await expectLater(
            MaintenanceStateFence.requireUnfenced(path),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        }
        preserved.close();
        for (final path in [state, Directory(preserved.path)]) {
          await expectLater(
            MaintenanceStateFence.requireUnfenced(path),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        }
        expect(await state.exists(), false);
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        preserved?.close();
        tree.close();
        storage.close();
        parent.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'preservation refuses special runtime entries instead of omitting them',
    () async {
      final parent = await OwnedImageDirectory.open(temporary);
      final storage = parent.createDirectory('preservation-work');
      final run = await Directory('${state.path}/run').create();
      imageFileMode(run.path, 0x1c0);
      final socketPath = '${run.path}/retained.sock';
      final socket = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      try {
        fence = await MaintenanceStateFence.begin(lease);
        final bytes = await File('${state.path}/gaovm.db').readAsBytes();
        await expectLater(
          lease.preserveForRollback(
            fence!,
            storage,
            'retained-current',
            verifyPreparedInputs: () async => fail('special entry was omitted'),
          ),
          throwsFormatException,
        );
        expect(await state.exists(), true);
        expect(maintenancePathEntryExists(socketPath), true);
        expect(await File('${state.path}/gaovm.db').readAsBytes(), bytes);
        expect(
          await Directory('${storage.path}/retained-current').exists(),
          true,
        );
        expect(
          await Directory('${storage.path}/retained-current/state').exists(),
          false,
        );
        final actual = await OwnedImageDirectory.open(state);
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
        } finally {
          actual.close();
        }
        await lease.verify();
        await expectLater(
          MaintenanceStateFence.requireUnfenced(state),
          throwsA(isA<MaintenanceFenceActive>()),
        );
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        await socket.close();
        storage.close();
        parent.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'preserved generation reopens its fixed checkpoint with fresh real ownership',
    () async {
      final parent = await OwnedImageDirectory.open(temporary);
      final storage = parent.createDirectory('preservation-work');
      PreservedColdState? preserved;
      MaintenanceTree? retained;
      try {
        fence = await MaintenanceStateFence.begin(lease);
        preserved = await lease.preserveForRollback(
          fence!,
          storage,
          'retained-current',
          verifyPreparedInputs: () async {},
        );
        final before = preserved.toJson();
        preserved.close();
        fence!.close();
        fence = await MaintenanceStateFence.open(state);
        retained = await MaintenanceTree.open(temporary);
        final files = await retained.capture(nativeMetadata: true);
        preserved = await PreservedColdState.open(
          state,
          fence!,
          storage,
          'retained-current',
          bundleIdentifier: 'org.gaovm.tests.Fence',
          host: _Host(initialHost.appPath),
        );
        expect(preserved.toJson(), before);
        await preserved.verify();
        await retained.verify(files, nativeMetadata: true);
        final root = await OwnedImageDirectory.open(Directory(preserved.path));
        final other = await root.tryAcquireMaintenanceLock(
          '.gaovmd.lock',
          create: false,
        );
        try {
          expect(other, isNull);
        } finally {
          other?.close();
          root.close();
        }
        for (final path in [state, Directory(preserved.path)]) {
          await expectLater(
            MaintenanceStateFence.requireUnfenced(path),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        }
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        preserved?.close();
        retained?.close();
        storage.close();
        parent.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'preservation keeps the original owner until its pending callback settles',
    () async {
      final parent = await OwnedImageDirectory.open(temporary);
      final storage = parent.createDirectory('preservation-work');
      final entered = Completer<void>(), release = Completer<void>();
      PreservedColdState? preserved;
      Future<void>? pending;
      Object? failure;
      try {
        fence = await MaintenanceStateFence.begin(lease);
        pending = lease
            .preserveForRollback(
              fence!,
              storage,
              'retained-current',
              verifyPreparedInputs: () async {
                entered.complete();
                await release.future;
              },
            )
            .then<void>(
              (value) {
                preserved = value;
              },
              onError: (Object error, StackTrace stack) {
                failure = error;
              },
            );
        await entered.future;
        expect(lease.close, throwsStateError);
        await expectLater(
          lease.preserveForRollback(
            fence!,
            storage,
            'another',
            verifyPreparedInputs: () async {},
          ),
          throwsStateError,
        );
        final root = await OwnedImageDirectory.open(state);
        final contender = await root.tryAcquireMaintenanceLock(
          '.gaovmd.lock',
          create: false,
        );
        try {
          expect(contender, isNull);
        } finally {
          contender?.close();
          root.close();
        }
        expect(await state.exists(), true);
        release.complete();
        await pending;
        expect(failure, isNull);
        await preserved!.verify();
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        if (!release.isCompleted) release.complete();
        await pending;
        preserved?.close();
        storage.close();
        parent.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final interrupted in ['completion absent', 'completion staged']) {
    test(
      'preserved recovery finishes $interrupted only after fresh cold ownership',
      () async {
        final parent = await OwnedImageDirectory.open(temporary);
        final storage = parent.createDirectory('preservation-work');
        final checkpoint = '${storage.path}/retained-current';
        final retainedPath = '$checkpoint/state';
        final source = await MaintenanceTree.open(state);
        PreservedColdState? preserved;
        MaintenanceTree? retained;
        try {
          final before = await source.capture(nativeMetadata: true);
          fence = await MaintenanceStateFence.begin(lease);
          initialHost.onStatus = () async {
            if (!await Directory('$checkpoint/completed').exists()) return;
            initialHost.onStatus = null;
            throw const ColdStateFailure(
              'injected_after_move',
              'retain the moved generation and both fences',
            );
          };
          await expectLater(
            lease.preserveForRollback(
              fence!,
              storage,
              'retained-current',
              verifyPreparedInputs: () async {},
            ),
            throwsA(
              isA<ColdStateFailure>().having(
                (failure) => failure.stage,
                'stage',
                'injected_after_move',
              ),
            ),
          );
          expect(await state.exists(), false);
          retained = await MaintenanceTree.open(Directory(retainedPath));
          await retained.verify(before, nativeMetadata: true);
          final actual = await OwnedImageDirectory.open(
            Directory(retainedPath),
          );
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
          } finally {
            actual.close();
          }
          // The failed original future is terminal before releasing its owner.
          lease.close();
          fence!.close();
          await Directory('$checkpoint/completed').rename(
            interrupted == 'completion staged'
                ? '$checkpoint/.completed.partial'
                : '${temporary.path}/retained-completion-evidence',
          );
          final intent = await File('$checkpoint/intent.json').readAsBytes();
          final prepared = await File(
            '$checkpoint/prepared/record.json',
          ).readAsBytes();
          fence = await MaintenanceStateFence.open(state);
          final observations = _Host(initialHost.appPath);
          preserved = await PreservedColdState.open(
            state,
            fence!,
            storage,
            'retained-current',
            bundleIdentifier: 'org.gaovm.tests.Fence',
            host: observations,
          );
          expect(observations.serviceCalls, greaterThan(0));
          expect(preserved.toJson()['startup_allowed'], false);
          expect(preserved.toJson()['committed'], false);
          expect(await Directory('$checkpoint/completed').exists(), true);
          expect(
            await Directory('$checkpoint/.completed.partial').exists(),
            false,
          );
          expect(await File('$checkpoint/intent.json').readAsBytes(), intent);
          expect(
            await File('$checkpoint/prepared/record.json').readAsBytes(),
            prepared,
          );
          await retained.verify(before, nativeMetadata: true);
          await preserved.verify();
          for (final target in [state, Directory(retainedPath)]) {
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          initialHost.onStatus = null;
          preserved?.close();
          retained?.close();
          source.close();
          storage.close();
          parent.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  for (final change in [
    'unknown entry',
    'changed bytes',
    'changed metadata',
    'forged completion',
    'incomplete completion',
    'ambiguous completion',
    'incomplete preparation',
    'changed checkpoint permissions',
    'copied inode',
    'missing ownership file',
    'occupied original slot',
  ]) {
    test(
      'preserved recovery retains $change without repair or cold helper execution',
      () async {
        final parent = await OwnedImageDirectory.open(temporary);
        final storage = parent.createDirectory('preservation-work');
        PreservedColdState? preserved;
        MaintenanceTree? all;
        try {
          fence = await MaintenanceStateFence.begin(lease);
          preserved = await lease.preserveForRollback(
            fence!,
            storage,
            'retained-current',
            verifyPreparedInputs: () async {},
          );
          final retainedPath = preserved.path;
          final checkpoint = '${storage.path}/retained-current';
          preserved.close();
          switch (change) {
            case 'unknown entry':
              final file = await File(
                '$checkpoint/foreign',
              ).writeAsString('retain');
              imageFileMode(file.path, 0x180);
            case 'changed bytes':
              await File(
                '$retainedPath/gaovm.db',
              ).writeAsString('retain changed generation', flush: true);
            case 'changed metadata':
              imageFileMode('$retainedPath/gaovm.db', 0x1a0);
            case 'forged completion':
              final file = File('$checkpoint/completed/record.json');
              final value =
                  jsonDecode(await file.readAsString()) as Map<String, Object?>;
              value['startup_allowed'] = true;
              imageFileMode(file.path, 0x180);
              await file.writeAsString('${jsonEncode(value)}\n', flush: true);
              imageFileMode(file.path, 0x100);
            case 'incomplete completion':
              await Directory(
                '$checkpoint/completed',
              ).rename('$checkpoint/.completed.partial');
              await File(
                '$checkpoint/.completed.partial/record.json',
              ).rename('${temporary.path}/retained-incomplete-completion');
            case 'ambiguous completion':
              await Directory('$checkpoint/.completed.partial').create();
              imageFileMode('$checkpoint/.completed.partial', 0x1c0);
            case 'incomplete preparation':
              await File(
                '$checkpoint/prepared/record.json',
              ).rename('${temporary.path}/retained-incomplete-preparation');
            case 'changed checkpoint permissions':
              imageFileMode(checkpoint, 0x1ed);
            case 'copied inode':
              final tree = await MaintenanceTree.open(Directory(retainedPath));
              try {
                await tree.snapshotTo(storage, 'copy');
              } finally {
                tree.close();
              }
              await Directory(
                retainedPath,
              ).rename('${temporary.path}/original-generation');
              await Directory(
                '${storage.path}/copy/payload',
              ).rename(retainedPath);
            case 'missing ownership file':
              await File(
                '$retainedPath/.gaovmd.lock',
              ).rename('${temporary.path}/retained-state-lock');
            case 'occupied original slot':
              await state.create();
              imageFileMode(state.path, 0x1c0);
              final file = await File(
                '${state.path}/foreign',
              ).writeAsString('never adopt');
              imageFileMode(file.path, 0x180);
          }
          all = await MaintenanceTree.open(temporary);
          final before = await all.capture(nativeMetadata: true);
          final observations = _Host(initialHost.appPath);
          await expectLater(
            () async {
              preserved = await PreservedColdState.open(
                state,
                fence!,
                storage,
                'retained-current',
                bundleIdentifier: 'org.gaovm.tests.Fence',
                host: observations,
              );
            },
            throwsA(anyOf(isA<FormatException>(), isA<FileSystemException>())),
          );
          expect(observations.serviceCalls, 0);
          await all.verify(before, nativeMetadata: true);
          for (final target in [state, Directory(retainedPath)]) {
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          preserved?.close();
          all?.close();
          storage.close();
          parent.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  for (final failure in [
    'registered service',
    'unresolved driver',
    'reference',
    'late bytes',
  ]) {
    test(
      'post-move recovery retains its checkpoint after $failure',
      () async {
        final parent = await OwnedImageDirectory.open(temporary);
        final storage = parent.createDirectory('preservation-work');
        PreservedColdState? preserved;
        MaintenanceTree? all;
        try {
          fence = await MaintenanceStateFence.begin(lease);
          preserved = await lease.preserveForRollback(
            fence!,
            storage,
            'retained-current',
            verifyPreparedInputs: () async {},
          );
          final retainedPath = preserved.path;
          final checkpoint = '${storage.path}/retained-current';
          preserved.close();
          await Directory(
            '$checkpoint/completed',
          ).rename('${temporary.path}/retained-completion-evidence');
          all = await MaintenanceTree.open(temporary);
          var expected = await all.capture(nativeMetadata: true);
          final observations = _Host(initialHost.appPath);
          switch (failure) {
            case 'registered service':
              observations.registered = true;
            case 'unresolved driver':
              observations.unresolvedDriver = true;
            case 'reference':
              observations.references = {pid + 99};
            case 'late bytes':
              observations.onStatus = () async {
                observations.onStatus = null;
                await File(
                  '$retainedPath/gaovm.db',
                ).writeAsString('retain late changed generation', flush: true);
                expected = await all!.capture(nativeMetadata: true);
              };
          }
          await expectLater(() async {
            preserved = await PreservedColdState.open(
              state,
              fence!,
              storage,
              'retained-current',
              bundleIdentifier: 'org.gaovm.tests.Fence',
              host: observations,
            );
          }, throwsA(anyOf(isA<ColdStateFailure>(), isA<FormatException>())));
          expect(await Directory('$checkpoint/completed').exists(), false);
          expect(
            await Directory('$checkpoint/.completed.partial').exists(),
            false,
          );
          await all.verify(expected, nativeMetadata: true);
          for (final target in [state, Directory(retainedPath)]) {
            await expectLater(
              MaintenanceStateFence.requireUnfenced(target),
              throwsA(isA<MaintenanceFenceActive>()),
            );
          }
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          preserved?.close();
          all?.close();
          storage.close();
          parent.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'cold commit retires the exact fence while retaining real state ownership',
    () async {
      final destinationDirectory = await Directory(
        '${temporary.path}/commit',
      ).create();
      imageFileMode(destinationDirectory.path, 0x1c0);
      final destination = await OwnedImageDirectory.open(destinationDirectory);
      final stateTree = await MaintenanceTree.open(state);
      try {
        fence = await MaintenanceStateFence.begin(lease);
        final marker = fence!.path;
        final original = await OwnedImageDirectory.open(Directory(marker));
        late Map<String, Object?> identity;
        try {
          identity = await original.maintenanceIdentity();
        } finally {
          original.close();
        }
        final intent = await File('$marker/intent.json').readAsBytes();
        final before = await stateTree.capture(nativeMetadata: true);
        var checked = false;
        await lease.commitStartupFence(
          fence!,
          destination,
          verifyPreparedInputs: () async {
            checked = true;
            await stateTree.verify(before, nativeMetadata: true);
          },
        );
        expect(checked, true);
        expect(fence!.path, marker);
        expect(await Directory(marker).exists(), false);
        final retired = destination.directory('retired-fence');
        final root = await OwnedImageDirectory.open(state);
        DaemonOwnership? contender;
        try {
          expect(await retired.maintenanceIdentity(), identity);
          expect(
            await File('${retired.path}/intent.json').readAsBytes(),
            intent,
          );
          await fence!.verifyFor(root);
          await MaintenanceStateFence.requireUnfenced(state);
          contender = await DaemonOwnership.tryAcquire(root);
          expect(contender, isNull);
          await stateTree.verify(before, nativeMetadata: true);
        } finally {
          contender?.close();
          root.close();
          retired.close();
        }
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        stateTree.close();
        destination.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'cold commit recovery reacquires the retained fence and original state lock',
    () async {
      final directory = await Directory('${temporary.path}/commit').create();
      imageFileMode(directory.path, 0x1c0);
      final checkpoint = await OwnedImageDirectory.open(directory);
      try {
        fence = await MaintenanceStateFence.begin(lease);
        final marker = fence!.path;
        final root = await OwnedImageDirectory.open(Directory(marker));
        late Map<String, Object?> identity;
        try {
          identity = await root.maintenanceIdentity();
        } finally {
          root.close();
        }
        final digest =
            'sha256:${sha256.convert(await File('$marker/intent.json').readAsBytes())}';
        await lease.commitStartupFence(
          fence!,
          checkpoint,
          verifyPreparedInputs: () async {},
        );
        fence!.close();
        lease.close();
        fence = await MaintenanceStateFence.openRetiredForCommit(
          state,
          checkpoint,
          expectedIdentity: identity,
          expectedIntentDigest: digest,
        );
        lease = await ColdStateLease.acquire(
          state,
          bundleIdentifier: 'org.gaovm.tests.Fence',
          host: initialHost,
          maintenanceFence: fence,
        );
        expect(fence!.path, marker);
        expect(fence!.retainedPath, '${checkpoint.path}/retired-fence');
        expect(fence!.retiredForCommit, true);
        await lease.verify();
        await MaintenanceStateFence.requireUnfenced(state);
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        checkpoint.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final change in ['identity', 'digest', 'active-marker']) {
    test(
      'cold commit recovery refuses a changed $change without repairing output',
      () async {
        final directory = await Directory('${temporary.path}/commit').create();
        imageFileMode(directory.path, 0x1c0);
        final checkpoint = await OwnedImageDirectory.open(directory);
        MaintenanceTree? retained;
        try {
          fence = await MaintenanceStateFence.begin(lease);
          final marker = fence!.path;
          final root = await OwnedImageDirectory.open(Directory(marker));
          late Map<String, Object?> identity;
          try {
            identity = await root.maintenanceIdentity();
          } finally {
            root.close();
          }
          var digest =
              'sha256:${sha256.convert(await File('$marker/intent.json').readAsBytes())}';
          await lease.commitStartupFence(
            fence!,
            checkpoint,
            verifyPreparedInputs: () async {},
          );
          fence!.close();
          lease.close();
          if (change == 'identity') {
            identity = {...identity, 'inode': (identity['inode'] as int) + 1};
          } else if (change == 'digest') {
            digest = 'sha256:${'00' * 32}';
          } else {
            await File(marker).writeAsString('foreign marker\n');
            imageFileMode(marker, 0x180);
          }
          retained = await MaintenanceTree.open(temporary);
          final before = await retained.capture(nativeMetadata: true);
          await expectLater(
            MaintenanceStateFence.openRetiredForCommit(
              state,
              checkpoint,
              expectedIdentity: identity,
              expectedIntentDigest: digest,
            ),
            throwsFormatException,
          );
          await retained.verify(before, nativeMetadata: true);
          expect(
            await Directory('${checkpoint.path}/retired-fence').exists(),
            true,
          );
          expect(await File('$marker.lock').exists(), true);
        } catch (_) {
          retainInputs = true;
          rethrow;
        } finally {
          retained?.close();
          checkpoint.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'cold commit keeps its owner during a pending verification and preserves a refused fence',
    () async {
      final directory = await Directory('${temporary.path}/commit').create();
      imageFileMode(directory.path, 0x1c0);
      final checkpoint = await OwnedImageDirectory.open(directory);
      final entered = Completer<void>(), release = Completer<void>();
      Future<void>? pending;
      Object? failure;
      var settled = false;
      try {
        fence = await MaintenanceStateFence.begin(lease);
        pending = lease
            .commitStartupFence(
              fence!,
              checkpoint,
              verifyPreparedInputs: () async {
                entered.complete();
                await release.future;
                throw const FormatException(
                  'injected final verification refusal',
                );
              },
            )
            .then<void>(
              (_) => fail('refused verification cannot commit'),
              onError: (Object error) {
                failure = error;
              },
            )
            .whenComplete(() {
              settled = true;
            });
        await entered.future;
        expect(lease.close, throwsStateError);
        expect(settled, false);
        final root = await OwnedImageDirectory.open(state);
        OwnedImageLock? contender;
        try {
          contender = await root.tryAcquireMaintenanceLock(
            '.gaovmd.lock',
            create: false,
          );
          expect(contender, isNull);
        } finally {
          contender?.close();
          root.close();
        }
        await expectLater(
          MaintenanceStateFence.requireUnfenced(state),
          throwsA(isA<MaintenanceFenceActive>()),
        );
        release.complete();
        await pending;
        expect(failure, isA<FormatException>());
        expect(
          await Directory('${checkpoint.path}/retired-fence').exists(),
          false,
        );
        await fence!.verify();
        await lease.verify();
      } catch (_) {
        retainInputs = true;
        rethrow;
      } finally {
        if (!release.isCompleted) release.complete();
        await pending;
        checkpoint.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'ordinary cold ownership and a fence cannot grant candidate state borrowing',
    () async {
      var called = false;
      Future<void> tryBorrow() => lease.withCandidateState((_, __) async {
        called = true;
      });
      await expectLater(tryBorrow(), throwsStateError);
      fence = await MaintenanceStateFence.begin(lease);
      await expectLater(tryBorrow(), throwsStateError);
      expect(called, false);
      await lease.verify();
      final root = await OwnedImageDirectory.open(state);
      try {
        expect(
          await root.tryAcquireMaintenanceLock('.gaovmd.lock', create: false),
          isNull,
        );
      } finally {
        root.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'persistent fence refuses ordinary startup after maintenance ownership closes',
    () async {
      fence = await MaintenanceStateFence.begin(lease);
      final marker = fence!.path;
      fence!.close();
      lease.close();
      final tree = await MaintenanceTree.open(state);
      try {
        final before = await tree.capture(nativeMetadata: true);
        await expectLater(
          DaemonApplication.start(
            stateDirectory: state,
            driverBinary: '${temporary.path}/must-not-resolve',
            openApiDocument: const {},
          ),
          throwsA(isA<MaintenanceFenceActive>()),
        );
        expect(await Directory(marker).exists(), true);
        expect(await Directory('${state.path}/run').exists(), false);
        await tree.verify(before, nativeMetadata: true);
      } finally {
        tree.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'fenced state refuses new ownership before touching its lock',
    () async {
      fence = await MaintenanceStateFence.begin(lease);
      fence!.close();
      lease.close();
      final lock = File('${state.path}/.gaovmd.lock');
      imageFileMode(lock.path, 0x100);
      final root = await OwnedImageDirectory.open(state);
      DaemonOwnership? owner;
      try {
        await expectLater(() async {
          owner = await DaemonOwnership.tryAcquire(root);
        }(), throwsA(isA<MaintenanceFenceActive>()));
        final retained = root.file('.gaovmd.lock');
        try {
          expect(retained.stat().mode & 0xfff, 0x100);
        } finally {
          retained.close();
        }
      } finally {
        owner?.close();
        root.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'explicit recovery rechecks cold ownership without clearing admission',
    () async {
      fence = await MaintenanceStateFence.begin(lease);
      final marker = fence!.path;
      fence!.close();
      lease.close();
      fence = await MaintenanceStateFence.open(state);
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Fence',
        host: _Host('${temporary.path}/GaoVM.app'),
        maintenanceFence: fence,
      );
      await lease.verify();
      expect(fence!.path, marker);
      expect(await Directory(marker).exists(), true);
      await expectLater(
        MaintenanceStateFence.requireUnfenced(state),
        throwsA(isA<MaintenanceFenceActive>()),
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'rename gap cannot recreate state or initialize SQLite',
    () async {
      fence = await MaintenanceStateFence.begin(lease);
      final retired = await state.rename('${temporary.path}/retained-state');
      final tree = await MaintenanceTree.open(retired);
      try {
        final before = await tree.capture(nativeMetadata: true);
        await expectLater(
          DaemonApplication.start(
            stateDirectory: state,
            driverBinary: '${temporary.path}/must-not-resolve',
            openApiDocument: const {},
          ),
          throwsA(isA<MaintenanceFenceActive>()),
        );
        expect(await state.exists(), false);
        await tree.verify(before, nativeMetadata: true);
        await fence!.verify();
      } finally {
        tree.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'copied state lock does not admit a replacement inode to recovery',
    () async {
      fence = await MaintenanceStateFence.begin(lease);
      fence!.close();
      lease.close();
      final retained = await state.rename('${temporary.path}/retained-state');
      await state.create();
      imageFileMode(state.path, 0x1c0);
      await File(
        '${retained.path}/.gaovmd.lock',
      ).copy('${state.path}/.gaovmd.lock');
      await File(
        '${state.path}/unknown-data',
      ).writeAsString('retain replacement');
      final tree = await MaintenanceTree.open(state);
      final retainedTree = await MaintenanceTree.open(retained);
      try {
        final before = await tree.capture(nativeMetadata: true);
        final retainedBefore = await retainedTree.capture(nativeMetadata: true);
        fence = await MaintenanceStateFence.open(state);
        await expectLater(
          ColdStateLease.acquire(
            state,
            bundleIdentifier: 'org.gaovm.tests.Fence',
            host: _Host('${temporary.path}/GaoVM.app'),
            maintenanceFence: fence,
          ),
          throwsFormatException,
        );
        await expectLater(
          DaemonApplication.start(
            stateDirectory: state,
            driverBinary: '${temporary.path}/must-not-resolve',
            openApiDocument: const {},
          ),
          throwsA(isA<MaintenanceFenceActive>()),
        );
        expect(await File('${state.path}/gaovm.db').exists(), false);
        await tree.verify(before, nativeMetadata: true);
        await retainedTree.verify(retainedBefore, nativeMetadata: true);
      } finally {
        retainedTree.close();
        tree.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unreadable maintenance namespace is not treated as absent',
    () async {
      fence = await MaintenanceStateFence.begin(lease);
      imageFileMode(temporary.path, 0);
      try {
        await expectLater(
          MaintenanceStateFence.requireUnfenced(state),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        imageFileMode(temporary.path, 0x1c0);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'recovery is exclusive and does not bypass the original state owner',
    () async {
      fence = await MaintenanceStateFence.begin(lease);
      await expectLater(MaintenanceStateFence.open(state), throwsStateError);
      fence!.close();
      fence = await MaintenanceStateFence.open(state);
      await expectLater(
        ColdStateLease.acquire(
          state,
          bundleIdentifier: 'org.gaovm.tests.Fence',
          host: _Host('${temporary.path}/GaoVM.app'),
          maintenanceFence: fence,
        ),
        throwsA(
          isA<ColdStateFailure>().having(
            (failure) => failure.stage,
            'stage',
            'ownership',
          ),
        ),
      );
      await lease.verify();
      await fence!.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'maintenance process crash retains durable admission and permits cold recovery',
    () async {
      lease.close();
      final process = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/test/fixtures/hold_maintenance_state_fence.dart',
        state.path,
        '${temporary.path}/GaoVM.app',
      ]);
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      final first = lines.first;
      final child = OwnedTestProcess(process, stdoutCapture: lines.join('\n'));
      children.add(child);
      final marker = await first.timeout(const Duration(seconds: 10));
      expect(await Directory(marker).exists(), true);
      await expectLater(MaintenanceStateFence.open(state), throwsStateError);
      expect(process.kill(ProcessSignal.sigkill), true);
      final result = await child.result();
      expect(child.exitConfirmed, true);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, isEmpty);
      await expectLater(
        MaintenanceStateFence.requireUnfenced(state),
        throwsA(isA<MaintenanceFenceActive>()),
      );
      fence = await MaintenanceStateFence.open(state);
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Fence',
        host: _Host('${temporary.path}/GaoVM.app'),
        maintenanceFence: fence,
      );
      await lease.verify();
      expect(await Directory(marker).exists(), true);
    },
    skip: !Platform.isMacOS,
  );

  for (final stage in [
    'service',
    'daemon_processes',
    'driver_processes',
    'state_references',
  ]) {
    test('recovery still refuses fresh $stage evidence', () async {
      fence = await MaintenanceStateFence.begin(lease);
      fence!.close();
      lease.close();
      fence = await MaintenanceStateFence.open(state);
      final host = _Host('${temporary.path}/GaoVM.app');
      switch (stage) {
        case 'service':
          host.registered = true;
        case 'daemon_processes':
          host.daemonRemains = true;
        case 'driver_processes':
          host.unresolvedDriver = true;
        case 'state_references':
          host.references = {pid, pid + 1};
      }
      await expectLater(
        ColdStateLease.acquire(
          state,
          bundleIdentifier: 'org.gaovm.tests.Fence',
          host: host,
          maintenanceFence: fence,
        ),
        throwsA(
          isA<ColdStateFailure>().having(
            (failure) => failure.stage,
            'stage',
            stage,
          ),
        ),
      );
      await fence!.verify();
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Fence',
        host: _Host('${temporary.path}/GaoVM.app'),
        maintenanceFence: fence,
      );
      await lease.verify();
    }, skip: !Platform.isMacOS);
  }

  for (final kind in ['file', 'symlink', 'empty-directory']) {
    test(
      'foreign $kind marker refuses admission without repair',
      () async {
        fence = await MaintenanceStateFence.begin(lease);
        final path = fence!.path;
        fence!.close();
        lease.close();
        final retained = await Directory(path).rename('$path.retained');
        final tree = await MaintenanceTree.open(retained);
        try {
          final before = await tree.capture(nativeMetadata: true);
          switch (kind) {
            case 'file':
              await File(path).writeAsString('unknown marker');
            case 'symlink':
              await Link(path).create(retained.path);
            case 'empty-directory':
              await Directory(path).create();
          }
          await expectLater(
            DaemonApplication.start(
              stateDirectory: state,
              driverBinary: '${temporary.path}/must-not-resolve',
              openApiDocument: const {},
            ),
            throwsA(isA<MaintenanceFenceActive>()),
          );
          await expectLater(
            MaintenanceStateFence.open(state),
            throwsA(anyOf(isA<FormatException>(), isA<FileSystemException>())),
          );
          switch (kind) {
            case 'file':
              expect(await File(path).readAsString(), 'unknown marker');
            case 'symlink':
              expect(await Link(path).target(), retained.path);
            case 'empty-directory':
              expect(await Directory(path).list().toList(), isEmpty);
          }
          await tree.verify(before, nativeMetadata: true);
        } finally {
          tree.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  for (final damage in [
    'json',
    'format',
    'state-path',
    'extra-field',
    'identity',
    'oversized',
  ]) {
    test(
      'damaged $damage intent is retained and cannot authorize recovery',
      () async {
        fence = await MaintenanceStateFence.begin(lease);
        final path = fence!.path;
        fence!.close();
        lease.close();
        final record = File('$path/intent.json');
        final value =
            jsonDecode(await record.readAsString()) as Map<String, Object?>;
        switch (damage) {
          case 'format':
            value['format'] = 'gaovm.maintenance-state-fence.v999';
          case 'state-path':
            value['state_path'] = '${temporary.path}/not-authorized';
          case 'extra-field':
            value['clear_fence'] = true;
          case 'identity':
            (value['state_identity'] as Map)['inode'] = true;
        }
        imageFileMode(record.path, 0x180);
        await record.writeAsString(switch (damage) {
          'json' => '{broken',
          'oversized' => 'x' * 16385,
          _ => '${jsonEncode(value)}\n',
        });
        imageFileMode(record.path, 0x100);
        final tree = await MaintenanceTree.open(Directory(path));
        try {
          final before = await tree.capture(nativeMetadata: true);
          await expectLater(
            MaintenanceStateFence.open(state),
            throwsFormatException,
          );
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
          await tree.verify(before, nativeMetadata: true);
          expect(await Directory('${state.path}/run').exists(), false);
        } finally {
          tree.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  test('recovery never recreates a missing namespace lock', () async {
    fence = await MaintenanceStateFence.begin(lease);
    final path = fence!.path;
    fence!.close();
    lease.close();
    final retained = await File('$path.lock').rename('$path.lock.retained');
    final tree = await MaintenanceTree.open(Directory(path));
    try {
      final before = await tree.capture(nativeMetadata: true);
      await expectLater(
        MaintenanceStateFence.open(state),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File('$path.lock').exists(), false);
      expect(await retained.readAsBytes(), isEmpty);
      await tree.verify(before, nativeMetadata: true);
      await expectLater(
        MaintenanceStateFence.requireUnfenced(state),
        throwsA(isA<MaintenanceFenceActive>()),
      );
    } finally {
      tree.close();
    }
  }, skip: !Platform.isMacOS);

  for (final damage in ['permissions', 'contents', 'hardlink', 'acl']) {
    test(
      'foreign $damage namespace lock is never normalized',
      () async {
        fence = await MaintenanceStateFence.begin(lease);
        final path = '${fence!.path}.lock';
        fence!.close();
        lease.close();
        switch (damage) {
          case 'permissions':
            imageFileMode(path, 0x1a4);
          case 'contents':
            await File(path).writeAsString('foreign namespace lock');
          case 'hardlink':
            expect(
              (await command('/bin/ln', [path, '$path.alias'])).exitCode,
              0,
            );
          case 'acl':
            final user = (await command('/usr/bin/id', [
              '-un',
            ])).stdout.toString().trim();
            expect(
              (await command('/bin/chmod', [
                '+a',
                'user:$user allow read',
                path,
              ])).exitCode,
              0,
            );
        }
        final held = await OwnedImageFile.open(File(path));
        try {
          final before = held.stat();
          final metadata = await held.maintenanceMetadata();
          final bytes = await held.readBounded(1024);
          await expectLater(
            MaintenanceStateFence.open(state),
            throwsFormatException,
          );
          expect(held.stat(), before);
          expect(await held.maintenanceMetadata(), metadata);
          expect(await held.readBounded(1024), bytes);
          await held.verifyPathBinding();
          await expectLater(
            MaintenanceStateFence.requireUnfenced(state),
            throwsA(isA<MaintenanceFenceActive>()),
          );
        } finally {
          held.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  for (final mismatch in ['app', 'bundle']) {
    test(
      'recovery refuses a different owning $mismatch before state-lock mutation',
      () async {
        fence = await MaintenanceStateFence.begin(lease);
        fence!.close();
        lease.close();
        fence = await MaintenanceStateFence.open(state);
        imageFileMode('${state.path}/.gaovmd.lock', 0x100);
        final tree = await MaintenanceTree.open(state);
        final host = _Host(
          '${temporary.path}/${mismatch == 'app' ? 'Other' : 'GaoVM'}.app',
        );
        try {
          final before = await tree.capture(nativeMetadata: true);
          await expectLater(
            ColdStateLease.acquire(
              state,
              bundleIdentifier: mismatch == 'bundle'
                  ? 'org.gaovm.tests.Other'
                  : 'org.gaovm.tests.Fence',
              host: host,
              maintenanceFence: fence,
            ),
            throwsFormatException,
          );
          expect(host.serviceCalls, 0);
          await tree.verify(before, nativeMetadata: true);
        } finally {
          tree.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'last native recovery callback cannot change the held maintenance intent',
    () async {
      fence = await MaintenanceStateFence.begin(lease);
      fence!.close();
      lease.close();
      fence = await MaintenanceStateFence.open(state);
      final host = _Host('${temporary.path}/GaoVM.app');
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Fence',
        host: host,
        maintenanceFence: fence,
      );
      final tree = await MaintenanceTree.open(state);
      final otherRoot = await OwnedImageDirectory.open(state);
      try {
        final before = await tree.capture(nativeMetadata: true);
        host.onStatus = () async {
          host.onStatus = null;
          final record = File('${fence!.path}/intent.json');
          imageFileMode(record.path, 0x180);
          await record.writeAsString('{}\n');
          imageFileMode(record.path, 0x100);
        };
        await expectLater(lease.verify(), throwsFormatException);
        final contender = await otherRoot.tryAcquireLock('.gaovmd.lock');
        try {
          expect(contender, isNull);
        } finally {
          contender?.close();
        }
        await tree.verify(before, nativeMetadata: true);
        expect(await File('${fence!.path}/intent.json').readAsString(), '{}\n');
      } finally {
        otherRoot.close();
        tree.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final phase in ['before-publication', 'after-publication']) {
    test(
      '$phase failure retains checkpoint and caller-owned source',
      () async {
        final tree = await MaintenanceTree.open(state);
        try {
          final before = await tree.capture(nativeMetadata: true);
          initialHost.onStatus = () async {
            final entries = await temporary.list(followLinks: false).toList();
            final exists = entries.whereType<Directory>().any(
              (entry) =>
                  entry.path.contains('/.gaovmd-maintenance-') &&
                  entry.path.endsWith('.partial') ==
                      (phase == 'before-publication'),
            );
            if (exists) initialHost.registered = true;
          };
          await expectLater(
            MaintenanceStateFence.begin(lease),
            throwsA(
              isA<ColdStateFailure>().having(
                (failure) => failure.stage,
                'stage',
                'service',
              ),
            ),
          );
          initialHost.onStatus = null;
          initialHost.registered = false;
          final checkpoints = await temporary
              .list(followLinks: false)
              .where(
                (entry) =>
                    entry is Directory &&
                    entry.path.contains('/.gaovmd-maintenance-'),
              )
              .toList();
          expect(checkpoints, hasLength(1));
          expect(
            checkpoints.single.path.endsWith('.partial'),
            phase == 'before-publication',
          );
          expect(
            await File('${checkpoints.single.path}/intent.json').exists(),
            true,
          );
          if (phase == 'before-publication') {
            await MaintenanceStateFence.requireUnfenced(state);
            await expectLater(
              MaintenanceStateFence.begin(lease),
              throwsFormatException,
            );
          } else {
            await expectLater(
              MaintenanceStateFence.requireUnfenced(state),
              throwsA(isA<MaintenanceFenceActive>()),
            );
            fence = await MaintenanceStateFence.open(state);
            await fence!.verify();
          }
          await lease.verify();
          await tree.verify(before, nativeMetadata: true);
        } finally {
          initialHost.onStatus = null;
          initialHost.registered = false;
          tree.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'unfenced lookup supports missing ancestors without creating them',
    () async {
      final missing = Directory('${temporary.path}/fresh/deep/state');
      await MaintenanceStateFence.requireUnfenced(missing);
      expect(await Directory('${temporary.path}/fresh').exists(), false);
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'normal admission resolves parent aliases to the same fence',
    () async {
      fence = await MaintenanceStateFence.begin(lease);
      await Link('${temporary.path}/alias').create(temporary.path);
      for (final alias in [
        Directory('${temporary.path}/alias/state'),
        Directory(state.path.replaceFirst('/private/tmp/', '/tmp/')),
        Directory('${temporary.path}/./state'),
      ]) {
        await expectLater(
          MaintenanceStateFence.requireUnfenced(alias),
          throwsA(
            isA<MaintenanceFenceActive>().having(
              (active) => active.markerPath,
              'marker',
              fence!.path,
            ),
          ),
        );
        await expectLater(
          MaintenanceStateFence.open(alias),
          throwsFormatException,
        );
      }
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'closing a recovered fence invalidates its dependent cold lease',
    () async {
      fence = await MaintenanceStateFence.begin(lease);
      fence!.close();
      lease.close();
      fence = await MaintenanceStateFence.open(state);
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Fence',
        host: _Host('${temporary.path}/GaoVM.app'),
        maintenanceFence: fence,
      );
      fence!.close();
      await expectLater(lease.verify(), throwsStateError);
      await expectLater(
        MaintenanceStateFence.requireUnfenced(state),
        throwsA(isA<MaintenanceFenceActive>()),
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'changed staging intent is retained without publishing an active fence',
    () async {
      String? stagingPath;
      initialHost.onStatus = () async {
        final partials = await temporary
            .list(followLinks: false)
            .where(
              (entry) => entry is Directory && entry.path.endsWith('.partial'),
            )
            .toList();
        if (partials.isEmpty) return;
        initialHost.onStatus = null;
        stagingPath = partials.single.path;
        final record = File('$stagingPath/intent.json');
        imageFileMode(record.path, 0x180);
        await record.writeAsString('{}\n');
        imageFileMode(record.path, 0x100);
      };
      await expectLater(
        MaintenanceStateFence.begin(lease),
        throwsFormatException,
      );
      expect(stagingPath, isNotNull);
      expect(await Directory(stagingPath!).exists(), true);
      expect(await File('$stagingPath/intent.json').readAsString(), '{}\n');
      await MaintenanceStateFence.requireUnfenced(state);
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );
  test(
    'changed canonical parent refuses before creating a maintenance namespace',
    () async {
      final previousPath = temporary.path;
      temporary = await temporary.rename('$previousPath.retained');
      Link? alias;
      try {
        alias = await Link(previousPath).create(temporary.path);
        final before =
            (await temporary
                  .list(followLinks: false)
                  .map((entry) => entry.path)
                  .toList())
              ..sort();
        await expectLater(
          MaintenanceStateFence.begin(lease),
          throwsFormatException,
        );
        final after =
            (await temporary
                  .list(followLinks: false)
                  .map((entry) => entry.path)
                  .toList())
              ..sort();
        expect(after, before);
      } finally {
        await alias?.delete();
      }
    },
    skip: !Platform.isMacOS,
  );
  for (final mode in [0x1ed, 0x1f8]) {
    test(
      'maintenance parent ${mode.toRadixString(8)} is checked without chmod',
      () async {
        imageFileMode(temporary.path, mode);
        final parent = await OwnedImageDirectory.open(temporary);
        try {
          if (mode == 0x1ed) {
            fence = await MaintenanceStateFence.begin(lease);
            await fence!.verify();
          } else {
            final before =
                (await temporary
                      .list(followLinks: false)
                      .map((e) => e.path)
                      .toList())
                  ..sort();
            await expectLater(
              MaintenanceStateFence.begin(lease),
              throwsFormatException,
            );
            final after =
                (await temporary
                      .list(followLinks: false)
                      .map((e) => e.path)
                      .toList())
                  ..sort();
            expect(after, before);
          }
          expect(parent.mode & 0xfff, mode);
          await lease.verify();
        } finally {
          parent.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }
}

final class _Host implements ColdStateHost {
  _Host(this.appPath);
  bool registered = false;
  bool daemonRemains = false;
  bool unresolvedDriver = false;
  Set<int> references = {pid};
  int serviceCalls = 0;
  Future<void> Function()? onStatus;
  @override
  final String appPath;
  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async =>
      DriverInventorySnapshot(
        processes: [
          if (!driver && daemonRemains)
            DriverProcessIdentity(
              pid: pid,
              uid: 0,
              executablePath: '$appPath/Contents/MacOS/gaovmd',
              startedAtMicroseconds: 0,
            ),
        ],
        unresolvedProcessIds: [if (driver && unresolvedDriver) pid],
      );
  @override
  Future<Set<int>> stateReferences(Directory state) async => references;
  @override
  Future<ProcessResult> serviceStatus() async {
    serviceCalls++;
    await onStatus?.call();
    return ProcessResult(
      pid,
      0,
      jsonEncode({
        'action': 'status',
        'bundle_identifier': 'org.gaovm.tests.Fence',
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
