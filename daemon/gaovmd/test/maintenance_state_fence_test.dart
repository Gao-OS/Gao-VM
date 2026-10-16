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
