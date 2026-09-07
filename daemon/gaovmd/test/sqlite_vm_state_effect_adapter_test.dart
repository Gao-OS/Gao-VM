import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/sqlite_vm_state_effect_adapter.dart';
import 'package:gaovmd/src/vm_controller_reducer.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:test/test.dart';

void main() {
  test(
    'stale execution cannot overwrite accepted desired state or deletion',
    () async {
      await _withPersistence((database, repository, adapter) async {
        await database.transaction((db) {
          db.execute('UPDATE vms SET intent_revision = 2 WHERE id = ?', [
            _vmId.value,
          ]);
          db.execute(
            "UPDATE vm_runtime SET desired_state = 'stopped' WHERE vm_id = ?",
            [_vmId.value],
          );
        });
        final stale =
            VmControllerState.initial(
              vmId: _vmId,
              specGeneration: 1,
              restartPolicy: RestartPolicy.onFailure,
            ).copyWith(
              desiredState: DesiredState.running,
              deletionState: VmDeletionState.deleted,
            );
        await adapter.persistVm(stale);
        final stored = await repository.get(_vmId);
        expect(stored, isNotNull);
        expect(stored!.metadata.revision, 1);
        expect(stored.status.desiredState, DesiredState.stopped);
        final current = stale.copyWith(
          appliedIntentRevision: 2,
          deletionState: VmDeletionState.active,
        );
        await adapter.persistVm(current);
        expect(
          (await repository.get(_vmId))!.status.desiredState,
          DesiredState.running,
        );
      });
    },
  );

  test(
    'runtime observations retain newer spec projection and persist execution checkpoint',
    () async {
      await _withPersistence((database, repository, adapter) async {
        final operationId = OperationId.generate();
        await database.transaction((db) {
          db.execute(
            'UPDATE vms SET intent_revision = 2, spec_generation = 2 WHERE id = ?',
            [_vmId.value],
          );
          db.execute(
            'UPDATE vm_runtime SET restart_required = 1 WHERE vm_id = ?',
            [_vmId.value],
          );
        });
        final oldSpec =
            VmControllerState.initial(
              vmId: _vmId,
              specGeneration: 1,
              restartPolicy: RestartPolicy.onFailure,
              appliedIntentRevision: 1,
            ).copyWith(
              phase: VmPhase.running,
              observedGeneration: 1,
              restartRequired: false,
              currentOperation: VmControllerOperation(
                id: operationId,
                kind: VmOperationKind.start,
                state: OperationState.running,
              ),
            );
        await adapter.persistRuntime(oldSpec);
        await database.read((db) {
          final row = db.select('SELECT * FROM vm_runtime WHERE vm_id = ?', [
            _vmId.value,
          ]).single;
          expect(row['restart_required'], 1);
          expect(row['observed_generation'], 1);
          expect(row['applied_intent_revision'], 1);
          expect(row['active_operation_id'], operationId.value);
        });
        await adapter.persistRuntime(
          oldSpec.copyWith(
            specGeneration: 2,
            observedGeneration: 2,
            appliedIntentRevision: 2,
            clearCurrentOperation: true,
          ),
        );
        await database.read((db) {
          final row = db.select('SELECT * FROM vm_runtime WHERE vm_id = ?', [
            _vmId.value,
          ]).single;
          expect(row['restart_required'], 0);
          expect(row['applied_intent_revision'], 2);
          expect(row['active_operation_id'], isNull);
        });
      });
    },
  );

  test(
    'superseded intent is a normal no-op and does not roll back old outcome events',
    () async {
      await _withPersistence((database, repository, adapter) async {
        await database.transaction(
          (db) => db.execute(
            'UPDATE vms SET intent_revision = 2 WHERE id = ?',
            [_vmId.value],
          ),
        );
        final state = VmControllerState.initial(
          vmId: _vmId,
          specGeneration: 1,
          restartPolicy: RestartPolicy.onFailure,
          appliedIntentRevision: 1,
        ).copyWith(desiredState: DesiredState.running, phase: VmPhase.running);
        final events = SqliteEventRepository(database);
        await database.transaction((_) async {
          await adapter.persistVm(state);
          await adapter.persistRuntime(state);
          await events.append(
            type: 'vm.started',
            resourceType: ResourceType.virtualMachine,
            resourceId: _vmId,
            vmId: _vmId,
            payload: JsonObjectValue.empty,
          );
        });
        expect(
          (await repository.get(_vmId))!.status.desiredState,
          DesiredState.stopped,
        );
        expect((await repository.get(_vmId))!.status.phase, VmPhase.running);
        expect(await events.list(vmId: _vmId), hasLength(1));
        expect(await events.readUnpublishedOutbox(), hasLength(1));
      });
    },
  );

  test(
    'execution checkpoints roll back atomically and missing VMs still fail',
    () async {
      await _withPersistence((database, repository, adapter) async {
        final state =
            VmControllerState.initial(
              vmId: _vmId,
              specGeneration: 1,
              restartPolicy: RestartPolicy.onFailure,
              appliedIntentRevision: 1,
            ).copyWith(
              currentOperation: VmControllerOperation(
                id: OperationId.generate(),
                kind: VmOperationKind.start,
                state: OperationState.running,
              ),
            );
        await expectLater(
          database.transaction((_) async {
            await adapter.persistRuntime(state);
            throw StateError('rollback checkpoint');
          }),
          throwsStateError,
        );
        await database.read((db) {
          final row = db.select(
            'SELECT applied_intent_revision, active_operation_id FROM vm_runtime WHERE vm_id = ?',
            [_vmId.value],
          ).single;
          expect(row['applied_intent_revision'], 0);
          expect(row['active_operation_id'], isNull);
        });
        final missing = VmControllerState.initial(
          vmId: VmId.generate(),
          specGeneration: 1,
          restartPolicy: RestartPolicy.onFailure,
          appliedIntentRevision: 2,
        );
        await expectLater(
          adapter.persistVm(missing),
          throwsA(isA<VmNotFoundException>()),
        );
        await expectLater(
          adapter.persistRuntime(missing),
          throwsA(isA<VmNotFoundException>()),
        );
      });
    },
  );
  test(
    'persists desired/runtime state and participates in outer rollback',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'vm-state-adapter-',
      );
      final database = await GaoVmDatabase.open('${directory.path}/gaovm.db');
      final repository = SqliteVmRepository(
        database,
        newVmId: () => _vmId,
        now: () => _now,
      );
      await repository.create(name: 'vm', spec: _spec);
      final adapter = SqliteVmStateEffectAdapter(
        database,
        now: () => _now.add(const Duration(seconds: 1)),
      );
      final state =
          VmControllerState.initial(
            vmId: _vmId,
            specGeneration: 1,
            restartPolicy: RestartPolicy.onFailure,
          ).copyWith(
            desiredState: DesiredState.running,
            phase: VmPhase.starting,
            driverGeneration: 3,
            activeDriverGeneration: 3,
            activeSpecGeneration: 1,
            observedGeneration: 1,
            restartRequired: true,
            lastError: _error,
          );

      await adapter.persistVm(state);
      await adapter.persistRuntime(state);
      final stored = await repository.get(_vmId);
      expect(stored?.status.desiredState, DesiredState.running);
      expect(stored?.status.phase, VmPhase.starting);
      expect(stored?.status.driverGeneration, 3);
      expect(stored?.status.restartRequired, isTrue);
      expect(stored?.status.lastError, _error);

      await expectLater(
        database.transaction((_) async {
          await adapter.persistVm(
            state.copyWith(desiredState: DesiredState.stopped),
          );
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(
        (await repository.get(_vmId))?.status.desiredState,
        DesiredState.running,
      );

      final deleting = state.copyWith(
        desiredState: DesiredState.stopped,
        phase: VmPhase.deleting,
        deletionState: VmDeletionState.deleting,
      );
      await expectLater(
        database.transaction((_) async {
          await adapter.persistVm(deleting);
          await adapter.persistRuntime(deleting);
          throw StateError('rollback deletion');
        }),
        throwsStateError,
      );
      expect((await repository.get(_vmId))?.metadata.revision, 1);

      await database.transaction((_) async {
        await adapter.persistVm(deleting);
        await adapter.persistRuntime(deleting);
      });
      await adapter.persistVm(deleting);
      final deletingStored = await repository.get(_vmId);
      expect(deletingStored?.metadata.revision, 2);
      expect(deletingStored?.status.phase, VmPhase.deleting);
      expect(await repository.list(), [deletingStored]);

      final deleted = deleting.copyWith(
        phase: VmPhase.deleted,
        deletionState: VmDeletionState.deleted,
      );
      await database.transaction((_) async {
        await adapter.persistVm(deleted);
        await adapter.persistRuntime(deleted);
      });
      await adapter.persistVm(deleted);
      await adapter.persistRuntime(deleted);
      expect(await repository.get(_vmId), isNull);
      expect(await repository.list(), isEmpty);
      final tombstone = await repository.get(_vmId, includeDeleted: true);
      expect(tombstone?.metadata.revision, 3);
      expect(tombstone?.status.phase, VmPhase.deleted);

      database.close();
      await directory.delete(recursive: true);
    },
  );
}

Future<void> _withPersistence(
  Future<void> Function(
    GaoVmDatabase database,
    SqliteVmRepository repository,
    SqliteVmStateEffectAdapter adapter,
  )
  action,
) async {
  final directory = await Directory.systemTemp.createTemp('vm-intent-adapter-');
  final database = await GaoVmDatabase.open('${directory.path}/gaovm.db');
  try {
    final repository = SqliteVmRepository(
      database,
      newVmId: () => _vmId,
      now: () => _now,
    );
    await repository.create(name: 'vm', spec: _spec);
    await action(
      database,
      repository,
      SqliteVmStateEffectAdapter(database, now: () => _now),
    );
  } finally {
    database.close();
    await directory.delete(recursive: true);
  }
}

final _now = DateTime.utc(2026, 9, 5, 3);
final _vmId = VmId('vm_01J00000000000000000000000');
final _error = OperationError(
  code: ErrorCode.driverUnhealthy,
  message: 'driver failed',
  retryable: true,
  details: JsonObjectValue.empty,
);
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
  restartPolicy: RestartPolicy.onFailure,
);
