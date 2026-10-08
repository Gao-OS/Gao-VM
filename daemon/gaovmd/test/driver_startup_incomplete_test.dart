import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late _Harness harness;
  setUp(() async => harness = await _Harness.create());
  tearDown(() => harness.close());

  test(
    'recovers an owned generation with no metadata and no drivers',
    () async {
      await harness.recovery().recover();
      expect(await Directory(harness.paths.directory).parent.exists(), isFalse);
      await harness.owner.verify();
    },
  );

  test(
    'live unrecorded and unresolved processes prevent any cleanup',
    () async {
      final unrecorded = DriverProcessIdentity(
        pid: pid,
        uid: 501,
        executablePath: '/opt/driver',
        startedAtMicroseconds: 1,
        pidVersion: 1,
      );
      for (final inventory in [
        DriverInventorySnapshot(
          processes: [unrecorded],
          unresolvedProcessIds: [],
        ),
        DriverInventorySnapshot(processes: [], unresolvedProcessIds: [pid]),
      ]) {
        await expectLater(
          harness.recovery(inventory: () async => inventory).recover(),
          throwsStateError,
        );
        expect(await Directory(harness.paths.directory).exists(), isTrue);
      }
    },
  );

  test('metadata appearing after discovery is preserved', () async {
    await expectLater(
      harness
          .recovery(
            inventory: () async {
              await File(
                harness.paths.metadataPath,
              ).writeAsString('new metadata');
              return _emptyInventory();
            },
          )
          .recover(),
      throwsStateError,
    );
    expect(
      await File(harness.paths.metadataPath).readAsString(),
      'new metadata',
    );
  });

  test('ownership replacement after discovery prevents cleanup', () async {
    var replaced = false;
    await expectLater(
      harness
          .recovery(
            inventory: () async {
              if (!replaced) {
                replaced = true;
                final marker = Directory(
                  '${harness.paths.directory}/.gaovm-owner-${harness.paths.cleanupToken}',
                );
                await marker.rename(
                  '${harness.paths.directory}/.gaovm-owner-${'B' * 32}',
                );
              }
              return _emptyInventory();
            },
          )
          .recover(),
      throwsStateError,
    );
    expect(await Directory(harness.paths.directory).exists(), isTrue);
  });

  test(
    'missing ownership, catalog binding and future generations stay intact',
    () async {
      await expectLater(
        harness.recovery(binding: (_) async => null).recover(),
        throwsStateError,
      );
      await expectLater(
        harness
            .recovery(binding: (_) async => harness.binding(generation: 0))
            .recover(),
        throwsStateError,
      );
      await Directory(
        '${harness.paths.directory}/.gaovm-owner-${harness.paths.cleanupToken}',
      ).delete();
      await expectLater(
        harness.recovery().recover(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await Directory(harness.paths.directory).exists(), isTrue);
    },
  );

  test('unknown files remain in quarantine and block recovery', () async {
    final note = File('${harness.paths.directory}/notes');
    await note.writeAsString('preserve');
    await expectLater(
      harness.recovery().recover(),
      throwsA(isA<FileSystemException>()),
    );
    final quarantine =
        '${harness.paths.directory}.cleanup.${harness.paths.cleanupToken}';
    expect(await File('$quarantine/notes').readAsString(), 'preserve');
    expect(
      await Directory(
        '$quarantine/.gaovm-owner-${harness.paths.cleanupToken}',
      ).exists(),
      isTrue,
    );
  });

  test(
    'metadata symlinks never become missing-metadata cleanup candidates',
    () async {
      final outside = await File(
        '${harness.temporary.path}/outside',
      ).writeAsString('preserve');
      await Link(harness.paths.metadataPath).create(outside.path);
      await expectLater(harness.recovery().recover(), throwsStateError);
      expect(await Link(harness.paths.metadataPath).exists(), isTrue);
      expect(await outside.readAsString(), 'preserve');
    },
  );

  for (final vmParent in [false, true]) {
    for (final markerRemoved in [false, true]) {
      test(
        'resumes interrupted cleanup (VM=$vmParent, marker removed=$markerRemoved)',
        () async {
          final canonical = vmParent
              ? Directory(harness.paths.directory).parent.path
              : harness.paths.directory;
          final token = vmParent
              ? harness.paths.vmCleanupToken!
              : harness.paths.cleanupToken!;
          if (vmParent && markerRemoved) {
            await Directory(
              '${harness.paths.directory}/.gaovm-owner-${harness.paths.cleanupToken}',
            ).delete();
            await Directory(harness.paths.directory).delete();
          }
          final quarantine = '$canonical.cleanup.$token';
          await Directory(canonical).rename(quarantine);
          if (markerRemoved)
            await Directory('$quarantine/.gaovm-owner-$token').delete();
          await harness.recovery().recover();
          expect(await Directory(quarantine).exists(), isFalse);
          final snapshot = await DriverRuntimeDiscovery(
            root: harness.run,
            resolveBinding: (_) async => harness.binding(),
          ).scan();
          expect(snapshot.records, isEmpty);
          expect(snapshot.issues, isEmpty);
        },
      );
    }
  }

  test('quarantine never replaces a canonical generation', () async {
    final quarantine =
        '${harness.paths.directory}.cleanup.${harness.paths.cleanupToken}';
    await Directory(harness.paths.directory).rename(quarantine);
    await Directory(harness.paths.directory).create();
    final replacement = await File(
      '${harness.paths.directory}/notes',
    ).writeAsString('new generation');
    await expectLater(harness.recovery().recover(), throwsStateError);
    expect(await replacement.readAsString(), 'new generation');
    expect(await Directory(quarantine).exists(), isTrue);
  });

  test(
    'quarantine token mismatch and linked VM quarantine are preserved',
    () async {
      final quarantine = '${harness.paths.directory}.cleanup.${'B' * 32}';
      await Directory(harness.paths.directory).rename(quarantine);
      await expectLater(harness.recovery().recover(), throwsStateError);
      expect(
        await Directory(
          '$quarantine/.gaovm-owner-${harness.paths.cleanupToken}',
        ).exists(),
        isTrue,
      );
      await Directory(quarantine).rename(harness.paths.directory);
      final outside = await Directory(
        '${harness.temporary.path}/outside',
      ).create();
      final note = await File(
        '${outside.path}/notes',
      ).writeAsString('preserve');
      final vmQuarantine =
          '${Directory(harness.paths.directory).parent.path}.cleanup.${harness.paths.vmCleanupToken}';
      await Link(vmQuarantine).create(outside.path);
      await expectLater(
        harness.recovery().recover(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await note.readAsString(), 'preserve');
      expect(await Link(vmQuarantine).exists(), isTrue);
    },
  );

  test('empty quarantine waits for a complete driver-free census', () async {
    final quarantine =
        '${harness.paths.directory}.cleanup.${harness.paths.cleanupToken}';
    await Directory(harness.paths.directory).rename(quarantine);
    await Directory(
      '$quarantine/.gaovm-owner-${harness.paths.cleanupToken}',
    ).delete();
    await expectLater(
      harness
          .recovery(
            inventory: () async => DriverInventorySnapshot(
              processes: [],
              unresolvedProcessIds: [pid],
            ),
          )
          .recover(),
      throwsStateError,
    );
    expect(await Directory(quarantine).exists(), isTrue);
  });

  test(
    'a process crash before metadata leaves recoverable owned files',
    () async {
      final temporary =
          await (Platform.isMacOS
                  ? Directory('/private/tmp')
                  : Directory.systemTemp)
              .createTemp('gvm-crash-');
      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/test/fixtures/crash_driver_runtime.dart',
        temporary.path,
      ]);
      final errors = child.stderr.drain<void>();
      try {
        expect(
          await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 10)),
          'ready',
        );
        expect(child.kill(ProcessSignal.sigkill), isTrue);
        expect(await child.exitCode, -9);
        final state = await OwnedImageDirectory.open(temporary);
        final owner = (await DaemonOwnership.tryAcquire(state))!;
        final layout = DriverRuntimeLayout('${state.path}/run');
        final run = state.directory('run');
        try {
          await DriverStartupRecovery(
            ownership: owner,
            layout: layout,
            discovery: DriverRuntimeDiscovery(
              root: run,
              resolveBinding: (_) async => DriverRecoveryBinding(
                driverGeneration: 1,
                executable: '/opt/driver',
                bundlePath: '${state.path}/bundle',
              ),
            ),
            // The fixture has no driver child. Its owner has been confirmed dead.
            readInventory: () async => _emptyInventory(),
          ).recover();
          expect(
            await Directory('${run.path}/${_vmId.value}').exists(),
            isFalse,
          );
          await owner.verify();
        } finally {
          run.close();
          owner.close();
          state.close();
        }
      } finally {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        await errors;
        await temporary.delete(recursive: true);
      }
    },
  );
}

final _vmId = VmId('vm_01J00000000000000000000000');
DriverInventorySnapshot _emptyInventory() =>
    DriverInventorySnapshot(processes: [], unresolvedProcessIds: []);

final class _Harness {
  _Harness(
    this.temporary,
    this.state,
    this.owner,
    this.layout,
    this.run,
    this.paths,
  );
  final Directory temporary;
  final OwnedImageDirectory state;
  final DaemonOwnership owner;
  final DriverRuntimeLayout layout;
  final OwnedImageDirectory run;
  final DriverRuntimePaths paths;

  static Future<_Harness> create() async {
    final temporary =
        await (Platform.isMacOS
                ? Directory('/private/tmp')
                : Directory.systemTemp)
            .createTemp('gvm-empty-');
    final state = await OwnedImageDirectory.open(temporary);
    final owner = (await DaemonOwnership.tryAcquire(state))!;
    final layout = DriverRuntimeLayout('${state.path}/run');
    final paths = await layout.create(
      DriverCorrelation(vmId: _vmId, driverGeneration: 1, operationId: null),
    );
    final run = state.directory('run');
    return _Harness(temporary, state, owner, layout, run, paths);
  }

  DriverRecoveryBinding binding({int generation = 1}) => DriverRecoveryBinding(
    driverGeneration: generation,
    executable: '/opt/driver',
    bundlePath: '${state.path}/bundle',
  );

  DriverStartupRecovery recovery({
    Future<DriverInventorySnapshot> Function()? inventory,
    Future<DriverRecoveryBinding?> Function(VmId)? binding,
  }) => DriverStartupRecovery(
    ownership: owner,
    layout: layout,
    discovery: DriverRuntimeDiscovery(
      root: run,
      resolveBinding: binding ?? (_) async => this.binding(),
    ),
    readInventory: inventory ?? () async => _emptyInventory(),
  );

  Future<void> close() async {
    run.close();
    owner.close();
    state.close();
    await temporary.delete(recursive: true);
  }
}
