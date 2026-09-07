import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/sqlite_vm_state_effect_adapter.dart';
import 'package:gaovmd/src/vm_controller_reducer.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:test/test.dart';

void main() {
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
