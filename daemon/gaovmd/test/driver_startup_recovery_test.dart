import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  test('startup ownership must cover the runtime state directory', () async {
    final temporary =
        await (Platform.isMacOS
                ? Directory('/private/tmp')
                : Directory.systemTemp)
            .createTemp('gvm-binding-');
    final state = await OwnedImageDirectory.open(temporary);
    final owner = (await DaemonOwnership.tryAcquire(state))!;
    final unrelated = state.createDirectory('unrelated');
    try {
      expect(
        () => DriverStartupRecovery(
          ownership: owner,
          layout: DriverRuntimeLayout(unrelated.path),
          discovery: DriverRuntimeDiscovery(
            root: unrelated,
            resolveBinding: (_) async => null,
          ),
          readInventory: () async =>
              DriverInventorySnapshot(processes: [], unresolvedProcessIds: []),
        ),
        throwsArgumentError,
      );
    } finally {
      unrelated.close();
      owner.close();
      state.close();
      await temporary.delete(recursive: true);
    }
  });

  for (final mode in _RecoveryCase.values)
    test('startup recovery ${mode.name}', () async {
      final temporary =
          await (Platform.isMacOS
                  ? Directory('/private/tmp')
                  : Directory.systemTemp)
              .createTemp('gvm-recover-');
      final state = await OwnedImageDirectory.open(temporary);
      final owner = (await DaemonOwnership.tryAcquire(state))!;
      final binary = File('/bin/cat').resolveSymbolicLinksSync();
      final child = await Process.start(binary, []);
      final pipes = [child.stdout.drain<void>(), child.stderr.drain<void>()];
      final inventory = MacOsDriverInventory(executablePath: binary);
      final identity = (await inventory.inspect(child.pid))!;
      final layout = DriverRuntimeLayout('${temporary.path}/run');
      final correlation = DriverCorrelation(
        vmId: VmId('vm_01J00000000000000000000000'),
        driverGeneration: 1,
        operationId: null,
      );
      final paths = await layout.create(correlation);
      await layout.writeMetadata(
        paths,
        correlation: correlation,
        pid: child.pid,
        executable: binary,
        bundlePath: '${temporary.path}/bundle',
        createdAt: DateTime.now(),
        processIdentity: identity,
      );
      final run = await OwnedImageDirectory.open(Directory(layout.runRoot));
      final before = await File(paths.metadataPath).readAsBytes();
      var exited = false;
      try {
        final recovery = DriverStartupRecovery(
          ownership: owner,
          layout: layout,
          discovery: DriverRuntimeDiscovery(
            root: run,
            resolveBinding: (_) async => DriverRecoveryBinding(
              driverGeneration: 1,
              executable: binary,
              bundlePath: '${temporary.path}/bundle',
            ),
          ),
          // Scope the native process-inventory boundary to this test's child;
          // unrelated host processes are covered by inventory's own tests.
          readInventory: () async {
            final current = await inventory.inspect(child.pid);
            if (mode == _RecoveryCase.changedMetadata && current == null) {
              await layout.writeMetadata(
                paths,
                correlation: correlation,
                pid: child.pid,
                executable: binary,
                bundlePath: '${temporary.path}/bundle',
                createdAt: DateTime.utc(2030),
                processIdentity: identity,
              );
            }
            return DriverInventorySnapshot(
              processes: [if (current != null) current],
              unresolvedProcessIds: [
                if (mode == _RecoveryCase.unresolvedBeforeExit ||
                    (mode == _RecoveryCase.unresolvedAfterExit &&
                        current == null))
                  child.pid,
              ],
            );
          },
          orphanGrace: const Duration(milliseconds: 50),
        );
        if (mode == _RecoveryCase.confirmedExit) {
          await recovery.recover();
        } else {
          await expectLater(recovery.recover(), throwsStateError);
          expect(await File(paths.metadataPath).exists(), isTrue);
          if (mode != _RecoveryCase.changedMetadata) {
            expect(await File(paths.metadataPath).readAsBytes(), before);
          }
          if (mode == _RecoveryCase.unresolvedBeforeExit) {
            expect(await inventory.inspect(child.pid), identity);
            return;
          }
        }
        expect(await child.exitCode, -15);
        exited = true;
        expect(
          await Directory(paths.directory).parent.exists(),
          mode != _RecoveryCase.confirmedExit,
        );
        await owner.verify();
      } finally {
        if (!exited) child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        await Future.wait(pipes);
        run.close();
        owner.close();
        state.close();
        await temporary.delete(recursive: true);
      }
    }, skip: !Platform.isMacOS);
}

enum _RecoveryCase {
  confirmedExit,
  unresolvedBeforeExit,
  unresolvedAfterExit,
  changedMetadata,
}
