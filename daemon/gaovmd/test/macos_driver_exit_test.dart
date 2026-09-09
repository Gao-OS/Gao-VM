import 'dart:io';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:test/test.dart';

void main() {
  test(
    'exit wait times out for a live child and confirms its later exit',
    () async {
      final executable = File('/bin/cat').resolveSymbolicLinksSync();
      final child = await Process.start(executable, []);
      final stdout = child.stdout.drain<void>();
      final stderr = child.stderr.drain<void>();
      var exited = false;
      try {
        final identity = (await MacOsDriverInventory(
          executablePath: executable,
        ).inspect(child.pid))!;
        final stale = DriverProcessIdentity(
          pid: identity.pid,
          uid: identity.uid,
          executablePath: identity.executablePath,
          startedAtMicroseconds: identity.startedAtMicroseconds,
          pidVersion: (identity.pidVersion! + 1) & 0xffffffff,
        );
        expect(
          await MacOsDriverExit.waitForExit(stale, const Duration(seconds: 1)),
          DriverExitObservation.identityChanged,
        );
        var timerRan = false;
        final timer = Future<void>.delayed(
          const Duration(milliseconds: 10),
          () => timerRan = true,
        );
        expect(
          await MacOsDriverExit.waitForExit(
            identity,
            const Duration(milliseconds: 100),
          ),
          DriverExitObservation.timedOut,
        );
        expect(timerRan, isTrue);
        await timer;
        final waiting = MacOsDriverExit.waitForExit(
          identity,
          const Duration(seconds: 5),
        );
        await MacOsDriverSignaler.signal(identity, ProcessSignal.sigterm);
        expect(await waiting, DriverExitObservation.exited);
        await child.exitCode;
        exited = true;
        expect(
          await MacOsDriverExit.waitForExit(
            identity,
            const Duration(seconds: 1),
          ),
          DriverExitObservation.exited,
        );
      } finally {
        if (!exited) child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        await Future.wait([stdout, stderr]);
      }
    },
    skip: !Platform.isMacOS,
  );
}
