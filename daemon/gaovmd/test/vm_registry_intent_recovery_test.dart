import 'dart:io';
import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late VirtualMachine vm;
  late VmController accepting;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vm-intent-recovery-');
    database = await GaoVmDatabase.open('${directory.path}/db');
    vm = await SqliteVmRepository(
      database,
    ).create(name: 'recovery', spec: _spec);
    accepting = VmController(
      initialState: VmControllerState.initial(
        vmId: vm.metadata.id,
        specGeneration: 1,
        restartPolicy: RestartPolicy.never,
      ),
      effectRunner: _NoEffects(),
    );
  });
  tearDown(() async {
    await accepting.shutdown();
    database.close();
    await directory.delete(recursive: true);
  });
  Future<OperationId> accept(VmLifecycleAction action) async =>
      (await accepting.accept(
        SqliteVmLifecycleAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 1),
          command: VmLifecycleCommand(
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
            vmId: vm.metadata.id,
            action: action,
          ),
        ),
      )).operationId;

  test(
    'startup preserves accepted start then stop and leaves dispatch FIFO untouched',
    () async {
      final start = await accept(VmLifecycleAction.start);
      final stop = await accept(VmLifecycleAction.stop);
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/db');
      final runner = _NoEffects();
      final registry = VmRegistry(
        repository: SqliteVmRepository(database),
        operations: SqliteOperationRepository(database),
        effectRunner: runner,
        recovery: SqliteVmIntentRecoveryRepository(database),
      );
      try {
        final controller = (await registry.reconcileOnStartup()).single;
        expect(controller.acceptedIntentRevision, 2);
        expect(controller.state.appliedIntentRevision, 0);
        expect(controller.state.desiredState, DesiredState.stopped);
        expect(controller.state.currentOperation, isNull);
        expect(runner.effects, isEmpty);
        expect(
          (await SqliteOperationRepository(database).get(start))!.state,
          OperationState.pending,
        );
        expect(
          (await SqliteOperationRepository(database).get(stop))!.state,
          OperationState.pending,
        );
        final commands = SqliteVmCommandRepository(database);
        final head = (await commands.claim(
          owner: 'test',
          lease: const Duration(seconds: 10),
        )).single;
        expect(head.record.operationId, start);
        expect(await commands.release(head), isTrue);
        expect(
          (await commands.claim(
            owner: 'test',
            lease: const Duration(seconds: 10),
          )).single.record.operationId,
          start,
        );
      } finally {
        await registry.shutdown();
      }
    },
  );

  test(
    'active start restores its pinned spec and desired target behind a newer stop',
    () async {
      final start = await accept(VmLifecycleAction.start);
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
              id: start,
              kind: VmOperationKind.start,
              state: OperationState.running,
            ),
            driverGeneration: 1,
            activeDriverGeneration: 1,
            activeSpecGeneration: 1,
            driverOperationId: start,
          );
      await SqliteVmStateEffectAdapter(database).persistRuntime(execution);
      await accepting.shutdown();
      accepting = VmController(
        initialState: execution,
        effectRunner: _NoEffects(),
      );
      final updatedSpec = VmSpec.fromJson({
        ..._spec.toJson(),
        'cpu': 4,
        'restart_policy': 'always',
      });
      await SqliteVmRepository(
        database,
      ).updateSpec(vm.metadata.id, expectedRevision: 1, spec: updatedSpec);
      final stop = await accept(VmLifecycleAction.stop);
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/db');
      final registry = VmRegistry(
        repository: SqliteVmRepository(database),
        operations: SqliteOperationRepository(database),
        effectRunner: _NoEffects(),
        recovery: SqliteVmIntentRecoveryRepository(database),
      );
      try {
        final restored = (await registry.reconcileOnStartup()).single;
        expect(restored.acceptedIntentRevision, 2);
        expect(restored.state.appliedIntentRevision, 1);
        expect(restored.state.currentOperation!.id, start);
        expect(restored.state.specGeneration, 1);
        expect(restored.state.restartPolicy, RestartPolicy.never);
        expect(restored.state.desiredState, DesiredState.running);
        await SqliteVmStateEffectAdapter(database).persistVm(restored.state);
        expect(
          (await SqliteVmRepository(
            database,
          ).get(vm.metadata.id))!.status.desiredState,
          DesiredState.stopped,
        );
        expect(
          (await SqliteOperationRepository(database).get(start))!.state,
          OperationState.pending,
        );
        expect(
          (await SqliteOperationRepository(database).get(stop))!.state,
          OperationState.pending,
        );
      } finally {
        await registry.shutdown();
      }
    },
  );

  test(
    'recovery rejects an active operation belonging to a queued later intent',
    () async {
      final start = await accept(VmLifecycleAction.start);
      final stop = await accept(VmLifecycleAction.stop);
      await database.transaction(
        (db) => db.execute(
          'UPDATE vm_runtime SET applied_intent_revision = 1, active_operation_id = ? WHERE vm_id = ?',
          [stop.value, vm.metadata.id.value],
        ),
      );
      await expectLater(
        SqliteVmIntentRecoveryRepository(database).restore(vm.metadata.id),
        throwsStateError,
      );
      expect(
        (await SqliteOperationRepository(database).get(start))!.state,
        OperationState.pending,
      );
      expect(
        (await SqliteOperationRepository(database).get(stop))!.state,
        OperationState.pending,
      );
    },
  );

  test(
    'recovery rejects cross-VM operation correlation without changing either operation',
    () async {
      final start = await accept(VmLifecycleAction.start);
      final otherVm = await SqliteVmRepository(
        database,
      ).create(name: 'other', spec: _spec);
      final otherOperation = await SqliteOperationRepository(database).create(
        type: 'vm.start',
        resourceType: ResourceType.virtualMachine,
        resourceId: otherVm.metadata.id,
        requestId: RequestId.generate(),
        cancellable: true,
        request: JsonObjectValue.empty,
      );
      await database.transaction(
        (db) => db.execute(
          'UPDATE vm_runtime SET applied_intent_revision = 1, active_operation_id = ? WHERE vm_id = ?',
          [otherOperation.id.value, vm.metadata.id.value],
        ),
      );
      await expectLater(
        SqliteVmIntentRecoveryRepository(database).restore(vm.metadata.id),
        throwsStateError,
      );
      expect(
        (await SqliteOperationRepository(database).get(start))!.state,
        OperationState.pending,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(otherOperation.id))!.state,
        OperationState.pending,
      );
    },
  );

  test(
    'recovery rejects an action target that contradicts its command',
    () async {
      await accept(VmLifecycleAction.start);
      await database.transaction((db) {
        final row = db.select(
          'SELECT id, payload_json FROM outbox WHERE topic = ?',
          [vmCommandOutboxTopic],
        ).single;
        final json =
            jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
        (json['payload'] as Map)['desired_state'] = 'stopped';
        db.execute('UPDATE outbox SET payload_json = ? WHERE id = ?', [
          jsonEncode(json),
          row['id'],
        ]);
      });
      await expectLater(
        SqliteVmIntentRecoveryRepository(database).restore(vm.metadata.id),
        throwsFormatException,
      );
    },
  );

  test(
    'missing applied history fails closed instead of selecting latest desired state',
    () async {
      await accept(VmLifecycleAction.start);
      await accept(VmLifecycleAction.stop);
      await database.transaction((db) {
        db.execute(
          'DELETE FROM outbox WHERE topic = ? AND id = (SELECT MIN(id) FROM outbox WHERE topic = ?)',
          [vmCommandOutboxTopic, vmCommandOutboxTopic],
        );
      });
      await expectLater(
        SqliteVmIntentRecoveryRepository(database).restore(vm.metadata.id),
        throwsFormatException,
      );
    },
  );

  test(
    'first accepted stop recovers a running legacy baseline from its execution snapshot',
    () async {
      await accepting.shutdown();
      final baseline =
          VmControllerState.initial(
            vmId: vm.metadata.id,
            specGeneration: 1,
            restartPolicy: RestartPolicy.never,
          ).copyWith(
            desiredState: DesiredState.running,
            phase: VmPhase.running,
            driverGeneration: 3,
            observedGeneration: 1,
          );
      await SqliteVmStateEffectAdapter(database).persistVm(baseline);
      await SqliteVmStateEffectAdapter(database).persistRuntime(baseline);
      accepting = VmController(
        initialState: baseline,
        effectRunner: _NoEffects(),
      );
      await accept(VmLifecycleAction.stop);
      final recovered = (await SqliteVmIntentRecoveryRepository(
        database,
      ).restore(vm.metadata.id))!;
      expect(recovered.executionState.desiredState, DesiredState.running);
      expect(recovered.executionState.appliedIntentRevision, 0);
      expect(recovered.executionState.driverGeneration, 3);
      expect(recovered.acceptedIntentRevision, 1);
      expect(
        (await SqliteVmRepository(
          database,
        ).get(vm.metadata.id))!.status.desiredState,
        DesiredState.stopped,
      );
    },
  );

  test(
    'SQLite VMs without accepted commands retain legacy registry activation',
    () async {
      expect(
        await SqliteVmIntentRecoveryRepository(
          database,
        ).restore(vm.metadata.id),
        isNull,
      );
      final registry = VmRegistry(
        repository: SqliteVmRepository(database),
        operations: SqliteOperationRepository(database),
        effectRunner: _NoEffects(),
        recovery: SqliteVmIntentRecoveryRepository(database),
      );
      try {
        final controller = (await registry.reconcileOnStartup()).single;
        expect(controller.state.vmId, vm.metadata.id);
        expect(controller.state.appliedIntentRevision, 0);
        expect(controller.acceptedIntentRevision, 0);
      } finally {
        await registry.shutdown();
      }
    },
  );
  test(
    'same registry resumes reconciliation after its backlog is acknowledged',
    () async {
      await accept(VmLifecycleAction.start);
      await accept(VmLifecycleAction.stop);
      // Simulate durable adoption preceding transport acknowledgement. The
      // restored actor and database already agree on the executed revision.
      await SqliteVmStateEffectAdapter(database).persistRuntime(
        VmControllerState.initial(
          vmId: vm.metadata.id,
          specGeneration: 1,
          restartPolicy: RestartPolicy.never,
          appliedIntentRevision: 2,
        ).copyWith(phase: VmPhase.starting),
      );
      final runner = _NoEffects();
      final registry = VmRegistry(
        repository: SqliteVmRepository(database),
        operations: SqliteOperationRepository(database),
        effectRunner: runner,
        recovery: SqliteVmIntentRecoveryRepository(database),
      );
      try {
        final controller = (await registry.reconcileOnStartup()).single;
        expect(runner.effects, isEmpty);
        final commands = SqliteVmCommandRepository(database);
        for (var i = 0; i < 2; i++) {
          final claim = (await commands.claim(
            owner: 'dispatcher',
            lease: const Duration(seconds: 10),
          )).single;
          expect(await commands.acknowledge(claim), isTrue);
        }
        expect((await registry.reconcileOnStartup()).single, same(controller));
        expect(runner.effects.whereType<PersistRuntime>(), isNotEmpty);
        expect(controller.state.phase, VmPhase.stopped);
      } finally {
        await registry.shutdown();
      }
    },
  );

  test(
    'independent delete recovery is accepted only for an applied delete intent',
    () async {
      final original = await accept(VmLifecycleAction.delete);
      final recovery = await SqliteOperationRepository(database).create(
        type: 'vm.delete.recovery',
        resourceType: ResourceType.virtualMachine,
        resourceId: vm.metadata.id,
        requestId: RequestId.generate(),
        cancellable: false,
        request: JsonObjectValue.fromJson({'recovery': true}),
      );
      await database.transaction(
        (db) => db.execute(
          'UPDATE vm_runtime SET applied_intent_revision = 1, active_operation_id = ? WHERE vm_id = ?',
          [recovery.id.value, vm.metadata.id.value],
        ),
      );
      final snapshot = (await SqliteVmIntentRecoveryRepository(
        database,
      ).restore(vm.metadata.id))!;
      expect(snapshot.executionState.currentOperation!.id, recovery.id);
      expect(
        snapshot.executionState.currentOperation!.kind,
        VmOperationKind.delete,
      );
      expect(snapshot.executionState.deletionState, VmDeletionState.deleting);
      expect(
        (await SqliteOperationRepository(database).get(original))!.state,
        OperationState.pending,
      );
    },
  );

  test(
    'published work beyond applied checkpoint fails closed on restore and live recheck',
    () async {
      await accept(VmLifecycleAction.start);
      final commands = SqliteVmCommandRepository(database);
      final claim = (await commands.claim(
        owner: 'invalid-dispatcher',
        lease: const Duration(seconds: 10),
      )).single;
      expect(await commands.acknowledge(claim), isTrue);
      final recovery = SqliteVmIntentRecoveryRepository(database);
      await expectLater(recovery.restore(vm.metadata.id), throwsStateError);
      await expectLater(
        recovery.hasUnpublishedCommands(vm.metadata.id),
        throwsStateError,
      );
    },
  );

  test('delete recovery cannot substitute for an applied start intent', () async {
    await accept(VmLifecycleAction.start);
    final recovery = await SqliteOperationRepository(database).create(
      type: 'vm.delete.recovery',
      resourceType: ResourceType.virtualMachine,
      resourceId: vm.metadata.id,
      requestId: RequestId.generate(),
      cancellable: false,
      request: JsonObjectValue.fromJson({'recovery': true}),
    );
    await database.transaction(
      (db) => db.execute(
        'UPDATE vm_runtime SET applied_intent_revision = 1, active_operation_id = ? WHERE vm_id = ?',
        [recovery.id.value, vm.metadata.id.value],
      ),
    );
    await expectLater(
      SqliteVmIntentRecoveryRepository(database).restore(vm.metadata.id),
      throwsStateError,
    );
  });
}

final class _NoEffects implements VmEffectRunner {
  final List<VmEffect> effects = [];
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    effects.add(effect);
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
      source: ExternalDiskSource('/private/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
