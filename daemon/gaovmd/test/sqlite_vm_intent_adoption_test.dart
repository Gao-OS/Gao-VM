import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late VirtualMachine vm;
  late VmController controller;
  late _ExternalProbe external;
  late RepositoryVmEffectRunner durable;
  late SqliteOperationRepository operations;
  late SqliteVmCommandRepository commands;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('intent-adopt-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    vm = await SqliteVmRepository(database).create(name: 'adopt', spec: _spec);
    operations = SqliteOperationRepository(database);
    commands = SqliteVmCommandRepository(database);
    final unused = _UnusedAdapters();
    durable = RepositoryVmEffectRunner(
      database: database,
      operations: operations,
      events: SqliteEventRepository(database),
      persistence: SqliteVmStateEffectAdapter(database),
      leases: unused,
      drivers: unused,
      managedFiles: unused,
    );
    external = _ExternalProbe();
    controller = VmController(
      initialState: VmControllerState.initial(
        vmId: vm.metadata.id,
        specGeneration: 1,
        restartPolicy: RestartPolicy.never,
      ),
      effectRunner: external,
    );
  });
  tearDown(() async {
    await controller.shutdown();
    database.close();
    await directory.delete(recursive: true);
  });

  Future<OperationAcceptance> accept(VmLifecycleAction action) =>
      controller.accept(
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
      );
  Future<VmCommandClaim> claim() async => (await commands.claim(
    owner: 'worker',
    lease: const Duration(seconds: 30),
  )).single;
  Future<VmIntentAdoptionDisposition> adopt(VmCommandClaim claimed) =>
      controller.adopt(
        SqliteVmIntentAdoption(
          database: database,
          record: claimed.record,
          effectRunner: durable,
        ),
      );

  Future<void> installExecution(VmControllerState state) async {
    await controller.shutdown();
    await database.transaction((_) async {
      final persistence = SqliteVmStateEffectAdapter(database);
      await persistence.persistVm(state);
      await persistence.persistRuntime(state);
    });
    external.effects.clear();
    controller = VmController(initialState: state, effectRunner: external);
  }

  test(
    'running no-op start checkpoints its operation without replacing the live driver identity',
    () async {
      final original = await accept(VmLifecycleAction.start);
      final first = await claim();
      expect(await adopt(first), VmIntentAdoptionDisposition.adopted);
      await controller.waitUntilIdle();
      expect(await commands.acknowledge(first), isTrue);
      await operations.succeed(original.operationId);
      await installExecution(
        controller.state.copyWith(
          phase: VmPhase.running,
          driverGeneration: 1,
          activeDriverGeneration: 1,
          activeSpecGeneration: 1,
          observedGeneration: 1,
          driverOperationId: original.operationId,
          leaseState: VmLeaseState.held,
          currentOperation: VmControllerOperation(
            id: original.operationId,
            kind: VmOperationKind.start,
            state: OperationState.succeeded,
          ),
        ),
      );
      final catalog = (await SqliteVmRepository(database).get(vm.metadata.id))!;
      await SqliteVmRepository(database).updateSpec(
        vm.metadata.id,
        expectedRevision: catalog.metadata.revision,
        spec: VmSpec.fromJson({..._spec.toJson(), 'cpu': 4}),
      );
      final noOp = await accept(VmLifecycleAction.start);
      final second = await claim();
      expect(await adopt(second), VmIntentAdoptionDisposition.adopted);
      await controller.waitUntilIdle();
      expect(controller.state.activeDriverGeneration, 1);
      expect(controller.state.activeSpecGeneration, 1);
      expect(controller.state.driverOperationId, original.operationId);
      expect(controller.state.specGeneration, 2);
      expect(controller.state.observedGeneration, 1);
      expect(controller.state.restartRequired, isTrue);
      expect(controller.state.appliedIntentRevision, 2);
      expect(controller.state.currentOperation!.id, noOp.operationId);
      expect(
        controller.state.currentOperation!.state,
        OperationState.succeeded,
      );
      expect(
        (await operations.get(noOp.operationId))!.state,
        OperationState.succeeded,
      );
      expect(external.effects, isEmpty);
      expect(await commands.acknowledge(second), isTrue);
      final restored = (await SqliteVmIntentRecoveryRepository(
        database,
      ).restore(vm.metadata.id))!;
      expect(restored.executionState.appliedIntentRevision, 2);
      expect(restored.executionState.currentOperation!.id, noOp.operationId);
      expect(
        restored.executionState.currentOperation!.state,
        OperationState.succeeded,
      );
      expect(restored.executionState.desiredState, DesiredState.running);
      expect(restored.executionState.specGeneration, 2);
      expect(restored.executionState.observedGeneration, 1);
      expect(restored.executionState.restartRequired, isTrue);
    },
  );

  test(
    'retry stop commits checkpoint and supersession before its leading timer effect',
    () async {
      final original = await accept(VmLifecycleAction.start);
      final first = await claim();
      expect(await adopt(first), VmIntentAdoptionDisposition.adopted);
      await controller.waitUntilIdle();
      expect(await commands.acknowledge(first), isTrue);
      await installExecution(
        controller.state.copyWith(
          phase: VmPhase.crashed,
          leaseState: VmLeaseState.none,
          driverGeneration: 1,
          retryState: VmRetryState(
            attempts: 1,
            scheduledDelay: const Duration(seconds: 1),
          ),
        ),
      );
      final stopped = await accept(VmLifecycleAction.stop);
      final claimed = await claim();
      final before = controller.state;
      // Inspect the database-only prefix before the controller is allowed to
      // install the returned state or execute the deferred CancelRetry effect.
      final adoption = await SqliteVmIntentAdoption(
        database: database,
        record: claimed.record,
        effectRunner: durable,
      ).commit(before);
      expect(adoption.disposition, VmIntentAdoptionDisposition.adopted);
      expect(adoption.remainingEffects, [isA<CancelRetry>()]);
      expect(controller.state, same(before));
      expect(controller.state.retryState.retryScheduled, isTrue);
      expect(external.effects, isEmpty);
      expect(adoption.state.appliedIntentRevision, 2);
      expect(adoption.state.retryState.retryScheduled, isFalse);
      expect(
        (await operations.get(original.operationId))!.state,
        OperationState.failed,
      );
      final superseded = (await operations.get(original.operationId))!;
      expect(superseded.error!.code, ErrorCode.vmOperationConflict);
      expect(superseded.error!.message, contains('superseded'));
      expect(
        (await operations.get(stopped.operationId))!.state,
        OperationState.succeeded,
      );
      final restored = (await SqliteVmIntentRecoveryRepository(
        database,
      ).restore(vm.metadata.id))!;
      expect(restored.executionState.appliedIntentRevision, 2);
      expect(restored.executionState.currentOperation!.id, stopped.operationId);
      expect(
        restored.executionState.currentOperation!.state,
        OperationState.succeeded,
      );
      expect(restored.executionState.desiredState, DesiredState.stopped);
      expect(restored.executionState.phase, VmPhase.stopped);
    },
  );

  test(
    'adoption commits execution and operation before external effects',
    () async {
      final accepted = await accept(VmLifecycleAction.start);
      final claimed = await claim();
      expect(await adopt(claimed), VmIntentAdoptionDisposition.adopted);
      await controller.waitUntilIdle();
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.running,
      );
      final recovered = await SqliteVmIntentRecoveryRepository(
        database,
      ).restore(vm.metadata.id);
      expect(recovered!.executionState.appliedIntentRevision, 1);
      expect(
        recovered.executionState.currentOperation!.id,
        accepted.operationId,
      );
      expect(recovered.executionState.desiredState, DesiredState.running);
      expect(external.effects, [isA<AcquireHostLease>()]);
      expect(await commands.acknowledge(claimed), isTrue);
      expect(await adopt(claimed), VmIntentAdoptionDisposition.duplicate);
      expect(external.effects, hasLength(1));
    },
  );
  test(
    'failed adoption transaction leaves a pending command retryable',
    () async {
      final accepted = await accept(VmLifecycleAction.start);
      final claimed = await claim();
      final initial = controller.state;
      await database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER reject_adoption BEFORE INSERT ON events
      WHEN NEW.type = 'vm.command_adopted'
      BEGIN SELECT RAISE(ABORT, 'injected adoption failure'); END
    '''),
      );
      await expectLater(adopt(claimed), throwsA(anything));
      expect(identical(controller.state, initial), isTrue);
      expect(external.effects, isEmpty);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await SqliteVmIntentRecoveryRepository(
          database,
        ).restore(vm.metadata.id))!.executionState.appliedIntentRevision,
        0,
      );
      await database.transaction(
        (db) => db.execute('DROP TRIGGER reject_adoption'),
      );
      expect(await adopt(claimed), VmIntentAdoptionDisposition.adopted);
    },
  );
  test(
    'successive no-op stops checkpoint their own terminal operation',
    () async {
      for (var revision = 1; revision <= 2; revision++) {
        final accepted = await accept(VmLifecycleAction.stop);
        final claimed = await claim();
        expect(await adopt(claimed), VmIntentAdoptionDisposition.adopted);
        expect(
          (await operations.get(accepted.operationId))!.state,
          OperationState.succeeded,
        );
        final restored = await SqliteVmIntentRecoveryRepository(
          database,
        ).restore(vm.metadata.id);
        expect(restored!.executionState.appliedIntentRevision, revision);
        expect(
          restored.executionState.currentOperation!.id,
          accepted.operationId,
        );
        expect(
          restored.executionState.currentOperation!.state,
          OperationState.succeeded,
        );
        expect(await commands.acknowledge(claimed), isTrue);
      }
      expect(external.effects, isEmpty);
    },
  );
  test(
    'cancelled queued start preserves actual desired state and spec',
    () async {
      await SqliteVmRepository(database).updateSpec(
        vm.metadata.id,
        expectedRevision: vm.metadata.revision,
        spec: VmSpec.fromJson({..._spec.toJson(), 'cpu': 4}),
      );
      final cancelled = await accept(VmLifecycleAction.start);
      await operations.cancel(cancelled.operationId);
      final later = await accept(VmLifecycleAction.start);
      final claimed = await claim();
      expect(await adopt(claimed), VmIntentAdoptionDisposition.adopted);
      final restored = await SqliteVmIntentRecoveryRepository(
        database,
      ).restore(vm.metadata.id);
      expect(restored!.acceptedIntentRevision, 2);
      expect(restored.executionState.appliedIntentRevision, 1);
      expect(restored.executionState.desiredState, DesiredState.stopped);
      expect(restored.executionState.specGeneration, 1);
      expect(
        restored.executionState.currentOperation!.state,
        OperationState.cancelled,
      );
      expect(
        (await operations.get(later.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await SqliteVmRepository(
          database,
        ).get(vm.metadata.id))!.status.desiredState,
        DesiredState.running,
      );
      expect(external.effects, isEmpty);
      expect(await commands.acknowledge(claimed), isTrue);
      expect(await adopt(await claim()), VmIntentAdoptionDisposition.adopted);
      expect(controller.state.specGeneration, 2);
    },
  );
  test(
    'duplicate proof rejects a checkpoint newer than accepted intent',
    () async {
      await accept(VmLifecycleAction.stop);
      final claimed = await claim();
      final impossible = controller.state.copyWith(appliedIntentRevision: 2);
      await controller.shutdown();
      controller = VmController(
        initialState: impossible,
        effectRunner: external,
      );
      await database.transaction(
        (db) => db.execute(
          'UPDATE vm_runtime SET applied_intent_revision = 2 WHERE vm_id = ?',
          [vm.metadata.id.value],
        ),
      );
      await expectLater(adopt(claimed), throwsStateError);
    },
  );
  test(
    'queued adoption rejects caller transaction without waiting on its lock',
    () async {
      await accept(VmLifecycleAction.start);
      await accept(VmLifecycleAction.stop);
      final first = await claim();
      final release = Completer<void>();
      external.effectStarted = Completer<void>();
      external.waitForEffect = release.future;
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      expect(await adopt(first), VmIntentAdoptionDisposition.adopted);
      await external.effectStarted!.future;
      expect(await commands.acknowledge(first), isTrue);
      final second = await claim();
      await database.transaction((_) async {
        final rejected = expectLater(adopt(second), throwsStateError);
        release.complete();
        await rejected.timeout(const Duration(seconds: 2));
      });
      expect(controller.state.appliedIntentRevision, 1);
      expect(
        (await operations.get(second.record.operationId))!.state,
        OperationState.pending,
      );
    },
  );
}

final class _ExternalProbe implements VmEffectRunner {
  final effects = <VmEffect>[];
  Completer<void>? effectStarted;
  Future<void>? waitForEffect;
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    effects.add(effect);
    if (effect is AcquireHostLease) {
      effectStarted?.complete();
      await waitForEffect;
    }
    return null;
  }
}

final class _UnusedAdapters
    implements
        VmLeaseEffectAdapter,
        VmDriverEffectAdapter,
        VmManagedFileEffectAdapter {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('external effect executed inside adoption');
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
