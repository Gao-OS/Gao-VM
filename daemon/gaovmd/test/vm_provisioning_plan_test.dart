import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/image_manifest.dart';
import 'package:gaovmd/src/image_repository.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_provisioning_plan.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteVmRepository vms;
  late SqliteOperationRepository operations;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('provision-plan-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    vms = SqliteVmRepository(database);
    operations = SqliteOperationRepository(database);
  });
  tearDown(() async {
    database.close();
    await directory.delete(recursive: true);
  });
  Future<Operation> createOperation(
    VmId vmId, {
    String type = 'vm.create',
    int? generation,
  }) => operations.create(
    type: type,
    resourceType: ResourceType.virtualMachine,
    resourceId: vmId,
    requestId: RequestId.generate(),
    cancellable: true,
    request: JsonObjectValue.fromJson({
      if (generation != null) 'spec_generation': generation,
    }),
  );
  Future<Image> insertImage(ImageManifest manifest) =>
      ImageRepository(database).insert(
        Image(
          id: ImageId.generate(),
          digest: manifest.digest,
          type: manifest.type,
          architecture: Architecture.arm64,
          guestProfile: manifest.metadata('guest_profile'),
          version: manifest.metadata('version'),
          buildId: manifest.metadata('build_id'),
          channel: manifest.metadata('channel'),
          manifest: JsonObjectValue.fromJson(manifest.toJson()),
          createdAt: DateTime.utc(2026, 9, 7),
        ),
      );

  test('pins distinct GaoOS object roles from one immutable bundle', () async {
    final manifest = ImageManifest.create(
      type: ImageType.gaoosBundle,
      guestProfile: 'gaoos',
      version: '1',
      buildId: 'build',
      channel: 'dev',
      objects: {
        'kernel-a': _object('kernel'),
        'initrd-a': _object('initrd'),
        'root-a': _object('root'),
      },
      gaoos: {
        'kernel': 'kernel-a',
        'initrd': 'initrd-a',
        'root_disk': 'root-a',
        'default_command_line': '',
        'guest_agent_expected': false,
      },
    );
    final image = await insertImage(manifest);
    final spec = VmSpec.fromJson({
      ..._spec.toJson(),
      'boot': LinuxKernelBoot(
        kernelImageId: image.id,
        initrdImageId: image.id,
      ).toJson(),
      'disks': [
        VmDisk(
          id: 'root',
          source: ManagedImageDiskSource(image.id),
          writable: true,
        ).toJson(),
      ],
    });
    final vm = await vms.create(name: 'bundle', spec: spec);
    final operation = await createOperation(vm.metadata.id);
    final plan = await SqliteVmProvisioningPlanner(
      database,
    ).plan(vmId: vm.metadata.id, operationId: operation.id, specGeneration: 1);
    expect(plan.kernel!.objectName, 'kernel-a');
    expect(plan.initrd!.objectName, 'initrd-a');
    final disk = (plan.disks.single.source as VmProvisioningManagedDisk).image;
    expect(disk.objectName, 'root-a');
    expect(disk.role, VmProvisioningImageRole.rootDisk);
    expect(disk.imageId, image.id);
    expect(disk.imageDigest, manifest.digest);
    expect(disk.objectDigest, _object('root')['digest']);
    expect(disk.sizeBytes, 4);
    final json = plan.toJson();
    expect(
      VmProvisioningPlan.fromJson(jsonDecode(jsonEncode(json))).toJson(),
      json,
    );
    (json['disks'] as List).clear();
    expect(plan.disks, hasLength(1));
  });

  test(
    'pins retained spec generation and preserves external ownership',
    () async {
      final vm = await vms.create(name: 'plan', spec: _spec);
      final operation = await createOperation(vm.metadata.id, generation: 1);
      await vms.updateSpec(
        vm.metadata.id,
        expectedRevision: 1,
        spec: VmSpec.fromJson({..._spec.toJson(), 'cpu': 4}),
      );
      final plan = await SqliteVmProvisioningPlanner(database).plan(
        vmId: vm.metadata.id,
        operationId: operation.id,
        specGeneration: 1,
      );
      expect(plan.specGeneration, 1);
      expect(plan.specDigest, contentDigest(_spec.toJson()));
      expect(plan.kernel, isNull);
      expect(plan.initrd, isNull);
      final disk = plan.disks.single;
      expect(disk.id, 'root');
      expect(disk.writable, isTrue);
      expect(
        (disk.source as VmProvisioningExternalDisk).path,
        '/external/root.img',
      );
      expect(
        VmProvisioningPlan.fromJson(
          jsonDecode(jsonEncode(plan.toJson())),
        ).toJson(),
        plan.toJson(),
      );
      expect(() => plan.disks.clear(), throwsUnsupportedError);
      expect(
        (await operations.get(operation.id))!.state,
        OperationState.pending,
      );
    },
  );

  test('pins standalone kernel, initrd and raw disk payloads', () async {
    Future<Image> image(ImageType type) => insertImage(
      ImageManifest.create(
        type: type,
        objects: {'payload': _object(type.name)},
      ),
    );
    final kernel = await image(ImageType.linuxKernel);
    final initrd = await image(ImageType.initrd);
    final root = await image(ImageType.rawDisk);
    final spec = VmSpec.fromJson({
      ..._spec.toJson(),
      'boot': LinuxKernelBoot(
        kernelImageId: kernel.id,
        initrdImageId: initrd.id,
      ).toJson(),
      'disks': [
        VmDisk(
          id: 'root',
          source: ManagedImageDiskSource(root.id),
          writable: false,
        ).toJson(),
      ],
    });
    final vm = await vms.create(name: 'standalone', spec: spec);
    final operation = await createOperation(vm.metadata.id);
    final plan = await SqliteVmProvisioningPlanner(
      database,
    ).plan(vmId: vm.metadata.id, operationId: operation.id, specGeneration: 1);
    expect(plan.kernel!.imageId, kernel.id);
    expect(plan.initrd!.imageId, initrd.id);
    expect(plan.kernel!.objectName, 'payload');
    expect(plan.disks.single.writable, isFalse);
    expect(
      (plan.disks.single.source as VmProvisioningManagedDisk).image.imageId,
      root.id,
    );
  });

  for (final role in VmProvisioningImageRole.values) {
    test('rejects standalone type mismatch for ${role.name}', () async {
      final wrong = await insertImage(
        ImageManifest.create(
          type: role == VmProvisioningImageRole.rootDisk
              ? ImageType.linuxKernel
              : ImageType.rawDisk,
          objects: {'payload': _object('wrong')},
        ),
      );
      final kernel = await insertImage(
        ImageManifest.create(
          type: ImageType.linuxKernel,
          objects: {'payload': _object('kernel')},
        ),
      );
      final spec = VmSpec.fromJson({
        ..._spec.toJson(),
        if (role != VmProvisioningImageRole.rootDisk)
          'boot': LinuxKernelBoot(
            kernelImageId: role == VmProvisioningImageRole.kernel
                ? wrong.id
                : kernel.id,
            initrdImageId: role == VmProvisioningImageRole.initrd
                ? wrong.id
                : null,
          ).toJson(),
        if (role == VmProvisioningImageRole.rootDisk)
          'disks': [
            VmDisk(
              id: 'root',
              source: ManagedImageDiskSource(wrong.id),
              writable: true,
            ).toJson(),
          ],
      });
      final vm = await vms.create(name: 'wrong', spec: spec);
      final operation = await createOperation(vm.metadata.id);
      await expectLater(
        SqliteVmProvisioningPlanner(database).plan(
          vmId: vm.metadata.id,
          operationId: operation.id,
          specGeneration: 1,
        ),
        throwsFormatException,
      );
    });
  }

  test('rejects missing or catalog-corrupted immutable images', () async {
    final image = await insertImage(
      ImageManifest.create(
        type: ImageType.rawDisk,
        objects: {'payload': _object('root')},
      ),
    );
    final vm = await vms.create(
      name: 'corrupt',
      spec: VmSpec.fromJson({
        ..._spec.toJson(),
        'disks': [
          VmDisk(
            id: 'root',
            source: ManagedImageDiskSource(image.id),
            writable: true,
          ).toJson(),
        ],
      }),
    );
    final operation = await createOperation(vm.metadata.id);
    Future<VmProvisioningPlan> plan() => SqliteVmProvisioningPlanner(
      database,
    ).plan(vmId: vm.metadata.id, operationId: operation.id, specGeneration: 1);
    await database.transaction(
      (db) => db.execute("UPDATE images SET version = 'corrupt'"),
    );
    await expectLater(plan(), throwsFormatException);
    await database.transaction((db) => db.execute('DELETE FROM images'));
    await expectLater(plan(), throwsStateError);
  });

  test(
    'requires matching active create operation and positive retained generation',
    () async {
      final vm = await vms.create(name: 'op', spec: _spec);
      final other = await vms.create(name: 'other', spec: _spec);
      final wrongVm = await createOperation(other.metadata.id);
      final wrongType = await createOperation(vm.metadata.id, type: 'vm.patch');
      final wrongGeneration = await createOperation(
        vm.metadata.id,
        generation: 2,
      );
      final terminal = await createOperation(vm.metadata.id);
      await operations.cancel(terminal.id);
      for (final operation in [wrongVm, wrongType, wrongGeneration, terminal]) {
        await expectLater(
          SqliteVmProvisioningPlanner(database).plan(
            vmId: vm.metadata.id,
            operationId: operation.id,
            specGeneration: 1,
          ),
          throwsStateError,
        );
      }
      final valid = await createOperation(vm.metadata.id);
      await expectLater(
        SqliteVmProvisioningPlanner(
          database,
        ).plan(vmId: vm.metadata.id, operationId: valid.id, specGeneration: 0),
        throwsFormatException,
      );
      await expectLater(
        SqliteVmProvisioningPlanner(
          database,
        ).plan(vmId: vm.metadata.id, operationId: valid.id, specGeneration: 99),
        throwsA(isA<VmNotFoundException>()),
      );
      await expectLater(
        SqliteVmProvisioningPlanner(database).plan(
          vmId: vm.metadata.id,
          operationId: OperationId.generate(),
          specGeneration: 1,
        ),
        throwsA(isA<OperationNotFoundException>()),
      );
    },
  );

  test(
    'joins acceptance transaction without publishing or mutating resources',
    () async {
      await expectLater(
        database.transaction((db) async {
          final vm = await vms.create(name: 'uncommitted', spec: _spec);
          final operation = await createOperation(vm.metadata.id);
          final before = db
              .select('SELECT COUNT(*) AS count FROM events')
              .single['count'];
          final plan = await SqliteVmProvisioningPlanner(database).plan(
            vmId: vm.metadata.id,
            operationId: operation.id,
            specGeneration: 1,
          );
          expect(plan.vmId, vm.metadata.id);
          expect(
            db.select('SELECT COUNT(*) AS count FROM events').single['count'],
            before,
          );
          expect(
            (await operations.get(operation.id))!.state,
            OperationState.pending,
          );
          throw StateError('rollback acceptance');
        }),
        throwsStateError,
      );
      expect(await vms.list(), isEmpty);
      expect(await operations.list(), isEmpty);
    },
  );

  test(
    'serialized plans reject unknown fields, invalid digest, duplicate disks and roles',
    () async {
      final vm = await vms.create(name: 'decode', spec: _spec);
      final operation = await createOperation(vm.metadata.id);
      final plan = await SqliteVmProvisioningPlanner(database).plan(
        vmId: vm.metadata.id,
        operationId: operation.id,
        specGeneration: 1,
      );
      final json = plan.toJson();
      for (final corrupted in [
        {...json, 'unknown': true},
        {...json, 'plan_version': 1.0},
        {...json, 'spec_generation': -1},
        {...json, 'disks': <Object?>[]},
        {
          ...json,
          'disks': [
            for (var index = 0; index < 33; index++)
              {...plan.disks.single.toJson(), 'id': 'disk-$index'},
          ],
        },
        {...json, 'spec_digest': 'sha256:bad'},
        {
          ...json,
          'disks': [...json['disks'] as List, ...json['disks'] as List],
        },
        {
          ...json,
          'kernel': {
            'role': 'root_disk',
            'image_id': ImageId.generate().value,
            'image_digest': contentDigest('image'),
            'object_name': 'payload',
            'object_digest': contentDigest('object'),
            'size_bytes': 1,
          },
        },
        {
          ...json,
          'disks': [
            {
              'id': 'root',
              'writable': true,
              'source': {
                'type': 'managed_image',
                'image': {
                  'role': 'kernel',
                  'image_id': ImageId.generate().value,
                  'image_digest': contentDigest('image'),
                  'object_name': '../outside',
                  'object_digest': contentDigest('object'),
                  'size_bytes': 1,
                },
              },
            },
          ],
        },
      ]) {
        expect(
          () => VmProvisioningPlan.fromJson(corrupted),
          throwsFormatException,
        );
      }
    },
  );
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/external/root.img'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);

Map<String, Object?> _object(String content) => {
  'digest': contentDigest(content),
  'size_bytes': content.length,
};
