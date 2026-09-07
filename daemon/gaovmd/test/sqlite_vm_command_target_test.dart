import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteVmRepository vms;
  late SqliteOperationRepository operations;
  late SqliteVmCommandRepository commands;
  late RepositoryVmEffectRunner runner;
  late VmRegistry registry;
  late _Adapters adapters;
  late DateTime now;

  VmRegistry openRegistry() => VmRegistry(
    repository: vms,
    operations: operations,
    effectRunner: runner,
    recovery: SqliteVmIntentRecoveryRepository(database),
  );
  SqliteVmCommandTarget target() => SqliteVmCommandTarget(
    database: database,
    registry: registry,
    effectRunner: runner,
  );
  VmCommandDispatcher dispatcher() => VmCommandDispatcher(
    commands: commands,
    target: target(),
    owner: 'worker',
  );

  Future<void> openCatalog() async {
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    vms = SqliteVmRepository(database);
    operations = SqliteOperationRepository(database);
    commands = SqliteVmCommandRepository(database, now: () => now);
    runner = RepositoryVmEffectRunner(
      database: database,
      operations: operations,
      events: SqliteEventRepository(database),
      persistence: SqliteVmStateEffectAdapter(database),
      leases: adapters,
      drivers: adapters,
      managedFiles: adapters,
    );
    registry = openRegistry();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('command-target-');
    now = DateTime.utc(2026, 9, 7);
    adapters = _Adapters();
    await openCatalog();
  });
  tearDown(() async {
    await registry.shutdown();
    database.close();
    await directory.delete(recursive: true);
  });

  Future<OperationAcceptance> accept(
    VmId vmId,
    VmLifecycleAction action,
  ) async => (await registry.get(vmId))!.accept(
    SqliteVmLifecycleAcceptance(
      database: database,
      idempotencyRetention: const Duration(days: 1),
      command: VmLifecycleCommand(
        vmId: vmId,
        action: action,
        requestId: RequestId.generate(),
        idempotencyKey: null,
        requestBody: const [],
      ),
    ),
  );

  test(
    'restart redelivery acknowledges committed intent without activation',
    () async {
      final vm = await vms.create(name: 'restart', spec: _spec);
      final accepted = await accept(vm.metadata.id, VmLifecycleAction.stop);
      final claim = (await commands.claim(
        owner: 'crashed',
        lease: const Duration(seconds: 30),
      )).single;
      expect(
        await target().adopt(claim.record),
        VmIntentAdoptionDisposition.adopted,
      );
      await registry.shutdown();
      database.close();
      await openCatalog();
      now = now.add(const Duration(minutes: 1));
      expect(
        (await dispatcher().dispatchOnce()).single.status,
        VmCommandDispatchStatus.acknowledged,
      );
      expect(registry.activeCount, 0);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
      expect(await dispatcher().dispatchOnce(), isEmpty);
    },
  );

  test('completed delete redelivery does not repeat managed cleanup', () async {
    final vm = await vms.create(name: 'delete', spec: _spec);
    final accepted = await accept(vm.metadata.id, VmLifecycleAction.delete);
    final controller = (await registry.get(vm.metadata.id))!;
    final claim = (await commands.claim(
      owner: 'crashed',
      lease: const Duration(seconds: 30),
    )).single;
    expect(
      await target().adopt(claim.record),
      VmIntentAdoptionDisposition.adopted,
    );
    await controller.waitUntilIdle();
    expect(
      (await operations.get(accepted.operationId))!.state,
      OperationState.succeeded,
    );
    expect(await vms.get(vm.metadata.id), isNull);
    expect(adapters.removals, 1);
    await registry.shutdown();
    database.close();
    await openCatalog();
    now = now.add(const Duration(minutes: 1));
    expect(
      (await dispatcher().dispatchOnce()).single.status,
      VmCommandDispatchStatus.acknowledged,
    );
    expect(registry.activeCount, 0);
    expect(adapters.removals, 1);
  });

  test(
    'reconcile retires controllers deleted through durable delivery',
    () async {
      final vm = await vms.create(name: 'retire', spec: _spec);
      await accept(vm.metadata.id, VmLifecycleAction.delete);
      final controller = (await registry.get(vm.metadata.id))!;
      expect(
        (await dispatcher().dispatchOnce()).single.status,
        VmCommandDispatchStatus.acknowledged,
      );
      await controller.waitUntilIdle();
      expect(await vms.get(vm.metadata.id), isNull);
      await registry.reconcileOnStartup();
      expect(registry.activeCount, 0);
      expect(controller.isAccepting, isFalse);
    },
  );

  test('dispatch commits and acknowledges one FIFO head for each VM', () async {
    final a = await vms.create(name: 'a', spec: _spec);
    final b = await vms.create(name: 'b', spec: _spec);
    final a1 = await accept(a.metadata.id, VmLifecycleAction.stop);
    final a2 = await accept(a.metadata.id, VmLifecycleAction.stop);
    final b1 = await accept(b.metadata.id, VmLifecycleAction.stop);
    final first = await dispatcher().dispatchOnce();
    expect(first, hasLength(2));
    expect(
      first.map((item) => item.status),
      everyElement(VmCommandDispatchStatus.acknowledged),
    );
    expect(
      (await operations.get(a1.operationId))!.state,
      OperationState.succeeded,
    );
    expect(
      (await operations.get(b1.operationId))!.state,
      OperationState.succeeded,
    );
    expect(
      (await operations.get(a2.operationId))!.state,
      OperationState.pending,
    );
    expect(
      await SqliteVmIntentRecoveryRepository(
        database,
      ).hasUnpublishedCommands(a.metadata.id),
      isTrue,
    );
    final second = await dispatcher().dispatchOnce();
    expect(second.single.status, VmCommandDispatchStatus.acknowledged);
    expect(
      (await operations.get(a2.operationId))!.state,
      OperationState.succeeded,
    );
    expect(await dispatcher().dispatchOnce(), isEmpty);
  });
}

final class _Adapters
    implements
        VmLeaseEffectAdapter,
        VmDriverEffectAdapter,
        VmManagedFileEffectAdapter {
  int removals = 0;
  @override
  Future<void> remove(VmControllerState state, OperationId operationId) async {
    removals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected runtime effect');
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
