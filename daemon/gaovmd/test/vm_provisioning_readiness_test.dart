import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteVmRepository repository;
  late SqliteOperationRepository operations;
  late VirtualMachine vm;
  late Operation create;
  late VmRegistry registry;
  late _NoEffects runner;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('provision-ready-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    repository = SqliteVmRepository(database);
    operations = SqliteOperationRepository(database);
    vm = await repository.create(name: 'pending', spec: _spec);
    create = await operations.create(
      type: 'vm.create',
      resourceType: ResourceType.virtualMachine,
      resourceId: vm.metadata.id,
      requestId: RequestId.generate(),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    await database.transaction(
      (db) => db.execute(
        "UPDATE vm_runtime SET phase = 'provisioning' WHERE vm_id = ?",
        [vm.metadata.id.value],
      ),
    );
    runner = _NoEffects();
    registry = VmRegistry(
      repository: repository,
      operations: operations,
      effectRunner: runner,
      recovery: SqliteVmIntentRecoveryRepository(database),
    );
  });
  tearDown(() async {
    await registry.shutdown();
    database.close();
    await directory.delete(recursive: true);
  });

  test(
    'lazy activation rejects unpublished VM without orphaning create',
    () async {
      await expectLater(
        registry.get(vm.metadata.id),
        throwsA(isA<VmProvisioningConflictException>()),
      );
      expect(registry.activeCount, 0);
      expect(runner.effects, isEmpty);
      expect((await operations.get(create.id))!.state, OperationState.pending);
    },
  );

  test(
    'startup skips provisioning while restoring legacy and completed VMs',
    () async {
      final legacy = await repository.create(name: 'legacy', spec: _spec);
      final ready = await repository.create(name: 'ready', spec: _spec);
      await database.transaction(
        (db) => db.execute(
          "UPDATE vm_runtime SET phase = 'stopped' WHERE vm_id = ?",
          [ready.metadata.id.value],
        ),
      );
      final controllers = await registry.reconcileOnStartup();
      expect(
        controllers.map((controller) => controller.state.vmId),
        unorderedEquals([legacy.metadata.id, ready.metadata.id]),
      );
      expect((await operations.get(create.id))!.state, OperationState.pending);
      expect(
        runner.effects.where((effect) => effect.$1 == vm.metadata.id),
        isEmpty,
      );
    },
  );

  test('repository writes preserve the pinned spec and revision', () async {
    await expectLater(
      repository.patch(vm.metadata.id, expectedRevision: 1, name: 'changed'),
      throwsA(isA<VmProvisioningConflictException>()),
    );
    await expectLater(
      repository.updateSpec(vm.metadata.id, expectedRevision: 1, spec: _spec),
      throwsA(isA<VmProvisioningConflictException>()),
    );
    final stored = (await repository.get(vm.metadata.id))!;
    expect(stored.metadata.revision, 1);
    expect(stored.metadata.name, 'pending');
    expect(stored.status.specGeneration, 1);
  });

  test(
    'lifecycle acceptance checks durable phase even with stale controller state',
    () async {
      final eventsBefore = await SqliteEventRepository(database).list();
      for (final action in VmLifecycleAction.values) {
        await expectLater(
          SqliteVmLifecycleAcceptance(
            database: database,
            idempotencyRetention: const Duration(days: 1),
            command: VmLifecycleCommand(
              requestId: RequestId.generate(),
              idempotencyKey: action.name,
              requestBody: const [],
              vmId: vm.metadata.id,
              action: action,
            ),
          ).commit(
            VmControllerState.initial(
              vmId: vm.metadata.id,
              specGeneration: 1,
              restartPolicy: RestartPolicy.never,
            ),
          ),
          throwsA(isA<VmProvisioningConflictException>()),
        );
      }
      expect(await operations.list(), hasLength(1));
      expect(
        await SqliteEventRepository(database).list(),
        hasLength(eventsBefore.length),
      );
      await database.read((db) {
        expect(
          db
              .select('SELECT intent_revision FROM vms')
              .single['intent_revision'],
          0,
        );
        expect(
          db.select("SELECT * FROM outbox WHERE topic = 'vm.commands'"),
          isEmpty,
        );
        expect(db.select('SELECT * FROM idempotency_keys'), isEmpty);
      });
      expect(
        (await repository.get(vm.metadata.id))!.status.desiredState,
        DesiredState.stopped,
      );
    },
  );
}

final class _NoEffects implements VmEffectRunner {
  final List<(VmId, VmEffect)> effects = [];
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    effects.add((state.vmId, effect));
    return null;
  }
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
