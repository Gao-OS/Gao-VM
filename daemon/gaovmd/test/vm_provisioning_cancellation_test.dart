import 'dart:io';
import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OperationAcceptance create;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('provision-cancel-');
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    final external = await File(
      '${temporary.path}/external.raw',
    ).writeAsString('external guest disk');
    create =
        await SqliteVmCreateAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 30),
        ).accept(
          VmCreateCommand(
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
            name: 'cancel-vm',
            spec: VmSpec(
              cpu: 2,
              memoryBytes: 268435456,
              boot: EfiBoot(),
              disks: [
                VmDisk(
                  id: 'root',
                  source: ExternalDiskSource(external.path),
                  writable: true,
                ),
              ],
              networks: [DisconnectedNetwork(id: 'net0')],
              graphics: GraphicsConfig(enabled: false),
              serial: const SerialConfig(enabled: true, capture: true),
              guestAgent: GuestAgentConfig(
                enabled: false,
                requiredForReady: false,
              ),
              restartPolicy: RestartPolicy.never,
            ),
          ),
        );
  });
  tearDown(() async {
    database.close();
    await temporary.delete(recursive: true);
  });
  SqliteVmProvisioningCancellation cancellation() =>
      SqliteVmProvisioningCancellation(
        database: database,
        idempotencyRetention: const Duration(days: 30),
      );
  OperationCancelCommand command({String? key = 'cancel-1'}) =>
      OperationCancelCommand(
        requestId: RequestId.generate(),
        idempotencyKey: key,
        requestBody: const [123, 125],
        operationId: create.operationId,
      );

  Future<VmProvisioningOutcome> dispatch() async {
    final bundles = await OwnedImageDirectory.open(
      await Directory('${temporary.path}/vms').create(),
    );
    final images = await OwnedImageDirectory.open(
      await Directory('${temporary.path}/images').create(),
    );
    try {
      return (await VmProvisioningWorker(
        work: SqliteVmProvisioningWorkRepository(database),
        bundles: VmBundleStore(
          database: database,
          bundles: bundles,
          images: images,
        ),
        owner: 'cleanup-worker',
      ).dispatchOnce()).single;
    } finally {
      images.close();
      bundles.close();
    }
  }

  test(
    'acceptance durably requests cleanup without completing either operation',
    () async {
      final accepted = await cancellation().cancel(command());
      expect(accepted.operationId, isNot(create.operationId));
      expect(accepted.resourceId, create.operationId);
      expect(accepted.resourceType, ResourceType.operation);
      expect(accepted.state, OperationState.pending);
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final operations = SqliteOperationRepository(database);
      final action = (await operations.get(accepted.operationId))!;
      expect(action.type, 'operation.cancel');
      expect(action.cancellable, isFalse);
      expect(action.state, OperationState.pending);
      expect(
        (await operations.get(create.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await SqliteVmProvisioningRepository(
          database,
        ).get(create.resourceId as VmId))!.cancellationRequested,
        isTrue,
      );
      expect(await Directory('${temporary.path}/vms').exists(), isFalse);
      expect(
        await File('${temporary.path}/external.raw').readAsString(),
        'external guest disk',
      );
    },
  );

  test(
    'worker completes every accepted cancellation action only after cleanup across restart',
    () async {
      final first = await cancellation().cancel(command());
      final second = await cancellation().cancel(command(key: 'cancel-2'));
      expect((await cancellation().cancel(command())).toJson(), first.toJson());
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final bundles = await OwnedImageDirectory.open(
        await Directory('${temporary.path}/vms').create(),
      );
      final images = await OwnedImageDirectory.open(
        await Directory('${temporary.path}/images').create(),
      );
      try {
        final outcome = (await VmProvisioningWorker(
          work: SqliteVmProvisioningWorkRepository(database),
          bundles: VmBundleStore(
            database: database,
            bundles: bundles,
            images: images,
          ),
          owner: 'restarted-worker',
        ).dispatchOnce()).single;
        expect(outcome.completion, VmProvisioningCompletionKind.cancelled);
        final operations = SqliteOperationRepository(database);
        expect(
          (await operations.get(create.operationId))!.state,
          OperationState.cancelled,
        );
        for (final accepted in [first, second]) {
          final action = (await operations.get(accepted.operationId))!;
          expect(action.state, OperationState.succeeded);
          expect(
            action.completedAt,
            (await operations.get(create.operationId))!.completedAt,
          );
        }
        expect(
          (await cancellation().cancel(command())).toJson(),
          first.toJson(),
        );
        expect(
          await SqliteVmRepository(database).get(create.resourceId as VmId),
          isNull,
        );
        expect(
          await File('${temporary.path}/external.raw').readAsString(),
          'external guest disk',
        );
      } finally {
        images.close();
        bundles.close();
      }
    },
  );

  test(
    'completion transaction failure preserves both pending operations for retry',
    () async {
      final accepted = await cancellation().cancel(command());
      await database.read(
        (db) => db.execute('''
      CREATE TRIGGER fail_cancel_action BEFORE UPDATE OF state ON operations
      WHEN NEW.type = 'operation.cancel' AND NEW.state = 'succeeded'
      BEGIN SELECT RAISE(ABORT, 'injected completion failure'); END;
    '''),
      );
      expect((await dispatch()).kind, VmProvisioningOutcomeKind.failed);
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(create.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await SqliteVmProvisioningRepository(
          database,
        ).get(create.resourceId as VmId))!.completion,
        isNull,
      );
      await database.read(
        (db) => db.execute('DROP TRIGGER fail_cancel_action'),
      );
      expect(
        (await dispatch()).completion,
        VmProvisioningCompletionKind.cancelled,
      );
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
    },
  );

  test(
    'failed acceptance rolls back intent action events and idempotency together',
    () async {
      final eventsBefore = await SqliteEventRepository(database).list();
      await database.read(
        (db) => db.execute('''
      CREATE TRIGGER fail_cancel_link BEFORE INSERT ON vm_provisioning_cancellations
      BEGIN SELECT RAISE(ABORT, 'injected acceptance failure'); END;
    '''),
      );
      await expectLater(
        cancellation().cancel(command()),
        throwsA(isA<Exception>()),
      );
      expect(
        (await SqliteVmProvisioningRepository(
          database,
        ).get(create.resourceId as VmId))!.cancellationRequested,
        isFalse,
      );
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(
        await SqliteEventRepository(database).list(),
        hasLength(eventsBefore.length),
      );
      await database.read((db) => db.execute('DROP TRIGGER fail_cancel_link'));
      expect(
        (await cancellation().cancel(command())).state,
        OperationState.pending,
      );
    },
  );

  test(
    'idempotency conflict does not create another cancellation action',
    () async {
      await cancellation().cancel(command());
      final eventsBefore = await SqliteEventRepository(database).list();
      await expectLater(
        cancellation().cancel(
          OperationCancelCommand(
            requestId: RequestId.generate(),
            idempotencyKey: 'cancel-1',
            requestBody: utf8.encode('{"different":true}'),
            operationId: create.operationId,
          ),
        ),
        throwsA(isA<IdempotencyConflictException>()),
      );
      expect(await SqliteOperationRepository(database).list(), hasLength(2));
      expect(
        await SqliteEventRepository(database).list(),
        hasLength(eventsBefore.length),
      );
    },
  );

  test(
    'unknown non-cancellable unsupported and terminal targets leave no cancellation records',
    () async {
      final operations = SqliteOperationRepository(database);
      Future<void> rejected(OperationId id, Matcher error) => expectLater(
        cancellation().cancel(
          OperationCancelCommand(
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
            operationId: id,
          ),
        ),
        throwsA(error),
      );
      await rejected(OperationId.generate(), isA<OperationNotFoundException>());
      final unsupported = await operations.create(
        type: 'vm.start',
        resourceType: ResourceType.virtualMachine,
        resourceId: create.resourceId,
        requestId: RequestId.generate(),
        cancellable: true,
        request: JsonObjectValue.empty,
      );
      await rejected(unsupported.id, isA<OperationNotCancellableException>());
      await operations.setCancellable(create.operationId, cancellable: false);
      await rejected(
        create.operationId,
        isA<OperationNotCancellableException>(),
      );
      await operations.start(create.operationId);
      await operations.succeed(create.operationId);
      await rejected(
        create.operationId,
        isA<OperationNotCancellableException>(),
      );
      expect(await operations.list(), hasLength(2));
      expect(
        (await SqliteVmProvisioningRepository(
          database,
        ).get(create.resourceId as VmId))!.cancellationRequested,
        isFalse,
      );
    },
  );

  test(
    'caller transaction cannot return an uncommitted cancellation acceptance',
    () async {
      await expectLater(
        database.transaction((_) => cancellation().cancel(command())),
        throwsStateError,
      );
      final other = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      try {
        await expectLater(
          other.transaction((_) => cancellation().cancel(command())),
          throwsStateError,
        );
      } finally {
        other.close();
      }
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
    },
  );

  test(
    'unknown staging contents keep target and cancellation pending until cleanup is possible',
    () async {
      final accepted = await cancellation().cancel(command());
      final stage = Directory(
        '${temporary.path}/vms/.staging-${create.resourceId.value}-${create.operationId.value}',
      );
      await stage.create(recursive: true);
      final unknown = await File(
        '${stage.path}/unknown-user-file',
      ).writeAsString('preserve');
      expect((await dispatch()).kind, VmProvisioningOutcomeKind.failed);
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(create.operationId))!.state,
        OperationState.pending,
      );
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.pending,
      );
      expect(await unknown.readAsString(), 'preserve');
      await unknown.delete(); // Test-owned obstruction removed by its owner.
      expect(
        (await dispatch()).completion,
        VmProvisioningCompletionKind.cancelled,
      );
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
    },
  );

  test(
    'expired work cannot acknowledge cancellation actions accepted under a newer lease',
    () async {
      var now = DateTime.utc(2026, 9, 7);
      final work = SqliteVmProvisioningWorkRepository(database, now: () => now);
      final stale = (await work.claim(
        owner: 'old',
        lease: const Duration(seconds: 30),
      )).single;
      final accepted = await cancellation().cancel(command());
      now = now.add(const Duration(seconds: 31));
      final current = (await work.claim(
        owner: 'new',
        lease: const Duration(seconds: 30),
      )).single;
      expect(await work.completeCancelled(stale), isFalse);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.pending,
      );
      // No bundle IO has occurred: there are no job-owned files to clean.
      expect(await work.completeCancelled(current), isTrue);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
    },
  );

  test(
    'mismatched durable action fails closed and rolls back target completion',
    () async {
      final accepted = await cancellation().cancel(command());
      final operations = SqliteOperationRepository(database);
      final action = (await operations.get(accepted.operationId))!;
      await database.read(
        (db) => db.execute(
          'UPDATE operations SET resource_id = ? WHERE id = ?',
          [OperationId.generate().value, action.id.value],
        ),
      );
      expect((await dispatch()).kind, VmProvisioningOutcomeKind.failed);
      expect(
        (await operations.get(create.operationId))!.state,
        OperationState.pending,
      );
      expect((await operations.get(action.id))!.state, OperationState.pending);
      await database.read(
        (db) => db.execute(
          'UPDATE operations SET resource_id = ? WHERE id = ?',
          [create.operationId.value, action.id.value],
        ),
      );
      expect(
        (await dispatch()).completion,
        VmProvisioningCompletionKind.cancelled,
      );
    },
  );

  test(
    'cancellation after publication wins before success commit without early cleanup success',
    () async {
      final bundles = await OwnedImageDirectory.open(
        await Directory('${temporary.path}/vms').create(),
      );
      final images = await OwnedImageDirectory.open(
        await Directory('${temporary.path}/images').create(),
      );
      final work = SqliteVmProvisioningWorkRepository(database);
      final claim = (await work.claim(
        owner: 'publisher',
        lease: const Duration(seconds: 30),
      )).single;
      try {
        await VmBundleStore(
          database: database,
          bundles: bundles,
          images: images,
        ).withBundle(claim.plan, (session) async {
          final manifest = await session.publish();
          final action = await cancellation().cancel(command());
          expect(
            await Directory(
              '${bundles.path}/${create.resourceId.value}.gaovm',
            ).exists(),
            isTrue,
          );
          expect(
            (await SqliteOperationRepository(
              database,
            ).get(action.operationId))!.state,
            OperationState.pending,
          );
          await expectLater(
            work.completePublished(claim, manifestDigest: manifest.digest),
            throwsStateError,
          );
          await session.removeUncommitted();
          expect(await work.completeCancelled(claim), isTrue);
          expect(
            (await SqliteOperationRepository(
              database,
            ).get(action.operationId))!.state,
            OperationState.succeeded,
          );
        });
        expect(
          await File('${temporary.path}/external.raw').readAsString(),
          'external guest disk',
        );
      } finally {
        images.close();
        bundles.close();
      }
    },
  );

  test(
    'committed publication rejects fresh cancellation and preserves the bundle',
    () async {
      expect(
        (await dispatch()).completion,
        VmProvisioningCompletionKind.succeeded,
      );
      await expectLater(
        cancellation().cancel(command()),
        throwsA(isA<OperationNotCancellableException>()),
      );
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(
        await File(
          '${temporary.path}/vms/${create.resourceId.value}.gaovm/manifest.json',
        ).exists(),
        isTrue,
      );
      final job = (await SqliteVmProvisioningRepository(
        database,
      ).get(create.resourceId as VmId))!;
      expect(job.cancellationRequested, isFalse);
      expect(job.completion!.kind, VmProvisioningCompletionKind.succeeded);
    },
  );
}
