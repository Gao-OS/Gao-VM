import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/cold_catalog_inspection.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/daemon_ownership.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/image_manifest.dart';
import 'package:gaovmd/src/legacy_vm_migration.dart';
import 'package:gaovmd/src/macos_driver_inventory.dart';
import 'package:gaovmd/src/macos_open_references.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  late Directory temporary;
  late Directory state;
  late File kernel;
  late File disk;
  late ColdStateLease lease;
  ColdLegacyInspection? inspection;
  final observed = <String>[];
  final scratch = <OwnedImageDirectory>[];
  final children = <OwnedTestProcess>[];
  var retainInputs = false;

  setUp(() async {
    temporary = Directory(
      await (await Directory(
        '/private/tmp',
      ).createTemp('gvm-cl-')).resolveSymbolicLinks(),
    );
    imageFileMode(temporary.path, 0x1c0);
    state = await Directory('${temporary.path}/state').create();
    imageFileMode(state.path, 0x1c0);
    kernel = await File('${temporary.path}/kernel').writeAsString('kernel');
    disk = await File('${temporary.path}/disk').writeAsString('mutable disk');
    for (final file in [kernel, disk]) {
      imageFileMode(file.path, 0x180);
    }
    await File('${state.path}/config.json').writeAsString(
      jsonEncode({
        'cpu': 1,
        'memory': 268435456,
        'boot': {'loader': 'linux', 'kernelPath': kernel.path},
        'disk': {'path': disk.path},
        'network': {'mode': 'none'},
        'graphics': {'enabled': false, 'width': 1280, 'height': 800},
      }),
    );
    imageFileMode('${state.path}/config.json', 0x180);
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: 'org.gaovm.tests.Legacy',
      host: _Host(),
    );
    observed.clear();
    inspection = null;
    retainInputs = false;
  });
  tearDown(() async {
    for (final child in children) {
      if (!await child.terminate()) retainInputs = true;
    }
    children.clear();
    inspection?.close();
    lease.close();
    for (final directory in scratch) {
      directory.close();
    }
    scratch.clear();
    if (retainInputs) {
      throw StateError(
        'retaining inputs for unconfirmed native child: ${temporary.path}',
      );
    }
    await temporary.delete(recursive: true);
  });

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

  MacOsOpenReferences observer() => MacOsOpenReferences(
    command: (executable, arguments) async {
      observed.add(arguments.last);
      return ProcessResult(pid, 1, '', '');
    },
  );

  Future<ColdCatalogInspection> catalog() async {
    final directory = await Directory(
      '${temporary.path}/inspection-${scratch.length}',
    ).create();
    imageFileMode(directory.path, 0x1c0);
    final root = await OwnedImageDirectory.open(directory);
    scratch.add(root);
    return ColdCatalogInspection.inspect(lease, root);
  }

  Future<void> migrate({LegacyMigrationCheckpoint? stopAfter}) async {
    lease.close();
    final root = await OwnedImageDirectory.open(state);
    final ownership = (await DaemonOwnership.tryAcquire(root))!;
    final images = root.createDirectory('images');
    final bundles = root.createDirectory('vms');
    final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    try {
      final migration = LegacyVmMigration(
        database: database,
        state: root,
        images: images,
        bundles: bundles,
        ownership: ownership,
        onCheckpoint: stopAfter != null
            ? (checkpoint) {
                if (checkpoint == stopAfter) {
                  throw StateError('fixture stops at $checkpoint');
                }
              }
            : null,
      );
      if (stopAfter != null) {
        await expectLater(migration.migrate(), throwsStateError);
      } else {
        expect(await migration.migrate(), isNotNull);
      }
    } finally {
      database.close();
      bundles.close();
      images.close();
      ownership.close();
      root.close();
    }
    imageFileMode('${state.path}/gaovm.db', 0x180);
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: 'org.gaovm.tests.Legacy',
      host: _Host(),
    );
  }

  test(
    'pre-catalog inputs bind current external bytes without migration',
    () async {
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        inspection = await ColdLegacyInspection.inspect(
          lease,
          observer: observer(),
        );
        final json = inspection!.toJson();
        expect(json['format'], 'gaovm.cold-legacy-inspection.v1');
        expect(json['mode'], 'pending');
        expect(json['selected_config'], 'config.json');
        expect(json['snapshot_authorized'], isFalse);
        expect((json['files'] as List).map((file) => file['path']).toSet(), {
          kernel.path,
          disk.path,
        });
        expect(observed.toSet(), {kernel.path, disk.path});
        await inspection!.verify();
        await source.verify(before, nativeMetadata: true);
        expect(await File('${state.path}/gaovm.db').exists(), isFalse);
        expect(
          await Directory('${state.path}/legacy-v1-backup').exists(),
          false,
        );
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'completed real migration treats changed old inputs as opaque history',
    () async {
      await migrate();
      await kernel.delete();
      await disk.writeAsString('current writable disk is not its old digest');
      await File('${state.path}/config.json').writeAsString('not JSON anymore');
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        final modern = await catalog();
        inspection = await ColdLegacyInspection.inspect(
          lease,
          catalog: modern,
          observer: observer(),
        );
        final json = inspection!.toJson();
        expect(json['mode'], 'completed');
        expect(json['migration_vm_id'], startsWith('vm_'));
        expect(json['backup_digest'], startsWith('sha256:'));
        expect(json['selected_config'], isNull);
        expect(json['files'], isEmpty);
        expect(observed, isEmpty);
        await inspection!.verify();
        final references = await ColdFileReferences.inspect(
          modern,
          observer: observer(),
        );
        try {
          expect(observed.toSet(), {disk.path});
          expect(
            (references.toJson()['files'] as List).single['path'],
            disk.path,
          );
          await references.verify();
        } finally {
          references.close();
        }
        await source.verify(before, nativeMetadata: true);
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'published pending backup pins boot sources but not mutable disk history',
    () async {
      final initrd = await File(
        '${temporary.path}/initrd',
      ).writeAsString('initrd');
      imageFileMode(initrd.path, 0x180);
      final configuration = File('${state.path}/config.json');
      final config = jsonDecode(await configuration.readAsString()) as Map;
      (config['boot'] as Map)['initrdPath'] = initrd.path;
      await configuration.writeAsString(jsonEncode(config));
      await migrate(stopAfter: LegacyMigrationCheckpoint.backupPublished);
      await disk.writeAsString('new current disk bytes');
      inspection = await ColdLegacyInspection.inspect(
        lease,
        catalog: await catalog(),
        observer: observer(),
      );
      expect(inspection!.toJson()['mode'], 'pending');
      expect(inspection!.toJson()['backup_digest'], startsWith('sha256:'));
      expect(observed.toSet(), {kernel.path, initrd.path, disk.path});
      await inspection!.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'pending config alone determines external references including initrd',
    () async {
      final next = await File(
        '${temporary.path}/next-kernel',
      ).writeAsString('next');
      final initrd = await File(
        '${temporary.path}/initrd',
      ).writeAsString('initrd');
      for (final file in [next, initrd]) {
        imageFileMode(file.path, 0x180);
      }
      await File('${state.path}/pending_config.json').writeAsString(
        jsonEncode({
          'boot': {'kernelPath': next.path, 'initrdPath': initrd.path},
          'disk': {'path': disk.path},
        }),
      );
      imageFileMode('${state.path}/pending_config.json', 0x180);
      await kernel.delete();
      inspection = await ColdLegacyInspection.inspect(
        lease,
        observer: observer(),
      );
      expect(inspection!.toJson()['selected_config'], 'pending_config.json');
      expect(observed.toSet(), {next.path, initrd.path, disk.path});
      await inspection!.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unknown regular backup and staging data is bound without cleanup',
    () async {
      await migrate();
      final stage = await Directory(
        '${state.path}/.legacy-v1-backup-stage',
      ).create();
      imageFileMode(stage.path, 0x1c0);
      for (final path in [
        '${stage.path}/unknown-operator-data',
        '${state.path}/legacy-v1-backup/unknown-retained-data',
      ]) {
        await File(path).writeAsString('retain exactly these bytes');
        imageFileMode(path, 0x180);
      }
      inspection = await ColdLegacyInspection.inspect(
        lease,
        catalog: await catalog(),
        observer: observer(),
      );
      final trees = inspection!.toJson()['trees'] as Map;
      expect(
        (trees['.legacy-v1-backup-stage'] as Map).keys,
        contains('unknown-operator-data'),
      );
      expect(
        (trees['legacy-v1-backup'] as Map).keys,
        contains('unknown-retained-data'),
      );
      await inspection!.verify();
      expect(
        await File('${stage.path}/unknown-operator-data').readAsString(),
        'retain exactly these bytes',
      );
    },
    skip: !Platform.isMacOS,
  );

  for (final fault in ['content', 'manifest', 'record', 'marker', 'missing']) {
    test(
      'completed migration refuses $fault backup corruption',
      () async {
        await migrate();
        final backup = '${state.path}/legacy-v1-backup';
        switch (fault) {
          case 'content':
            await File('$backup/config.json').writeAsString('changed backup');
          case 'manifest':
            await File('$backup/manifest.json').writeAsString('{}');
          case 'record':
            final file = File('$backup/manifest.json');
            final manifest =
                jsonDecode(await file.readAsString()) as Map<String, dynamic>;
            (manifest['boot_sources']['kernel'] as Map)['path'] =
                '${temporary.path}/other';
            manifest.remove('digest');
            manifest['digest'] = contentDigest(manifest);
            await file.writeAsString(jsonEncode(manifest));
          case 'marker':
            final file = await File(
              '$backup/.gaovm-legacy-backup-owner/unexpected',
            ).writeAsString('retained');
            imageFileMode(file.path, 0x180);
          case 'missing':
            await Directory(
              backup,
            ).rename('${state.path}/retained-legacy-backup');
        }
        await expectLater(
          ColdLegacyInspection.inspect(
            lease,
            catalog: await catalog(),
            observer: observer(),
          ),
          throwsA(isA<ColdStateFailure>()),
        );
        await lease.verify();
        expect(await File('${state.path}/config.json').exists(), isTrue);
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'incomplete durable migration cannot be treated as inactive history',
    () async {
      await migrate(stopAfter: LegacyMigrationCheckpoint.catalogAccepted);
      final copy = await catalog();
      expect(copy.blockers, isNotEmpty);
      await expectLater(
        ColdLegacyInspection.inspect(
          lease,
          catalog: copy,
          observer: observer(),
        ),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(observed, isEmpty);
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'pending backup refuses changed boot bytes before inspecting writers',
    () async {
      await migrate(stopAfter: LegacyMigrationCheckpoint.backupPublished);
      await kernel.writeAsString('KERNEL');
      await expectLater(
        ColdLegacyInspection.inspect(
          lease,
          catalog: await catalog(),
          observer: observer(),
        ),
        throwsA(
          isA<ColdStateFailure>().having(
            (error) => error.reason,
            'reason',
            contains('boot source'),
          ),
        ),
      );
      expect(await kernel.readAsString(), 'KERNEL');
      expect(observed, isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  test('pending backup refuses changed original JSON', () async {
    await migrate(stopAfter: LegacyMigrationCheckpoint.backupPublished);
    final file = File('${state.path}/config.json');
    await file.writeAsString('${await file.readAsString()} ');
    await expectLater(
      ColdLegacyInspection.inspect(
        lease,
        catalog: await catalog(),
        observer: observer(),
      ),
      throwsA(
        isA<ColdStateFailure>().having(
          (error) => error.reason,
          'reason',
          contains('originals'),
        ),
      ),
    );
    expect(observed, isEmpty);
  }, skip: !Platform.isMacOS);
  for (final name in [
    'gaovm.db',
    'gaovm.db-wal',
    'gaovm.db-shm',
    'gaovm.db-journal',
  ]) {
    test('$name cannot bypass catalog inspection', () async {
      await File('${state.path}/$name').writeAsBytes([]);
      imageFileMode('${state.path}/$name', 0x180);
      await expectLater(
        ColdLegacyInspection.inspect(lease, observer: observer()),
        throwsA(
          isA<ColdStateFailure>().having(
            (error) => error.reason,
            'reason',
            contains('catalog inspection'),
          ),
        ),
      );
      expect(observed, isEmpty);
      await lease.verify();
    }, skip: !Platform.isMacOS);
  }

  test(
    'empty legacy state is absent and never creates a config or database',
    () async {
      await File('${state.path}/config.json').delete();
      inspection = await ColdLegacyInspection.inspect(
        lease,
        observer: observer(),
      );
      expect(inspection!.toJson()['mode'], 'absent');
      expect(inspection!.toJson()['files'], isEmpty);
      await inspection!.verify();
      expect(observed, isEmpty);
      expect(await File('${state.path}/gaovm.db').exists(), isFalse);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'old desired state and PID values are byte evidence, not cold authority',
    () async {
      for (final name in ['desired_state.json', 'daemon_state.json']) {
        await File(
          '${state.path}/$name',
        ).writeAsString('{"desired":"running","driverPid":1}');
        imageFileMode('${state.path}/$name', 0x180);
      }
      inspection = await ColdLegacyInspection.inspect(
        lease,
        observer: observer(),
      );
      expect(inspection!.toJson()['mode'], 'pending');
      expect(
        (inspection!.toJson()['inputs'] as Map).keys,
        containsAll(['desired_state.json', 'daemon_state.json']),
      );
      expect(observed.toSet(), {kernel.path, disk.path});
      await inspection!.verify();
    },
    skip: !Platform.isMacOS,
  );

  for (final mutation in ['config', 'disk', 'kernel', 'stage', 'database']) {
    test(
      'later $mutation change invalidates evidence without releasing caller ownership',
      () async {
        inspection = await ColdLegacyInspection.inspect(
          lease,
          observer: observer(),
        );
        switch (mutation) {
          case 'config':
            await File('${state.path}/config.json').writeAsString('{}');
          case 'disk':
            await disk.writeAsString('changed disk bytes');
          case 'kernel':
            await kernel.writeAsString('KERNEL');
          case 'stage':
            await Directory('${state.path}/.legacy-v1-backup-stage').create();
            imageFileMode('${state.path}/.legacy-v1-backup-stage', 0x1c0);
          case 'database':
            await File('${state.path}/gaovm.db').writeAsBytes([]);
            imageFileMode('${state.path}/gaovm.db', 0x180);
        }
        await expectLater(
          inspection!.verify(),
          throwsA(isA<ColdStateFailure>()),
        );
        final root = await OwnedImageDirectory.open(state);
        try {
          expect(await DaemonOwnership.tryAcquire(root), isNull);
        } finally {
          root.close();
        }
        await lease.verify();
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'mutation during native observation is not sealed as the initial input',
    () async {
      final changing = MacOsOpenReferences(
        command: (_, _) async {
          await File('${state.path}/config.json').writeAsString('{}');
          return ProcessResult(0x7ffffffe, 1, '', '');
        },
      );
      await expectLater(
        ColdLegacyInspection.inspect(lease, observer: changing),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(await File('${state.path}/config.json').readAsString(), '{}');
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'native evidence failure is not an empty reference set',
    () async {
      final unavailable = MacOsOpenReferences(
        command: (_, _) async =>
            ProcessResult(0x7ffffffe, 1, '', 'partial native observation'),
      );
      await expectLater(
        ColdLegacyInspection.inspect(lease, observer: unavailable),
        throwsFormatException,
      );
      await lease.verify();
      expect(await kernel.readAsString(), 'kernel');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'actual native file holder refuses until its owned exit is confirmed',
    () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/test/fixtures/hold_maintenance_file.dart',
        disk.path,
      ]);
      final ready = Completer<void>();
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map((line) {
            if (line == 'held' && !ready.isCompleted) ready.complete();
            return line;
          })
          .join('\n');
      final child = OwnedTestProcess(process, stdoutCapture: output);
      children.add(child);
      await ready.future.timeout(const Duration(seconds: 10));
      final native = MacOsOpenReferences(command: command);
      await expectLater(
        ColdLegacyInspection.inspect(lease, observer: native),
        throwsA(
          isA<ColdStateFailure>().having(
            (error) => error.reason,
            'reason',
            contains('other process'),
          ),
        ),
      );
      await process.stdin.close();
      expect((await child.result()).exitCode, 0);
      expect(child.exitConfirmed, isTrue);
      inspection = await ColdLegacyInspection.inspect(lease, observer: native);
      await inspection!.verify();
      expect(await disk.readAsString(), 'mutable disk');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'exported JSON changes neither held evidence nor inspection authority',
    () async {
      inspection = await ColdLegacyInspection.inspect(
        lease,
        observer: observer(),
      );
      final json = inspection!.toJson();
      expect(() => (json['inputs'] as Map).clear(), throwsUnsupportedError);
      json['inputs'] = <String, Object?>{};
      (json['files'] as List).clear();
      json['snapshot_authorized'] = true;
      await inspection!.verify();
      expect(inspection!.toJson()['snapshot_authorized'], isFalse);
      expect(inspection!.toJson()['files'], hasLength(2));
    },
    skip: !Platform.isMacOS,
  );

  test(
    'closed lease fails before untrusted legacy JSON or native file reads',
    () async {
      lease.close();
      await File('${state.path}/config.json').writeAsString('malformed');
      await expectLater(
        ColdLegacyInspection.inspect(lease, observer: observer()),
        throwsStateError,
      );
      expect(observed, isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  test('closing readers leaves original caller lease held', () async {
    inspection = await ColdLegacyInspection.inspect(
      lease,
      observer: observer(),
    );
    inspection!.close();
    inspection!.close();
    await expectLater(inspection!.verify(), throwsStateError);
    expect(inspection!.toJson, throwsStateError);
    await lease.verify();
  }, skip: !Platform.isMacOS);

  test(
    'a fresh lease cannot reuse catalog facts from a closed original lease',
    () async {
      await migrate();
      final original = await catalog();
      lease.close();
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Legacy',
        host: _Host(),
      );
      await expectLater(
        ColdLegacyInspection.inspect(
          lease,
          catalog: original,
          observer: observer(),
        ),
        throwsA(
          isA<ColdStateFailure>().having(
            (error) => error.reason,
            'reason',
            contains('original catalog lease'),
          ),
        ),
      );
      await lease.verify();
      expect(observed, isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  for (final fault in ['empty', 'symlink', 'hardlink', 'writable', 'acl']) {
    test(
      'unsafe $fault legacy dependency is retained and refused',
      () async {
        switch (fault) {
          case 'empty':
            await disk.writeAsBytes([]);
          case 'symlink':
            final retained = await disk.rename(
              '${temporary.path}/retained-disk',
            );
            await Link(disk.path).create(retained.path);
          case 'hardlink':
            expect(
              (await command('/bin/ln', [
                disk.path,
                '${temporary.path}/retained-disk',
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
          ColdLegacyInspection.inspect(lease, observer: observer()),
          throwsA(anyOf(isA<ColdStateFailure>(), isA<FileSystemException>())),
        );
        expect(await kernel.readAsString(), 'kernel');
        expect(observed, isEmpty);
        await lease.verify();
      },
      skip: !Platform.isMacOS,
    );
  }

  test('unknown staging symlink is not followed or removed', () async {
    final stage = await Directory(
      '${state.path}/.legacy-v1-backup-stage',
    ).create();
    imageFileMode(stage.path, 0x1c0);
    final link = await Link('${stage.path}/unknown').create(disk.path);
    await expectLater(
      ColdLegacyInspection.inspect(lease, observer: observer()),
      throwsFormatException,
    );
    expect(await link.target(), disk.path);
    expect(await disk.readAsString(), 'mutable disk');
  }, skip: !Platform.isMacOS);

  for (final json in ['[]', 'x' * (1024 * 1024 + 1)]) {
    test(
      'nonobject or oversized selected JSON cannot hide dependencies (${json.length})',
      () async {
        await File('${state.path}/config.json').writeAsString(json);
        await expectLater(
          ColdLegacyInspection.inspect(lease, observer: observer()),
          throwsA(anyOf(isA<ColdStateFailure>(), isA<FormatException>())),
        );
        expect(observed, isEmpty);
        expect(await File('${state.path}/config.json').length(), json.length);
      },
      skip: !Platform.isMacOS,
    );
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
      'bundle_identifier': 'org.gaovm.tests.Legacy',
      'plist_name': 'gaovmd.plist',
      'authorization_state': 'notRegistered',
      'native_status': 0,
      'outcome': 'observed',
      'error_code': null,
    }),
    '',
  );
}
