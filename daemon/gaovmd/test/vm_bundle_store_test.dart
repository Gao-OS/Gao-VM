import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OwnedImageDirectory bundles;
  late OwnedImageDirectory images;
  late Image kernel;
  late Image disk;
  late VmSpec spec;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('vm-bundle-store-');
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    final imageRoot = Directory('${temporary.path}/images');
    final source = await File(
      '${temporary.path}/source',
    ).writeAsString('guest bytes');
    final store = ImageStore(database, imageRoot);
    kernel = await store.importFile(source, type: ImageType.linuxKernel);
    disk = await store.importFile(source, type: ImageType.rawDisk);
    bundles = await OwnedImageDirectory.open(
      await Directory('${temporary.path}/vms').create(),
    );
    images = await OwnedImageDirectory.open(imageRoot);
    spec = VmSpec(
      cpu: 2,
      memoryBytes: 268435456,
      boot: LinuxKernelBoot(kernelImageId: kernel.id),
      disks: [
        VmDisk(
          id: 'root',
          source: ManagedImageDiskSource(disk.id),
          writable: true,
        ),
      ],
      networks: [DisconnectedNetwork(id: 'net0')],
      graphics: GraphicsConfig(enabled: false),
      serial: const SerialConfig(enabled: true, capture: true),
      guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
      restartPolicy: RestartPolicy.never,
    );
  });
  tearDown(() async {
    images.close();
    bundles.close();
    database.close();
    await temporary.delete(recursive: true);
  });
  Future<VmProvisioningPlan> plan() async {
    final accepted =
        await SqliteVmCreateAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 30),
        ).accept(
          VmCreateCommand(
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
            name: 'vm',
            spec: spec,
          ),
        );
    return (await SqliteVmProvisioningRepository(
      database,
    ).get(accepted.resourceId as VmId))!.plan;
  }

  VmBundleStore store({void Function(VmBundleCheckpoint)? checkpoint}) =>
      VmBundleStore(
        database: database,
        bundles: bundles,
        images: images,
        onCheckpoint: checkpoint,
      );

  test(
    'publishes complete isolated bundles without completing create operations',
    () async {
      final a = await plan();
      final b = await plan();
      final manifests = await Future.wait([
        store().withBundle(a, (bundle) => bundle.publish()),
        store().withBundle(b, (bundle) => bundle.publish()),
      ]);
      for (final manifest in manifests) {
        final root = '${bundles.path}/${manifest.plan.vmId.value}.gaovm';
        final saved = VmBundleManifest.fromJson(
          jsonDecode(await File('$root/manifest.json').readAsString()),
        );
        expect(saved.digest, manifest.digest);
        expect(
          await File('$root/disks/root.raw').readAsString(),
          'guest bytes',
        );
        for (final child in ['logs', 'artifacts', 'runtime', 'nvram']) {
          expect(await Directory('$root/$child').exists(), isTrue);
        }
        expect(
          (await SqliteOperationRepository(
            database,
          ).get(manifest.plan.operationId))!.state,
          OperationState.pending,
        );
      }
      await File(
        '${bundles.path}/${a.vmId.value}.gaovm/disks/root.raw',
      ).writeAsString('a changed');
      expect(
        await File(
          '${bundles.path}/${b.vmId.value}.gaovm/disks/root.raw',
        ).readAsString(),
        'guest bytes',
      );
      expect(
        await File(
          '${images.path}/sha256-${disk.digest.substring(7)}/objects/payload',
        ).readAsString(),
        'guest bytes',
      );
    },
  );

  test(
    'cancelled copy removes only its private stage and leaves external disks intact',
    () async {
      final external = await File(
        '${temporary.path}/external',
      ).writeAsString('keep');
      spec = VmSpec.fromJson({
        ...spec.toJson(),
        'disks': [
          ...spec.disks.map((disk) => disk.toJson()),
          VmDisk(
            id: 'data',
            source: ExternalDiskSource(external.path),
            writable: true,
          ).toJson(),
        ],
      });
      final pinned = await plan();
      var cancelled = false;
      await expectLater(
        store().withBundle(
          pinned,
          (bundle) => bundle.publish(
            isCancelled: () => cancelled,
            onProgress: (_) => cancelled = true,
          ),
        ),
        throwsA(isA<ManagedDiskCancelled>()),
      );
      expect(
        await Directory('${bundles.path}/${pinned.vmId.value}.gaovm').exists(),
        isFalse,
      );
      expect(
        (await Directory(bundles.path).list().toList()).whereType<Directory>(),
        isEmpty,
      );
      expect(await external.readAsString(), 'keep');
    },
  );

  test(
    'missing external disk prevents publication and removes staging',
    () async {
      spec = VmSpec.fromJson({
        ...spec.toJson(),
        'disks': [
          VmDisk(
            id: 'data',
            source: ExternalDiskSource('${temporary.path}/missing'),
            writable: true,
          ).toJson(),
        ],
      });
      final pinned = await plan();
      await expectLater(
        store().withBundle(pinned, (bundle) => bundle.publish()),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        (await Directory(bundles.path).list().toList()).whereType<Directory>(),
        isEmpty,
      );
    },
  );

  for (final point in ['staged', 'published']) {
    test(
      'recovers process exit after $point without replacing a publication',
      () async {
        final pinned = await plan();
        final child = await Process.run(Platform.resolvedExecutable, [
          'run',
          'test/fixtures/crash_vm_bundle.dart',
          '${temporary.path}/catalog.db',
          bundles.path,
          images.path,
          pinned.vmId.value,
          point,
        ]);
        expect(child.exitCode, 91, reason: '${child.stdout}\n${child.stderr}');
        final restored = await store().withBundle(
          pinned,
          (bundle) => bundle.publish(),
        );
        expect(restored.digest, VmBundleManifest.create(pinned).digest);
        expect(
          await File(
            '${bundles.path}/${pinned.vmId.value}.gaovm/disks/root.raw',
          ).readAsString(),
          'guest bytes',
        );
        expect(
          (await Directory(
            bundles.path,
          ).list().toList()).whereType<Directory>(),
          hasLength(1),
        );
      },
    );
  }

  test(
    'uncommitted cleanup rejects foreign origin and never removes external files',
    () async {
      final external = await File(
        '${temporary.path}/external',
      ).writeAsString('keep');
      spec = VmSpec.fromJson({
        ...spec.toJson(),
        'disks': [
          ...spec.disks.map((disk) => disk.toJson()),
          VmDisk(
            id: 'data',
            source: ExternalDiskSource(external.path),
            writable: true,
          ).toJson(),
        ],
      });
      final pinned = await plan();
      await store().withBundle(pinned, (bundle) => bundle.publish());
      final foreign = VmProvisioningPlan.fromJson({
        ...pinned.toJson(),
        'operation_id': OperationId.generate().value,
      });
      await expectLater(
        store().withBundle(foreign, (bundle) => bundle.removeUncommitted()),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      expect(
        await File(
          '${bundles.path}/${pinned.vmId.value}.gaovm/disks/root.raw',
        ).readAsString(),
        'guest bytes',
      );
      await store().withBundle(pinned, (bundle) => bundle.removeUncommitted());
      expect(
        (await Directory(bundles.path).list().toList()).whereType<Directory>(),
        isEmpty,
      );
      expect(await external.readAsString(), 'keep');
    },
  );

  test(
    'unknown publication is preserved rather than overwritten or cleaned',
    () async {
      final pinned = await plan();
      final destination = await Directory(
        '${bundles.path}/${pinned.vmId.value}.gaovm',
      ).create();
      final existing = await File(
        '${destination.path}/keep',
      ).writeAsString('user data');
      await expectLater(
        store().withBundle(pinned, (bundle) => bundle.publish()),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        store().withBundle(pinned, (bundle) => bundle.removeUncommitted()),
        throwsA(isA<FileSystemException>()),
      );
      expect(await existing.readAsString(), 'user data');
    },
  );

  test('bounded abandoned-stage cleanup recovers a partial manifest', () async {
    final pinned = await plan();
    final stage = bundles.createDirectory(
      '.staging-${pinned.vmId.value}-${pinned.operationId.value}',
    );
    try {
      await File(
        '${stage.path}/manifest.json',
      ).writeAsString('{"bundle_version":');
      stage.createDirectory('disks').close();
      await File('${stage.path}/disks/root.raw').writeAsString('partial');
    } finally {
      stage.close();
    }
    final manifest = await store().withBundle(
      pinned,
      (bundle) => bundle.publish(),
    );
    expect(manifest.plan.vmId, pinned.vmId);
    expect(
      await File(
        '${bundles.path}/${pinned.vmId.value}.gaovm/disks/root.raw',
      ).readAsString(),
      'guest bytes',
    );
  });

  test(
    'bundle mutations reject caller transactions and expired sessions',
    () async {
      final pinned = await plan();
      await database.transaction((_) async {
        await expectLater(
          store().withBundle(pinned, (bundle) => bundle.publish()),
          throwsStateError,
        );
      });
      late VmBundleSession escaped;
      await store().withBundle(pinned, (bundle) async {
        escaped = bundle;
      });
      await expectLater(escaped.publish(), throwsStateError);
      expect(
        (await Directory(bundles.path).list().toList()).whereType<Directory>(),
        isEmpty,
      );
    },
  );

  test(
    'cleanup resumes after process exits with the origin manifest already removed',
    () async {
      final pinned = await plan();
      final child = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/fixtures/crash_vm_bundle.dart',
        '${temporary.path}/catalog.db',
        bundles.path,
        images.path,
        pinned.vmId.value,
        'cleanupContentsRemoved',
      ]);
      expect(child.exitCode, 91, reason: '${child.stdout}\n${child.stderr}');
      await store().withBundle(pinned, (bundle) => bundle.removeUncommitted());
      expect(
        (await Directory(bundles.path).list().toList()).whereType<Directory>(),
        isEmpty,
      );
    },
  );
}
