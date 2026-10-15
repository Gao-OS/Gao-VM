import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/cold_catalog_inspection.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/macos_open_references.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory state;
  late Image image;
  late ColdStateLease lease;
  late OwnedImageDirectory scratch;
  late ColdCatalogInspection catalog;
  var retainInputs = false;

  Future<ProcessResult> command(String executable, List<String> args) async {
    try {
      return await runMaintenanceCommand(executable, args);
    } on MaintenanceCommandFailure catch (error) {
      if (!error.exitConfirmed) retainInputs = true;
      rethrow;
    }
  }

  Future<void> refreshCatalog() async {
    final output = await temporary.createTemp('inspection-');
    imageFileMode(output.path, 0x1c0);
    scratch.close();
    scratch = await OwnedImageDirectory.open(output);
    catalog = await ColdCatalogInspection.inspect(lease, scratch);
  }

  Future<VmId> provision({VmSpec? spec}) async {
    final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    final root = await Directory('${state.path}/vms').create();
    imageFileMode(root.path, 0x1c0);
    final bundles = await OwnedImageDirectory.open(root);
    final images = await OwnedImageDirectory.open(
      Directory('${state.path}/images'),
    );
    try {
      final accepted =
          await SqliteVmCreateAcceptance(
            database: database,
            idempotencyRetention: const Duration(days: 30),
          ).create(
            VmCreateCommand(
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
              name: 'guest-mutated-disk',
              spec:
                  spec ??
                  VmSpec(
                    cpu: 1,
                    memoryBytes: 268435456,
                    boot: EfiBoot(),
                    disks: [
                      VmDisk(
                        id: 'root',
                        source: ManagedImageDiskSource(image.id),
                        writable: true,
                      ),
                    ],
                    networks: [DisconnectedNetwork(id: 'net0')],
                    graphics: GraphicsConfig(enabled: false),
                    serial: const SerialConfig(enabled: true, capture: true),
                    guestAgent: GuestAgentConfig(
                      enabled: false,
                      requiredForReady: false,
                    ),
                    restartPolicy: RestartPolicy.never,
                  ),
            ),
          );
      final result = (await VmProvisioningWorker(
        work: SqliteVmProvisioningWorkRepository(database),
        bundles: VmBundleStore(
          database: database,
          bundles: bundles,
          images: images,
        ),
        owner: 'cold-assets-fixture',
      ).dispatchOnce()).single;
      expect(result.completion, VmProvisioningCompletionKind.succeeded);
      return accepted.resourceId as VmId;
    } finally {
      images.close();
      bundles.close();
      database.close();
    }
  }

  ColdManagedAssets? heldAssets;
  Future<ColdManagedAssets> inspect() async =>
      heldAssets = await ColdManagedAssets.inspect(
        catalog,
        observer: MacOsOpenReferences(
          command: (_, _) async => ProcessResult(pid, 1, '', ''),
        ),
      );

  Future<void> editCatalog(void Function(Database) change) async {
    final database = sqlite3.open('${state.path}/gaovm.db');
    try {
      change(database);
    } finally {
      database.dispose();
    }
  }

  setUp(() async {
    retainInputs = false;
    heldAssets = null;
    temporary = Directory(
      await (await Directory.systemTemp.createTemp(
        'gvm-cold-assets-',
      )).resolveSymbolicLinks(),
    );
    imageFileMode(temporary.path, 0x1c0);
    state = await Directory('${temporary.path}/state').create();
    imageFileMode(state.path, 0x1c0);
    final source = await File(
      '${temporary.path}/seed.raw',
    ).writeAsString('immutable image bytes');
    final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    try {
      image = await ImageStore(
        database,
        Directory('${state.path}/images'),
      ).importFile(source, type: ImageType.rawDisk);
    } finally {
      database.close();
    }
    imageFileMode('${state.path}/gaovm.db', 0x180);
    final output = await Directory('${temporary.path}/inspection').create();
    imageFileMode(output.path, 0x1c0);
    scratch = await OwnedImageDirectory.open(output);
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: 'org.gaovm.tests.Managed',
      host: _Host(),
    );
    catalog = await ColdCatalogInspection.inspect(lease, scratch);
  });
  tearDown(() async {
    heldAssets?.close();
    lease.close();
    scratch.close();
    if (retainInputs)
      throw StateError(
        'retaining inputs for unconfirmed observer: ${temporary.path}',
      );
    await temporary.delete(recursive: true);
  });

  test(
    'managed image inspection binds catalog, manifest and actual immutable bytes without source writes',
    () async {
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        final assets = await ColdManagedAssets.inspect(
          catalog,
          observer: MacOsOpenReferences(command: command),
        );
        try {
          final json = assets.toJson();
          expect(json['format'], 'gaovm.cold-managed-assets.v1');
          expect(json['images'], [
            {'image_id': image.id.value, 'digest': image.digest},
          ]);
          expect(json['vms'], isEmpty);
          final files = json['files'] as List;
          final root =
              '${state.path}/images/sha256-${image.digest.substring(7)}';
          expect(files.map((entry) => entry['path']).toSet(), {
            '$root/manifest.json',
            '$root/objects/payload',
          });
          expect(files.every((entry) => entry['backed_up'] == false), isTrue);
          await assets.verify();
          await source.verify(before, nativeMetadata: true);
        } finally {
          assets.close();
        }
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'completed bundle retains guest-mutated disk and EFI bytes instead of comparing image seed digests',
    () async {
      final id = await provision();
      final bundle = '${state.path}/vms/${id.value}.gaovm';
      final disk = File('$bundle/disks/root.raw');
      await disk.writeAsString('guest filesystem after several runs');
      final efi = await File(
        '$bundle/nvram/efi-variable-store',
      ).writeAsString('guest EFI variables');
      imageFileMode(efi.path, 0x180);
      await refreshCatalog();
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        final assets = await inspect();
        final json = assets.toJson();
        expect((json['vms'] as List).single['vm_id'], id.value);
        final files = json['files'] as List;
        expect(
          files.map((entry) => entry['path']),
          containsAll([disk.path, efi.path, '$bundle/manifest.json']),
        );
        expect(
          await disk.readAsString(),
          'guest filesystem after several runs',
        );
        expect(await efi.readAsString(), 'guest EFI variables');
        await assets.verify();
        await source.verify(before, nativeMetadata: true);
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unstarted VM permits absent managed EFI but revalidation refuses a newly appeared store',
    () async {
      final id = await provision();
      final efi = File(
        '${state.path}/vms/${id.value}.gaovm/nvram/efi-variable-store',
      );
      expect(await efi.exists(), isFalse);
      await refreshCatalog();
      final assets = await inspect();
      expect(assets.toJson()['absent_files'], [efi.path]);
      expect(
        await efi.exists(),
        isFalse,
        reason: 'inspection must not initialize a variable store',
      );
      await efi.writeAsString('unexpected new store');
      imageFileMode(efi.path, 0x180);
      await expectLater(assets.verify(), throwsA(isA<ColdStateFailure>()));
      expect(await efi.readAsString(), 'unexpected new store');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unsafe empty bundle directories are refused without permission normalization',
    () async {
      final id = await provision();
      final logs = '${state.path}/vms/${id.value}.gaovm/logs';
      imageFileMode(logs, 0x1ff);
      await refreshCatalog();
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect((await Directory(logs).stat()).mode & 0xfff, 0x1ff);
    },
    skip: !Platform.isMacOS,
  );

  for (final fault in [
    'missing',
    'empty',
    'symlink',
    'hardlink',
    'writable',
    'origin',
  ]) {
    test(
      '$fault managed bundle evidence refuses progress and preserves remaining bytes',
      () async {
        final id = await provision();
        final root = '${state.path}/vms/${id.value}.gaovm';
        final disk = File('$root/disks/root.raw');
        final retained = File('${temporary.path}/retained.raw');
        switch (fault) {
          case 'missing':
            await disk.rename(retained.path);
          case 'empty':
            await disk.writeAsBytes([]);
          case 'symlink':
            await disk.rename(retained.path);
            await Link(disk.path).create(retained.path);
          case 'hardlink':
            expect(
              (await command('/bin/ln', [disk.path, retained.path])).exitCode,
              0,
            );
          case 'writable':
            imageFileMode(disk.path, 0x1b6);
          case 'origin':
            final file = File('$root/manifest.json');
            final json =
                jsonDecode(await file.readAsString()) as Map<String, dynamic>;
            (json['plan'] as Map)['operation_id'] =
                OperationId.generate().value;
            await file.writeAsString(
              jsonEncode(
                VmBundleManifest.create(
                  VmProvisioningPlan.fromJson(json['plan']),
                ).toJson(),
              ),
            );
        }
        await refreshCatalog();
        await expectLater(
          inspect(),
          throwsA(anyOf(isA<ColdStateFailure>(), isA<FileSystemException>())),
        );
        if (['missing', 'symlink', 'hardlink'].contains(fault)) {
          expect(await retained.readAsString(), 'immutable image bytes');
        } else {
          expect(await disk.exists(), isTrue);
          if (fault != 'empty')
            expect(await disk.readAsString(), 'immutable image bytes');
        }
        if (fault == 'writable')
          expect((await disk.stat()).mode & 0xfff, 0x1b6);
        final rootHandle = await OwnedImageDirectory.open(state);
        try {
          expect(await DaemonOwnership.tryAcquire(rootHandle), isNull);
        } finally {
          rootHandle.close();
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  test(
    'immutable image corruption is not mistaken for a legitimate writable-disk change',
    () async {
      final object = File(
        '${state.path}/images/sha256-${image.digest.substring(7)}/objects/payload',
      );
      imageFileMode(object.path, 0x180);
      await object.writeAsString('corrupt immutable bytes');
      imageFileMode(object.path, 0x100);
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(await object.readAsString(), 'corrupt immutable bytes');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'already-used VM cannot silently replace missing EFI with a fresh empty store',
    () async {
      final id = await provision();
      await editCatalog(
        (db) => db.execute(
          "UPDATE vm_runtime SET driver_generation = 1, observed_generation = 1 WHERE vm_id = ?",
          [id.value],
        ),
      );
      await refreshCatalog();
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(
        await File(
          '${state.path}/vms/${id.value}.gaovm/nvram/efi-variable-store',
        ).exists(),
        isFalse,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'returned nested JSON cannot alter held tree or file verification',
    () async {
      final assets = await inspect();
      final json = assets.toJson();
      expect(() => (json['trees'] as Map).clear(), throwsUnsupportedError);
      (json['files'] as List).clear();
      expect((assets.toJson()['trees'] as Map), isNotEmpty);
      expect((assets.toJson()['files'] as List).length, 2);
      await assets.verify();
      final object = File(
        '${state.path}/images/sha256-${image.digest.substring(7)}/objects/payload',
      );
      imageFileMode(object.path, 0x180);
      await object.writeAsString('changed after inspection');
      await expectLater(assets.verify(), throwsA(isA<FormatException>()));
    },
    skip: !Platform.isMacOS,
  );

  test(
    'new EFI appearing during the first file observation prevents inspection from returning',
    () async {
      final id = await provision();
      final efi = File(
        '${state.path}/vms/${id.value}.gaovm/nvram/efi-variable-store',
      );
      await refreshCatalog();
      var appeared = false;
      await expectLater(
        ColdManagedAssets.inspect(
          catalog,
          observer: MacOsOpenReferences(
            command: (_, _) async {
              if (!appeared) {
                appeared = true;
                await efi.writeAsString('writer raced inspection');
                imageFileMode(efi.path, 0x180);
              }
              return ProcessResult(pid, 1, '', '');
            },
          ),
        ),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(appeared, isTrue);
      expect(await efi.readAsString(), 'writer raced inspection');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'current, observed and execution generations retain distinct consumer bindings for the same current disk',
    () async {
      final id = await provision();
      final efi = await File(
        '${state.path}/vms/${id.value}.gaovm/nvram/efi-variable-store',
      ).writeAsString('retained EFI');
      imageFileMode(efi.path, 0x180);
      final db = await GaoVmDatabase.open('${state.path}/gaovm.db');
      try {
        final repo = SqliteVmRepository(db);
        for (final cpu in [2, 3]) {
          final current = (await repo.get(id))!;
          await repo.updateSpec(
            id,
            expectedRevision: current.metadata.revision,
            spec: VmSpec.fromJson({...current.spec.toJson(), 'cpu': cpu}),
          );
        }
      } finally {
        db.close();
      }
      await editCatalog(
        (db) => db.execute(
          "UPDATE vm_runtime SET observed_generation = 1, driver_generation = 2, execution_desired_state = 'stopped', execution_spec_generation = 2 WHERE vm_id = ?",
          [id.value],
        ),
      );
      await refreshCatalog();
      final assets = await inspect();
      expect((assets.toJson()['vms'] as List).single['spec_generations'], [
        1,
        2,
        3,
      ]);
      final disk = (assets.toJson()['files'] as List).singleWhere(
        (file) => (file['path'] as String).endsWith('/disks/root.raw'),
      );
      expect(
        (disk['bindings'] as List)
            .map((binding) => binding['spec_generation'])
            .toSet(),
        {1, 2, 3},
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'failed retained TestRun VM keeps writable data and terminal history unchanged',
    () async {
      final id = await provision();
      final root = '${state.path}/vms/${id.value}.gaovm';
      final efi = await File(
        '$root/nvram/efi-variable-store',
      ).writeAsString('failed VM EFI');
      imageFileMode(efi.path, 0x180);
      await File(
        '$root/disks/root.raw',
      ).writeAsString('failed VM debugging filesystem');
      final db = await GaoVmDatabase.open('${state.path}/gaovm.db');
      late TestRunId runId;
      try {
        final repo = SqliteTestRunRepository(db);
        final run = await repo.create(
          spec: TestRunSpec(
            source: TemplateVmTestRunSource(id),
            wait: VmWaitSpec(
              condition: WaitCondition.guestAgentReady,
              timeoutSeconds: 1,
            ),
            steps: [
              TestStepRequest(argv: ['false'], timeoutSeconds: 1),
            ],
            cleanup: CleanupPolicy.retain,
            retainOnFailure: true,
          ),
          requestId: RequestId.generate(),
        );
        runId = run.id;
        await repo.transition(
          runId,
          expectedState: TestRunState.pending,
          nextState: TestRunState.provisioning,
        );
        await repo.transition(
          runId,
          expectedState: TestRunState.provisioning,
          nextState: TestRunState.collecting,
          vmId: id,
          outcome: TestRunState.failed,
          error: OperationError(
            code: ErrorCode.internalError,
            message: 'retained failure fixture',
            retryable: false,
            details: JsonObjectValue.empty,
          ),
        );
        await repo.transition(
          runId,
          expectedState: TestRunState.collecting,
          nextState: TestRunState.cleaningUp,
          cleanupDecision: 'retain',
        );
        await repo.finish(runId, outcome: TestRunState.failed);
      } finally {
        db.close();
      }
      await editCatalog(
        (db) => db.execute(
          "UPDATE vm_runtime SET phase = 'failed', observed_generation = 1, driver_generation = 1 WHERE vm_id = ?",
          [id.value],
        ),
      );
      await refreshCatalog();
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        final assets = await inspect();
        expect((assets.toJson()['vms'] as List).single['vm_id'], id.value);
        expect(
          await File('$root/disks/root.raw').readAsString(),
          'failed VM debugging filesystem',
        );
        await assets.verify();
        await source.verify(before, nativeMetadata: true);
        final reader = sqlite3.open(
          '${scratch.path}/gaovm.db',
          mode: OpenMode.readOnly,
        );
        try {
          expect(
            reader.select('SELECT state FROM test_runs WHERE id = ?', [
              runId.value,
            ]).single['state'],
            'failed',
          );
          expect(
            reader.select('SELECT deleted_at FROM vms WHERE id = ?', [
              id.value,
            ]).single['deleted_at'],
            isNull,
          );
        } finally {
          reader.dispose();
        }
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a contradictory failed provisioning proof cannot hide a live definition and its published bundle',
    () async {
      final id = await provision();
      await editCatalog((db) {
        db.execute('DROP TRIGGER vm_provisioning_immutable_completion');
        db.execute(
          "UPDATE vm_provisioning SET completion_kind = 'failed', manifest_digest = NULL WHERE vm_id = ?",
          [id.value],
        );
        db.execute(
          "UPDATE operations SET state = 'failed' WHERE id = (SELECT operation_id FROM vm_provisioning WHERE vm_id = ?)",
          [id.value],
        );
        db.execute("UPDATE vm_runtime SET phase = 'failed' WHERE vm_id = ?", [
          id.value,
        ]);
      });
      await refreshCatalog();
      catalog.requireQuiescent();
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(
        await File(
          '${state.path}/vms/${id.value}.gaovm/disks/root.raw',
        ).readAsString(),
        'immutable image bytes',
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'successful-looking bundle cannot substitute an unrelated create Operation identity',
    () async {
      final id = await provision();
      await editCatalog(
        (db) => db.execute(
          'UPDATE operations SET resource_id = ? WHERE id = (SELECT operation_id FROM vm_provisioning WHERE vm_id = ?)',
          [VmId.generate().value, id.value],
        ),
      );
      await refreshCatalog();
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
      expect(
        await File(
          '${state.path}/vms/${id.value}.gaovm/manifest.json',
        ).exists(),
        isTrue,
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'catalog image metadata mismatch refuses the private copy without repairing the original',
    () async {
      await editCatalog(
        (db) => db.execute(
          "UPDATE images SET version = 'not-in-manifest' WHERE id = ?",
          [image.id.value],
        ),
      );
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        await expectLater(refreshCatalog(), throwsA(isA<ColdStateFailure>()));
        await source.verify(before, nativeMetadata: true);
        expect(await File('${scratch.path}/gaovm.db').exists(), isTrue);
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unknown regular staging and orphan data remain in bound trees instead of being cleaned as upgrade garbage',
    () async {
      final stage = await Directory(
        '${state.path}/images/.unknown-stage/retained',
      ).create(recursive: true);
      imageFileMode(stage.parent.path, 0x1c0);
      imageFileMode(stage.path, 0x1c0);
      final bytes = await File(
        '${stage.path}/unrecognized.bin',
      ).writeAsString('keep interrupted output');
      imageFileMode(bytes.path, 0x180);
      final assets = await inspect();
      final tree =
          (assets.toJson()['trees'] as Map)['${state.path}/images'] as Map;
      expect(tree['.unknown-stage/retained/unrecognized.bin'], isNotNull);
      expect(await bytes.readAsString(), 'keep interrupted output');
      await bytes.writeAsString('later external writer');
      await expectLater(assets.verify(), throwsA(isA<FormatException>()));
      expect(await bytes.readAsString(), 'later external writer');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'GaoOS role pins resolve distinct immutable objects while the VM root disk stays mutable',
    () async {
      final source = await Directory(
        '${temporary.path}/gaoos/objects',
      ).create(recursive: true);
      final objects = <String, Map<String, Object?>>{};
      for (final role in ['kernel', 'initrd', 'root']) {
        final file = await File(
          '${source.path}/$role',
        ).writeAsString('$role bytes');
        // Use the real imported object's content digest, not the manifest digest.
        final bytes = await file.readAsBytes();
        objects[role] = {
          'size_bytes': bytes.length,
          'digest': 'sha256:${sha256.convert(bytes)}',
        };
      }
      final manifest = ImageManifest.create(
        type: ImageType.gaoosBundle,
        objects: objects,
        guestProfile: 'gaoos',
        version: 'v1',
        buildId: 'build-1',
        channel: 'stable',
        gaoos: {
          'kernel': 'kernel',
          'initrd': 'initrd',
          'root_disk': 'root',
          'default_command_line': 'console=hvc0',
          'guest_agent_expected': true,
        },
      );
      await File(
        '${source.parent.path}/manifest.json',
      ).writeAsString(jsonEncode(manifest.toJson()));
      final db = await GaoVmDatabase.open('${state.path}/gaovm.db');
      try {
        image = await ImageStore(
          db,
          Directory('${state.path}/images'),
        ).importBundle(source.parent);
      } finally {
        db.close();
      }
      final id = await provision(
        spec: VmSpec(
          cpu: 1,
          memoryBytes: 268435456,
          boot: LinuxKernelBoot(
            kernelImageId: image.id,
            initrdImageId: image.id,
          ),
          disks: [
            VmDisk(
              id: 'root',
              source: ManagedImageDiskSource(image.id),
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
      final disk = File('${state.path}/vms/${id.value}.gaovm/disks/root.raw');
      await disk.writeAsString('mutated GaoOS guest filesystem');
      await refreshCatalog();
      final assets = await inspect();
      final paths = (assets.toJson()['files'] as List).map(
        (file) => file['path'],
      );
      final root =
          '${state.path}/images/sha256-${image.digest.substring(7)}/objects';
      expect(
        paths,
        containsAll(['$root/kernel', '$root/initrd', '$root/root', disk.path]),
      );
      expect(await disk.readAsString(), 'mutated GaoOS guest filesystem');
      expect(assets.toJson()['absent_files'], isEmpty);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'create request generation must remain an integer, not an equal floating-point JSON number',
    () async {
      final id = await provision();
      await editCatalog(
        (db) => db.execute(
          'UPDATE operations SET request_json = ? WHERE id = (SELECT operation_id FROM vm_provisioning WHERE vm_id = ?)',
          ['{"spec_generation":1.0}', id.value],
        ),
      );
      await refreshCatalog();
      await expectLater(inspect(), throwsA(isA<ColdStateFailure>()));
    },
    skip: !Platform.isMacOS,
  );

  test(
    'closing asset readers invalidates reuse without releasing the caller cold lease',
    () async {
      final assets = await inspect();
      assets.close();
      assets.close();
      expect(assets.toJson, throwsStateError);
      await expectLater(assets.verify(), throwsStateError);
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
    'revalidation requires the original held cold lease before reading potentially live managed trees',
    () async {
      final assets = await inspect();
      lease.close();
      final object = File(
        '${state.path}/images/sha256-${image.digest.substring(7)}/objects/payload',
      );
      imageFileMode(object.path, 0x180);
      await object.writeAsString('possibly live data after lease release');
      await expectLater(assets.verify(), throwsStateError);
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
      'bundle_identifier': 'org.gaovm.tests.Managed',
      'plist_name': 'gaovmd.plist',
      'authorization_state': 'notRegistered',
      'native_status': 0,
      'outcome': 'observed',
      'error_code': null,
    }),
    '',
  );
}
