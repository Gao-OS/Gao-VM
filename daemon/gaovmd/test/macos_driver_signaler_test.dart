import 'dart:io';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:test/test.dart';

void main() {
  test(
    'rejects legacy identities and unsupported signals before mutation',
    () async {
      const legacy = DriverProcessIdentity(
        pid: 123,
        uid: 502,
        executablePath: '/bin/cat',
        startedAtMicroseconds: 100,
      );
      await expectLater(
        MacOsDriverSignaler.signal(legacy, ProcessSignal.sigkill),
        throwsArgumentError,
      );
      const versioned = DriverProcessIdentity(
        pid: 123,
        uid: 502,
        executablePath: '/bin/cat',
        startedAtMicroseconds: 100,
        pidVersion: 1,
      );
      await expectLater(
        MacOsDriverSignaler.signal(versioned, ProcessSignal.sigstop),
        throwsArgumentError,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'signals an owned child only with its current full kernel identity',
    () async {
      final binary = File('/bin/cat').resolveSymbolicLinksSync();
      final child = await Process.start(binary, []);
      final output = child.stdout.drain<void>();
      final errors = child.stderr.drain<void>();
      var exited = false;
      try {
        final inventory = MacOsDriverInventory(executablePath: binary);
        final identity = (await inventory.inspect(child.pid))!;
        final stale = DriverProcessIdentity(
          pid: identity.pid,
          uid: identity.uid,
          executablePath: binary,
          startedAtMicroseconds: identity.startedAtMicroseconds,
          pidVersion: (identity.pidVersion! + 1) & 0xffffffff,
        );
        expect(
          await MacOsDriverSignaler.signal(stale, ProcessSignal.sigkill),
          isFalse,
        );
        expect(await inventory.inspect(child.pid), identity);
        expect(
          await MacOsDriverSignaler.signal(identity, ProcessSignal.sigterm),
          isTrue,
        );
        await child.exitCode.timeout(const Duration(seconds: 5));
        exited = true;
        expect(await inventory.inspect(child.pid), isNull);
      } finally {
        if (!exited) child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        await Future.wait([output, errors]);
      }
    },
    skip: !Platform.isMacOS,
  );
}
