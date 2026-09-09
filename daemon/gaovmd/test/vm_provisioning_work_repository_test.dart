import 'dart:io';
import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_provisioning_plan.dart';
import 'package:gaovmd/src/vm_provisioning_repository.dart';
import 'package:gaovmd/src/vm_provisioning_work_repository.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:gaovmd/src/vm_command_repository.dart';
import 'package:gaovmd/src/vm_bundle_manifest.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late DateTime now;
  const lease = Duration(seconds: 30);
  SqliteVmProvisioningWorkRepository work() =>
      SqliteVmProvisioningWorkRepository(database, now: () => now);
  setUp(() async {
    now = DateTime.utc(2026, 9, 7);
    directory = await Directory.systemTemp.createTemp('provision-work-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
  });
  tearDown(() async {
    database.close();
    await directory.delete(recursive: true);
  });
  Future<VmProvisioningPlan> accept({JsonObjectValue? request}) async {
    final vm = await SqliteVmRepository(
      database,
    ).create(name: 'work', spec: _spec);
    final operation = await SqliteOperationRepository(database).create(
      type: 'vm.create',
      resourceType: ResourceType.virtualMachine,
      resourceId: vm.metadata.id,
      requestId: RequestId.generate(),
      cancellable: true,
      request: request ?? JsonObjectValue.fromJson({'spec_generation': 1}),
    );
    final plan = await SqliteVmProvisioningPlanner(
      database,
    ).plan(vmId: vm.metadata.id, operationId: operation.id, specGeneration: 1);
    await SqliteVmProvisioningRepository(database).accept(plan);
    return plan;
  }

  test('committed claim survives reopen and blocks another worker', () async {
    final plan = await accept();
    final claim = (await work().claim(owner: 'one', lease: lease)).single;
    expect(claim.plan.toJson(), plan.toJson());
    expect(claim.job.cancellationRequested, isFalse);
    expect(claim.attempt, 1);
    database.close();
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    expect(await work().isCurrent(claim), isTrue);
    expect(await work().claim(owner: 'two', lease: lease), isEmpty);
    expect(await work().release(claim), isTrue);
    expect(await work().isCurrent(claim), isFalse);
    final next = (await work().claim(owner: 'two', lease: lease)).single;
    expect(next.outboxId, claim.outboxId);
    expect(next.attempt, 2);
  });

  test(
    'legacy create request without spec generation can finish and replay its pinned job',
    () async {
      final plan = await accept(request: JsonObjectValue.empty);
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      expect(claim.plan.toJson(), plan.toJson());
      expect(
        await work().completePublished(
          claim,
          manifestDigest: VmBundleManifest.create(plan).digest,
        ),
        isTrue,
      );
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      final job = (await SqliteVmProvisioningRepository(
        database,
      ).get(plan.vmId))!;
      expect(job.plan.toJson(), plan.toJson());
      expect(job.completion!.kind, VmProvisioningCompletionKind.succeeded);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.request.toJson(),
        isEmpty,
      );
    },
  );
  test(
    'renewal fences old handles and expired reuse fences stale workers',
    () async {
      await accept();
      final claim = (await work().claim(owner: 'same', lease: lease)).single;
      final renewed = (await work().renew(claim, lease: lease))!;
      expect(renewed.leaseExpiresAt, claim.leaseExpiresAt);
      expect(renewed.attempt, claim.attempt);
      expect(await work().isCurrent(claim), isFalse);
      expect(await work().release(claim), isFalse);
      expect(await work().renew(claim, lease: lease), isNull);
      now = now.add(lease);
      expect(await work().isCurrent(renewed), isFalse);
      expect(await work().renew(renewed, lease: lease), isNull);
      expect(await work().release(renewed), isFalse);
      final next = (await work().claim(owner: 'same', lease: lease)).single;
      expect(next.attempt, 2);
      expect(await work().release(renewed), isFalse);
      now = now.add(const Duration(seconds: 10));
      final extended = (await work().renew(next, lease: lease))!;
      expect(extended.leaseExpiresAt, now.add(lease));
      expect(await work().isCurrent(next), isFalse);
      expect(await work().isCurrent(extended), isTrue);
    },
  );

  test(
    'two connections claim exclusively without touching events or lifecycle commands',
    () async {
      final plan = await accept();
      await SqliteVmCommandRepository(database).enqueue(
        action: VmCommandAction.start,
        vmId: plan.vmId,
        operationId: plan.operationId,
        payload: JsonObjectValue.fromJson({}),
      );
      final other = await GaoVmDatabase.open('${directory.path}/catalog.db');
      try {
        final unrelated = await database.read(
          (db) => db
              .select('SELECT * FROM outbox WHERE topic != ?', [
                vmProvisioningOutboxTopic,
              ])
              .map((row) => Map<String, Object?>.from(row))
              .toList(),
        );
        final results = await Future.wait([
          work().claim(owner: 'one', lease: lease),
          SqliteVmProvisioningWorkRepository(
            other,
            now: () => now,
          ).claim(owner: 'two', lease: lease),
        ]);
        expect(results.expand((claims) => claims), hasLength(1));
        await database.read(
          (db) => expect(
            db
                .select('SELECT * FROM outbox WHERE topic != ?', [
                  vmProvisioningOutboxTopic,
                ])
                .map((row) => Map<String, Object?>.from(row))
                .toList(),
            unrelated,
          ),
        );
      } finally {
        other.close();
      }
    },
  );

  test(
    'work APIs reject a caller transaction including through another connection',
    () async {
      await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      final other = await GaoVmDatabase.open('${directory.path}/catalog.db');
      try {
        for (final connection in [database, other]) {
          await connection.transaction((_) async {
            await expectLater(
              work().claim(owner: 'nested', lease: lease),
              throwsStateError,
            );
            await expectLater(
              work().renew(claim, lease: lease),
              throwsStateError,
            );
            await expectLater(work().release(claim), throwsStateError);
            await expectLater(work().isCurrent(claim), throwsStateError);
            await expectLater(
              work().completePublished(
                claim,
                manifestDigest: VmBundleManifest.create(claim.plan).digest,
              ),
              throwsStateError,
            );
            await expectLater(
              work().completeFailed(claim, error: _error),
              throwsStateError,
            );
            await expectLater(
              work().completeCancelled(claim),
              throwsStateError,
            );
          });
        }
        expect(await work().isCurrent(claim), isTrue);
      } finally {
        other.close();
      }
    },
  );

  test('forged envelope rolls back every claim in the batch', () async {
    await accept();
    final forged = await accept();
    final original = {
      'vm_id': forged.vmId.value,
      'operation_id': forged.operationId.value,
      'spec_generation': 1,
    };
    for (final mutation in [
      {...original, 'extra': true},
      {...original, 'vm_id': VmId.generate().value},
      {...original, 'operation_id': OperationId.generate().value},
      {...original, 'spec_generation': 2},
      {...original, 'spec_generation': 1.0},
    ]) {
      await database.transaction(
        (db) => db.execute(
          'UPDATE outbox SET payload_json = ? WHERE topic = ? AND key = ?',
          [
            jsonEncode(mutation),
            vmProvisioningOutboxTopic,
            forged.operationId.value,
          ],
        ),
      );
      await expectLater(
        work().claim(owner: 'one', lease: lease),
        throwsFormatException,
      );
      await database.read(
        (db) => expect(
          db
              .select(
                'SELECT attempts, claimed_by FROM outbox WHERE topic = ?',
                [vmProvisioningOutboxTopic],
              )
              .every(
                (row) => row['attempts'] == 0 && row['claimed_by'] == null,
              ),
          isTrue,
        ),
      );
    }
    await database.transaction(
      (db) => db.execute(
        'UPDATE outbox SET payload_json = ?, key = ? WHERE topic = ? AND key = ?',
        [
          jsonEncode(original),
          OperationId.generate().value,
          vmProvisioningOutboxTopic,
          forged.operationId.value,
        ],
      ),
    );
    await expectLater(
      work().claim(owner: 'one', lease: lease),
      throwsFormatException,
    );
  });

  test('changed operation identity and claimed envelope fail closed', () async {
    final plan = await accept();
    final claim = (await work().claim(owner: 'one', lease: lease)).single;
    await database.transaction(
      (db) => db.execute(
        "UPDATE operations SET type = 'vm.start' WHERE id = ?",
        [plan.operationId.value],
      ),
    );
    await expectLater(work().isCurrent(claim), throwsFormatException);
    await expectLater(work().renew(claim, lease: lease), throwsFormatException);
    await expectLater(work().release(claim), throwsFormatException);
    await database.transaction((db) {
      db.execute("UPDATE operations SET type = 'vm.create' WHERE id = ?", [
        plan.operationId.value,
      ]);
      db.execute("UPDATE outbox SET payload_json = '{}' WHERE id = ?", [
        claim.outboxId,
      ]);
    });
    await expectLater(work().isCurrent(claim), throwsFormatException);
    await expectLater(work().release(claim), throwsFormatException);
  });

  test('claim limits and invalid lease inputs preserve queued work', () async {
    await accept();
    await accept();
    for (final owner in ['', 'x' * 256]) {
      await expectLater(
        work().claim(owner: owner, lease: lease),
        throwsArgumentError,
      );
    }
    for (final limit in [0, 1001]) {
      await expectLater(
        work().claim(owner: 'one', lease: lease, limit: limit),
        throwsArgumentError,
      );
    }
    await expectLater(
      work().claim(owner: 'one', lease: Duration.zero),
      throwsArgumentError,
    );
    final first = (await work().claim(
      owner: 'one',
      lease: lease,
      limit: 1,
    )).single;
    await expectLater(
      work().renew(first, lease: Duration.zero),
      throwsArgumentError,
    );
    expect(await work().isCurrent(first), isTrue);
    expect(await work().claim(owner: 'two', lease: lease), hasLength(1));
  });

  test(
    'renewal refreshes cancellation intent while preserving pinned inputs',
    () async {
      final plan = await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      await SqliteVmProvisioningRepository(
        database,
      ).requestCancellation(plan.vmId, operationId: plan.operationId);
      final renewed = (await work().renew(claim, lease: lease))!;
      expect(claim.job.cancellationRequested, isFalse);
      expect(renewed.job.cancellationRequested, isTrue);
      expect(renewed.plan.toJson(), plan.toJson());
    },
  );

  test(
    'claim rejects operation request generations with altered wire types',
    () async {
      final plan = await accept();
      await database.transaction(
        (db) =>
            db.execute('UPDATE operations SET request_json = ? WHERE id = ?', [
              jsonEncode({'spec_generation': 1.0}),
              plan.operationId.value,
            ]),
      );
      await expectLater(
        work().claim(owner: 'one', lease: lease),
        throwsFormatException,
      );
    },
  );

  test(
    'published completion commits immutable proof, stopped VM, operation and ACK together',
    () async {
      final plan = await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      final digest = VmBundleManifest.create(plan).digest;
      expect(
        await work().completePublished(claim, manifestDigest: digest),
        isTrue,
      );
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      final job = (await SqliteVmProvisioningRepository(
        database,
      ).get(plan.vmId))!;
      expect(job.completion!.kind, VmProvisioningCompletionKind.succeeded);
      expect(job.completion!.manifestDigest, digest);
      expect(job.completion!.completedAt, now);
      final vm = (await SqliteVmRepository(database).get(plan.vmId))!;
      expect(vm.status.phase, VmPhase.stopped);
      expect(vm.status.observedGeneration, 0);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.state,
        OperationState.succeeded,
      );
      expect(await work().claim(owner: 'two', lease: lease), isEmpty);
      expect(
        await work().completePublished(claim, manifestDigest: digest),
        isFalse,
      );
      expect(
        (await SqliteEventRepository(database).list(
          vmId: plan.vmId,
        )).where((e) => e.type == 'vm.provisioning.succeeded'),
        hasLength(1),
      );
    },
  );

  test(
    'wrong digest and stale completion leave all acceptance state intact',
    () async {
      final plan = await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      await expectLater(
        work().completePublished(claim, manifestDigest: 'sha256:wrong'),
        throwsArgumentError,
      );
      now = now.add(lease);
      expect(
        await work().completePublished(
          claim,
          manifestDigest: VmBundleManifest.create(plan).digest,
        ),
        isFalse,
      );
      expect(await work().completeCancelled(claim), isFalse);
      expect(await work().completeFailed(claim, error: _error), isFalse);
      expect(
        (await SqliteVmProvisioningRepository(
          database,
        ).get(plan.vmId))!.completion,
        isNull,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await SqliteVmRepository(database).get(plan.vmId))!.status.phase,
        VmPhase.provisioning,
      );
      expect(await work().claim(owner: 'two', lease: lease), hasLength(1));
    },
  );

  test(
    'cancellation intent wins and tombstones only after cancellation completion',
    () async {
      final plan = await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      await expectLater(work().completeCancelled(claim), throwsStateError);
      await SqliteVmProvisioningRepository(
        database,
      ).requestCancellation(plan.vmId, operationId: plan.operationId);
      await expectLater(
        work().completePublished(
          claim,
          manifestDigest: VmBundleManifest.create(plan).digest,
        ),
        throwsStateError,
      );
      await expectLater(
        work().completeFailed(claim, error: _error),
        throwsStateError,
      );
      expect(await work().completeCancelled(claim), isTrue);
      expect(await SqliteVmRepository(database).get(plan.vmId), isNull);
      final tombstone = (await SqliteVmRepository(
        database,
      ).get(plan.vmId, includeDeleted: true))!;
      expect(tombstone.metadata.revision, 2);
      expect(tombstone.metadata.updatedAt, now);
      await database.read((db) {
        final row = db.select(
          'SELECT deleting_at, deleted_at FROM vms WHERE id = ?',
          [plan.vmId.value],
        ).single;
        expect(DateTime.parse(row['deleting_at'] as String), now);
        expect(row['deleted_at'], row['deleting_at']);
      });
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.state,
        OperationState.cancelled,
      );
      final job = (await SqliteVmProvisioningRepository(
        database,
      ).get(plan.vmId))!;
      expect(job.completion!.kind, VmProvisioningCompletionKind.cancelled);
      expect(job.completion!.manifestDigest, isNull);
      expect(await work().claim(owner: 'two', lease: lease), isEmpty);
    },
  );

  test(
    'failure retains pinned external paths and operation while tombstoning provisional VM',
    () async {
      final plan = await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      expect(await work().completeFailed(claim, error: _error), isTrue);
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      expect(await SqliteVmRepository(database).get(plan.vmId), isNull);
      expect(await SqliteVmRepository(database).list(), isEmpty);
      final tombstone = (await SqliteVmRepository(
        database,
      ).get(plan.vmId, includeDeleted: true))!;
      expect(tombstone.metadata.revision, 2);
      expect(tombstone.metadata.updatedAt, now);
      await database.read((db) {
        final row = db.select(
          'SELECT deleting_at, deleted_at FROM vms WHERE id = ?',
          [plan.vmId.value],
        ).single;
        expect(DateTime.parse(row['deleting_at'] as String), now);
        expect(row['deleted_at'], row['deleting_at']);
      });
      final operation = (await SqliteOperationRepository(
        database,
      ).get(plan.operationId))!;
      expect(operation.state, OperationState.failed);
      expect(operation.error!.toJson(), _error.toJson());
      final job = (await SqliteVmProvisioningRepository(
        database,
      ).get(plan.vmId))!;
      expect(job.completion!.kind, VmProvisioningCompletionKind.failed);
      expect(job.plan.toJson(), plan.toJson());
      expect(await work().claim(owner: 'two', lease: lease), isEmpty);
    },
  );

  test(
    'terminal event failure rolls back operation, catalog, proof and ACK',
    () async {
      final plan = await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      final before = (await SqliteEventRepository(database).list()).length;
      await database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER fail_completion_event BEFORE INSERT ON events
      WHEN NEW.type = 'vm.provisioning.succeeded'
      BEGIN SELECT RAISE(ABORT, 'injected event failure'); END;
    '''),
      );
      await expectLater(
        work().completePublished(
          claim,
          manifestDigest: VmBundleManifest.create(plan).digest,
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(
        (await SqliteVmProvisioningRepository(
          database,
        ).get(plan.vmId))!.completion,
        isNull,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await SqliteVmRepository(database).get(plan.vmId))!.status.phase,
        VmPhase.provisioning,
      );
      expect((await SqliteEventRepository(database).list()).length, before);
      expect(await work().isCurrent(claim), isTrue);
    },
  );

  test(
    'terminal proof is immutable and replay ignores subsequent spec updates',
    () async {
      final plan = await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      await work().completePublished(
        claim,
        manifestDigest: VmBundleManifest.create(plan).digest,
      );
      await SqliteVmRepository(database).updateSpec(
        plan.vmId,
        expectedRevision: 1,
        spec: VmSpec.fromJson({..._spec.toJson(), 'cpu': 4}),
      );
      expect(
        (await SqliteVmProvisioningRepository(
          database,
        ).get(plan.vmId))!.plan.toJson(),
        plan.toJson(),
      );
      for (final change in [
        "completion_kind = 'failed'",
        'manifest_digest = NULL',
        'completed_at = NULL',
        'cancellation_requested = 1',
      ]) {
        await expectLater(
          database.transaction(
            (db) => db.execute('UPDATE vm_provisioning SET $change'),
          ),
          throwsA(isA<SqliteException>()),
        );
      }
    },
  );

  test(
    'expiry during terminal transaction rolls back and reports a stale claim',
    () async {
      final plan = await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      var clockReads = 0;
      final expiring = SqliteVmProvisioningWorkRepository(
        database,
        now: () => ++clockReads < 3 ? now : now.add(lease),
      );
      expect(
        await expiring.completePublished(
          claim,
          manifestDigest: VmBundleManifest.create(plan).digest,
        ),
        isFalse,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await SqliteVmProvisioningRepository(
          database,
        ).get(plan.vmId))!.completion,
        isNull,
      );
      expect(await work().isCurrent(claim), isTrue);
    },
  );

  test(
    'expiry during renewal cannot extend a lease that has just expired',
    () async {
      await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      var clockReads = 0;
      final expiring = SqliteVmProvisioningWorkRepository(
        database,
        now: () => ++clockReads == 1 ? now : now.add(lease),
      );
      expect(await expiring.renew(claim, lease: lease), isNull);
      expect(await work().isCurrent(claim), isTrue);
    },
  );

  test(
    'terminal proof reads fail closed on changed digest or operation identity',
    () async {
      final plan = await accept();
      final claim = (await work().claim(owner: 'one', lease: lease)).single;
      final digest = VmBundleManifest.create(plan).digest;
      await work().completePublished(claim, manifestDigest: digest);
      await database.transaction((db) {
        db.execute('DROP TRIGGER vm_provisioning_immutable_completion');
        db.execute("UPDATE vm_provisioning SET manifest_digest = 'forged'");
      });
      await expectLater(
        SqliteVmProvisioningRepository(database).get(plan.vmId),
        throwsFormatException,
      );
      await database.transaction((db) {
        db.execute('UPDATE vm_provisioning SET manifest_digest = ?', [digest]);
        db.execute("UPDATE operations SET type = 'vm.start' WHERE id = ?", [
          plan.operationId.value,
        ]);
      });
      await expectLater(
        SqliteVmProvisioningRepository(database).get(plan.vmId),
        throwsFormatException,
      );
    },
  );

  test(
    'completion refuses runtime or lifecycle state acquired after claim',
    () async {
      for (final assignment in [
        "phase = 'running'",
        "desired_state = 'running'",
        'driver_generation = 1',
        'observed_generation = 1',
        'applied_intent_revision = 1',
      ]) {
        final plan = await accept();
        final claim = (await work().claim(owner: 'one', lease: lease)).single;
        await database.transaction(
          (db) => db.execute(
            'UPDATE vm_runtime SET $assignment WHERE vm_id = ?',
            [plan.vmId.value],
          ),
        );
        await expectLater(
          work().completePublished(
            claim,
            manifestDigest: VmBundleManifest.create(plan).digest,
          ),
          throwsStateError,
        );
        expect(
          (await SqliteVmProvisioningRepository(
            database,
          ).get(plan.vmId))!.completion,
          isNull,
        );
        expect(
          (await SqliteOperationRepository(
            database,
          ).get(plan.operationId))!.state,
          OperationState.pending,
        );
        expect(await work().isCurrent(claim), isTrue);
      }
    },
  );
}

final _error = OperationError(
  code: ErrorCode.driverStartFailed,
  message: 'materialization failed',
  retryable: false,
  details: JsonObjectValue.empty,
);

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
