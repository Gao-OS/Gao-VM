import 'dart:io';

import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:test/test.dart';

void main() {
  test(
    'unmanaged counting requires full identity and a complete inventory',
    () {
      const current = DriverProcessIdentity(
        pid: 123,
        uid: 502,
        executablePath: '/driver',
        startedAtMicroseconds: 200,
      );
      const previous = DriverProcessIdentity(
        pid: 123,
        uid: 502,
        executablePath: '/driver',
        startedAtMicroseconds: 100,
      );
      final snapshot = DriverInventorySnapshot(
        processes: [current],
        unresolvedProcessIds: [],
      );
      expect(snapshot.countUnmanaged({previous}), 1);
      expect(snapshot.countUnmanaged({current}), 0);
      expect(
        () => DriverInventorySnapshot(
          processes: [current],
          unresolvedProcessIds: [456],
        ).countUnmanaged({current}),
        throwsStateError,
      );
    },
  );

  test(
    'snapshot retains unresolved processes instead of silently undercounting',
    () async {
      final inventory = MacOsDriverInventory(
        executablePath: File(
          Platform.resolvedExecutable,
        ).resolveSymbolicLinksSync(),
      );
      final snapshot = await inventory.snapshot();
      expect(snapshot.processes.any((entry) => entry.pid == pid), isTrue);
      expect(() => snapshot.processes.clear(), throwsUnsupportedError);
      expect(
        () => snapshot.unresolvedProcessIds.clear(),
        throwsUnsupportedError,
      );
      if (snapshot.unresolvedProcessIds.isNotEmpty) {
        expect(() => snapshot.countUnmanaged({}), throwsStateError);
      } else {
        expect(snapshot.countUnmanaged(snapshot.processes.toSet()), 0);
        expect(snapshot.countUnmanaged({}), snapshot.processes.length);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'owned child identity disappears after confirmed exit; path is exact',
    () async {
      final executable = File('/bin/cat').resolveSymbolicLinksSync();
      final inventory = MacOsDriverInventory(executablePath: executable);
      final child = await Process.start(executable, []);
      final output = child.stdout.drain<void>();
      final errors = child.stderr.drain<void>();
      try {
        final identity = (await inventory.inspect(child.pid))!;
        expect(identity.pid, child.pid);
        expect(
          await MacOsDriverInventory(
            executablePath: '/different/cat',
          ).inspect(child.pid),
          isNull,
        );
        final reusedPid = DriverProcessIdentity(
          pid: identity.pid,
          uid: identity.uid,
          executablePath: identity.executablePath,
          startedAtMicroseconds: identity.startedAtMicroseconds + 1,
        );
        expect({identity}.contains(reusedPid), isFalse);
        await child.stdin.close();
        expect(await child.exitCode, 0);
        expect(await inventory.inspect(child.pid), isNull);
      } finally {
        child.kill();
        await child.exitCode;
        await Future.wait([output, errors]);
      }
    },
    skip: !Platform.isMacOS,
  );

  test('invalid identity lookup cannot target process groups', () async {
    final inventory = MacOsDriverInventory(executablePath: '/bin/cat');
    await expectLater(inventory.inspect(0), throwsArgumentError);
    await expectLater(inventory.inspect(-1), throwsArgumentError);
    await expectLater(inventory.inspect(0x100000001), throwsArgumentError);
    expect(
      () => MacOsDriverInventory(executablePath: 'cat'),
      throwsArgumentError,
    );
  });

  test(
    'inventory identifies this process by executable and kernel birth time',
    () async {
      final inventory = MacOsDriverInventory(
        executablePath: File(
          Platform.resolvedExecutable,
        ).resolveSymbolicLinksSync(),
      );
      final first = (await inventory.inspect(pid))!;
      final second = (await inventory.inspect(pid))!;
      expect(first, second);
      expect(first.startedAtMicroseconds, greaterThan(0));
      expect(
        first.startedAtMicroseconds,
        lessThan(DateTime.now().microsecondsSinceEpoch),
      );
      expect(first.executablePath, inventory.executablePath);
      expect(first.uid, greaterThanOrEqualTo(0));
      expect(first.pidVersion, isNotNull);
      expect(first.pidVersion, inInclusiveRange(0, 0xffffffff));
    },
    skip: !Platform.isMacOS,
  );
}
