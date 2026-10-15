import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/cold_catalog_inspection.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:gaovmd/src/macos_open_references.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory state;
  late File disk;
  late File efi;
  late ColdStateLease lease;
  late OwnedImageDirectory scratch;
  late ColdCatalogInspection catalog;
  var retainInputs = false;

  Future<ProcessResult> command(
    String executable,
    List<String> arguments,
  ) async {
    try {
      return await runMaintenanceCommand(executable, arguments);
    } on MaintenanceCommandFailure catch (error) {
      if (!error.exitConfirmed) retainInputs = true;
      rethrow;
    }
  }

  Future<ColdFileReferences> inspect({MacOsOpenReferences? observer}) =>
      ColdFileReferences.inspect(
        catalog,
        observer: observer ?? MacOsOpenReferences(command: command),
      );

  Future<void> changeDiskPath(String path) async {
    final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    try {
      final repository = SqliteVmRepository(database);
      final vm = (await repository.list()).single;
      final json = vm.spec.toJson();
      ((json['disks'] as List).single['source'] as Map)['path'] = path;
      await repository.updateSpec(
        vm.metadata.id,
        expectedRevision: vm.metadata.revision,
        spec: VmSpec.fromJson(json),
      );
    } finally {
      database.close();
    }
    final output = await Directory(
      '${temporary.path}/next-inspection',
    ).create();
    imageFileMode(output.path, 0x1c0);
    scratch.close();
    scratch = await OwnedImageDirectory.open(output);
    catalog = await ColdCatalogInspection.inspect(lease, scratch);
  }

  setUp(() async {
    retainInputs = false;
    temporary = Directory(
      await (await Directory.systemTemp.createTemp(
        'gvm-file-ref-',
      )).resolveSymbolicLinks(),
    );
    imageFileMode(temporary.path, 0x1c0);
    state = await Directory('${temporary.path}/state').create();
    imageFileMode(state.path, 0x1c0);
    disk = await File(
      '${temporary.path}/operator.raw',
    ).writeAsString('original disk bytes');
    efi = await File(
      '${temporary.path}/operator.efi',
    ).writeAsString('original EFI bytes');
    for (final file in [disk, efi]) {
      imageFileMode(file.path, 0x180);
    }
    final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    try {
      await SqliteVmRepository(database).create(
        name: 'external-files',
        spec: VmSpec(
          cpu: 1,
          memoryBytes: 268435456,
          boot: EfiBoot(
            variableStore: EfiVariableStore.external,
            variableStorePath: efi.path,
          ),
          disks: [
            VmDisk(
              id: 'root',
              source: ExternalDiskSource(disk.path),
              writable: true,
            ),
          ],
          networks: [DisconnectedNetwork(id: 'net0')],
          graphics: GraphicsConfig(enabled: false),
          serial: const SerialConfig(enabled: true, capture: true),
          guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
          restartPolicy: RestartPolicy.never,
        ),
      );
    } finally {
      database.close();
    }
    imageFileMode('${state.path}/gaovm.db', 0x180);
    final output = await Directory('${temporary.path}/inspection').create();
    imageFileMode(output.path, 0x1c0);
    scratch = await OwnedImageDirectory.open(output);
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: 'org.gaovm.tests.Files',
      host: _Host(),
    );
    catalog = await ColdCatalogInspection.inspect(lease, scratch);
  });
  tearDown(() async {
    lease.close();
    scratch.close();
    if (retainInputs)
      throw StateError(
        'retaining inputs for unconfirmed observer: ${temporary.path}',
      );
    await temporary.delete(recursive: true);
  });

  test(
    'actual disk and EFI files have held, revalidatable evidence, not backups',
    () async {
      final references = await inspect();
      try {
        final evidence = references.toJson();
        expect(evidence['format'], 'gaovm.cold-file-references.v1');
        final files = evidence['files'] as List;
        expect(files.map((e) => e['path']).toSet(), {disk.path, efi.path});
        for (final file in files) {
          expect(file['location'], 'external');
          expect(file['backed_up'], isFalse);
          expect((file['evidence'] as Map)['digest'], startsWith('sha256:'));
          expect((file['bindings'] as List).length, 1);
        }
        await references.verify();
        expect(await disk.readAsString(), 'original disk bytes');
        expect(await efi.readAsString(), 'original EFI bytes');
      } finally {
        references.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'shared disk/EFI consumers are bound to one held file',
    () async {
      await changeDiskPath(efi.path);
      final references = await inspect();
      try {
        final files = references.toJson()['files'] as List;
        expect(files.length, 1);
        expect((files.single['bindings'] as List).length, 2);
      } finally {
        references.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'an external-source path inside state remains explicitly accounted for',
    () async {
      final managed = await File(
        '${state.path}/retained.raw',
      ).writeAsString('managed bytes');
      imageFileMode(managed.path, 0x180);
      await changeDiskPath(managed.path);
      final references = await inspect();
      try {
        final files = references.toJson()['files'] as List;
        expect(
          files.singleWhere((file) => file['path'] == managed.path)['location'],
          'state',
        );
        expect(
          files.any((file) => file['path'] == disk.path),
          isFalse,
          reason: 'unapplied historical specs are not live consumers',
        );
      } finally {
        references.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  for (final fault in [
    'missing',
    'empty',
    'symlink',
    'hardlink',
    'writable',
    'acl',
  ]) {
    test('$fault reference is retained and refused', () async {
      switch (fault) {
        case 'missing':
          await disk.rename('${temporary.path}/retained.raw');
        case 'empty':
          await disk.writeAsBytes([]);
        case 'symlink':
          final retained = await disk.rename('${temporary.path}/retained.raw');
          await Link(disk.path).create(retained.path);
        case 'hardlink':
          expect(
            (await command('/bin/ln', [
              disk.path,
              '${temporary.path}/second-link.raw',
            ])).exitCode,
            0,
          );
        case 'writable':
          imageFileMode(disk.path, 0x1b6);
        case 'acl':
          final user = (await command('/usr/bin/id', [
            '-un',
          ])).stdout.toString().trim();
          expect(user, isNotEmpty);
          expect(
            (await command('/bin/chmod', [
              '+a',
              'user:$user allow read',
              disk.path,
            ])).exitCode,
            0,
          );
      }
      await expectLater(
        inspect(),
        throwsA(anyOf(isA<ColdStateFailure>(), isA<FileSystemException>())),
      );
      expect(await efi.readAsString(), 'original EFI bytes');
      expect(await Directory(temporary.path).exists(), isTrue);
      await lease.verify();
    }, skip: !Platform.isMacOS);
  }

  test(
    'occupied native observation, including partial exit one, refuses progress',
    () async {
      final observer = MacOsOpenReferences(
        command: (_, _) async =>
            ProcessResult(0x7ffffffe, 1, 'p123456\x00\nf3\x00\n', ''),
      );
      await expectLater(
        inspect(observer: observer),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(await disk.readAsString(), 'original disk bytes');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a byte change during native observation is not sealed as cold',
    () async {
      var changed = false;
      final observer = MacOsOpenReferences(
        command: (_, _) async {
          if (!changed) {
            changed = true;
            await disk.writeAsString('changed by fixture writer');
          }
          return ProcessResult(0x7ffffffe, 1, '', '');
        },
      );
      await expectLater(
        inspect(observer: observer),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            'referenced file changed during inspection',
          ),
        ),
      );
      expect(await disk.readAsString(), 'changed by fixture writer');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'revalidation rejects metadata-only changes without releasing state ownership',
    () async {
      final references = await inspect();
      try {
        imageFileMode(disk.path, 0x100);
        await expectLater(
          references.verify(),
          throwsA(isA<ColdStateFailure>()),
        );
        expect(await disk.readAsString(), 'original disk bytes');
        await lease.verify();
      } finally {
        references.close();
      }
      await expectLater(references.verify(), throwsStateError);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'revalidation rejects a replaced pathname even with the same bytes',
    () async {
      final references = await inspect();
      try {
        await disk.rename('${temporary.path}/retained.raw');
        await disk.writeAsString('original disk bytes');
        imageFileMode(disk.path, 0x180);
        await expectLater(
          references.verify(),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          await File('${temporary.path}/retained.raw').readAsString(),
          'original disk bytes',
        );
      } finally {
        references.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'changed catalog cannot lend stale file bindings to a later check',
    () async {
      final references = await inspect();
      try {
        final database = sqlite3.open('${state.path}/gaovm.db');
        try {
          database.execute(
            "UPDATE vms SET name = 'changed' WHERE deleted_at IS NULL",
          );
        } finally {
          database.dispose();
        }
        await expectLater(
          references.verify(),
          throwsA(isA<ColdStateFailure>()),
        );
      } finally {
        references.close();
      }
    },
    skip: !Platform.isMacOS,
  );
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
      'bundle_identifier': 'org.gaovm.tests.Files',
      'plist_name': 'gaovmd.plist',
      'authorization_state': 'notRegistered',
      'native_status': 0,
      'outcome': 'observed',
      'error_code': null,
    }),
    '',
  );
}
