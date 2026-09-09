import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/driver_process_manager.dart';
import 'package:gaovmd/src/driver_runtime_layout.dart';
import 'package:gaovmd/src/driver_runtime_metadata.dart';
import 'package:gaovmd/src/driver_runtime_discovery.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:gaovmd/src/runtime_driver_effect_adapter.dart';
import 'package:gaovmd/src/vm_controller_reducer.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late DriverProcessManager manager;

  setUp(() async {
    temporaryDirectory = await Directory('/private/tmp').createTemp('gvm-');
    manager = _manager(temporaryDirectory);
  });

  tearDown(() async {
    await manager.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'metadata sync failure compensates spawn before a retry can own the VM',
    () async {
      var failSync = true;
      final syncingManager = _manager(
        temporaryDirectory,
        metadataDirectorySync: (_) {
          if (failSync)
            throw FileSystemException('injected metadata sync failure');
        },
      );
      addTearDown(syncingManager.close);
      final first = _correlation(_vm1, 1, _operation1);
      await expectLater(
        syncingManager.spawn(RuntimeDriverLaunch(correlation: first)),
        throwsA(
          isA<RuntimeDriverError>().having(
            (error) => error.code,
            'code',
            RuntimeDriverErrorCode.runtimeStartFailed,
          ),
        ),
      );
      expect(syncingManager.activeProcessCount, 0);
      expect(syncingManager.activeGenerationCount, 0);
      expect(syncingManager.managedProcessIdentities, isEmpty);
      final layout = DriverRuntimeLayout('${temporaryDirectory.path}/run');
      expect(await Directory(layout.paths(first).directory).exists(), isFalse);
      failSync = false;
      final second = _correlation(_vm1, 2, _operation2);
      await syncingManager.spawn(RuntimeDriverLaunch(correlation: second));
      expect(syncingManager.activeProcessCount, 1);
      await syncingManager.release(second);
    },
  );

  test(
    'unverified executable identity fails spawn and cleans the owned child',
    () async {
      final wrapper = File('${temporaryDirectory.path}/driver-wrapper');
      await wrapper.writeAsString('#!/bin/sh\nexec /bin/cat\n');
      final chmod = await Process.run('/bin/chmod', ['700', wrapper.path]);
      expect(chmod.exitCode, 0);
      final layout = DriverRuntimeLayout('${temporaryDirectory.path}/run');
      final identityManager = DriverProcessManager(
        layout: layout,
        resolveExecutable: (_) => DriverExecutable(path: wrapper.path),
        resolveBundlePath: (_) => temporaryDirectory.path,
      );
      addTearDown(identityManager.close);
      final correlation = _correlation(_vm1, 1, _operation1);
      await expectLater(
        identityManager.spawn(RuntimeDriverLaunch(correlation: correlation)),
        throwsA(
          isA<RuntimeDriverError>().having(
            (error) => error.code,
            'code',
            RuntimeDriverErrorCode.runtimeStartFailed,
          ),
        ),
      );
      expect(identityManager.activeProcessCount, 0);
      expect(identityManager.pendingSpawnCount, 0);
      expect(identityManager.activeGenerationCount, 0);
      expect(identityManager.managedProcessIdentities, isEmpty);
      expect(
        await Directory(layout.paths(correlation).directory).exists(),
        isFalse,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'runs two correlated driver processes independently and cleans them',
    () async {
      final firstCorrelation = _correlation(_vm1, 1, _operation1);
      final secondCorrelation = _correlation(_vm2, 1, _operation2);
      final sessions = await Future.wait([
        manager.spawn(RuntimeDriverLaunch(correlation: firstCorrelation)),
        manager.spawn(RuntimeDriverLaunch(correlation: secondCorrelation)),
      ]);
      final first = sessions[0] as ProcessRuntimeDriverSession;
      final second = sessions[1] as ProcessRuntimeDriverSession;
      expect(first.pid, isNot(second.pid));
      expect(first.paths.socketPath, isNot(second.paths.socketPath));
      expect(manager.activeProcessCount, 2);

      final firstEvents = <RuntimeEvent>[];
      final secondEvents = <RuntimeEvent>[];
      final firstSub = first.events.listen(firstEvents.add);
      final secondSub = second.events.listen(secondEvents.add);
      await Future.wait([
        first.connect(DriverCapabilities.runtimeCore),
        second.connect(DriverCapabilities.runtimeCore),
      ]);
      await Future.wait([
        first.execute(RuntimeStartCommand(correlation: firstCorrelation)),
        second.execute(RuntimeStartCommand(correlation: secondCorrelation)),
      ]);
      await _eventually(
        () =>
            firstEvents.whereType<RuntimeStateChanged>().any(
              (event) => event.state == RuntimeDriverState.running,
            ) &&
            secondEvents.whereType<RuntimeStateChanged>().any(
              (event) => event.state == RuntimeDriverState.running,
            ),
      );

      final metadata =
          jsonDecode(await File(first.paths.metadataPath).readAsString())
              as Map<String, Object?>;
      expect(metadata['vm_id'], _vm1.value);
      expect(metadata['driver_generation'], 1);
      if (Platform.isMacOS) {
        final identity = (await MacOsDriverInventory(
          executablePath: File(
            Platform.resolvedExecutable,
          ).resolveSymbolicLinksSync(),
        ).inspect(first.pid))!;
        expect(metadata['process_identity'], {
          'pid': identity.pid,
          'uid': identity.uid,
          'executable_path': identity.executablePath,
          'started_at_microseconds': identity.startedAtMicroseconds,
          'pid_version': identity.pidVersion,
        });
        expect(manager.managedProcessIdentities, contains(identity));
        final runRoot = await OwnedImageDirectory.open(
          Directory('${temporaryDirectory.path}/run'),
        );
        try {
          final discovered = await DriverRuntimeDiscovery(
            root: runRoot,
            resolveBinding: (vmId) async => DriverRecoveryBinding(
              driverGeneration: 1,
              executable: identity.executablePath,
              bundlePath: '${temporaryDirectory.path}/vms/${vmId.value}.gaovm',
            ),
          ).scan();
          expect(
            discovered.records.map((record) => record.correlation.vmId).toSet(),
            {_vm1, _vm2},
          );
          expect(discovered.issues, isEmpty);
        } finally {
          runRoot.close();
        }
        final directory = await OwnedImageDirectory.open(
          Directory(first.paths.directory),
        );
        try {
          final record = await DriverRuntimeMetadata.readFrom(
            directory,
            correlation: firstCorrelation,
            executable: identity.executablePath,
            bundlePath: '${temporaryDirectory.path}/vms/${_vm1.value}.gaovm',
          );
          expect(record!.processIdentity, identity);
        } finally {
          directory.close();
        }
      }
      expect(metadata.toString(), isNot(contains('GAOVM_AUTH_TOKEN')));

      await Future.wait([
        first.execute(RuntimeStopCommand(correlation: firstCorrelation)),
        second.execute(RuntimeStopCommand(correlation: secondCorrelation)),
      ]);
      await Future.wait([first.exited, second.exited]);
      expect(manager.managedProcessIdentities, isEmpty);
      await Future.wait([
        manager.release(firstCorrelation),
        manager.release(secondCorrelation),
      ]);
      expect(manager.activeProcessCount, 0);
      expect(await Directory(first.paths.directory).exists(), isFalse);
      expect(await Directory(second.paths.directory).exists(), isFalse);
      await firstSub.cancel();
      await secondSub.cancel();
    },
  );

  test('rejects a second active generation for one VM', () async {
    final first = _correlation(_vm1, 1, _operation1);
    await manager.spawn(RuntimeDriverLaunch(correlation: first));

    await expectLater(
      manager.spawn(
        RuntimeDriverLaunch(correlation: _correlation(_vm1, 2, _operation2)),
      ),
      throwsA(
        isA<RuntimeDriverError>().having(
          (error) => error.code,
          'code',
          RuntimeDriverErrorCode.invalidRuntimeState,
        ),
      ),
    );
  });

  test(
    'kill escalates an accepted graceful stop with new correlation',
    () async {
      final stoppingManager = _manager(
        temporaryDirectory,
        scenario: 'accepted-stop',
      );
      addTearDown(stoppingManager.close);
      final correlation = _correlation(_vm1, 1, _operation1);
      final session = await stoppingManager.spawn(
        RuntimeDriverLaunch(correlation: correlation),
      );
      await session.connect(DriverCapabilities.runtimeCore);
      await session.execute(RuntimeStartCommand(correlation: correlation));
      await session.execute(RuntimeStopCommand(correlation: correlation));
      final events = <RuntimeEvent>[];
      final subscription = session.events.listen(events.add);
      addTearDown(subscription.cancel);

      await session.execute(
        RuntimeKillCommand(correlation: _correlation(_vm1, 1, _operation2)),
      );
      final exit = await session.exited.timeout(const Duration(seconds: 3));
      expect(exit.correlation.operationId, _operation2);
      expect(exit.correlation.driverGeneration, 1);
      expect(exit.exitCode, 137);
      expect(
        events.whereType<RuntimeStateChanged>().any(
          (event) =>
              event.correlation.operationId == _operation2 &&
              event.state == RuntimeDriverState.stopped,
        ),
        isTrue,
      );
      await stoppingManager.release(correlation);
      expect(stoppingManager.activeProcessCount, 0);
    },
  );

  test(
    'real process adapter routes stop escalation exit and releases session',
    () async {
      final stoppingManager = _manager(
        temporaryDirectory,
        scenario: 'accepted-stop',
      );
      addTearDown(stoppingManager.close);
      final commands = <VmCommand>[];
      final adapter = RuntimeDriverEffectAdapter(
        factory: stoppingManager,
        resolveConfiguration: (_) async => throw StateError('not configuring'),
        dispatch: (_, command) async => commands.add(command),
      );
      addTearDown(adapter.close);
      final state = VmControllerState.initial(
        vmId: _vm1,
        specGeneration: 1,
        restartPolicy: RestartPolicy.onFailure,
      );
      await adapter.spawn(state, _operation1, 1);
      await adapter.connect(state, _operation1, 1);
      await adapter.start(state, _operation1, 1);
      await adapter.stop(state, _operation1, 1);
      await adapter.kill(state, _operation2, 1);
      await _eventually(() => commands.whereType<DriverExited>().isNotEmpty);
      await adapter.waitUntilEventsDispatched();

      final exit = commands.whereType<DriverExited>().single;
      expect(exit.operationId, _operation2);
      expect(exit.driverGeneration, 1);
      expect(adapter.activeSessionCount, 0);
      expect(stoppingManager.activeProcessCount, 0);
    },
  );

  test(
    'identity mismatch fails handshake and release kills the process',
    () async {
      final badManager = _manager(
        temporaryDirectory,
        scenario: 'bad-generation',
      );
      final correlation = _correlation(_vm1, 1, _operation1);
      final session = await badManager.spawn(
        RuntimeDriverLaunch(correlation: correlation),
      );

      await expectLater(
        session.connect(DriverCapabilities.runtimeCore),
        throwsA(isA<RuntimeDriverError>()),
      );
      await badManager.release(correlation);
      expect(badManager.activeProcessCount, 0);
      await badManager.close();
    },
  );

  test('concurrent release waits for one confirmed process exit', () async {
    final slowManager = _manager(temporaryDirectory, scenario: 'ignore-stop');
    final correlation = _correlation(_vm1, 1, _operation1);
    final session = await slowManager.spawn(
      RuntimeDriverLaunch(correlation: correlation),
    );
    await session.connect(DriverCapabilities.runtimeCore);
    var processExited = false;
    session.exited.then((_) => processExited = true);

    final firstRelease = slowManager.release(correlation);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await slowManager.release(correlation);

    expect(processExited, isTrue);
    await firstRelease;
    expect(slowManager.activeProcessCount, 0);
    await slowManager.close();
  });

  test(
    'release retains ownership so failed layout cleanup can retry',
    () async {
      final cleanupManager = _manager(temporaryDirectory);
      final correlation = _correlation(_vm1, 1, _operation1);
      final session =
          await cleanupManager.spawn(
                RuntimeDriverLaunch(correlation: correlation),
              )
              as ProcessRuntimeDriverSession;
      await session.connect(DriverCapabilities.runtimeCore);
      await session.execute(RuntimeStopCommand(correlation: correlation));
      await session.exited;

      final blocked = Directory('${session.paths.directory}/blocked');
      await blocked.create();
      await Process.run('/bin/chmod', ['000', blocked.path]);
      final quarantine =
          '${session.paths.directory}.cleanup.${session.paths.cleanupToken}';

      Object? cleanupFailure;
      try {
        await cleanupManager.release(correlation);
      } catch (error) {
        cleanupFailure = error;
      } finally {
        await Process.run('/bin/chmod', ['700', '$quarantine/blocked']);
      }
      expect(cleanupFailure, isA<FileSystemException>());
      expect(cleanupManager.activeProcessCount, 1);

      // Unknown content requires explicit resolution, not merely permission
      // changes that would let a recursive cleanup delete it.
      await Directory('$quarantine/blocked').delete();
      await cleanupManager.release(correlation);

      expect(cleanupManager.activeProcessCount, 0);
      expect(await Directory(quarantine).exists(), isFalse);
      await cleanupManager.close();
    },
  );

  test(
    'close timeout retains pending ownership and retry awaits compensation',
    () async {
      final resolver = Completer<DriverExecutable>();
      final closingManager = DriverProcessManager(
        layout: DriverRuntimeLayout('${temporaryDirectory.path}/pending-run'),
        resolveExecutable: (_) => resolver.future,
        resolveBundlePath: (_) => '${temporaryDirectory.path}/pending.gaovm',
        shutdownTimeout: const Duration(milliseconds: 50),
      );
      final correlation = _correlation(_vm1, 1, _operation1);
      final spawn = closingManager.spawn(
        RuntimeDriverLaunch(correlation: correlation),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await expectLater(
        closingManager.close(),
        throwsA(
          isA<RuntimeDriverError>()
              .having(
                (error) => error.code,
                'code',
                RuntimeDriverErrorCode.driverUnhealthy,
              )
              .having((error) => error.retryable, 'retryable', isTrue),
        ),
      );
      expect(closingManager.pendingSpawnCount, 1);
      expect(closingManager.activeGenerationCount, 1);

      resolver.complete(
        DriverExecutable(
          path: Platform.resolvedExecutable,
          prefixArguments: const ['--version'],
        ),
      );
      await expectLater(
        spawn,
        throwsA(
          isA<RuntimeDriverError>().having(
            (error) => error.code,
            'code',
            RuntimeDriverErrorCode.cancelled,
          ),
        ),
      );
      await closingManager.close();
      expect(closingManager.pendingSpawnCount, 0);
      expect(closingManager.activeGenerationCount, 0);
      expect(
        await Directory(
          '${temporaryDirectory.path}/pending-run',
        ).list().isEmpty,
        isTrue,
      );
    },
  );

  test('close awaits a paused spawn through complete compensation', () async {
    final resolver = Completer<DriverExecutable>();
    final runRoot = '${temporaryDirectory.path}/wait-run';
    final closingManager = DriverProcessManager(
      layout: DriverRuntimeLayout(runRoot),
      resolveExecutable: (_) => resolver.future,
      resolveBundlePath: (_) => '${temporaryDirectory.path}/wait.gaovm',
      shutdownTimeout: const Duration(seconds: 1),
    );
    final correlation = _correlation(_vm1, 1, _operation1);
    final spawnFailure = expectLater(
      closingManager.spawn(RuntimeDriverLaunch(correlation: correlation)),
      throwsA(isA<RuntimeDriverError>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final close = closingManager.close();
    resolver.complete(
      DriverExecutable(
        path: Platform.resolvedExecutable,
        prefixArguments: const ['--version'],
      ),
    );
    await close;
    await spawnFailure;

    expect(closingManager.pendingSpawnCount, 0);
    expect(closingManager.activeGenerationCount, 0);
    expect(await Directory(runRoot).list().isEmpty, isTrue);
  });

  test('heartbeat timeout is reported once with session correlation', () async {
    final heartbeatManager = _manager(
      temporaryDirectory,
      scenario: 'heartbeat-hang',
      heartbeatInterval: const Duration(milliseconds: 20),
      heartbeatTimeout: const Duration(milliseconds: 20),
    );
    final correlation = _correlation(_vm1, 1, _operation1);
    final session = await heartbeatManager.spawn(
      RuntimeDriverLaunch(correlation: correlation),
    );
    final events = <RuntimeEvent>[];
    final subscription = session.events.listen(
      events.add,
      onError: (Object _, StackTrace __) {},
    );
    await session.connect(DriverCapabilities.runtimeCore);

    await _eventually(
      () => events.whereType<RuntimeHeartbeatMissed>().length == 1,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final missed = events.whereType<RuntimeHeartbeatMissed>().single;
    expect(missed.correlation.vmId, correlation.vmId);
    expect(missed.correlation.driverGeneration, correlation.driverGeneration);
    expect(missed.correlation.operationId, correlation.operationId);

    await subscription.cancel();
    await heartbeatManager.close();
  });

  test('rejects notifications before bidirectional hello completes', () async {
    final preauthManager = _manager(
      temporaryDirectory,
      scenario: 'preauth-event',
    );
    final correlation = _correlation(_vm1, 1, _operation1);
    final session = await preauthManager.spawn(
      RuntimeDriverLaunch(correlation: correlation),
    );
    final events = <RuntimeEvent>[];
    final subscription = session.events.listen(
      events.add,
      onError: (Object _, StackTrace __) {},
    );

    await expectLater(
      session.connect(DriverCapabilities.runtimeCore),
      throwsA(
        isA<RuntimeDriverError>().having(
          (error) => error.code,
          'code',
          RuntimeDriverErrorCode.protocolViolation,
        ),
      ),
    );
    expect(events, isEmpty);

    await subscription.cancel();
    await preauthManager.release(correlation);
    await preauthManager.close();
  });

  test(
    'log pause applies pipe backpressure and emitted chunks are bounded',
    () async {
      final logManager = _manager(temporaryDirectory, scenario: 'large-log');
      final correlation = _correlation(_vm1, 1, _operation1);
      final session =
          await logManager.spawn(RuntimeDriverLaunch(correlation: correlation))
              as ProcessRuntimeDriverSession;
      final chunks = <RuntimeDriverLogChunk>[];
      final subscription = session.logs.listen(chunks.add);
      await session.connect(DriverCapabilities.runtimeCore);

      subscription.pause();
      expect(session.logInputsPaused, isTrue);
      await session.execute(RuntimeStartCommand(correlation: correlation));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chunks, isEmpty);

      subscription.resume();
      await _eventually(
        () =>
            chunks.fold<int>(0, (total, chunk) => total + chunk.bytes.length) >=
            200000,
      );
      expect(chunks.every((chunk) => chunk.bytes.length <= 65536), isTrue);
      expect(() => session.logs.listen((_) {}), throwsStateError);

      await subscription.cancel();
      await logManager.release(correlation);
      await logManager.close();
    },
  );

  test('release does not wait for a paused log consumer', () async {
    final logManager = _manager(temporaryDirectory);
    final correlation = _correlation(_vm1, 1, _operation1);
    final session = await logManager.spawn(
      RuntimeDriverLaunch(correlation: correlation),
    );
    final subscription = session.logs.listen((_) {});
    await session.connect(DriverCapabilities.runtimeCore);
    subscription.pause();

    final release = logManager.release(correlation);
    var completedWhilePaused = false;
    try {
      await release.timeout(const Duration(seconds: 1));
      completedWhilePaused = true;
    } on TimeoutException {
      // Cleanup below resumes the stream so the pre-fix implementation settles.
    } finally {
      await subscription.cancel();
      await release;
    }

    expect(completedWhilePaused, isTrue);
    expect(logManager.activeProcessCount, 0);
    await logManager.close();
  });

  test('release does not wait for a paused event consumer', () async {
    final eventManager = _manager(temporaryDirectory);
    final correlation = _correlation(_vm1, 1, _operation1);
    final session = await eventManager.spawn(
      RuntimeDriverLaunch(correlation: correlation),
    );
    final subscription = session.events.listen((_) {});
    await session.connect(DriverCapabilities.runtimeCore);
    subscription.pause();

    final release = eventManager.release(correlation);
    var completedWhilePaused = false;
    try {
      await release.timeout(const Duration(seconds: 1));
      completedWhilePaused = true;
    } on TimeoutException {
      // Cleanup below resumes the stream so the pre-fix implementation settles.
    } finally {
      await subscription.cancel();
      await release;
    }

    expect(completedWhilePaused, isTrue);
    expect(eventManager.activeProcessCount, 0);
    await eventManager.close();
  });

  test(
    'drains and discards child output before a log consumer attaches',
    () async {
      final logManager = _manager(
        temporaryDirectory,
        scenario: 'prelisten-log',
      );
      final correlation = _correlation(_vm1, 1, _operation1);
      final session = await logManager.spawn(
        RuntimeDriverLaunch(correlation: correlation),
      );

      await session.connect(DriverCapabilities.runtimeCore);
      final chunks = <RuntimeDriverLogChunk>[];
      final subscription = session.logs.listen(chunks.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chunks, isEmpty);

      await subscription.cancel();
      await logManager.release(correlation);
      await logManager.close();
    },
  );

  test('Swift v2 driver stops and exits with no configured VZ VM', () async {
    final target = switch (Abi.current()) {
      Abi.macosArm64 => 'arm64-apple-macosx',
      Abi.macosX64 => 'x86_64-apple-macosx',
      _ => null,
    };
    if (target == null) {
      markTestSkipped('Swift VZ driver is only built on macOS');
      return;
    }
    final executable = File(
      '${Directory.current.path}/../../drivers/vz_macos/'
      '.build/$target/debug/gaovm-driver-vz',
    );
    if (!await executable.exists()) {
      markTestSkipped('build drivers/vz_macos before running this integration');
      return;
    }
    final swiftManager = DriverProcessManager(
      layout: DriverRuntimeLayout('${temporaryDirectory.path}/swift-run'),
      resolveExecutable: (_) =>
          DriverExecutable(path: executable.absolute.path),
      resolveBundlePath: (vmId) async {
        final path = '${temporaryDirectory.path}/vms/${vmId.value}.gaovm';
        await Directory('$path/logs').create(recursive: true);
        return path;
      },
      connectTimeout: const Duration(seconds: 2),
      handshakeTimeout: const Duration(seconds: 2),
      heartbeatInterval: const Duration(seconds: 30),
    );
    final correlation = _correlation(_vm1, 1, _operation1);
    final session = await swiftManager.spawn(
      RuntimeDriverLaunch(correlation: correlation),
    );

    final accepted = await session.connect(DriverCapabilities.runtimeCore);
    expect(accepted.containsAll(DriverCapabilities.runtimeCore), isTrue);
    final status = await session.execute(
      RuntimeStatusCommand(correlation: correlation.withOperation(null)),
    );
    expect(status.status, RuntimeCommandStatus.succeeded);

    await session.execute(RuntimeStopCommand(correlation: correlation));
    final exit = await session.exited.timeout(const Duration(seconds: 2));
    expect(exit.clean, isTrue);
    expect(exit.exitCode, 0);
    expect(exit.error, isNull);
    await swiftManager.release(correlation);
    expect(swiftManager.activeProcessCount, 0);

    final killCorrelation = _correlation(_vm2, 1, _operation2);
    final killSession = await swiftManager.spawn(
      RuntimeDriverLaunch(correlation: killCorrelation),
    );
    await killSession.connect(DriverCapabilities.runtimeCore);
    await killSession.execute(RuntimeKillCommand(correlation: killCorrelation));
    final killed = await killSession.exited.timeout(const Duration(seconds: 2));
    expect(killed.clean, isFalse);
    expect(killed.exitCode, 137);
    await swiftManager.release(killCorrelation);
    await swiftManager.close();
  });

  test(
    'cancelling an in-flight lifecycle command terminates its process',
    () async {
      final hangingManager = _manager(
        temporaryDirectory,
        scenario: 'hang-start',
      );
      final correlation = _correlation(_vm1, 1, _operation1);
      final session = await hangingManager.spawn(
        RuntimeDriverLaunch(correlation: correlation),
      );
      await session.connect(DriverCapabilities.runtimeCore);
      final commandFailure = expectLater(
        session.execute(RuntimeStartCommand(correlation: correlation)),
        throwsA(anything),
      );
      final queuedFailure = expectLater(
        session.execute(
          RuntimeStopCommand(correlation: _correlation(_vm1, 1, _operation2)),
        ),
        throwsA(anything),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await session.cancel(_operation1);

      final exit = await session.exited.timeout(const Duration(seconds: 2));
      expect(exit.correlation.operationId, _operation1);
      await commandFailure;
      await queuedFailure;
      await hangingManager.release(correlation);
      expect(hangingManager.activeProcessCount, 0);
      await hangingManager.close();
    },
  );
}

DriverProcessManager _manager(
  Directory root, {
  FutureOr<void> Function(String)? metadataDirectorySync,
  String scenario = 'normal',
  Duration heartbeatInterval = const Duration(seconds: 30),
  Duration heartbeatTimeout = const Duration(seconds: 5),
}) => DriverProcessManager(
  layout: DriverRuntimeLayout(
    '${root.path}/run',
    metadataDirectorySync: metadataDirectorySync,
  ),
  resolveExecutable: (_) => DriverExecutable(
    path: Platform.resolvedExecutable,
    prefixArguments: [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      '${Directory.current.path}/test/fixtures/fake_driver_v2.dart',
      '--scenario',
      scenario,
    ],
  ),
  resolveBundlePath: (vmId) async {
    final path = '${root.path}/vms/${vmId.value}.gaovm';
    await Directory('$path/logs').create(recursive: true);
    return path;
  },
  connectTimeout: const Duration(seconds: 2),
  handshakeTimeout: const Duration(seconds: 2),
  heartbeatInterval: heartbeatInterval,
  heartbeatTimeout: heartbeatTimeout,
);

DriverCorrelation _correlation(
  VmId vmId,
  int generation,
  OperationId operationId,
) => DriverCorrelation(
  vmId: vmId,
  driverGeneration: generation,
  operationId: operationId,
);

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition did not become true before deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final _vm1 = VmId('vm_01J00000000000000000000000');
final _vm2 = VmId('vm_01J00000000000000000000001');
final _operation1 = OperationId('op_01J00000000000000000000000');
final _operation2 = OperationId('op_01J00000000000000000000001');
