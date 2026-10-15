import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/cold_catalog_inspection.dart';
import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_open_references.dart';
import 'package:gaovmd/src/maintenance_command.dart';
import 'package:gaovmd/src/maintenance_tree.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late Directory state;
  late OwnedImageDirectory scratch;
  late OwnedImageDirectory backups;
  late ColdStateLease lease;
  late Image image;
  late _Host host;
  ColdStateSnapshot? snapshot;
  var retainInputs = false;

  setUp(() async {
    temporary = Directory(
      await (await Directory(
        '/private/tmp',
      ).createTemp('gvm-cs-')).resolveSymbolicLinks(),
    );
    imageFileMode(temporary.path, 0x1c0);
    state = await Directory('${temporary.path}/state').create();
    imageFileMode(state.path, 0x1c0);
    final seed = await File(
      '${temporary.path}/seed.raw',
    ).writeAsString('immutable image bytes');
    final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    try {
      image = await ImageStore(
        database,
        Directory('${state.path}/images'),
      ).importFile(seed, type: ImageType.rawDisk);
    } finally {
      database.close();
    }
    imageFileMode('${state.path}/gaovm.db', 0x180);
    final unknown = await Directory('${state.path}/unknown-staging').create();
    imageFileMode(unknown.path, 0x1c0);
    await File('${unknown.path}/keep').writeAsString('retain unknown data');
    imageFileMode('${unknown.path}/keep', 0x180);
    final inspection = await Directory('${temporary.path}/inspection').create();
    imageFileMode(inspection.path, 0x1c0);
    scratch = await OwnedImageDirectory.open(inspection);
    final output = await Directory('${temporary.path}/backups').create();
    imageFileMode(output.path, 0x1c0);
    backups = await OwnedImageDirectory.open(output);
    final app = await Directory('${temporary.path}/GaoVM.app').create();
    imageFileMode(app.path, 0x1c0);
    host = _Host(app.path);
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: 'org.gaovm.tests.Snapshot',
      host: host,
    );
    snapshot = null;
    retainInputs = false;
  });
  tearDown(() async {
    snapshot?.close();
    lease.close();
    backups.close();
    scratch.close();
    if (retainInputs)
      throw StateError(
        'retained unconfirmed native fixture at ${temporary.path}',
      );
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

  Future<void> socket() async {
    final run = await Directory('${state.path}/run').create();
    imageFileMode(run.path, 0x1c0);
    final path = '${run.path}/api.sock';
    final server = await ServerSocket.bind(
      InternetAddress('$path.tmp', type: InternetAddressType.unix),
      0,
    );
    try {
      expect((await command('/bin/ln', ['$path.tmp', path])).exitCode, 0);
    } finally {
      await server.close();
    }
    imageFileMode(path, 0x180);
  }

  Future<ColdStateSnapshot> prepare({
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) async => snapshot = await ColdStateSnapshot.prepare(
    lease,
    scratch,
    observer:
        observer ??
        MacOsOpenReferences(
          command: (_, _) async => ProcessResult(pid, 1, '', ''),
        ),
    inventory:
        inventory ??
        (_) async =>
            DriverInventorySnapshot(processes: [], unresolvedProcessIds: []),
  );

  Future<VmId> provision({VmSpec? spec}) async {
    final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
    final directory = await Directory('${state.path}/vms').create();
    imageFileMode(directory.path, 0x1c0);
    final bundles = await OwnedImageDirectory.open(directory);
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
              name: 'snapshot-retained-vm',
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
        owner: 'snapshot-fixture',
      ).dispatchOnce()).single;
      expect(result.completion, VmProvisioningCompletionKind.succeeded);
      return accepted.resourceId as VmId;
    } finally {
      images.close();
      bundles.close();
      database.close();
    }
  }

  test(
    'snapshot preserves the entire persistent tree without source writes',
    () async {
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        final prepared = await prepare();
        final receipt = await prepared.snapshotTo(backups, 'before');
        final payload = await MaintenanceTree.open(
          Directory('${backups.path}/before/payload'),
        );
        try {
          await payload.verify(before, nativeMetadata: true);
        } finally {
          payload.close();
        }
        expect(receipt['manifest'], before);
        expect(
          await File(
            '${backups.path}/before/payload/unknown-staging/keep',
          ).readAsString(),
          'retain unknown data',
        );
        expect(
          await File(
            '${backups.path}/before/payload/images/sha256-${image.digest.substring(7)}/objects/payload',
          ).readAsString(),
          'immutable image bytes',
        );
        await source.verify(before, nativeMetadata: true);
        await lease.verify();
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'only the composed boundary omits root runtime and durably records why',
    () async {
      await socket();
      final nested = await Directory(
        '${state.path}/logs/run',
      ).create(recursive: true);
      imageFileMode('${state.path}/logs', 0x1c0);
      imageFileMode(nested.path, 0x1c0);
      await File('${nested.path}/keep').writeAsString('not root runtime');
      imageFileMode('${nested.path}/keep', 0x180);
      final source = await MaintenanceTree.open(state);
      try {
        await expectLater(
          source.capture(nativeMetadata: true),
          throwsFormatException,
        );
      } finally {
        source.close();
      }
      final prepared = await prepare();
      final receipt = await prepared.snapshotTo(backups, 'before');
      expect(receipt['format'], 'gaovm.cold-state-snapshot.v1');
      expect(receipt['omitted_paths'], ['run']);
      final boundary = receipt['boundary'] as Map;
      expect(boundary['source_state'], state.path);
      expect(boundary['paired_app_snapshot'], isFalse);
      expect(boundary['candidate_publication_authorized'], isFalse);
      expect(
        ((boundary['runtime'] as Map)['entries'] as Map).keys,
        contains('api.sock'),
      );
      expect(
        (receipt['manifest'] as Map).keys.any(
          (path) => path == 'run' || path.startsWith('run/'),
        ),
        isFalse,
      );
      final saved = jsonDecode(
        await File('${backups.path}/before/receipt.json').readAsString(),
      );
      expect(saved, receipt);
      expect(
        await File(
          '${backups.path}/before/payload/logs/run/keep',
        ).readAsString(),
        'not root runtime',
      );
      expect(
        await Directory('${backups.path}/before/payload/run').exists(),
        isFalse,
      );
      expect(
        await FileSystemEntity.type(
          '${state.path}/run/api.sock',
          followLinks: false,
        ),
        FileSystemEntityType.unixDomainSock,
      );
      await prepared.verify();
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );
  test(
    'pre-catalog legacy state snapshots before any candidate migration',
    () async {
      lease.close();
      final retained = await state.rename(
        '${temporary.path}/retained-modern-state',
      );
      state = await Directory('${temporary.path}/state').create();
      imageFileMode(state.path, 0x1c0);
      final kernel = await File(
        '${temporary.path}/legacy-kernel',
      ).writeAsString('legacy boot bytes');
      imageFileMode(kernel.path, 0x180);
      await File('${state.path}/config.json').writeAsString(
        jsonEncode({
          'boot': {'kernelPath': kernel.path},
          'disk': {'path': '${temporary.path}/seed.raw'},
        }),
      );
      imageFileMode('${state.path}/config.json', 0x180);
      imageFileMode('${temporary.path}/seed.raw', 0x180);
      lease = await ColdStateLease.acquire(
        state,
        bundleIdentifier: 'org.gaovm.tests.Snapshot',
        host: host,
      );
      final prepared = await prepare();
      final receipt = await prepared.snapshotTo(backups, 'legacy');
      final boundary = receipt['boundary'] as Map;
      expect(boundary['catalog'], isNull);
      expect((boundary['legacy'] as Map)['mode'], 'pending');
      expect((boundary['legacy'] as Map)['files'], hasLength(2));
      expect(await File('${state.path}/gaovm.db').exists(), isFalse);
      expect(await File('${retained.path}/gaovm.db').exists(), isTrue);
      expect(
        await File('${backups.path}/legacy/payload/config.json').readAsString(),
        await File('${state.path}/config.json').readAsString(),
      );
      expect(await Directory('${state.path}/legacy-v1-backup').exists(), false);
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );
  test(
    'failed retained TestRun snapshots current disk, EFI and terminal history',
    () async {
      final vm = await provision();
      final bundle = '${state.path}/vms/${vm.value}.gaovm';
      await File(
        '$bundle/disks/root.raw',
      ).writeAsString('guest debugging filesystem');
      await File(
        '$bundle/nvram/efi-variable-store',
      ).writeAsString('guest NVRAM');
      imageFileMode('$bundle/nvram/efi-variable-store', 0x180);
      await File(
        '$bundle/logs/failed.log',
      ).writeAsString('retain failed diagnostics');
      imageFileMode('$bundle/logs/failed.log', 0x180);
      final db = await GaoVmDatabase.open('${state.path}/gaovm.db');
      try {
        final runs = SqliteTestRunRepository(db);
        final run = await runs.create(
          spec: TestRunSpec(
            source: TemplateVmTestRunSource(vm),
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
        await runs.transition(
          run.id,
          expectedState: TestRunState.pending,
          nextState: TestRunState.provisioning,
        );
        await runs.transition(
          run.id,
          expectedState: TestRunState.provisioning,
          nextState: TestRunState.collecting,
          vmId: vm,
          outcome: TestRunState.failed,
          error: OperationError(
            code: ErrorCode.internalError,
            message: 'retained failure fixture',
            retryable: false,
            details: JsonObjectValue.empty,
          ),
        );
        await runs.transition(
          run.id,
          expectedState: TestRunState.collecting,
          nextState: TestRunState.cleaningUp,
          cleanupDecision: 'retain',
        );
        await runs.finish(run.id, outcome: TestRunState.failed);
        await db.transaction(
          (raw) => raw.execute(
            "UPDATE vm_runtime SET phase = 'failed', observed_generation = 1, driver_generation = 1 WHERE vm_id = ?",
            [vm.value],
          ),
        );
      } finally {
        db.close();
      }
      final source = await MaintenanceTree.open(state);
      try {
        final before = await source.capture(nativeMetadata: true);
        final receipt = await (await prepare()).snapshotTo(backups, 'retained');
        final payload = '${backups.path}/retained/payload';
        final saved = await MaintenanceTree.open(Directory(payload));
        try {
          await saved.verify(before, nativeMetadata: true);
        } finally {
          saved.close();
        }
        expect(receipt['manifest'], before);
        expect(
          await File(
            '$payload/vms/${vm.value}.gaovm/disks/root.raw',
          ).readAsString(),
          'guest debugging filesystem',
        );
        expect(
          await File(
            '$payload/vms/${vm.value}.gaovm/nvram/efi-variable-store',
          ).readAsString(),
          'guest NVRAM',
        );
        expect(
          await File(
            '$payload/vms/${vm.value}.gaovm/logs/failed.log',
          ).readAsString(),
          'retain failed diagnostics',
        );
        await source.verify(before, nativeMetadata: true);
      } finally {
        source.close();
      }
    },
    skip: !Platform.isMacOS,
  );
  test(
    'pending durable work prevents preparation and stays pending',
    () async {
      final db = await GaoVmDatabase.open('${state.path}/gaovm.db');
      late OperationId operation;
      try {
        operation = (await SqliteOperationRepository(db).create(
          type: 'image.import',
          resourceType: ResourceType.image,
          resourceId: image.id,
          requestId: RequestId.generate(),
          cancellable: true,
          request: JsonObjectValue.empty,
        )).id;
      } finally {
        db.close();
      }
      await expectLater(
        prepare(),
        throwsA(
          isA<ColdStateFailure>().having(
            (error) => error.stage,
            'stage',
            'catalog',
          ),
        ),
      );
      final retained = await GaoVmDatabase.open('${state.path}/gaovm.db');
      try {
        expect(
          (await SqliteOperationRepository(retained).get(operation))!.state,
          OperationState.pending,
        );
      } finally {
        retained.close();
      }
      expect(await Directory('${backups.path}/before').exists(), false);
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'service restart after preparation refuses before snapshot staging',
    () async {
      final prepared = await prepare();
      host.registered = true;
      await expectLater(
        prepared.snapshotTo(backups, 'before'),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(
        await Directory('${backups.path}/.before.partial').exists(),
        false,
      );
      expect(await Directory('${backups.path}/before').exists(), false);
      host.registered = false;
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unresolved runtime observation cannot authorize exclusion or publication',
    () async {
      var unresolved = false;
      final prepared = await prepare(
        inventory: (_) async => DriverInventorySnapshot(
          processes: [],
          unresolvedProcessIds: unresolved ? [123456] : [],
        ),
      );
      unresolved = true;
      await expectLater(
        prepared.snapshotTo(backups, 'before'),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(
        await Directory('${backups.path}/.before.partial').exists(),
        false,
      );
      expect(await Directory('${backups.path}/before').exists(), false);
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unknown runtime data is retained and never treated as disposable',
    () async {
      await socket();
      await File(
        '${state.path}/run/unknown',
      ).writeAsString('retain runtime evidence');
      imageFileMode('${state.path}/run/unknown', 0x180);
      await expectLater(
        prepare(),
        throwsA(anyOf(isA<ColdStateFailure>(), isA<FormatException>())),
      );
      expect(
        await File('${state.path}/run/unknown').readAsString(),
        'retain runtime evidence',
      );
      expect(
        await FileSystemEntity.type(
          '${state.path}/run/api.sock',
          followLinks: false,
        ),
        FileSystemEntityType.unixDomainSock,
      );
      expect(await Directory('${backups.path}/before').exists(), false);
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'unknown source ACL grants refuse without normalization or staging',
    () async {
      final prepared = await prepare();
      final file = '${state.path}/unknown-staging/keep';
      final user = (await command('/usr/bin/id', [
        '-un',
      ])).stdout.toString().trim();
      expect(user, isNotEmpty);
      expect(
        (await command('/bin/chmod', [
          '+a',
          'user:$user allow read',
          file,
        ])).exitCode,
        0,
      );
      await expectLater(
        prepared.snapshotTo(backups, 'before'),
        throwsFormatException,
      );
      expect(
        await Directory('${backups.path}/.before.partial').exists(),
        false,
      );
      final root = await OwnedImageDirectory.open(
        Directory('${state.path}/unknown-staging'),
      );
      final retained = root.file('keep');
      try {
        expect((await retained.maintenanceMetadata())['has_acl'], isTrue);
      } finally {
        retained.close();
        root.close();
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a persistent change after copying retains source and partial output',
    () async {
      var changed = false;
      final observer = MacOsOpenReferences(
        command: (_, _) async {
          if (!changed &&
              await Directory('${backups.path}/.before.partial').exists()) {
            changed = true;
            await File(
              '${state.path}/unknown-staging/keep',
            ).writeAsString('changed by fixture writer');
          }
          return ProcessResult(pid, 1, '', '');
        },
      );
      final prepared = await prepare(observer: observer);
      await expectLater(
        prepared.snapshotTo(backups, 'before').then((_) => true),
        throwsA(isA<MaintenanceSnapshotFailure>()),
      );
      expect(changed, isTrue);
      expect(await Directory('${backups.path}/before').exists(), false);
      expect(
        await Directory('${backups.path}/.before.partial/payload').exists(),
        isTrue,
      );
      expect(
        await File('${state.path}/unknown-staging/keep').readAsString(),
        'changed by fixture writer',
      );
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  for (final existing in ['before', '.before.partial']) {
    test('existing $existing is retained without overwrite', () async {
      final directory = await Directory('${backups.path}/$existing').create();
      imageFileMode(directory.path, 0x1c0);
      await File(
        '${directory.path}/keep',
      ).writeAsString('existing snapshot bytes');
      imageFileMode('${directory.path}/keep', 0x180);
      final prepared = await prepare();
      await expectLater(
        prepared.snapshotTo(backups, 'before'),
        throwsFormatException,
      );
      expect(
        await File('${directory.path}/keep').readAsString(),
        'existing snapshot bytes',
      );
      await lease.verify();
    }, skip: !Platform.isMacOS);
  }

  test('closed preparation or caller lease cannot publish', () async {
    final prepared = await prepare();
    prepared.close();
    prepared.close();
    await expectLater(prepared.snapshotTo(backups, 'before'), throwsStateError);
    await lease.verify();
    final root = await OwnedImageDirectory.open(state);
    try {
      expect(await DaemonOwnership.tryAcquire(root), isNull);
    } finally {
      root.close();
    }
    expect(await Directory('${backups.path}/before').exists(), false);
  }, skip: !Platform.isMacOS);

  test(
    'closed caller lease fails before reading or creating snapshot paths',
    () async {
      final prepared = await prepare();
      lease.close();
      await expectLater(
        prepared.snapshotTo(backups, 'before'),
        throwsStateError,
      );
      expect(
        await Directory('${backups.path}/.before.partial').exists(),
        false,
      );
      expect(await Directory('${backups.path}/before').exists(), false);
    },
    skip: !Platform.isMacOS,
  );
  test(
    'external disk and EFI remain separate and later writers refuse another copy',
    () async {
      final disk = await File(
        '${temporary.path}/external.raw',
      ).writeAsString('operator disk bytes');
      final efi = await File(
        '${temporary.path}/external.efi',
      ).writeAsString('operator EFI bytes');
      for (final file in [disk, efi]) {
        imageFileMode(file.path, 0x180);
      }
      await provision(
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
          serial: SerialConfig(enabled: true, capture: true),
          guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
          restartPolicy: RestartPolicy.never,
        ),
      );
      var occupied = false;
      final observer = MacOsOpenReferences(
        command: (_, arguments) async =>
            occupied && [disk.path, efi.path].contains(arguments.last)
            ? ProcessResult(0x7ffffffe, 1, 'p123456\x00\nf3\x00\n', '')
            : ProcessResult(pid, 1, '', ''),
      );
      final prepared = await prepare(observer: observer);
      final receipt = await prepared.snapshotTo(backups, 'external');
      final boundary = receipt['boundary'] as Map;
      final files = ((boundary['external_files'] as Map)['files'] as List);
      expect(files.map((file) => file['path']).toSet(), {disk.path, efi.path});
      expect(files.every((file) => file['backed_up'] == false), isTrue);
      expect(boundary['external_files_backed_up'], isFalse);
      expect(
        await File('${backups.path}/external/payload/external.raw').exists(),
        false,
      );
      expect(await disk.readAsString(), 'operator disk bytes');
      expect(await efi.readAsString(), 'operator EFI bytes');
      occupied = true;
      await expectLater(
        prepared.snapshotTo(backups, 'occupied'),
        throwsA(isA<ColdStateFailure>()),
      );
      expect(
        await Directory('${backups.path}/.occupied.partial').exists(),
        false,
      );
      expect(await Directory('${backups.path}/occupied').exists(), false);
    },
    skip: !Platform.isMacOS,
  );

  for (final protected in ['app', 'inspection']) {
    test('snapshot cannot write inside $protected input', () async {
      final prepared = await prepare();
      final target = protected == 'app'
          ? await OwnedImageDirectory.open(Directory(host.appPath))
          : scratch;
      try {
        await expectLater(
          prepared.snapshotTo(target, 'before'),
          throwsA(isA<ColdStateFailure>()),
        );
        expect(
          await File('${target.path}/.gaovm-maintenance.lock').exists(),
          false,
        );
        expect(
          await Directory('${target.path}/.before.partial').exists(),
          false,
        );
      } finally {
        if (protected == 'app') target.close();
      }
      await lease.verify();
    }, skip: !Platform.isMacOS);
  }
  test(
    'post-publication evidence failure retains final snapshot but never reports success',
    () async {
      final observer = MacOsOpenReferences(
        command: (_, _) async =>
            await Directory('${backups.path}/before').exists()
            ? ProcessResult(
                0x7ffffffe,
                1,
                '',
                'native evidence unavailable after publication',
              )
            : ProcessResult(pid, 1, '', ''),
      );
      final prepared = await prepare(observer: observer);
      await expectLater(
        prepared.snapshotTo(backups, 'before'),
        throwsA(
          isA<MaintenanceSnapshotFailure>().having(
            (error) => error.snapshotPath,
            'retained final',
            '${backups.path}/before',
          ),
        ),
      );
      expect(
        await File('${backups.path}/before/receipt.json').exists(),
        isTrue,
      );
      expect(
        await File(
          '${backups.path}/before/payload/unknown-staging/keep',
        ).readAsString(),
        'retain unknown data',
      );
      expect(
        await Directory('${backups.path}/.before.partial').exists(),
        false,
      );
      expect(
        await File('${state.path}/unknown-staging/keep').readAsString(),
        'retain unknown data',
      );
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  test(
    'copy mechanism rejects boundary observations for another source',
    () async {
      final tree = await MaintenanceTree.open(state);
      try {
        await expectLater(
          tree.snapshotStateDataTo(
            backups,
            'wrong',
            verifyBoundary: () async => {
              'source_state': '${temporary.path}/another-state',
            },
          ),
          throwsFormatException,
        );
      } finally {
        tree.close();
      }
      expect(await Directory('${backups.path}/.wrong.partial').exists(), false);
      expect(await Directory('${backups.path}/wrong').exists(), false);
      await lease.verify();
    },
    skip: !Platform.isMacOS,
  );

  for (final obstruction in ['run', 'gaovm.db-wal']) {
    test(
      'pre-catalog $obstruction is unresolved state, not permission to omit it',
      () async {
        lease.close();
        final retained = await state.rename(
          '${temporary.path}/retained-modern-state',
        );
        state = await Directory('${temporary.path}/state').create();
        imageFileMode(state.path, 0x1c0);
        if (obstruction == 'run') {
          await Directory('${state.path}/run').create();
          imageFileMode('${state.path}/run', 0x1c0);
        } else {
          await File(
            '${state.path}/$obstruction',
          ).writeAsString('retain orphan WAL bytes');
          imageFileMode('${state.path}/$obstruction', 0x180);
        }
        lease = await ColdStateLease.acquire(
          state,
          bundleIdentifier: 'org.gaovm.tests.Snapshot',
          host: host,
        );
        await expectLater(prepare(), throwsA(isA<ColdStateFailure>()));
        expect(
          await FileSystemEntity.type(
            '${state.path}/$obstruction',
            followLinks: false,
          ),
          isNot(FileSystemEntityType.notFound),
        );
        expect(await File('${retained.path}/gaovm.db').exists(), isTrue);
        expect(await Directory('${backups.path}/before').exists(), false);
        await lease.verify();
      },
      skip: !Platform.isMacOS,
    );
  }
  for (final phase in ['partial', 'final']) {
    test(
      '$phase output tampering during boundary recheck cannot report a valid snapshot',
      () async {
        var changed = false;
        final target =
            '${backups.path}/${phase == 'partial' ? '.before.partial' : 'before'}/payload/unknown-staging/keep';
        final observer = MacOsOpenReferences(
          command: (_, _) async {
            if (!changed && await File(target).exists()) {
              changed = true;
              await File(target).writeAsString('tampered snapshot copy');
            }
            return ProcessResult(pid, 1, '', '');
          },
        );
        final prepared = await prepare(observer: observer);
        await expectLater(
          prepared.snapshotTo(backups, 'before'),
          throwsA(isA<MaintenanceSnapshotFailure>()),
        );
        expect(changed, isTrue);
        expect(await File(target).readAsString(), 'tampered snapshot copy');
        expect(
          await File('${state.path}/unknown-staging/keep').readAsString(),
          'retain unknown data',
        );
        expect(
          await Directory('${backups.path}/before').exists(),
          phase == 'final',
        );
        await lease.verify();
      },
      skip: !Platform.isMacOS,
    );
  }
  for (final phase in ['partial', 'final']) {
    test(
      '$phase receipt tampering cannot bless otherwise matching payload bytes',
      () async {
        var changed = false;
        final target =
            '${backups.path}/${phase == 'partial' ? '.before.partial' : 'before'}/receipt.json';
        final observer = MacOsOpenReferences(
          command: (_, _) async {
            if (!changed && await File(target).exists()) {
              changed = true;
              imageFileMode(target, 0x180);
              await File(target).writeAsString('{"tampered":true}');
            }
            return ProcessResult(pid, 1, '', '');
          },
        );
        final prepared = await prepare(observer: observer);
        await expectLater(
          prepared.snapshotTo(backups, 'before').then((_) => true),
          throwsA(isA<MaintenanceSnapshotFailure>()),
        );
        expect(changed, isTrue);
        expect(await File(target).readAsString(), '{"tampered":true}');
        expect(
          await File('${state.path}/unknown-staging/keep').readAsString(),
          'retain unknown data',
        );
        expect(
          await Directory('${backups.path}/before').exists(),
          phase == 'final',
        );
        await lease.verify();
      },
      skip: !Platform.isMacOS,
    );
  }
}

final class _Host implements ColdStateHost {
  _Host(this.appPath);
  bool registered = false;
  @override
  final String appPath;
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
      'bundle_identifier': 'org.gaovm.tests.Snapshot',
      'plist_name': 'gaovmd.plist',
      'authorization_state': registered ? 'enabled' : 'notRegistered',
      'native_status': 0,
      'outcome': 'observed',
      'error_code': null,
    }),
    '',
  );
}
