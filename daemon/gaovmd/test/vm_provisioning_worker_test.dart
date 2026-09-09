import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OwnedImageDirectory bundles;
  late OwnedImageDirectory images;
  late VmSpec spec;
  late DateTime now;
  setUp(() async {
    now = DateTime.utc(2026, 9, 7);
    temporary = await Directory.systemTemp.createTemp('provision-worker-');
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    final imageRoot = Directory('${temporary.path}/images');
    final source = await File(
      '${temporary.path}/source',
    ).writeAsString('guest bytes');
    final disk = await ImageStore(
      database,
      imageRoot,
    ).importFile(source, type: ImageType.rawDisk);
    bundles = await OwnedImageDirectory.open(
      await Directory('${temporary.path}/vms').create(),
    );
    images = await OwnedImageDirectory.open(imageRoot);
    spec = VmSpec(
      cpu: 2,
      memoryBytes: 268435456,
      boot: EfiBoot(),
      disks: [
        VmDisk(
          id: 'root',
          source: ManagedImageDiskSource(disk.id),
          writable: true,
        ),
      ],
      networks: [DisconnectedNetwork(id: 'net0')],
      graphics: GraphicsConfig(enabled: false),
      serial: const SerialConfig(enabled: true, capture: true),
      guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
      restartPolicy: RestartPolicy.never,
    );
  });
  tearDown(() async {
    images.close();
    bundles.close();
    database.close();
    await temporary.delete(recursive: true);
  });
  Future<VmProvisioningPlan> accept() async {
    final result =
        await SqliteVmCreateAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 30),
        ).accept(
          VmCreateCommand(
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
            name: 'vm',
            spec: spec,
          ),
        );
    return (await SqliteVmProvisioningRepository(
      database,
    ).get(result.resourceId as VmId))!.plan;
  }

  SqliteVmProvisioningWorkRepository work() =>
      SqliteVmProvisioningWorkRepository(database, now: () => now);
  VmProvisioningWorker worker({
    void Function(VmBundleCheckpoint)? checkpoint,
  }) => VmProvisioningWorker(
    work: work(),
    bundles: VmBundleStore(
      database: database,
      bundles: bundles,
      images: images,
      onCheckpoint: checkpoint,
    ),
    owner: 'worker',
    lease: const Duration(seconds: 30),
  );

  test(
    'accepted creates publish independently and commit stopped successful operations',
    () async {
      final plans = [await accept(), await accept()];
      final outcomes = await worker().dispatchOnce();
      expect(outcomes, hasLength(2));
      expect(
        outcomes.every(
          (result) => result.kind == VmProvisioningOutcomeKind.completed,
        ),
        isTrue,
      );
      for (final plan in plans) {
        expect(
          await File(
            '${bundles.path}/${plan.vmId.value}.gaovm/disks/root.raw',
          ).readAsString(),
          'guest bytes',
        );
        expect(
          (await SqliteVmRepository(database).get(plan.vmId))!.status.phase,
          VmPhase.stopped,
        );
        expect(
          (await SqliteOperationRepository(
            database,
          ).get(plan.operationId))!.state,
          OperationState.succeeded,
        );
      }
      expect(await worker().dispatchOnce(), isEmpty);
    },
  );

  test(
    'durable pre-cancellation cleans up then tombstones and cancels',
    () async {
      final plan = await accept();
      await SqliteVmProvisioningRepository(
        database,
      ).requestCancellation(plan.vmId, operationId: plan.operationId);
      final outcome = (await worker().dispatchOnce()).single;
      expect(outcome.kind, VmProvisioningOutcomeKind.completed);
      expect(outcome.completion, VmProvisioningCompletionKind.cancelled);
      expect(await SqliteVmRepository(database).get(plan.vmId), isNull);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.state,
        OperationState.cancelled,
      );
      expect(
        (await Directory(bundles.path).list().toList()).whereType<Directory>(),
        isEmpty,
      );
      expect(await worker().dispatchOnce(), isEmpty);
    },
  );

  test(
    'completed work survives restart without rehashing or deleting mutable disks',
    () async {
      final plan = await accept();
      await worker().dispatchOnce();
      final file = File(
        '${bundles.path}/${plan.vmId.value}.gaovm/disks/root.raw',
      );
      await file.writeAsString('guest changed the disk after boot');
      final proof = (await SqliteVmProvisioningRepository(
        database,
      ).get(plan.vmId))!.completion!;
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect(await worker().dispatchOnce(), isEmpty);
      final restored = (await SqliteVmProvisioningRepository(
        database,
      ).get(plan.vmId))!.completion!;
      expect(restored.manifestDigest, proof.manifestDigest);
      await expectLater(
        VmBundleStore(
          database: database,
          bundles: bundles,
          images: images,
        ).withBundle(plan, (bundle) => bundle.removeUncommitted()),
        throwsStateError,
      );
      expect(await file.readAsString(), 'guest changed the disk after boot');
    },
  );

  test(
    'invalid external source cleans owned files before durable failure',
    () async {
      spec = VmSpec.fromJson({
        ...spec.toJson(),
        'disks': [
          VmDisk(
            id: 'root',
            source: ExternalDiskSource('${temporary.path}/missing'),
            writable: true,
          ).toJson(),
        ],
      });
      final plan = await accept();
      final outcome = (await worker().dispatchOnce()).single;
      expect(outcome.kind, VmProvisioningOutcomeKind.completed);
      expect(outcome.completion, VmProvisioningCompletionKind.failed);
      expect(await SqliteVmRepository(database).get(plan.vmId), isNull);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.state,
        OperationState.failed,
      );
      expect(
        (await Directory(bundles.path).list().toList()).whereType<Directory>(),
        isEmpty,
      );
      expect(await worker().dispatchOnce(), isEmpty);
    },
  );

  test(
    'insufficient space reports the stable resource exhaustion error',
    () async {
      final plan = await accept();
      final outcomes = await VmProvisioningWorker(
        work: work(),
        owner: 'low-space',
        bundles: VmBundleStore(
          database: database,
          bundles: bundles,
          images: images,
          materializer: ManagedDiskMaterializer(availableBytes: (_) async => 0),
        ),
      ).dispatchOnce();
      expect(outcomes.single.completion, VmProvisioningCompletionKind.failed);
      final operation = (await SqliteOperationRepository(
        database,
      ).get(plan.operationId))!;
      expect(operation.error!.code, ErrorCode.hostResourceExhausted);
      expect(operation.error!.retryable, isTrue);
      expect(
        (await Directory(bundles.path).list().toList()).whereType<Directory>(),
        isEmpty,
      );
    },
  );

  test('invalid external file reports a nonretryable spec error', () async {
    final empty = await File('${temporary.path}/empty').create();
    spec = VmSpec.fromJson({
      ...spec.toJson(),
      'disks': [
        VmDisk(
          id: 'root',
          source: ExternalDiskSource(empty.path),
          writable: true,
        ).toJson(),
      ],
    });
    final plan = await accept();
    expect(
      (await worker().dispatchOnce()).single.completion,
      VmProvisioningCompletionKind.failed,
    );
    final operation = (await SqliteOperationRepository(
      database,
    ).get(plan.operationId))!;
    expect(operation.error!.code, ErrorCode.vmSpecInvalid);
    expect(operation.error!.retryable, isFalse);
    expect(await empty.exists(), isTrue);
  });

  test(
    'expired publication claim leaves operation and work pending for recovery',
    () async {
      final plan = await accept();
      final outcome = (await worker(
        checkpoint: (point) {
          if (point == VmBundleCheckpoint.published)
            now = now.add(const Duration(seconds: 30));
        },
      ).dispatchOnce()).single;
      expect(outcome.kind, VmProvisioningOutcomeKind.deferred);
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
      expect(
        await Directory('${bundles.path}/${plan.vmId.value}.gaovm').exists(),
        isTrue,
      );
      final recovered = (await worker().dispatchOnce()).single;
      expect(recovered.completion, VmProvisioningCompletionKind.succeeded);
    },
  );

  test(
    'cancellation after publication removes bundle before cancelled completion',
    () async {
      final plan = await accept();
      Future<void>? cancellation;
      final outcome = (await worker(
        checkpoint: (point) {
          if (point == VmBundleCheckpoint.published) {
            cancellation = SqliteVmProvisioningRepository(database)
                .requestCancellation(plan.vmId, operationId: plan.operationId)
                .then((_) {});
          }
        },
      ).dispatchOnce()).single;
      await cancellation;
      expect(outcome.completion, VmProvisioningCompletionKind.cancelled);
      expect(
        await Directory('${bundles.path}/${plan.vmId.value}.gaovm').exists(),
        isFalse,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.state,
        OperationState.cancelled,
      );
    },
  );

  test(
    'unknown staged child prevents cleanup proof and leaves work retryable',
    () async {
      final plan = await accept();
      final stage =
          '${bundles.path}/.staging-${plan.vmId.value}-${plan.operationId.value}';
      final outcome = (await worker(
        checkpoint: (point) {
          if (point == VmBundleCheckpoint.staged) {
            File('$stage/unowned').writeAsStringSync('keep');
            throw StateError('injected failure');
          }
        },
      ).dispatchOnce()).single;
      expect(outcome.kind, VmProvisioningOutcomeKind.failed);
      expect(outcome.completion, isNull);
      expect(await File('$stage/unowned').readAsString(), 'keep');
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
      expect(
        await work().claim(owner: 'next', lease: const Duration(seconds: 30)),
        hasLength(1),
      );
    },
  );

  test('lease renews while waiting for the filesystem lock', () async {
    final plan = await accept();
    final lock = await bundles.acquireLock('.lock-${plan.vmId.value}');
    final repository = SqliteVmProvisioningWorkRepository(database);
    final pending = VmProvisioningWorker(
      work: repository,
      bundles: VmBundleStore(
        database: database,
        bundles: bundles,
        images: images,
      ),
      owner: 'waiting',
      lease: const Duration(milliseconds: 300),
    ).dispatchOnce();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        await repository.claim(
          owner: 'contender',
          lease: const Duration(seconds: 30),
        ),
        isEmpty,
      );
    } finally {
      lock.close();
    }
    expect(
      (await pending).single.completion,
      VmProvisioningCompletionKind.succeeded,
    );
  });

  test(
    'failed terminal transaction retains publication for a later delivery',
    () async {
      final plan = await accept();
      await database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER fail_worker_commit BEFORE INSERT ON events
      WHEN NEW.type = 'vm.provisioning.succeeded'
      BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
    '''),
      );
      final outcome = (await worker().dispatchOnce()).single;
      expect(outcome.kind, VmProvisioningOutcomeKind.failed);
      expect(outcome.completion, isNull);
      expect(
        await Directory('${bundles.path}/${plan.vmId.value}.gaovm').exists(),
        isTrue,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.state,
        OperationState.pending,
      );
      await database.transaction(
        (db) => db.execute('DROP TRIGGER fail_worker_commit'),
      );
      expect(
        (await worker().dispatchOnce()).single.completion,
        VmProvisioningCompletionKind.succeeded,
      );
    },
  );

  test(
    'loss while waiting on a lock prevents publication or acknowledgement',
    () async {
      final plan = await accept();
      final lock = await bundles.acquireLock('.lock-${plan.vmId.value}');
      final pending = worker().dispatchOnce();
      // Wait only in the test; the worker waits on native flock off-isolate.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      now = now.add(const Duration(seconds: 30));
      lock.close();
      expect((await pending).single.kind, VmProvisioningOutcomeKind.deferred);
      expect(
        (await Directory(bundles.path).list().toList()).whereType<Directory>(),
        isEmpty,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(plan.operationId))!.state,
        OperationState.pending,
      );
      expect(
        await work().claim(owner: 'next', lease: const Duration(seconds: 30)),
        hasLength(1),
      );
    },
  );
}
