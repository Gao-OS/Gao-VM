import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OwnedImageDirectory bundles;
  late OwnedImageDirectory images;
  late VmId vmId;
  late Image image;
  late VmSpec spec;
  late VmControllerState state;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('runtime-assets-');
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    final source = await Directory(
      '${temporary.path}/source/objects',
    ).create(recursive: true);
    final objects = <String, Map<String, Object?>>{};
    for (final role in ['kernel', 'initrd', 'root']) {
      final bytes = utf8.encode('$role bytes');
      await File('${source.path}/$role').writeAsBytes(bytes);
      objects[role] = {
        'digest': 'sha256:${sha256.convert(bytes)}',
        'size_bytes': bytes.length,
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
    final imageRoot = Directory('${temporary.path}/images');
    image = await ImageStore(database, imageRoot).importBundle(source.parent);
    final vmRoot = await Directory('${temporary.path}/vms').create();
    imageFileMode(vmRoot.path, 0x1c0);
    bundles = await OwnedImageDirectory.open(vmRoot);
    images = await OwnedImageDirectory.open(imageRoot);
    spec = VmSpec(
      cpu: 2,
      memoryBytes: 268435456,
      boot: LinuxKernelBoot(kernelImageId: image.id, initrdImageId: image.id),
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
    );
    final accepted =
        await SqliteVmCreateAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 30),
        ).create(
          VmCreateCommand(
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
            name: 'vm',
            spec: spec,
          ),
        );
    vmId = accepted.resourceId as VmId;
    final result = (await VmProvisioningWorker(
      work: SqliteVmProvisioningWorkRepository(database),
      bundles: VmBundleStore(
        database: database,
        bundles: bundles,
        images: images,
      ),
      owner: 'provision',
    ).dispatchOnce()).single;
    expect(result.completion, VmProvisioningCompletionKind.succeeded);
    state = VmControllerState.initial(
      vmId: vmId,
      specGeneration: 1,
      restartPolicy: RestartPolicy.never,
    );
  });
  tearDown(() async {
    images.close();
    bundles.close();
    database.close();
    await temporary.delete(recursive: true);
  });
  SqliteVmRuntimeAssets resolver() => SqliteVmRuntimeAssets(
    database: database,
    bundles: bundles,
    images: images,
  );

  test(
    'provisioned assets configure a driver through the public composition',
    () async {
      final operationId = OperationId.generate();
      final starting = state.copyWith(driverGeneration: 1);
      await SqliteVmStateEffectAdapter(database).persistRuntime(starting);
      final factory = FakeRuntimeDriverFactory(
        scheduler: ManualRuntimeScheduler(),
      );
      final configuration = VmRuntimeConfigurationResolver(assets: resolver());
      final adapter = RuntimeDriverEffectAdapter.scopedConfiguration(
        factory: factory,
        withConfiguration: configuration.withConfiguration,
        dispatch: (_, _) async {},
      );
      try {
        await adapter.spawn(starting, operationId, 1);
        await adapter.connect(starting, operationId, 1);
        await adapter.configure(starting, operationId, 1);
        final control = factory.controlFor(
          DriverCorrelation(
            vmId: vmId,
            driverGeneration: 1,
            operationId: operationId,
          ),
        );
        final command = control.commandHistory
            .whereType<RuntimeConfigureCommand>()
            .single;
        final boot =
            command.configuration.boot as RuntimeLinuxBootConfiguration;
        expect(await File(boot.kernelPath).readAsString(), 'kernel bytes');
        expect(await File(boot.initrdPath!).readAsString(), 'initrd bytes');
        expect(command.configuration.cpu, 2);
        expect(
          command.configuration.disks.single.path,
          '${bundles.path}/${vmId.value}.gaovm/disks/root.raw',
        );
      } finally {
        await adapter.close();
      }
    },
  );

  test(
    'one GaoOS image resolves distinct boot roles and the VM-owned writable disk',
    () async {
      await resolver().withAssets(state, (assets) async {
        expect(assets.vmId, vmId);
        expect(assets.specGeneration, 1);
        final boot = assets.boot as RuntimeLinuxBootConfiguration;
        expect(await File(boot.kernelPath).readAsString(), 'kernel bytes');
        expect(await File(boot.initrdPath!).readAsString(), 'initrd bytes');
        expect(boot.kernelPath, isNot(boot.initrdPath));
        expect(
          assets.disks.single.path,
          '${bundles.path}/${vmId.value}.gaovm/disks/root.raw',
        );
        expect(
          await File(assets.disks.single.path).readAsString(),
          'root bytes',
        );
      });
    },
  );

  test(
    'CPU-only generations reuse guest-mutated disks and resolve the requested retained spec',
    () async {
      final disk = File('${bundles.path}/${vmId.value}.gaovm/disks/root.raw');
      await disk.writeAsString('guest wrote new filesystem data');
      final repository = SqliteVmRepository(database);
      final current = (await repository.get(vmId))!;
      final updated = await repository.updateSpec(
        vmId,
        expectedRevision: current.metadata.revision,
        spec: VmSpec.fromJson({...spec.toJson(), 'cpu': 4}),
      );
      state = state.copyWith(specGeneration: updated.status.specGeneration);
      await resolver().withAssets(state, (assets) async {
        expect(assets.spec.cpu, 4);
        expect(assets.specGeneration, 2);
        expect(
          await File(assets.disks.single.path).readAsString(),
          'guest wrote new filesystem data',
        );
      });
      await resolver().withAssets(state.copyWith(activeSpecGeneration: 1), (
        assets,
      ) async {
        expect(assets.spec.cpu, 2);
        expect(assets.specGeneration, 1);
        expect(
          await File(assets.disks.single.path).readAsString(),
          'guest wrote new filesystem data',
        );
      });
    },
  );

  test(
    'changed managed source is never silently rebound to the old disk',
    () async {
      final otherFile = await File(
        '${temporary.path}/other',
      ).writeAsString('replacement image');
      final other = await ImageStore(
        database,
        Directory(images.path),
      ).importFile(otherFile, type: ImageType.rawDisk);
      final repository = SqliteVmRepository(database);
      final vm = (await repository.get(vmId))!;
      final updated = await repository.updateSpec(
        vmId,
        expectedRevision: vm.metadata.revision,
        spec: VmSpec.fromJson({
          ...spec.toJson(),
          'disks': [
            VmDisk(
              id: 'root',
              source: ManagedImageDiskSource(other.id),
              writable: true,
            ).toJson(),
          ],
        }),
      );
      await expectLater(
        resolver().withAssets(
          state.copyWith(specGeneration: updated.status.specGeneration),
          (_) async => fail('unbound disk exposed'),
        ),
        throwsA(
          isA<RuntimeDriverError>().having(
            (error) => error.code,
            'code',
            RuntimeDriverErrorCode.invalidRuntimeConfig,
          ),
        ),
      );
      expect(
        await File(
          '${bundles.path}/${vmId.value}.gaovm/disks/root.raw',
        ).readAsString(),
        'root bytes',
      );
      await resolver().withAssets(state, (_) async {});
    },
  );

  test(
    'namespace lock is held through consumption and released on consumer failure',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final failure = StateError('driver rejected configuration');
      final first = resolver().withAssets(state, (_) async {
        entered.complete();
        await release.future;
        throw failure;
      });
      final firstResult = expectLater(first, throwsA(same(failure)));
      await entered.future;
      final secondEntered = Completer<void>();
      final second = resolver().withAssets(state, (_) async {
        secondEntered.complete();
      });
      await expectLater(
        secondEntered.future.timeout(const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
      release.complete();
      await firstResult;
      await second.timeout(const Duration(seconds: 2));
      expect(secondEntered.isCompleted, isTrue);
    },
  );

  test(
    'external disk is validated and canonicalized at launch without taking ownership',
    () async {
      final source = await File(
        '${temporary.path}/external.raw',
      ).writeAsString('external data');
      final alias = await Link(
        '${temporary.path}/alias.raw',
      ).create(source.path);
      final externalSpec = VmSpec.fromJson({
        ...spec.toJson(),
        'disks': [
          VmDisk(
            id: 'root',
            source: ExternalDiskSource(alias.path),
            writable: true,
          ).toJson(),
        ],
      });
      final accepted =
          await SqliteVmCreateAcceptance(
            database: database,
            idempotencyRetention: const Duration(days: 30),
          ).create(
            VmCreateCommand(
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
              name: 'external',
              spec: externalSpec,
            ),
          );
      expect(
        (await VmProvisioningWorker(
          work: SqliteVmProvisioningWorkRepository(database),
          bundles: VmBundleStore(
            database: database,
            bundles: bundles,
            images: images,
          ),
          owner: 'external-provision',
        ).dispatchOnce()).single.completion,
        VmProvisioningCompletionKind.succeeded,
      );
      final externalState = VmControllerState.initial(
        vmId: accepted.resourceId as VmId,
        specGeneration: 1,
        restartPolicy: RestartPolicy.never,
      );
      await resolver().withAssets(externalState, (assets) async {
        expect(assets.disks.single.path, await source.resolveSymbolicLinks());
        expect(
          await File(assets.disks.single.path).readAsString(),
          'external data',
        );
      });
      await source.writeAsString('');
      await expectLater(
        resolver().withAssets(
          externalState,
          (_) async => fail('empty external exposed'),
        ),
        throwsA(isA<RuntimeDriverError>()),
      );
      expect(await alias.exists(), isTrue);
      expect(await source.exists(), isTrue);
    },
  );

  for (final mutation in <String, Future<void> Function()>{
    'corrupt boot object': () async {
      final path =
          '${images.path}/sha256-${image.digest.substring(7)}/objects/kernel';
      imageFileMode(path, 0x180);
      await File(path).writeAsString('corrupt boot');
    },
    'corrupt bundle origin': () async {
      await File(
        '${bundles.path}/${vmId.value}.gaovm/manifest.json',
      ).writeAsString('{}');
    },
    'empty managed disk': () async {
      await File(
        '${bundles.path}/${vmId.value}.gaovm/disks/root.raw',
      ).writeAsString('');
    },
    'symlink managed disk': () async {
      final path = '${bundles.path}/${vmId.value}.gaovm/disks/root.raw';
      await File(path).rename('$path.original');
      await Link(path).create('$path.original');
    },
    'nonprivate VM directory': () async {
      imageFileMode('${bundles.path}/${vmId.value}.gaovm/logs', 0x1ed);
    },
    'symlink serial log': () async {
      final external = await File(
        '${temporary.path}/outside.log',
      ).writeAsString('preserve');
      await Link(
        '${bundles.path}/${vmId.value}.gaovm/logs/serial.log',
      ).create(external.path);
    },
    'symlink lock file': () async {
      final path = '${bundles.path}/.lock-${vmId.value}';
      await File(path).rename('$path.original');
      await Link(path).create('$path.original');
    },
    'replaced root pathname': () async {
      await Directory(bundles.path).rename('${bundles.path}.moved');
      await Directory(bundles.path).create();
      imageFileMode(bundles.path, 0x1c0);
    },
  }.entries) {
    test('${mutation.key} fails before any paths reach the driver', () async {
      await mutation.value();
      await expectLater(
        resolver().withAssets(
          state,
          (_) async => fail('invalid assets exposed'),
        ),
        throwsA(
          isA<RuntimeDriverError>().having(
            (error) => error.code,
            'code',
            RuntimeDriverErrorCode.invalidRuntimeConfig,
          ),
        ),
      );
    });
  }

  test(
    'deleting VM and stale driver generation cannot resolve completed assets',
    () async {
      await expectLater(
        resolver().withAssets(
          state.copyWith(driverGeneration: 1),
          (_) async => fail('stale generation'),
        ),
        throwsA(isA<RuntimeDriverError>()),
      );
      final repository = SqliteVmRepository(database);
      final vm = (await repository.get(vmId))!;
      await repository.markDeleting(
        vmId,
        expectedRevision: vm.metadata.revision,
      );
      await expectLater(
        resolver().withAssets(state, (_) async => fail('deleting VM')),
        throwsA(isA<RuntimeDriverError>()),
      );
      expect(
        await File(
          '${bundles.path}/${vmId.value}.gaovm/disks/root.raw',
        ).readAsString(),
        'root bytes',
      );
    },
  );

  test(
    'caller transactions cannot retain locks or expose uncommitted spec paths',
    () async {
      await expectLater(
        database.transaction(
          (_) => resolver().withAssets(
            state,
            (_) async => fail('uncommitted paths'),
          ),
        ),
        throwsStateError,
      );
      final other = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      try {
        await expectLater(
          other.transaction(
            (_) => resolver().withAssets(
              state,
              (_) async => fail('other transaction paths'),
            ),
          ),
          throwsStateError,
        );
      } finally {
        other.close();
      }
      await resolver().withAssets(state, (_) async {});
    },
  );

  test(
    'managed EFI permits an absent store but rejects an existing symlink',
    () async {
      final efiSpec = VmSpec.fromJson({
        ...spec.toJson(),
        'boot': EfiBoot().toJson(),
      });
      final accepted =
          await SqliteVmCreateAcceptance(
            database: database,
            idempotencyRetention: const Duration(days: 30),
          ).create(
            VmCreateCommand(
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
              name: 'efi',
              spec: efiSpec,
            ),
          );
      expect(
        (await VmProvisioningWorker(
          work: SqliteVmProvisioningWorkRepository(database),
          bundles: VmBundleStore(
            database: database,
            bundles: bundles,
            images: images,
          ),
          owner: 'efi-provision',
        ).dispatchOnce()).single.completion,
        VmProvisioningCompletionKind.succeeded,
      );
      final efiState = VmControllerState.initial(
        vmId: accepted.resourceId as VmId,
        specGeneration: 1,
        restartPolicy: RestartPolicy.never,
      );
      late String variableStore;
      await resolver().withAssets(efiState, (assets) async {
        variableStore =
            (assets.boot as RuntimeEfiBootConfiguration).variableStorePath;
      });
      expect(await File(variableStore).exists(), isFalse);
      final external = await File(
        '${temporary.path}/outside-nvram',
      ).writeAsString('preserve');
      await Link(variableStore).create(external.path);
      await expectLater(
        resolver().withAssets(
          efiState,
          (_) async => fail('symlink EFI exposed'),
        ),
        throwsA(isA<RuntimeDriverError>()),
      );
      expect(await external.readAsString(), 'preserve');
    },
  );

  test('uncompleted create cannot expose staged runtime assets', () async {
    final accepted =
        await SqliteVmCreateAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 30),
        ).create(
          VmCreateCommand(
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
            name: 'pending',
            spec: spec,
          ),
        );
    final pending = VmControllerState.initial(
      vmId: accepted.resourceId as VmId,
      specGeneration: 1,
      restartPolicy: RestartPolicy.never,
    );
    await expectLater(
      resolver().withAssets(
        pending,
        (_) async => fail('pending assets exposed'),
      ),
      throwsA(isA<RuntimeDriverError>()),
    );
    expect(
      await Directory(
        '${bundles.path}/${accepted.resourceId.value}.gaovm',
      ).exists(),
      isFalse,
    );
  });
}
