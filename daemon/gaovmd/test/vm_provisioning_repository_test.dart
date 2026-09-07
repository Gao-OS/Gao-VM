import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_provisioning_plan.dart';
import 'package:gaovmd/src/vm_provisioning_repository.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  SqliteVmProvisioningRepository jobs() =>
      SqliteVmProvisioningRepository(database);
  SqliteOperationRepository operations() => SqliteOperationRepository(database);
  SqliteEventRepository events() => SqliteEventRepository(database);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('provision-jobs-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
  });
  tearDown(() async {
    database.close();
    await directory.delete(recursive: true);
  });
  Future<VmProvisioningPlan> plan() async {
    final vm = await SqliteVmRepository(
      database,
    ).create(name: 'job', spec: _spec);
    final operation = await operations().create(
      type: 'vm.create',
      resourceType: ResourceType.virtualMachine,
      resourceId: vm.metadata.id,
      requestId: RequestId.generate(),
      cancellable: true,
      request: JsonObjectValue.fromJson({'spec_generation': 1}),
    );
    return SqliteVmProvisioningPlanner(
      database,
    ).plan(vmId: vm.metadata.id, operationId: operation.id, specGeneration: 1);
  }

  test(
    'acceptance persists pinned job and correlated event across reopen',
    () async {
      final pinned = await plan();
      final accepted = await jobs().accept(pinned);
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      final restored = (await jobs().get(pinned.vmId))!;
      expect(restored.plan.toJson(), pinned.toJson());
      expect(restored.createdAt, accepted.createdAt);
      expect(restored.cancellationRequested, isFalse);
      expect(
        (await operations().get(pinned.operationId))!.state,
        OperationState.pending,
      );
      final event = (await events().list(
        vmId: pinned.vmId,
      )).singleWhere((event) => event.type == 'vm.provisioning.accepted');
      expect(event.operationId, pinned.operationId);
      expect(event.payload.toJson()['spec_generation'], 1);
      expect(
        (await events().readUnpublishedOutbox()).any(
          (row) => row.key == event.eventId.value,
        ),
        isTrue,
      );
    },
  );

  test(
    'acceptance marks provisioning and queues work without lifecycle intent',
    () async {
      final pinned = await plan();
      await jobs().accept(pinned);
      final vm = (await SqliteVmRepository(database).get(pinned.vmId))!;
      expect(vm.status.phase, VmPhase.provisioning);
      expect(vm.status.driverGeneration, 0);
      expect(vm.status.observedGeneration, 0);
      await database.read((db) {
        final work = db.select(
          "SELECT * FROM outbox WHERE topic = 'vm.provisioning'",
        );
        expect(work, hasLength(1));
        expect(work.single['key'], pinned.operationId.value);
        expect(
          db.select("SELECT * FROM outbox WHERE topic = 'vm.commands'"),
          isEmpty,
        );
        expect(
          db
              .select('SELECT intent_revision FROM vms')
              .single['intent_revision'],
          0,
        );
      });
    },
  );

  test('rejects a pinned plan that differs from authoritative spec', () async {
    final pinned = await plan();
    final forged = VmProvisioningPlan.fromJson({
      ...pinned.toJson(),
      'disks': [
        {...pinned.disks.single.toJson(), 'writable': false},
      ],
    });
    await expectLater(jobs().accept(forged), throwsStateError);
    expect(await jobs().get(pinned.vmId), isNull);
    expect(
      (await SqliteVmRepository(database).get(pinned.vmId))!.status.phase,
      VmPhase.defined,
    );
  });

  test(
    'acceptance requires an untouched provisional VM and pending create',
    () async {
      for (final change in [
        "UPDATE vm_runtime SET phase = 'running'",
        "UPDATE vm_runtime SET desired_state = 'running'",
        'UPDATE vm_runtime SET driver_generation = 1',
        'UPDATE vm_runtime SET observed_generation = 1',
        "UPDATE vms SET deleting_at = '2026-09-07T00:00:00Z'",
        "UPDATE operations SET state = 'running'",
      ]) {
        final pinned = await plan();
        await database.transaction((db) => db.execute(change));
        await expectLater(
          jobs().accept(pinned),
          throwsStateError,
          reason: change,
        );
        expect(await jobs().get(pinned.vmId), isNull);
      }
    },
  );

  test('identical pending acceptance reuses the pinned job and work', () async {
    final pinned = await plan();
    final first = await jobs().accept(pinned);
    final second = await jobs().accept(
      VmProvisioningPlan.fromJson(pinned.toJson()),
    );
    expect(second.createdAt, first.createdAt);
    expect(second.plan.toJson(), first.plan.toJson());
    expect(
      (await events().list(
        vmId: pinned.vmId,
      )).where((event) => event.type == 'vm.provisioning.accepted'),
      hasLength(1),
    );
    await database.read(
      (db) => expect(
        db.select("SELECT * FROM outbox WHERE topic = 'vm.provisioning'"),
        hasLength(1),
      ),
    );
    final other = await operations().create(
      type: 'vm.create',
      resourceType: ResourceType.virtualMachine,
      resourceId: pinned.vmId,
      requestId: RequestId.generate(),
      cancellable: true,
      request: JsonObjectValue.fromJson({'spec_generation': 1}),
    );
    final conflict = VmProvisioningPlan.fromJson({
      ...pinned.toJson(),
      'operation_id': other.id.value,
    });
    await expectLater(jobs().accept(conflict), throwsStateError);
    expect((await jobs().get(pinned.vmId))!.plan.toJson(), pinned.toJson());
  });

  test(
    'cancellation request survives reopen without completing or cleaning the VM',
    () async {
      final pinned = await plan();
      await jobs().accept(pinned);
      await operations().start(pinned.operationId);
      await jobs().requestCancellation(
        pinned.vmId,
        operationId: pinned.operationId,
      );
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      final cancelled = await jobs().requestCancellation(
        pinned.vmId,
        operationId: pinned.operationId,
      );
      expect(cancelled.cancellationRequested, isTrue);
      expect(cancelled.plan.toJson(), pinned.toJson());
      expect((await jobs().get(pinned.vmId))!.cancellationRequested, isTrue);
      expect(
        (await operations().get(pinned.operationId))!.state,
        OperationState.running,
      );
      expect(
        (await SqliteVmRepository(database).get(pinned.vmId))!.status.phase,
        VmPhase.provisioning,
      );
      final event = (await events().list(vmId: pinned.vmId)).singleWhere(
        (event) => event.type == 'vm.provisioning.cancellation_requested',
      );
      expect(event.operationId, pinned.operationId);
      expect(
        (await events().readUnpublishedOutbox()).where(
          (row) => row.key == event.eventId.value,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'cancellation requires the matching active cancellable create operation',
    () async {
      final pinned = await plan();
      await jobs().accept(pinned);
      await expectLater(
        jobs().requestCancellation(
          pinned.vmId,
          operationId: OperationId.generate(),
        ),
        throwsStateError,
      );
      await operations().setCancellable(pinned.operationId, cancellable: false);
      await expectLater(
        jobs().requestCancellation(
          pinned.vmId,
          operationId: pinned.operationId,
        ),
        throwsA(isA<OperationNotCancellableException>()),
      );
      expect((await jobs().get(pinned.vmId))!.cancellationRequested, isFalse);
      await operations().setCancellable(pinned.operationId, cancellable: true);
      await jobs().requestCancellation(
        pinned.vmId,
        operationId: pinned.operationId,
      );
      await operations().cancel(pinned.operationId);
      await expectLater(
        jobs().requestCancellation(
          pinned.vmId,
          operationId: pinned.operationId,
        ),
        throwsA(isA<OperationNotCancellableException>()),
      );
      expect((await jobs().get(pinned.vmId))!.plan.toJson(), pinned.toJson());
      await expectLater(jobs().accept(pinned), throwsStateError);
    },
  );

  test(
    'outer acceptance rollback removes VM, job, operation, events and work',
    () async {
      late VmProvisioningPlan pinned;
      await expectLater(
        database.transaction((_) async {
          pinned = await plan();
          await jobs().accept(pinned);
          await jobs().requestCancellation(
            pinned.vmId,
            operationId: pinned.operationId,
          );
          throw StateError('failed immutable response persistence');
        }),
        throwsStateError,
      );
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      expect(await jobs().get(pinned.vmId), isNull);
      expect(await SqliteVmRepository(database).list(), isEmpty);
      expect(await operations().list(), isEmpty);
      expect(await events().list(), isEmpty);
      await database.read(
        (db) => expect(db.select('SELECT * FROM outbox'), isEmpty),
      );
    },
  );

  test(
    'outer cancellation rollback restores flag and event together',
    () async {
      final pinned = await plan();
      await jobs().accept(pinned);
      await expectLater(
        database.transaction((_) async {
          await jobs().requestCancellation(
            pinned.vmId,
            operationId: pinned.operationId,
          );
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect((await jobs().get(pinned.vmId))!.cancellationRequested, isFalse);
      expect(
        (await events().list(vmId: pinned.vmId)).where(
          (event) => event.type == 'vm.provisioning.cancellation_requested',
        ),
        isEmpty,
      );
    },
  );

  test(
    'pending acceptance rejects obsolete spec generation and wrong operation identity',
    () async {
      final pinned = await plan();
      await SqliteVmRepository(database).updateSpec(
        pinned.vmId,
        expectedRevision: 1,
        spec: VmSpec.fromJson({..._spec.toJson(), 'cpu': 4}),
      );
      await expectLater(jobs().accept(pinned), throwsStateError);
      final valid = await plan();
      for (final change in [
        "type = 'vm.start'",
        "type = 'vm.create', resource_id = '${pinned.vmId.value}'",
      ]) {
        await database.transaction(
          (db) => db.execute('UPDATE operations SET $change WHERE id = ?', [
            valid.operationId.value,
          ]),
        );
        await expectLater(jobs().accept(valid), throwsStateError);
      }
      expect(await jobs().get(valid.vmId), isNull);
    },
  );

  test(
    'SQLite refuses rewriting pinned job identity, plan or acceptance timestamp',
    () async {
      final pinned = await plan();
      final accepted = await jobs().accept(pinned);
      for (final assignment in [
        "plan_json = '{}'",
        'spec_generation = 2',
        "created_at = '2026-01-01T00:00:00Z'",
        "operation_id = '${OperationId.generate().value}'",
        "vm_id = '${VmId.generate().value}'",
      ]) {
        await expectLater(
          database.transaction(
            (db) => db.execute(
              'UPDATE vm_provisioning SET $assignment WHERE vm_id = ?',
              [pinned.vmId.value],
            ),
          ),
          throwsA(isA<SqliteException>()),
        );
      }
      final restored = (await jobs().get(pinned.vmId))!;
      expect(restored.plan.toJson(), pinned.toJson());
      expect(restored.createdAt, accepted.createdAt);
    },
  );

  test(
    'acceptance rejects generation-zero VM with accepted lifecycle intent',
    () async {
      for (final assignment in [
        'UPDATE vms SET intent_revision = 1',
        'UPDATE vm_runtime SET applied_intent_revision = 1',
        "UPDATE vm_runtime SET active_operation_id = '${OperationId.generate().value}'",
      ]) {
        final pinned = await plan();
        await database.transaction((db) => db.execute(assignment));
        await expectLater(jobs().accept(pinned), throwsStateError);
        expect(await jobs().get(pinned.vmId), isNull);
      }
    },
  );

  test(
    'reading a corrupted job fails closed on relational correlation mismatch',
    () async {
      final pinned = await plan();
      await jobs().accept(pinned);
      // Simulate catalog corruption beyond ordinary writes, which the trigger rejects.
      await database.transaction(
        (db) => db.execute('DROP TRIGGER vm_provisioning_immutable_input'),
      );
      for (final mismatch in [
        {'vm_id': VmId.generate().value},
        {'operation_id': OperationId.generate().value},
        {'spec_generation': 2},
      ]) {
        await database.transaction(
          (db) => db.execute('UPDATE vm_provisioning SET plan_json = ?', [
            jsonEncode({...pinned.toJson(), ...mismatch}),
          ]),
        );
        await expectLater(jobs().get(pinned.vmId), throwsFormatException);
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
      source: ExternalDiskSource('/external/not-opened.img'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
