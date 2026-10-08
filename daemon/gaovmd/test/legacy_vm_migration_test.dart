import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a new state directory does not create an implicit default VM',
    () async {
      final fixture = await _Fixture.open();
      addTearDown(fixture.close);
      expect(await fixture.migration().migrate(), isNull);
      expect(await SqliteVmRepository(fixture.database).list(), isEmpty);
      expect(await SqliteOperationRepository(fixture.database).list(), isEmpty);
      expect(
        await Directory('${fixture.state.path}/legacy-v1-backup').exists(),
        isFalse,
      );
    },
  );

  test(
    'migration completion rolls back desired state when its event fails',
    () async {
      final fixture = await _Fixture.open();
      addTearDown(fixture.close);
      await fixture.legacy(desired: 'running');
      await fixture.crash('bundlePublished');
      await fixture.database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER reject_legacy_completion BEFORE INSERT ON events
      WHEN NEW.type = 'vm.legacy_migrated' BEGIN
        SELECT RAISE(ABORT, 'injected migration event failure');
      END;
    '''),
      );
      await expectLater(
        fixture.migration().migrate(),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('injected migration event failure'),
          ),
        ),
      );
      final retained = (await SqliteVmRepository(
        fixture.database,
      ).list()).single;
      expect(retained.status.desiredState, DesiredState.stopped);
      await fixture.database.transaction(
        (db) => db.execute('DROP TRIGGER reject_legacy_completion'),
      );
      final migrated = (await fixture.migration().migrate())!;
      expect(migrated.metadata.id, retained.metadata.id);
      expect(migrated.status.desiredState, DesiredState.running);
      final events = await SqliteEventRepository(
        fixture.database,
      ).list(vmId: migrated.metadata.id);
      expect(
        events.where((event) => event.type == 'vm.legacy_migrated'),
        hasLength(1),
      );
    },
  );

  test(
    'a kernel changed after backup cannot silently rebase migration',
    () async {
      final fixture = await _Fixture.open();
      addTearDown(fixture.close);
      await fixture.legacy();
      await fixture.crash('backupPublished');
      // Equal length proves digest pinning rather than only a size check.
      await fixture.kernel.writeAsString('kernel other');
      await expectLater(fixture.migration().migrate(), throwsFormatException);
      expect(await fixture.kernel.readAsString(), 'kernel other');
      expect(await SqliteVmRepository(fixture.database).list(), isEmpty);
    },
  );

  test(
    'an incomplete migration cannot lose both backup and original inputs',
    () async {
      final fixture = await _Fixture.open();
      addTearDown(fixture.close);
      final originals = await fixture.legacy();
      await fixture.crash('catalogAccepted');
      await Directory(
        '${fixture.state.path}/legacy-v1-backup',
      ).delete(recursive: true);
      for (final name in originals.keys) {
        await File('${fixture.state.path}/$name').delete();
      }
      await expectLater(fixture.migration().migrate(), throwsStateError);
      final retained = (await SqliteVmRepository(
        fixture.database,
      ).list()).single;
      expect(retained.status.phase, VmPhase.provisioning);
    },
  );

  for (final checkpoint in [
    'backupPublished',
    'assetsImported',
    'bundlePublished',
    'completed',
  ]) {
    test('process exit at $checkpoint resumes exactly one migration', () async {
      final fixture = await _Fixture.open();
      addTearDown(fixture.close);
      final originals = await fixture.legacy(desired: 'running');
      await fixture.crash(checkpoint);
      final migrated = (await fixture.migration().migrate())!;
      final repeated = (await fixture.migration().migrate())!;
      expect(repeated.metadata.id, migrated.metadata.id);
      expect(migrated.status.phase, VmPhase.stopped);
      expect(migrated.status.desiredState, DesiredState.running);
      expect(await SqliteVmRepository(fixture.database).list(), hasLength(1));
      expect(
        await SqliteOperationRepository(fixture.database).list(),
        hasLength(1),
      );
      final events = await SqliteEventRepository(
        fixture.database,
      ).list(vmId: migrated.metadata.id);
      expect(
        events.where((event) => event.type == 'vm.legacy_migrated'),
        hasLength(1),
      );
      expect(await fixture.disk.readAsString(), 'external mutable disk');
      for (final entry in originals.entries) {
        expect(
          await File('${fixture.state.path}/${entry.key}').readAsString(),
          entry.value,
        );
      }
    });
  }

  test(
    'pending legacy config wins without becoming an active state source',
    () async {
      final fixture = await _Fixture.open();
      addTearDown(fixture.close);
      final originals = await fixture.legacy(desired: 'running');
      final pending =
          jsonDecode(originals['config.json']!) as Map<String, dynamic>;
      pending['cpu'] = 3;
      final bytes = jsonEncode(pending);
      await File(
        '${fixture.state.path}/pending_config.json',
      ).writeAsString(bytes);
      final migrated = (await fixture.migration().migrate())!;
      expect(migrated.spec.cpu, 3);
      expect(migrated.status.desiredState, DesiredState.running);
      expect(
        await File(
          '${fixture.state.path}/legacy-v1-backup/pending_config.json',
        ).readAsString(),
        bytes,
      );
      await File(
        '${fixture.state.path}/pending_config.json',
      ).writeAsString('{}');
      expect((await fixture.migration().migrate())!.spec.cpu, 3);
    },
  );

  test(
    'an unmarked staging directory is preserved rather than overwritten',
    () async {
      final fixture = await _Fixture.open();
      addTearDown(fixture.close);
      await fixture.legacy();
      final staging = fixture.state.createDirectory('.legacy-v1-backup-stage');
      staging.close();
      final unrelated = await File(
        '${fixture.state.path}/.legacy-v1-backup-stage/config.json',
      ).writeAsString('unrelated user file');
      await expectLater(fixture.migration().migrate(), throwsStateError);
      expect(await unrelated.readAsString(), 'unrelated user file');
      expect(await SqliteVmRepository(fixture.database).list(), isEmpty);
    },
  );

  test(
    'unresolved native census rejects startup before legacy migration',
    () async {
      final fixture = await _Fixture.open();
      addTearDown(fixture.close);
      final originals = await fixture.legacy();
      final leases = SqliteHostLeaseRepository(fixture.database);
      await leases.acquire(
        request: HostCapacityRequest(
          vmId: VmId.generate(),
          cpuCount: 1,
          memoryBytes: 268435456,
          diskBytes: 0,
          phase: HostLeasePhase.running,
          specGeneration: 1,
          operationId: null,
          driverGeneration: 1,
        ),
        limits: HostSchedulerLimits(
          maxRunningVms: 4,
          maxConcurrentBoots: 2,
          maxDriverProcesses: 4,
          maxCpuCount: 4,
          maxMemoryBytes: 4294967296,
          minFreeDiskBytes: 0,
        ),
        metrics: const HostMetrics(
          logicalCpuCount: 4,
          totalMemoryBytes: 4294967296,
          availableMemoryBytes: 4294967296,
          freeDiskBytes: 4294967296,
          unmanagedDriverProcesses: 0,
        ),
        ownerId: 'previous-daemon',
        now: DateTime.now().toUtc(),
        ttl: const Duration(seconds: 30),
      );
      final previous = await leases.list();
      expect(previous, hasLength(1));
      final executable = await File(
        '/bin/cat',
      ).copy('${fixture.temporary.path}/unresolved-process');
      final chmod = await Process.run('/bin/chmod', ['700', executable.path]);
      expect(chmod.exitCode, 0);
      // Re-sign the disposable copy and await execution before unlinking it;
      // an unstarted copied platform binary is not a valid census fixture.
      final signed = await Process.run('/usr/bin/codesign', [
        '--force',
        '--sign',
        '-',
        executable.path,
      ]);
      expect(signed.exitCode, 0, reason: '${signed.stderr}');
      final canonical = await executable.resolveSymbolicLinks();
      final process = await Process.start(canonical, const []);
      final output = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = process.stderr.drain<void>();
      try {
        process.stdin.writeln('native-fixture-ready');
        expect(
          await output.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        expect(output.current, 'native-fixture-ready');
        final inventory = MacOsDriverInventory(executablePath: canonical);
        expect(await inventory.inspect(process.pid), isNotNull);
        await executable.delete();
        await expectLater(
          inventory.inspect(process.pid),
          throwsA(isA<OSError>()),
        );
        fixture.ownership.close();
        await expectLater(
          DaemonApplication.start(
            stateDirectory: Directory(fixture.state.path),
            driverBinary: '/bin/cat',
            openApiDocument: const {},
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('process inventory contains unresolved executables'),
            ),
          ),
        );
        fixture.ownership = (await DaemonOwnership.tryAcquire(fixture.state))!;
        expect(await leases.list(), previous);
        expect(await SqliteVmRepository(fixture.database).list(), isEmpty);
        expect(
          await Directory('${fixture.state.path}/legacy-v1-backup').exists(),
          isFalse,
        );
        expect(
          await FileSystemEntity.type(
            '${fixture.state.path}/run/api.sock',
            followLinks: false,
          ),
          FileSystemEntityType.notFound,
        );
        for (final entry in originals.entries) {
          expect(
            await File('${fixture.state.path}/${entry.key}').readAsString(),
            entry.value,
          );
        }
      } finally {
        await output.cancel();
        await process.stdin.close();
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 5));
        await errors;
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'process exit after catalog acceptance resumes the same legacy VM',
    () async {
      final fixture = await _Fixture.open();
      addTearDown(fixture.close);
      await fixture.legacy(desired: 'running');
      await fixture.crash('catalogAccepted');
      final before = (await SqliteVmRepository(fixture.database).list()).single;
      expect(before.status.phase, VmPhase.provisioning);
      // Durable migration intent, not retained JSON, owns a resumed acceptance.
      await File(
        '${fixture.state.path}/desired_state.json',
      ).writeAsString('{"desired":"stopped"}');
      final migrated = (await fixture.migration().migrate())!;
      expect(migrated.metadata.id, before.metadata.id);
      expect(migrated.status.desiredState, DesiredState.running);
      expect(migrated.status.driverGeneration, 0);
      expect(migrated.status.observedGeneration, 0);
      expect(
        await SqliteOperationRepository(fixture.database).list(),
        hasLength(1),
      );
    },
  );

  test('legacy config migrates once without moving the external disk', () async {
    final fixture = await _Fixture.open();
    addTearDown(fixture.close);
    final originals = await fixture.legacy();
    final vm = (await fixture.migration().migrate())!;
    expect(vm.metadata.name, 'migrated-default');
    expect(vm.metadata.id.value, startsWith('vm_'));
    expect(vm.status.desiredState, DesiredState.stopped);
    expect(vm.status.phase, VmPhase.stopped);
    expect(vm.spec.cpu, 2);
    expect(vm.spec.restartPolicy, RestartPolicy.onFailure);
    expect(vm.spec.guestAgent.enabled, isFalse);
    expect(
      (vm.spec.disks.single.source as ExternalDiskSource).path,
      await fixture.disk.resolveSymbolicLinks(),
    );
    final boot = vm.spec.boot as LinuxKernelBoot;
    final images = ImageStore(fixture.database, Directory(fixture.images.path));
    expect((await images.get(boot.kernelImageId))!.type, ImageType.linuxKernel);
    expect((await images.get(boot.initrdImageId!))!.type, ImageType.initrd);
    final bundle = Directory('${fixture.bundles.path}/${vm.metadata.id}.gaovm');
    expect(await File('${bundle.path}/manifest.json').exists(), isTrue);
    expect(await File('${bundle.path}/disks/root.raw').exists(), isFalse);
    expect(await fixture.disk.readAsString(), 'external mutable disk');
    for (final entry in originals.entries) {
      expect(
        await File('${fixture.state.path}/${entry.key}').readAsString(),
        entry.value,
      );
      expect(
        await File(
          '${fixture.state.path}/legacy-v1-backup/${entry.key}',
        ).readAsString(),
        entry.value,
      );
    }
    await fixture.reopenDatabase();
    // Once complete, retained JSON is backup material, not active desired state.
    await File(
      '${fixture.state.path}/desired_state.json',
    ).writeAsString('{"desired":"running"}');
    final again = (await fixture.migration().migrate())!;
    expect(again.metadata.id, vm.metadata.id);
    expect(again.status.desiredState, DesiredState.stopped);
    expect(await SqliteVmRepository(fixture.database).list(), hasLength(1));
    final events = await SqliteEventRepository(
      fixture.database,
    ).list(vmId: vm.metadata.id);
    expect(
      events.where((event) => event.type == 'vm.legacy_migrated'),
      hasLength(1),
    );
  });
}

final class _Fixture {
  _Fixture(
    this.temporary,
    this.state,
    this.bundles,
    this.images,
    this.ownership,
    this.database,
  );
  final Directory temporary;
  final OwnedImageDirectory state;
  final OwnedImageDirectory bundles;
  final OwnedImageDirectory images;
  DaemonOwnership ownership;
  GaoVmDatabase database;
  File get kernel => File('${temporary.path}/kernel');
  File get initrd => File('${temporary.path}/initrd');
  File get disk => File('${temporary.path}/root.raw');

  static Future<_Fixture> open() async {
    final temporary = await Directory.systemTemp.createTemp('gvm-legacy-');
    final root = await OwnedImageDirectory.open(temporary);
    final state = root.createDirectory('state');
    root.close();
    final ownership = (await DaemonOwnership.tryAcquire(state))!;
    return _Fixture(
      temporary,
      state,
      state.createDirectory('vms'),
      state.createDirectory('images'),
      ownership,
      await GaoVmDatabase.open('${state.path}/gaovm.db'),
    );
  }

  LegacyVmMigration migration() => LegacyVmMigration(
    database: database,
    state: state,
    bundles: bundles,
    images: images,
    ownership: ownership,
  );

  Future<Map<String, String>> legacy({String desired = 'stopped'}) async {
    await kernel.writeAsString('kernel bytes');
    await initrd.writeAsString('initrd bytes');
    await disk.writeAsString('external mutable disk');
    final originals = {
      'config.json': jsonEncode({
        'cpu': 2,
        'memory': 268435456,
        'boot': {
          'loader': 'linux',
          'kernelPath': kernel.path,
          'initrdPath': initrd.path,
          'commandLine': 'console=hvc0',
        },
        'disk': {'path': disk.path, 'sizeMiB': 8192},
        'network': {'mode': 'shared'},
        'graphics': {'enabled': true, 'width': 1280, 'height': 800},
      }),
      'desired_state.json': jsonEncode({
        'desired': desired,
        'maxRestartAttempts': 5,
      }),
      // Volatile PID/observed state must not become native recovery authority.
      'daemon_state.json': jsonEncode({
        'desired': 'running',
        'actual': 'running',
        'driverPid': 12345,
      }),
    };
    for (final entry in originals.entries) {
      await File('${state.path}/${entry.key}').writeAsString(entry.value);
    }
    return originals;
  }

  Future<void> reopenDatabase() async {
    database.close();
    database = await GaoVmDatabase.open('${state.path}/gaovm.db');
  }

  Future<void> crash(String checkpoint) async {
    database.close();
    ownership.close();
    final child = await Process.start(Platform.resolvedExecutable, [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      '${Directory.current.path}/test/fixtures/crash_legacy_migration.dart',
      state.path,
      checkpoint,
    ]);
    final output = child.stdout.drain<void>();
    final errors = child.stderr.transform(utf8.decoder).join();
    late int code;
    try {
      code = await child.exitCode.timeout(const Duration(seconds: 20));
    } catch (_) {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
      rethrow;
    } finally {
      await output;
      ownership = (await DaemonOwnership.tryAcquire(state))!;
      database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    }
    expect(code, 91, reason: await errors);
  }

  Future<void> close() async {
    database.close();
    ownership.close();
    images.close();
    bundles.close();
    state.close();
    await temporary.delete(recursive: true);
  }
}
