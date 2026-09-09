import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late GaoVmDatabase database;
  late VmRegistry registry;
  late VirtualMachine vm;
  late RepositoryVmEffectRunner effects;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('patch-accept-');
    database = await GaoVmDatabase.open('${root.path}/catalog.db');
    vm = await SqliteVmRepository(database).create(name: 'before', spec: _spec);
    final runtime = _NoRuntime();
    effects = RepositoryVmEffectRunner(
      database: database,
      operations: SqliteOperationRepository(database),
      events: SqliteEventRepository(database),
      persistence: SqliteVmStateEffectAdapter(database),
      leases: runtime,
      drivers: runtime,
      managedFiles: runtime,
    );
    registry = VmRegistry(
      repository: SqliteVmRepository(database),
      operations: SqliteOperationRepository(database),
      recovery: SqliteVmIntentRecoveryRepository(database),
      effectRunner: effects,
    );
  });
  tearDown(() async {
    await registry.shutdown();
    database.close();
    await root.delete(recursive: true);
  });

  test(
    'pending patch lets its unfinished lifecycle dependency recover first',
    () async {
      final start =
          await SqliteVmLifecycleAcceptor(
            database: database,
            registry: registry,
            idempotencyRetention: const Duration(days: 30),
          ).lifecycle(
            VmLifecycleCommand(
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
              vmId: vm.metadata.id,
              action: VmLifecycleAction.start,
            ),
          );
      await registry.shutdown();
      await SqliteOperationRepository(database).start(start.operationId);
      final execution =
          VmControllerState.initial(
            vmId: vm.metadata.id,
            specGeneration: 1,
            restartPolicy: RestartPolicy.never,
            appliedIntentRevision: 1,
          ).copyWith(
            desiredState: DesiredState.running,
            phase: VmPhase.starting,
            currentOperation: VmControllerOperation(
              id: start.operationId,
              kind: VmOperationKind.start,
              state: OperationState.running,
            ),
          );
      await SqliteVmStateEffectAdapter(database).persistRuntime(execution);
      final commands = SqliteVmCommandRepository(database);
      final adoptedStart = (await commands.claim(
        owner: 'test',
        lease: const Duration(seconds: 30),
      )).single;
      await commands.acknowledge(adoptedStart);
      registry = VmRegistry(
        repository: SqliteVmRepository(database),
        operations: SqliteOperationRepository(database),
        recovery: SqliteVmIntentRecoveryRepository(database),
        effectRunner: effects,
      );
      final accepted =
          await SqliteVmPatchAcceptor(
            database: database,
            registry: registry,
            idempotencyRetention: const Duration(days: 30),
          ).patch(
            VmPatchCommand(
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
              vmId: vm.metadata.id,
              expectedRevision: 1,
              spec: VmSpecPatch.fromJson({'cpu': 3}),
            ),
          );
      final patchClaim = (await commands.claim(
        owner: 'test',
        lease: const Duration(seconds: 30),
      )).single;
      expect(
        await SqliteVmCommandTarget(
          database: database,
          registry: registry,
          effectRunner: effects,
        ).adopt(patchClaim.record),
        VmIntentAdoptionDisposition.deferred,
      );
      final controller = (await registry.get(vm.metadata.id))!;
      expect(controller.state.specGeneration, 1);
      expect(
        await SqliteVmIntentRecoveryRepository(
          database,
        ).shouldDeferReconciliation(controller.state),
        isFalse,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.pending,
      );
    },
  );

  SqliteVmPatchAcceptor acceptor() => SqliteVmPatchAcceptor(
    database: database,
    registry: registry,
    idempotencyRetention: const Duration(days: 30),
  );
  VmPatchCommand patch({
    String? key,
    int revision = 1,
    String name = 'after',
  }) => VmPatchCommand(
    requestId: RequestId.generate(),
    idempotencyKey: key,
    requestBody: const [123, 125],
    vmId: vm.metadata.id,
    expectedRevision: revision,
    name: name,
  );

  test('a patch cannot commit a missing image reference', () async {
    await expectLater(
      acceptor().patch(
        VmPatchCommand(
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
          vmId: vm.metadata.id,
          expectedRevision: 1,
          spec: VmSpecPatch.fromJson({
            'boot': LinuxKernelBoot(kernelImageId: ImageId.generate()).toJson(),
          }),
        ),
      ),
      throwsA(isA<VmProvisioningImageNotFoundException>()),
    );
    expect(
      (await SqliteVmRepository(
        database,
      ).get(vm.metadata.id))!.status.specGeneration,
      1,
    );
    expect(await SqliteOperationRepository(database).list(), isEmpty);
  });

  for (final role in VmProvisioningImageRole.values)
    test(
      'patch $role references are checked atomically like create provisioning',
      () async {
        final source = await File(
          '${root.path}/image',
        ).writeAsString('disk bytes');
        final store = ImageStore(database, Directory('${root.path}/images'));
        final image = await store.importFile(
          source,
          type: role == VmProvisioningImageRole.rootDisk
              ? ImageType.linuxKernel
              : ImageType.rawDisk,
        );
        final kernel = role == VmProvisioningImageRole.initrd
            ? await store.importFile(source, type: ImageType.linuxKernel)
            : null;
        final changes = switch (role) {
          VmProvisioningImageRole.kernel => {
            'boot': LinuxKernelBoot(kernelImageId: image.id).toJson(),
          },
          VmProvisioningImageRole.initrd => {
            'boot': LinuxKernelBoot(
              kernelImageId: kernel!.id,
              initrdImageId: image.id,
            ).toJson(),
          },
          VmProvisioningImageRole.rootDisk => {
            'disks': [
              VmDisk(
                id: 'root',
                source: ManagedImageDiskSource(image.id),
                writable: true,
              ).toJson(),
            ],
          },
        };
        await expectLater(
          acceptor().patch(
            VmPatchCommand(
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
              vmId: vm.metadata.id,
              expectedRevision: 1,
              spec: VmSpecPatch.fromJson(changes),
            ),
          ),
          throwsFormatException,
        );
        expect(
          (await SqliteVmRepository(
            database,
          ).get(vm.metadata.id))!.status.specGeneration,
          1,
        );
        expect(await SqliteOperationRepository(database).list(), isEmpty);
      },
    );

  test('concurrent stale revisions commit exactly one patch', () async {
    final results = await Future.wait([
      for (final key in ['first', 'second'])
        acceptor()
            .patch(patch(key: key, name: key))
            .then<Object>((value) => value, onError: (Object error) => error),
    ]);
    expect(results.whereType<OperationAcceptance>(), hasLength(1));
    expect(results.whereType<RevisionConflictException>(), hasLength(1));
    expect(await SqliteOperationRepository(database).list(), hasLength(1));
    expect((await registry.get(vm.metadata.id))!.acceptedIntentRevision, 1);
  });

  test(
    'If-Match participates in idempotency and replay needs no live registry',
    () async {
      final command = patch(key: 'once');
      final accepted = await acceptor().patch(command);
      await registry.shutdown();
      expect((await acceptor().patch(command)).toJson(), accepted.toJson());
      await expectLater(
        acceptor().patch(patch(key: 'once', revision: 2)),
        throwsA(isA<IdempotencyConflictException>()),
      );
    },
  );

  test(
    'a failed event commit rolls back the spec operation and queued intent',
    () async {
      await database.read(
        (db) => db.execute(
          "CREATE TRIGGER reject_patch BEFORE INSERT ON events WHEN NEW.type = 'vm.patch_accepted' BEGIN SELECT RAISE(ABORT, 'injected event failure'); END",
        ),
      );
      await expectLater(
        acceptor().patch(patch(key: 'retry')),
        throwsA(isA<Exception>()),
      );
      expect(
        (await SqliteVmRepository(
          database,
        ).get(vm.metadata.id))!.metadata.revision,
        1,
      );
      expect(await SqliteOperationRepository(database).list(), isEmpty);
      expect((await registry.get(vm.metadata.id))!.acceptedIntentRevision, 0);
      expect(
        await SqliteVmCommandRepository(
          database,
        ).claim(owner: 'inspect', lease: const Duration(seconds: 1)),
        isEmpty,
      );
      await database.read((db) => db.execute('DROP TRIGGER reject_patch'));
      expect(
        (await acceptor().patch(patch(key: 'retry'))).state,
        OperationState.pending,
      );
    },
  );

  test(
    'patch preserves the prior lifecycle operation across recovery',
    () async {
      final lifecycle = SqliteVmLifecycleAcceptor(
        database: database,
        registry: registry,
        idempotencyRetention: const Duration(days: 30),
      );
      final stop = await lifecycle.lifecycle(
        VmLifecycleCommand(
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
          vmId: vm.metadata.id,
          action: VmLifecycleAction.stop,
        ),
      );
      final dispatch = VmCommandDispatcher(
        commands: SqliteVmCommandRepository(database),
        target: SqliteVmCommandTarget(
          database: database,
          registry: registry,
          effectRunner: effects,
        ),
        owner: 'patch-test',
      );
      expect(
        (await dispatch.dispatchOnce()).single.status,
        VmCommandDispatchStatus.acknowledged,
      );
      final patch =
          await SqliteVmPatchAcceptor(
            database: database,
            registry: registry,
            idempotencyRetention: const Duration(days: 30),
          ).patch(
            VmPatchCommand(
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
              vmId: vm.metadata.id,
              expectedRevision: 1,
              spec: VmSpecPatch.fromJson({'cpu': 3}),
            ),
          );
      expect(
        (await dispatch.dispatchOnce()).single.status,
        VmCommandDispatchStatus.acknowledged,
      );
      final restored = (await SqliteVmIntentRecoveryRepository(
        database,
      ).restore(vm.metadata.id))!;
      expect(restored.executionState.specGeneration, 2);
      expect(restored.executionState.appliedIntentRevision, 2);
      expect(restored.executionState.currentOperation!.id, stop.operationId);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(patch.operationId))!.state,
        OperationState.succeeded,
      );
    },
  );

  test(
    'patch commits OCC spec and durable intent without running effects',
    () async {
      final command = VmPatchCommand(
        requestId: RequestId.generate(),
        idempotencyKey: 'patch-once',
        requestBody: const [123, 125],
        vmId: vm.metadata.id,
        expectedRevision: 1,
        name: 'after',
        spec: VmSpecPatch.fromJson({'cpu': 3}),
      );
      final acceptor = SqliteVmPatchAcceptor(
        database: database,
        registry: registry,
        idempotencyRetention: const Duration(days: 30),
      );
      final accepted = await acceptor.patch(command);
      expect(accepted.state, OperationState.pending);
      final current = (await SqliteVmRepository(database).get(vm.metadata.id))!;
      expect(current.metadata.name, 'after');
      expect(current.metadata.revision, 2);
      expect(current.spec.cpu, 3);
      expect(current.status.specGeneration, 2);
      final controller = (await registry.get(vm.metadata.id))!;
      expect(controller.state.specGeneration, 1);
      expect(controller.acceptedIntentRevision, 1);
      final commands = await SqliteVmCommandRepository(
        database,
      ).claim(owner: 'test', lease: const Duration(seconds: 30));
      expect(commands.single.record.action, VmCommandAction.patch);
      expect(commands.single.record.operationId, accepted.operationId);
      expect((await acceptor.patch(command)).toJson(), accepted.toJson());
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      final target = SqliteVmCommandTarget(
        database: database,
        registry: registry,
        effectRunner: effects,
      );
      expect(
        await target.adopt(commands.single.record),
        VmIntentAdoptionDisposition.adopted,
      );
      expect(controller.state.specGeneration, 2);
      expect(controller.state.appliedIntentRevision, 1);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
      expect(
        await target.adopt(commands.single.record),
        VmIntentAdoptionDisposition.duplicate,
      );
    },
  );
}

final class _NoRuntime
    implements
        VmLeaseEffectAdapter,
        VmDriverEffectAdapter,
        VmManagedFileEffectAdapter {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected effect: ${invocation.memberName}');
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/tmp/root.raw'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
