import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/cold_catalog_inspection.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/daemon_ownership.dart';
import 'package:gaovmd/src/driver_runtime_layout.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory state;
  late OwnedImageDirectory scratch;
  late ColdStateLease lease;
  late VmId vm;
  late DriverRuntimeLayout layout;
  late _Inventory inventory;
  ColdRuntimeInspection? inspection;

  setUp(() async {
    temporary = Directory(
      await (await Directory(
        '/private/tmp',
      ).createTemp('gvm-cr-')).resolveSymbolicLinks(),
    );
    imageFileMode(temporary.path, 0x1c0);
    state = await Directory('${temporary.path}/state').create();
    imageFileMode(state.path, 0x1c0);
    final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    try {
      vm = (await SqliteVmRepository(database).create(
        name: 'retained-runtime',
        spec: VmSpec(
          cpu: 1,
          memoryBytes: 268435456,
          boot: EfiBoot(
            variableStore: EfiVariableStore.external,
            variableStorePath: '${temporary.path}/external.efi',
          ),
          disks: [
            VmDisk(
              id: 'root',
              source: ExternalDiskSource('${temporary.path}/external.raw'),
              writable: true,
            ),
          ],
          networks: [DisconnectedNetwork(id: 'net0')],
          graphics: GraphicsConfig(enabled: false),
          serial: SerialConfig(enabled: true, capture: true),
          guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
          restartPolicy: RestartPolicy.never,
        ),
      )).metadata.id;
    } finally {
      database.close();
    }
    final raw = sqlite3.open('${state.path}/gaovm.db');
    try {
      raw.execute(
        "UPDATE vm_runtime SET driver_generation = 2, phase = 'stopped'",
      );
    } finally {
      raw.dispose();
    }
    imageFileMode('${state.path}/gaovm.db', 0x180);
    layout = DriverRuntimeLayout('${state.path}/run');
    for (final generation in [1, 2]) {
      final correlation = DriverCorrelation(
        vmId: vm,
        driverGeneration: generation,
        operationId: null,
      );
      final paths = await layout.create(correlation);
      await layout.writeMetadata(
        paths,
        correlation: correlation,
        pid: 120 + generation,
        executable: generation == 1 ? _retired : _current,
        bundlePath: '${state.path}/vms/${vm.value}.gaovm',
        createdAt: DateTime.utc(2026, 10, 15),
      );
    }
    final output = await Directory('${temporary.path}/inspection').create();
    imageFileMode(output.path, 0x1c0);
    scratch = await OwnedImageDirectory.open(output);
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: 'org.gaovm.tests.Runtime',
      host: _Host(),
    );
    inventory = _Inventory();
    inspection = null;
  });
  tearDown(() async {
    inspection?.close();
    lease.close();
    scratch.close();
    await temporary.delete(recursive: true);
  });

  Future<ColdRuntimeInspection> inspect() async {
    final catalog = await ColdCatalogInspection.inspect(lease, scratch);
    return inspection = await ColdRuntimeInspection.inspect(
      catalog,
      inventory: inventory.snapshot,
    );
  }

  Future<void> staleSocket(String path) async {
    final server = await ServerSocket.bind(
      InternetAddress('$path.tmp', type: InternetAddressType.unix),
      0,
    );
    try {
      expect((await Process.run('/bin/ln', ['$path.tmp', path])).exitCode, 0);
    } finally {
      await server.close();
    }
    imageFileMode(path, 0x180);
    expect(
      await FileSystemEntity.type(path, followLinks: false),
      FileSystemEntityType.unixDomainSock,
    );
  }

  test(
    'checks all retained generations and old executable paths read-only',
    () async {
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        final result = await inspect();
        expect(result.toJson()['format'], 'gaovm.cold-runtime-inspection.v1');
        final records = result.toJson()['records'] as List;
        expect(records.map((record) => (record as Map)['driver_generation']), [
          1,
          2,
        ]);
        expect(inventory.observed.toSet(), {_current, _retired});
        expect(result.toJson()['run_omission_authorized'], false);
        await result.verify();
        await source.verify(before, nativeMetadata: true);
        final root = await OwnedImageDirectory.open(state);
        try {
          expect(await DaemonOwnership.tryAcquire(root), isNull);
        } finally {
          root.close();
        }
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'retains known stale socket entries without connecting or unlinking',
    () async {
      final path = '${state.path}/run/${vm.value}/1/driver.sock';
      await staleSocket(path);
      final result = await inspect();
      final entries = result.toJson()['entries'] as Map;
      expect((entries['${vm.value}/1/driver.sock'] as Map)['kind'], 'socket');
      await result.verify();
      expect(
        await FileSystemEntity.type(path, followLinks: false),
        FileSystemEntityType.unixDomainSock,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'contradictory foreign process identity cannot become exit evidence',
    () async {
      final root = await OwnedImageDirectory.open(state);
      late int owner;
      try {
        owner = (await root.maintenanceMetadata())['uid'] as int;
      } finally {
        root.close();
      }
      final metadata = File('${state.path}/run/${vm.value}/1/metadata.json');
      final value =
          jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
      value['process_identity'] = {
        'pid': 121,
        'uid': owner + 1,
        'executable_path': _retired,
        'started_at_microseconds': 1,
      };
      await metadata.writeAsString(jsonEncode(value));
      final bytes = await metadata.readAsBytes();
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(inventory.observed, isEmpty);
      expect(await metadata.readAsBytes(), bytes);
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  for (final executable in [_current, _retired]) {
    for (final unresolved in [false, true]) {
      test(
        '${unresolved ? 'unresolved census' : 'live process'} at $executable refuses and retains input',
        () async {
          inventory.results[executable] = DriverInventorySnapshot(
            processes: unresolved
                ? []
                : [
                    DriverProcessIdentity(
                      pid: 701,
                      uid: 501,
                      executablePath: executable,
                      startedAtMicroseconds: 1,
                    ),
                  ],
            unresolvedProcessIds: unresolved ? [702] : [],
          );
          final source = await MaintenanceTree.open(state);
          try {
            final before = await source.capture(nativeMetadata: true);
            await expectLater(
              inspect(),
              throwsA(
                isA<ColdStateFailure>().having(
                  (error) => error.stage,
                  'stage',
                  'runtime_processes',
                ),
              ),
            );
            await source.verify(before, nativeMetadata: true);
            await lease.verify();
            final root = await OwnedImageDirectory.open(state);
            try {
              expect(await DaemonOwnership.tryAcquire(root), isNull);
            } finally {
              root.close();
            }
          } finally {
            source.close();
          }
        },
        skip: !Platform.isMacOS,
      );
    }
  }

  test(
    'a later old driver observation refuses without releasing state ownership',
    () async {
      final result = await inspect();
      inventory.results[_retired] = DriverInventorySnapshot(
        processes: [],
        unresolvedProcessIds: [801],
      );
      await expectLater(result.verify(), throwsA(isA<ColdStateFailure>()));
      result.close();
      await lease.verify();
      final root = await OwnedImageDirectory.open(state);
      try {
        expect(await DaemonOwnership.tryAcquire(root), isNull);
      } finally {
        root.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final change in <String, Object?>{
    'version': 1.0,
    'vm_id': VmId.generate().value,
    'driver_generation': 2,
    'bundle_path': '/test-only/foreign.gaovm',
    'socket_path': '/test-only/foreign.sock',
    'executable': '/test-only/../driver',
  }.entries) {
    test(
      'mismatched ${change.key} metadata is retained and refused',
      () async {
        final file = File('${state.path}/run/${vm.value}/1/metadata.json');
        final value =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        value[change.key] = change.value;
        await file.writeAsString(jsonEncode(value));
        final bytes = await file.readAsBytes();
        await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
        expect(await file.readAsBytes(), bytes);
        expect(inventory.observed, isEmpty);
        await lease.verify();
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'a missing old generation record is unknown, not proof of exit',
    () async {
      final path = '${state.path}/run/${vm.value}/1';
      await File('$path/metadata.json').delete();
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(await Directory(path).exists(), true);
      expect(inventory.observed, isEmpty);
      expect(
        await File('${state.path}/run/${vm.value}/2/metadata.json').exists(),
        true,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a future generation directory is refused without cleanup',
    () async {
      final paths = await layout.create(
        DriverCorrelation(vmId: vm, driverGeneration: 3, operationId: null),
      );
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(await Directory(paths.directory).exists(), true);
      expect(inventory.observed, isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unknown runtime data is retained, not classified as garbage',
    () async {
      final file = await File(
        '${state.path}/run/unknown-data',
      ).writeAsString('operator evidence');
      imageFileMode(file.path, 0x180);
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(await file.readAsString(), 'operator evidence');
      expect(inventory.observed, isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'known API ownership hardlinks bind the same stale socket inode',
    () async {
      final base = '${state.path}/run';
      await staleSocket('$base/.g.test');
      for (final name in ['.o.test', 'api.sock']) {
        expect(
          (await Process.run('/bin/ln', [
            '$base/.g.test',
            '$base/$name',
          ])).exitCode,
          0,
        );
      }
      final result = await inspect();
      final entries = result.toJson()['entries'] as Map;
      final socket = entries['api.sock'] as Map;
      expect(socket['links'], 3);
      expect((entries['.g.test'] as Map)['inode'], socket['inode']);
      expect((entries['.o.test'] as Map)['inode'], socket['inode']);
      await result.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'deleted catalog VMs still bind retained runtime generations',
    () async {
      final database = sqlite3.open('${state.path}/gaovm.db');
      try {
        database.execute(
          "UPDATE vms SET deleted_at = '2026-10-15T00:00:00.000Z'",
        );
        database.execute("UPDATE vm_runtime SET phase = 'deleted'");
      } finally {
        database.dispose();
      }
      final result = await inspect();
      expect((result.toJson()['records'] as List).length, 2);
      expect(inventory.observed.toSet(), {_retired, _current});
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a metadata change during native observation cannot be certified',
    () async {
      final metadata = File('${state.path}/run/${vm.value}/1/metadata.json');
      inventory.onSnapshot = (_) async {
        inventory.onSnapshot = null;
        await metadata.writeAsString('retained concurrent write');
      };
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(await metadata.readAsString(), 'retained concurrent write');
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unavailable native observation propagates without erasing records',
    () async {
      final failure = StateError('native inventory unavailable');
      inventory.onSnapshot = (_) async => throw failure;
      await expectLater(inspect(), throwsA(same(failure)));
      expect(
        await File('${state.path}/run/${vm.value}/1/metadata.json').exists(),
        true,
      );
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  for (final value in ['not JSON', 'x' * 65537]) {
    test(
      '${value.length > 65536 ? 'oversized' : 'malformed'} metadata is retained and refused',
      () async {
        final metadata = File('${state.path}/run/${vm.value}/1/metadata.json');
        await metadata.writeAsString(value);
        await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
        expect(await metadata.readAsString(), value);
        expect(inventory.observed, isEmpty);
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'a regular file impersonating a known socket is never read or replaced',
    () async {
      final impostor = await File(
        '${state.path}/run/api.sock',
      ).writeAsString('retain me');
      imageFileMode(impostor.path, 0x180);
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(await impostor.readAsString(), 'retain me');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'socket ACL grants refuse inspection without normalization',
    () async {
      final socket = '${state.path}/run/${vm.value}/1/guest.sock';
      await staleSocket(socket);
      final user = (await Process.run('/usr/bin/id', [
        '-un',
      ])).stdout.toString().trim();
      expect(user, isNotEmpty);
      expect(
        (await Process.run('/bin/chmod', [
          '+a',
          'user:$user allow read',
          socket,
        ])).exitCode,
        0,
      );
      final before = (await Process.run('/bin/ls', ['-lde', socket])).stdout;
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect((await Process.run('/bin/ls', ['-lde', socket])).stdout, before);
      expect(
        await FileSystemEntity.type(socket, followLinks: false),
        FileSystemEntityType.unixDomainSock,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'closed caller lease refuses before reading potentially live runtime data',
    () async {
      final result = await inspect();
      final observations = inventory.observed.length;
      lease.close();
      await File(
        '${state.path}/run/${vm.value}/1/metadata.json',
      ).writeAsString('changed after release');
      await expectLater(result.verify(), throwsStateError);
      expect(inventory.observed.length, observations);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'closing inspection releases readers, not the original cold lease',
    () async {
      final result = await inspect();
      result.close();
      result.close();
      expect(result.toJson, throwsStateError);
      await expectLater(result.verify(), throwsStateError);
      await lease.verify();
      final root = await OwnedImageDirectory.open(state);
      try {
        expect(await DaemonOwnership.tryAcquire(root), isNull);
      } finally {
        root.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'absent run stays absent and later appearance refuses revalidation',
    () async {
      await Directory(
        '${state.path}/run',
      ).rename('${temporary.path}/retained-run');
      final result = await inspect();
      expect(result.toJson()['run_present'], false);
      expect(result.toJson()['run_omission_authorized'], false);
      expect(await Directory('${state.path}/run').exists(), false);
      await Directory('${state.path}/run').create();
      imageFileMode('${state.path}/run', 0x1c0);
      await expectLater(result.verify(), throwsA(isA<ColdStateFailure>()));
      expect(await Directory('${temporary.path}/retained-run').exists(), true);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'detached exported evidence cannot replace held runtime evidence',
    () async {
      final result = await inspect();
      final exported = result.toJson();
      (exported['records'] as List).clear();
      expect(
        () => (exported['entries'] as Map).clear(),
        throwsUnsupportedError,
      );
      expect((result.toJson()['records'] as List).length, 2);
      await result.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a symlink impersonating a socket is refused without following it',
    () async {
      final external = await File(
        '${temporary.path}/operator-file',
      ).writeAsString('operator bytes');
      await Link('${state.path}/run/api.sock').create(external.path);
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(await external.readAsString(), 'operator bytes');
      expect(await Link('${state.path}/run/api.sock').exists(), true);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'socket replacement after inspection is refused with both generations retained',
    () async {
      final path = '${state.path}/run/${vm.value}/1/driver.sock';
      await staleSocket(path);
      final result = await inspect();
      final original =
          (result.toJson()['entries'] as Map)['${vm.value}/1/driver.sock']
              as Map;
      final saved = '${temporary.path}/retained.sock';
      expect((await Process.run('/bin/mv', [path, saved])).exitCode, 0);
      await staleSocket(path);
      await expectLater(result.verify(), throwsA(isA<ColdStateFailure>()));
      final generation = await OwnedImageDirectory.open(
        Directory('${state.path}/run/${vm.value}/1'),
      );
      try {
        expect(
          (await generation.maintenanceSocketMetadata('driver.sock'))['inode'],
          isNot(original['inode']),
        );
      } finally {
        generation.close();
      }
      expect(
        await FileSystemEntity.type(saved, followLinks: false),
        FileSystemEntityType.unixDomainSock,
      );
    },
    skip: !Platform.isMacOS,
  );
}

const _current = '/test-only/GaoVM.app/Contents/Helpers/gaovm-driver-vz';
const _retired = '/test-only/old/GaoVM.app/Contents/Helpers/gaovm-driver-vz';

final class _Inventory {
  final observed = <String>[];
  final results = <String, DriverInventorySnapshot>{};
  Future<void> Function(String)? onSnapshot;
  Future<DriverInventorySnapshot> snapshot(String executable) async {
    observed.add(executable);
    await onSnapshot?.call(executable);
    return results[executable] ??
        DriverInventorySnapshot(processes: [], unresolvedProcessIds: []);
  }
}

final class _Host implements ColdStateHost {
  @override
  String get appPath => '/test-only/GaoVM.app';
  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async =>
      DriverInventorySnapshot(processes: [], unresolvedProcessIds: []);
  @override
  Future<Set<int>> stateReferences(Directory state) async => {pid};
  @override
  Future<ProcessResult> serviceStatus() async => ProcessResult(
    pid,
    0,
    jsonEncode({
      'action': 'status',
      'bundle_identifier': 'org.gaovm.tests.Runtime',
      'plist_name': 'gaovmd.plist',
      'authorization_state': 'notRegistered',
      'native_status': 0,
      'outcome': 'observed',
      'error_code': null,
    }),
    '',
  );
}
