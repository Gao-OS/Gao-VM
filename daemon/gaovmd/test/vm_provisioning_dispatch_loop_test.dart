import 'dart:async';
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
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('provision-loop-');
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

  Future<OperationAcceptance> accept() =>
      SqliteVmCreateAcceptance(
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

  VmProvisioningWorker worker({
    void Function(VmBundleCheckpoint)? checkpoint,
  }) => VmProvisioningWorker(
    work: SqliteVmProvisioningWorkRepository(database),
    bundles: VmBundleStore(
      database: database,
      bundles: bundles,
      images: images,
      onCheckpoint: checkpoint,
    ),
    owner: 'daemon',
  );

  test('rejects invalid intervals and claim batch limits', () {
    for (final limit in [-1, 0, 1001]) {
      expect(
        () => VmProvisioningDispatchLoop(
          worker: worker(),
          batchLimit: limit,
          onDispatch: (_) {},
          onError: (_, _) {},
        ),
        throwsArgumentError,
      );
    }
    for (final interval in [Duration.zero, const Duration(microseconds: -1)]) {
      expect(
        () => VmProvisioningDispatchLoop(
          worker: worker(),
          interval: interval,
          onDispatch: (_) {},
          onError: (_, _) {},
        ),
        throwsArgumentError,
      );
    }
  });

  test('claim infrastructure failures are reported and retried', () async {
    final create = await accept();
    await database.transaction(
      (db) => db.execute('''CREATE TRIGGER reject_claim BEFORE UPDATE ON outbox
      BEGIN SELECT RAISE(ABORT, 'injected claim failure'); END'''),
    );
    final scheduler = _Scheduler();
    final failed = Completer<Object>();
    final succeeded = Completer<List<VmProvisioningOutcome>>();
    final loop = VmProvisioningDispatchLoop(
      worker: worker(),
      scheduler: scheduler,
      onDispatch: succeeded.complete,
      onError: (error, _) => failed.complete(error),
    );
    try {
      loop.start();
      expect(
        (await failed.future).toString(),
        contains('injected claim failure'),
      );
      expect(succeeded.isCompleted, isFalse);
      expect(scheduler.delays.single, const Duration(milliseconds: 250));
      await database.transaction(
        (db) => db.execute('DROP TRIGGER reject_claim'),
      );
      scheduler.fire();
      final outcome = (await succeeded.future).single;
      expect(outcome.operationId, create.operationId);
      expect(outcome.completion, VmProvisioningCompletionKind.succeeded);
    } finally {
      await loop.close();
    }
    expect(scheduler.activeCount, 0);
  });

  test(
    'close drains publication and terminal commit without overlapping passes',
    () async {
      final create = await accept();
      final scheduler = _Scheduler();
      final entered = Completer<void>();
      final release = Completer<void>();
      Future<void>? blocked;
      var publications = 0;
      final outcomes = <VmProvisioningOutcome>[];
      final loop = VmProvisioningDispatchLoop(
        worker: worker(
          checkpoint: (checkpoint) {
            if (checkpoint == VmBundleCheckpoint.published) {
              publications++;
              blocked = database.transaction((_) async {
                entered.complete();
                await release.future;
              });
            }
          },
        ),
        scheduler: scheduler,
        onDispatch: outcomes.addAll,
        onError: (error, _) => fail('$error'),
      );
      try {
        loop.start();
        await entered.future;
        loop.start();
        scheduler.fire();
        expect(publications, 1);
        expect(scheduler.activeCount, 0);
        var closed = false;
        final closing = loop.close().then((_) => closed = true);
        await Future<void>.value();
        expect(closed, isFalse);
        expect(outcomes, isEmpty);
        release.complete();
        await closing;
        expect(
          outcomes.single.completion,
          VmProvisioningCompletionKind.succeeded,
        );
        expect(
          (await SqliteOperationRepository(
            database,
          ).get(create.operationId))!.state,
          OperationState.succeeded,
        );
        expect(
          await File(
            '${bundles.path}/${create.resourceId.value}.gaovm/disks/root.raw',
          ).readAsString(),
          'guest bytes',
        );
        expect(scheduler.activeCount, 0);
        expect(loop.start, throwsStateError);
      } finally {
        if (!release.isCompleted) release.complete();
        await blocked;
        await loop.close();
      }
    },
  );

  test(
    'accepted creates automatically publish on successive bounded passes',
    () async {
      final creates = [await accept(), await accept()];
      final completed = Completer<void>();
      final outcomes = <VmProvisioningOutcome>[];
      final loop = VmProvisioningDispatchLoop(
        worker: worker(),
        batchLimit: 1,
        interval: const Duration(milliseconds: 1),
        onDispatch: (pass) {
          expect(pass.length, lessThanOrEqualTo(1));
          outcomes.addAll(pass);
          if (outcomes.length == 2 && !completed.isCompleted)
            completed.complete();
        },
        onError: completed.completeError,
      );
      try {
        loop.start();
        await completed.future.timeout(const Duration(seconds: 5));
        for (final create in creates) {
          expect(
            (await SqliteOperationRepository(
              database,
            ).get(create.operationId))!.state,
            OperationState.succeeded,
          );
          expect(
            (await SqliteVmRepository(
              database,
            ).get(create.resourceId as VmId))!.status.phase,
            VmPhase.stopped,
          );
          expect(
            await File(
              '${bundles.path}/${create.resourceId.value}.gaovm/disks/root.raw',
            ).readAsString(),
            'guest bytes',
          );
        }
        expect(
          outcomes.every(
            (outcome) =>
                outcome.completion == VmProvisioningCompletionKind.succeeded,
          ),
          isTrue,
        );
      } finally {
        await loop.close();
      }
    },
  );
}

final class _Scheduler implements VmTimerScheduler {
  final handles = <_Handle>[];
  final delays = <Duration>[];
  int get activeCount => handles.where((handle) => handle.isActive).length;
  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) {
    delays.add(delay);
    final handle = _Handle(callback);
    handles.add(handle);
    return handle;
  }

  void fire() {
    for (final handle in handles.where((handle) => handle.isActive).toList()) {
      handle.cancel();
      handle.callback();
    }
  }
}

final class _Handle implements VmTimerHandle {
  _Handle(this.callback);
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
}
