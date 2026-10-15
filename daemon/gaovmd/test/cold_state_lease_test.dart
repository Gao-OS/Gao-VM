import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/daemon_ownership.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:gaovmd/src/macos_open_references.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:test/test.dart';

void main() {
  late Directory state;
  late _NativeBoundary host;
  var retainInputs = false;
  setUp(() async {
    final created = await Directory.systemTemp.createTemp('gvm-cold-state-');
    state = Directory(await created.resolveSymbolicLinks());
    imageFileMode(state.path, 0x1c0);
    await File('${state.path}/catalog-bytes').writeAsString('retain me');
    imageFileMode('${state.path}/catalog-bytes', 0x180);
    host = _NativeBoundary();
    retainInputs = false;
  });
  tearDown(() async {
    if (retainInputs) {
      throw StateError('retaining inputs for unconfirmed child: ${state.path}');
    }
    await state.delete(recursive: true);
  });

  Future<ColdStateLease> acquire() => ColdStateLease.acquire(
    state,
    bundleIdentifier: 'org.gaovm.tests.Cold',
    host: host,
  );

  test('unregistered service is insufficient while a driver remains', () async {
    host.driver = DriverInventorySnapshot(
      processes: [
        const DriverProcessIdentity(
          pid: 123,
          uid: 501,
          executablePath: '/test-only/gaovm-driver-vz',
          startedAtMicroseconds: 1,
        ),
      ],
      unresolvedProcessIds: [],
    );
    await expectLater(acquire(), throwsA(isA<ColdStateFailure>()));
    expect(
      await File('${state.path}/catalog-bytes').readAsString(),
      'retain me',
    );
    final root = await OwnedImageDirectory.open(state);
    try {
      final owner = await DaemonOwnership.tryAcquire(root);
      expect(
        owner,
        isNotNull,
        reason: 'a refused preflight must release its lock',
      );
      owner?.close();
    } finally {
      root.close();
    }
  });

  test('service status must preserve its native integer schema', () async {
    host.status['native_status'] = 0.0;
    await expectLater(acquire(), throwsA(isA<ColdStateFailure>()));
  });

  test(
    'a held lease excludes daemon ownership until explicit release',
    () async {
      host.references = {pid};
      final lease = await acquire();
      final root = await OwnedImageDirectory.open(state);
      try {
        await lease.verify();
        expect(lease.path, state.path);
        expect(await DaemonOwnership.tryAcquire(root), isNull);
        expect(
          await File('${state.path}/catalog-bytes').readAsString(),
          'retain me',
        );
        lease.close();
        await expectLater(lease.verify(), throwsStateError);
        final next = await DaemonOwnership.tryAcquire(root);
        expect(next, isNotNull);
        next?.close();
      } finally {
        lease.close();
        root.close();
      }
    },
  );

  test('unconfirmed helper exit is preserved as a retention failure', () async {
    host.statusFailure = const MaintenanceCommandFailure(
      'test-only unconfirmed child',
      9876,
      exitConfirmed: false,
    );
    await expectLater(
      acquire(),
      throwsA(
        isA<MaintenanceCommandFailure>().having(
          (e) => e.exitConfirmed,
          'exit',
          false,
        ),
      ),
    );
    expect(
      await File('${state.path}/catalog-bytes').readAsString(),
      'retain me',
    );
  });

  for (final driver in [false, true]) {
    test(
      'unresolved ${driver ? 'driver' : 'daemon'} census refuses acquisition',
      () async {
        final unresolved = DriverInventorySnapshot(
          processes: [],
          unresolvedProcessIds: [321],
        );
        if (driver) {
          host.driver = unresolved;
        } else {
          host.daemon = unresolved;
        }
        await expectLater(acquire(), throwsA(isA<ColdStateFailure>()));
      },
    );
  }

  for (final change in <String, Object?>{
    'authorization_state': 'enabled',
    'bundle_identifier': 'org.foreign.Service',
    'native_status': 3,
    'outcome': 'unregistered',
    'error_code': 'ACTION_UNCONFIRMED',
    'extra': true,
  }.entries) {
    test('service evidence rejects mismatched ${change.key}', () async {
      host.status[change.key] = change.value;
      await expectLater(acquire(), throwsA(isA<ColdStateFailure>()));
    });
  }

  test(
    'a state reference from another executable refuses acquisition',
    () async {
      host.references = {pid + 1};
      await expectLater(acquire(), throwsA(isA<ColdStateFailure>()));
    },
  );

  test(
    'an actual open-file child prevents a lease until confirmed exit',
    () async {
      host.nativeReferences = true;
      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/test/fixtures/hold_maintenance_file.dart',
        '${state.path}/catalog-bytes',
      ]);
      retainInputs = true;
      final errors = child.stderr.drain<void>();
      try {
        expect(
          await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 10)),
          'held',
        );
        await expectLater(
          acquire(),
          throwsA(
            isA<ColdStateFailure>().having(
              (e) => e.stage,
              'stage',
              'state_references',
            ),
          ),
        );
        await child.stdin.close();
        expect(await child.exitCode.timeout(const Duration(seconds: 5)), 0);
        final lease = await acquire();
        try {
          await lease.verify();
        } finally {
          lease.close();
        }
      } finally {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode.timeout(const Duration(seconds: 5));
        retainInputs = false;
        await errors;
      }
    },
    skip: !Platform.isMacOS,
  );

  test('failed revalidation retains the lock and every input byte', () async {
    final lease = await acquire();
    final root = await OwnedImageDirectory.open(state);
    try {
      host.references = {pid + 1};
      await expectLater(lease.verify(), throwsA(isA<ColdStateFailure>()));
      expect(await DaemonOwnership.tryAcquire(root), isNull);
      expect(
        await File('${state.path}/catalog-bytes').readAsString(),
        'retain me',
      );
      host.references = {};
      await lease.verify();
    } finally {
      lease.close();
      root.close();
    }
  });

  test(
    'the final observation rejects service re-registration during preflight',
    () async {
      host.onReferences = () => host.status['authorization_state'] = 'enabled';
      await expectLater(acquire(), throwsA(isA<ColdStateFailure>()));
    },
  );

  test('an existing daemon lock refuses without any native query', () async {
    final root = await OwnedImageDirectory.open(state);
    final owner = (await DaemonOwnership.tryAcquire(root))!;
    try {
      await expectLater(acquire(), throwsA(isA<ColdStateFailure>()));
      expect(host.statusCalls, 0);
      await owner.verify();
    } finally {
      owner.close();
      root.close();
    }
  });

  for (final relationship in ['same', 'state_inside_app', 'app_inside_state']) {
    test(
      '$relationship overlap is refused before creating ownership files',
      () async {
        host.appPath = switch (relationship) {
          'same' => state.path,
          'state_inside_app' => state.parent.path,
          _ => '${state.path}/GaoVM.app',
        };
        await expectLater(
          acquire().then((lease) {
            lease.close();
            return lease;
          }),
          throwsA(isA<ColdStateFailure>()),
        );
        expect(host.statusCalls, 0);
        expect(await File('${state.path}/.gaovmd.lock').exists(), isFalse);
      },
    );
  }

  test('a substituted state inode cannot retain a valid lease', () async {
    final lease = await acquire();
    final retained = await state.rename('${state.path}-retained');
    try {
      await state.create();
      imageFileMode(state.path, 0x1c0);
      await expectLater(lease.verify(), throwsA(isA<FileSystemException>()));
      expect(
        await File('${retained.path}/catalog-bytes').readAsString(),
        'retain me',
      );
    } finally {
      lease.close();
      await retained.delete(recursive: true);
    }
  });
}

final class _NativeBoundary implements ColdStateHost {
  @override
  String appPath = '/test-only/GaoVM.app';
  int statusCalls = 0;
  bool nativeReferences = false;
  Exception? statusFailure;
  Set<int> references = {};
  void Function()? onReferences;
  final status = <String, Object?>{
    'action': 'status',
    'bundle_identifier': 'org.gaovm.tests.Cold',
    'plist_name': 'gaovmd.plist',
    'authorization_state': 'notRegistered',
    'native_status': 0,
    'outcome': 'observed',
    'error_code': null,
  };
  DriverInventorySnapshot driver = DriverInventorySnapshot(
    processes: [],
    unresolvedProcessIds: [],
  );
  DriverInventorySnapshot daemon = DriverInventorySnapshot(
    processes: [],
    unresolvedProcessIds: [],
  );
  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async =>
      driver ? this.driver : daemon;
  @override
  Future<Set<int>> stateReferences(Directory state) async {
    onReferences?.call();
    if (nativeReferences) return MacOsOpenReferences().directory(state);
    return references;
  }

  @override
  Future<ProcessResult> serviceStatus() async {
    statusCalls++;
    if (statusFailure case final Exception failure) throw failure;
    return ProcessResult(9876, 0, jsonEncode(status), '');
  }
}
