import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  test(
    'one identity failure does not return while another teardown is active',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'startup-teardown-',
      );
      final root = await OwnedImageDirectory.open(temporary);
      final owner = (await DaemonOwnership.tryAcquire(root))!;
      final binary = File('/bin/cat').resolveSymbolicLinksSync();
      final children = await Future.wait([
        Process.start(binary, []),
        Process.start(binary, []),
      ]);
      final pipes = [
        for (final child in children) ...[
          child.stdout.drain<void>(),
          child.stderr.drain<void>(),
        ],
      ];
      var secondExited = false;
      try {
        final inventory = MacOsDriverInventory(executablePath: binary);
        final first = (await inventory.inspect(children[0].pid))!;
        final second = (await inventory.inspect(children[1].pid))!;
        final stale = DriverProcessIdentity(
          pid: first.pid,
          uid: first.uid,
          executablePath: binary,
          startedAtMicroseconds: first.startedAtMicroseconds,
          pidVersion: (first.pidVersion! + 1) & 0xffffffff,
        );
        await expectLater(
          DriverStartupTeardown(
            ownership: owner,
            orphanGrace: const Duration(milliseconds: 100),
            terminateGrace: const Duration(seconds: 1),
            killGrace: const Duration(seconds: 1),
          ).terminateRecorded(
            DriverDiscoverySnapshot([
              _record(stale),
              _record(second, vmId: 'vm_01J00000000000000000000001'),
            ], []),
          ),
          throwsStateError,
        );
        expect(await inventory.inspect(children[0].pid), first);
        expect(await inventory.inspect(children[1].pid), isNull);
        await children[1].exitCode;
        secondExited = true;
        await owner.verify();
      } finally {
        children[0].kill(ProcessSignal.sigkill);
        if (!secondExited) children[1].kill(ProcessSignal.sigkill);
        await Future.wait([for (final child in children) child.exitCode]);
        await Future.wait(pipes);
        owner.close();
        root.close();
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test('escalates ignored TERM to KILL and waits for exit', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'startup-teardown-',
    );
    final root = await OwnedImageDirectory.open(temporary);
    final owner = (await DaemonOwnership.tryAcquire(root))!;
    final binary = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
    final child = await Process.start(binary, [
      '${Directory.current.path}/test/fixtures/ignore_term.dart',
    ]);
    final lines = <String>[];
    final ready = Completer<void>();
    final output = child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          lines.add(line);
          if (line == 'ready') ready.complete();
        });
    final errors = child.stderr.drain<void>();
    var exited = false;
    try {
      await ready.future.timeout(const Duration(seconds: 10));
      final identity = (await MacOsDriverInventory(
        executablePath: binary,
      ).inspect(child.pid))!;
      await DriverStartupTeardown(
        ownership: owner,
        orphanGrace: const Duration(milliseconds: 50),
        terminateGrace: const Duration(milliseconds: 200),
        killGrace: const Duration(seconds: 2),
      ).terminateRecorded(DriverDiscoverySnapshot([_record(identity)], []));
      expect(await child.exitCode, -9);
      exited = true;
      expect(lines, contains('term'));
    } finally {
      if (!exited) child.kill(ProcessSignal.sigkill);
      await child.exitCode;
      await output.cancel();
      await errors;
      owner.close();
      root.close();
      await temporary.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);

  test(
    'unresolved discovery preserves a child; valid teardown confirms its exit',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'startup-teardown-',
      );
      final root = await OwnedImageDirectory.open(temporary);
      final owner = (await DaemonOwnership.tryAcquire(root))!;
      final binary = File('/bin/cat').resolveSymbolicLinksSync();
      final child = await Process.start(binary, []);
      final output = child.stdout.drain<void>();
      final errors = child.stderr.drain<void>();
      var exited = false;
      try {
        final identity = (await MacOsDriverInventory(
          executablePath: binary,
        ).inspect(child.pid))!;
        final record = _record(identity);
        final teardown = DriverStartupTeardown(
          ownership: owner,
          orphanGrace: const Duration(milliseconds: 100),
          terminateGrace: const Duration(seconds: 1),
          killGrace: const Duration(seconds: 1),
        );
        await expectLater(
          teardown.terminateRecorded(
            DriverDiscoverySnapshot(
              [record],
              [
                const DriverDiscoveryIssue(
                  '/unknown',
                  DriverDiscoveryIssueKind.missingMetadata,
                ),
              ],
            ),
          ),
          throwsStateError,
        );
        expect(
          await MacOsDriverInventory(executablePath: binary).inspect(child.pid),
          identity,
        );
        await expectLater(
          teardown.terminateRecorded(
            DriverDiscoverySnapshot([record, record], []),
          ),
          throwsStateError,
        );
        final legacy = record.toJson();
        (legacy['process_identity'] as Map<String, Object?>).remove(
          'pid_version',
        );
        await expectLater(
          teardown.terminateRecorded(
            DriverDiscoverySnapshot([
              DriverRuntimeMetadata.fromJson(legacy),
            ], []),
          ),
          throwsStateError,
        );
        expect(
          await MacOsDriverInventory(executablePath: binary).inspect(child.pid),
          identity,
        );
        await teardown.terminateRecorded(DriverDiscoverySnapshot([record], []));
        await child.exitCode;
        exited = true;
        expect(
          await MacOsDriverInventory(executablePath: binary).inspect(child.pid),
          isNull,
        );
        await owner.verify();
      } finally {
        if (!exited) child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        await Future.wait([output, errors]);
        owner.close();
        root.close();
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}

DriverRuntimeMetadata _record(
  DriverProcessIdentity identity, {
  String vmId = 'vm_01J00000000000000000000000',
}) => DriverRuntimeMetadata.fromJson({
  'version': 1,
  'vm_id': vmId,
  'driver_generation': 1,
  'operation_id': null,
  'pid': identity.pid,
  'executable': identity.executablePath,
  'bundle_path': '/owned/bundle',
  'socket_path': '/owned/run/driver.sock',
  'created_at': '2026-09-07T00:00:00Z',
  'process_identity': {
    'pid': identity.pid,
    'uid': identity.uid,
    'executable_path': identity.executablePath,
    'started_at_microseconds': identity.startedAtMicroseconds,
    'pid_version': identity.pidVersion,
  },
});
