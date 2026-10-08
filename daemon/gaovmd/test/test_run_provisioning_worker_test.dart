import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/test_run_provisioning_worker.dart';
import 'package:gaovmd/src/test_run_provisioning_dispatch_loop.dart';
import 'package:gaovmd/src/test_run_vm_start_dispatch_loop.dart';
import 'package:gaovmd/src/test_run_vm_start_worker.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OwnedImageDirectory bundles;
  late OwnedImageDirectory images;
  late Image source;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tr-provision-');
    imageFileMode(temporary.path, 0x1c0);
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    final input = await Directory('${temporary.path}/input').create();
    imageFileMode(input.path, 0x1c0);
    await Directory('${input.path}/objects').create();
    final objects = <String, Map<String, Object?>>{};
    for (final name in ['kernel', 'initrd', 'disk']) {
      final bytes = utf8.encode('original $name');
      await File('${input.path}/objects/$name').writeAsBytes(bytes);
      objects[name] = {
        'digest': 'sha256:${sha256.convert(bytes)}',
        'size_bytes': bytes.length,
      };
    }
    final manifest = ImageManifest.create(
      type: ImageType.gaoosBundle,
      guestProfile: 'gaoos',
      version: 'test',
      buildId: 'fixture',
      channel: 'test',
      objects: objects,
      gaoos: {
        'kernel': 'kernel',
        'initrd': 'initrd',
        'root_disk': 'disk',
        'default_command_line': 'console=hvc0 root=/dev/vda',
        'guest_agent_expected': true,
      },
    );
    await File(
      '${input.path}/manifest.json',
    ).writeAsString(jsonEncode(manifest.toJson()));
    source = await ImageStore(
      database,
      Directory('${temporary.path}/images'),
    ).importBundle(input);
    final vmRoot = await Directory('${temporary.path}/vms').create();
    imageFileMode(vmRoot.path, 0x1c0);
    bundles = await OwnedImageDirectory.open(vmRoot);
    images = await OwnedImageDirectory.open(
      Directory('${temporary.path}/images'),
    );
  });

  tearDown(() async {
    bundles.close();
    images.close();
    database.close();
    await temporary.delete(recursive: true);
  });

  Future<TestRunId> accept({
    VmSpecPatch? overrides,
    Image? from,
    num? timeoutSeconds,
    DateTime Function()? now,
  }) async {
    final spec = TestRunSpec(
      source: ImageTestRunSource((from ?? source).id),
      vmOverrides: overrides,
      wait: VmWaitSpec(
        condition: WaitCondition.guestAgentReady,
        timeoutSeconds: 30,
      ),
      steps: [
        TestStepRequest(argv: ['true'], timeoutSeconds: 30),
      ],
      cleanup: CleanupPolicy.deleteOnSuccess,
      retainOnFailure: true,
      timeoutSeconds: timeoutSeconds,
    );
    final result = await TestRunApplicationService(database: database, now: now)
        .create(
          TestRunCreateCommand(
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: utf8.encode(jsonEncode(spec.toJson())),
            spec: spec,
          ),
        );
    return result.resourceId as TestRunId;
  }

  test('an expired TestRun deadline cannot create a VM', () async {
    final created = DateTime.utc(2026, 10, 8);
    final id = await accept(timeoutSeconds: 1, now: () => created);
    await TestRunProvisioningWorker(
      database: database,
      now: () => created.add(const Duration(seconds: 2)),
    ).dispatchOnce();
    final run = (await SqliteTestRunRepository(database).get(id))!;
    expect(run.state, TestRunState.collecting);
    expect(run.error!.code, ErrorCode.waitTimeout);
    expect(await SqliteVmRepository(database).list(), isEmpty);
  });

  Future<
    ({
      VmRegistry registry,
      VmCommandDispatcher commands,
      ManualRuntimeScheduler clock,
      RuntimeDriverEffectAdapter drivers,
      Future<void> Function() close,
    })
  >
  openRuntime({FakeRuntimeScenarioResolver? scenarioForLaunch}) async {
    final clock = ManualRuntimeScheduler();
    late VmRegistry registry;
    final drivers = RuntimeDriverEffectAdapter.scopedConfiguration(
      factory: FakeRuntimeDriverFactory(
        scheduler: clock,
        scenarioForLaunch: scenarioForLaunch,
      ),
      withConfiguration: VmRuntimeConfigurationResolver(
        assets: SqliteVmRuntimeAssets(
          database: database,
          bundles: bundles,
          images: images,
        ),
      ).withConfiguration,
      dispatch: (id, command) async {
        final controller = await registry.get(id);
        if (controller != null) await controller.submit(command);
      },
    );
    final scheduler = HostScheduler(
      leases: SqliteHostLeaseRepository(database),
      catalog: SqliteHostCapacityCatalog(database, diskBytes: (_) => 0),
      metrics: _Metrics(),
      limits: HostSchedulerLimits(
        maxRunningVms: 3,
        maxConcurrentBoots: 3,
        maxDriverProcesses: 3,
        maxCpuCount: 8,
        maxMemoryBytes: 8 * 1024 * 1024 * 1024,
        minFreeDiskBytes: 0,
      ),
      ownerId: 'test-run-start',
      onLeaseLost: (vm, spec, operation, generation, error) =>
          registry.handleHostLeaseLost(vm, spec, operation, generation, error),
    );
    final runner = RepositoryVmEffectRunner(
      database: database,
      operations: SqliteOperationRepository(database),
      events: SqliteEventRepository(database),
      persistence: SqliteVmStateEffectAdapter(database),
      leases: scheduler,
      drivers: drivers,
      managedFiles: SqliteVmManagedFileEffectAdapter(
        database: database,
        bundles: bundles,
      ),
    );
    registry = VmRegistry(
      repository: SqliteVmRepository(database),
      operations: SqliteOperationRepository(database),
      effectRunner: runner,
      recovery: SqliteVmIntentRecoveryRepository(database),
    );
    final commands = VmCommandDispatcher(
      commands: SqliteVmCommandRepository(database),
      target: SqliteVmCommandTarget(
        database: database,
        registry: registry,
        effectRunner: runner,
      ),
      owner: 'test-run-start',
    );
    Future<void>? closing;
    Future<void> close() => closing ??= () async {
      await registry.shutdown();
      await scheduler.shutdown();
      await drivers.close();
    }();
    addTearDown(close);
    return (
      registry: registry,
      commands: commands,
      clock: clock,
      drivers: drivers,
      close: close,
    );
  }

  Future<void> provision() async {
    await TestRunProvisioningWorker(database: database).dispatchOnce();
    await VmProvisioningWorker(
      work: SqliteVmProvisioningWorkRepository(database),
      bundles: VmBundleStore(
        database: database,
        bundles: bundles,
        images: images,
      ),
      owner: 'test',
    ).dispatchOnce();
    await TestRunProvisioningWorker(database: database).dispatchOnce();
  }

  Future<Operation> waitOperation(OperationId id) =>
      SqliteOperationWaiter(
        operations: SqliteOperationRepository(database),
        events: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 1),
        ),
      ).wait(
        OperationWaitCommand(
          operationId: id,
          timeout: const Duration(seconds: 5),
        ),
      );

  Future<OperationAcceptance> acceptLifecycle(
    VmRegistry registry,
    VmId vmId,
    VmLifecycleAction action,
  ) =>
      SqliteVmLifecycleAcceptor(
        database: database,
        registry: registry,
        idempotencyRetention: const Duration(days: 1),
      ).lifecycle(
        VmLifecycleCommand(
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
          vmId: vmId,
          action: action,
        ),
      );

  test(
    'start dispatch rejects invalid limits before scheduling work',
    () async {
      final runtime = await openRuntime();
      final worker = TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      );
      final scheduler = _StartTimerScheduler();
      for (final limit in [-1, 0, 201]) {
        expect(
          () => TestRunVmStartDispatchLoop(
            worker: worker,
            scheduler: scheduler,
            batchLimit: limit,
            onDispatch: (_) {},
            onError: (_, _) {},
          ),
          throwsArgumentError,
        );
      }
      for (final interval in [
        Duration.zero,
        const Duration(milliseconds: -1),
      ]) {
        expect(
          () => TestRunVmStartDispatchLoop(
            worker: worker,
            scheduler: scheduler,
            interval: interval,
            onDispatch: (_) {},
            onError: (_, _) {},
          ),
          throwsArgumentError,
        );
      }
      expect(scheduler.activeCount, 0);
    },
  );

  test(
    'background start dispatch accepts successive bounded TestRuns',
    () async {
      final ids = [await accept(), await accept()];
      await provision();
      final runtime = await openRuntime();
      final completed = Completer<void>();
      final accepted = <TestRunId>{};
      final loop = TestRunVmStartDispatchLoop(
        worker: TestRunVmStartWorker(
          database: database,
          registry: runtime.registry,
        ),
        batchLimit: 1,
        interval: const Duration(milliseconds: 1),
        onDispatch: (pass) {
          expect(pass.length, lessThanOrEqualTo(1));
          for (final item in pass) {
            expect(item.error, isNull);
            accepted.add(item.testRunId);
          }
          if (accepted.length == ids.length && !completed.isCompleted) {
            completed.complete();
          }
        },
        onError: completed.completeError,
      );
      try {
        loop.start();
        await completed.future.timeout(const Duration(seconds: 5));
        final starts = (await SqliteOperationRepository(
          database,
        ).list()).where((op) => op.type == 'vm.start').toList();
        expect(starts, hasLength(2));
        for (final id in ids) {
          final run = (await SqliteTestRunRepository(database).get(id))!;
          expect(
            starts.singleWhere((op) => op.resourceId == run.vmId).state,
            OperationState.pending,
          );
          expect(
            (await SqliteVmRepository(
              database,
            ).get(run.vmId!))!.status.desiredState,
            DesiredState.running,
          );
        }
        expect(runtime.drivers.activeSessionCount, 0);
      } finally {
        await loop.close();
      }
    },
  );

  test(
    'background dispatch starts two isolated TestRuns without client polling',
    () async {
      final ids = [await accept(), await accept()];
      await provision();
      final runtime = await openRuntime();
      final delivered = Completer<void>();
      final adopted = <OperationId>{};
      final ready = Completer<void>();
      final started = <Event>[];
      final subscription =
          SqliteDurableEventFeed(
                database,
                pollInterval: const Duration(milliseconds: 1),
              )
              .watch()
              .where(
                (event) =>
                    event.type == 'test_run.vm_started' &&
                    ids.contains(event.testRunId),
              )
              .listen((event) {
                started.add(event);
                if (started.length == ids.length && !ready.isCompleted)
                  ready.complete();
              }, onError: ready.completeError);
      final starts = TestRunVmStartDispatchLoop(
        worker: TestRunVmStartWorker(
          database: database,
          registry: runtime.registry,
        ),
        batchLimit: 1,
        interval: const Duration(milliseconds: 1),
        onDispatch: (pass) {
          for (final item in pass) expect(item.error, isNull);
        },
        onError: ready.completeError,
      );
      final commands = VmCommandDispatchLoop(
        dispatcher: runtime.commands,
        interval: const Duration(milliseconds: 1),
        onDispatch: (pass) {
          for (final item in pass) {
            expect(item.error, isNull);
            if (item.status == VmCommandDispatchStatus.acknowledged) {
              adopted.add(item.record.operationId);
            }
          }
          if (adopted.length == ids.length && !delivered.isCompleted) {
            delivered.complete();
          }
        },
        onError: delivered.completeError,
      );
      try {
        commands.start();
        starts.start();
        await delivered.future.timeout(const Duration(seconds: 5));
        final runs = [
          for (final id in ids)
            (await SqliteTestRunRepository(database).get(id))!,
        ];
        for (final run in runs) {
          await (await runtime.registry.get(run.vmId!))!.waitUntilIdle();
        }
        runtime.clock.runUntilIdle();
        await ready.future.timeout(const Duration(seconds: 5));
        expect(started.map((event) => event.vmId).toSet(), hasLength(2));
        expect(runtime.drivers.activeSessionCount, 2);
        for (final run in runs) {
          final current = (await SqliteTestRunRepository(
            database,
          ).get(run.id))!;
          expect(current.state, TestRunState.waitingReady);
          expect(current.steps.single.state, TestStepState.pending);
          expect(
            (await SqliteVmRepository(database).get(run.vmId!))!.status.phase,
            VmPhase.running,
          );
          expect(
            (await SqliteOperationRepository(
              database,
            ).get(run.operationId))!.state,
            OperationState.running,
          );
        }
      } finally {
        await subscription.cancel();
        await Future.wait([starts.close(), commands.close(), runtime.close()]);
      }
    },
  );

  test('start dispatch shutdown drains an in-flight catalog pass', () async {
    final id = await accept();
    await provision();
    final runtime = await openRuntime();
    final scheduler = _StartTimerScheduler();
    final entered = Completer<void>();
    final release = Completer<void>();
    final held = database.transaction((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final passes = <List<TestRunVmStartOutcome>>[];
    final loop = TestRunVmStartDispatchLoop(
      worker: TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      ),
      scheduler: scheduler,
      onDispatch: passes.add,
      onError: (error, _) => fail('$error'),
    );
    try {
      loop.start();
      loop.start();
      scheduler.fire();
      var closed = false;
      final closing = loop.close().then((_) => closed = true);
      await Future<void>.value();
      expect(closed, isFalse);
      release.complete();
      await held;
      await closing;
      expect(passes, hasLength(1));
      expect(passes.single.single.testRunId, id);
      expect(passes.single.single.error, isNull);
      expect(scheduler.activeCount, 0);
      expect(loop.start, throwsStateError);
      expect(
        (await SqliteOperationRepository(
          database,
        ).list()).where((op) => op.type == 'vm.start'),
        hasLength(1),
      );
    } finally {
      if (!release.isCompleted) release.complete();
      await held;
      await loop.close();
    }
  });

  test(
    'a deleted TestRun VM advances to collection with a durable cause',
    () async {
      final id = await accept();
      await provision();
      final runtime = await openRuntime();
      final run = (await SqliteTestRunRepository(database).get(id))!;
      final deletion =
          await SqliteVmLifecycleAcceptor(
            database: database,
            registry: runtime.registry,
            idempotencyRetention: const Duration(days: 1),
          ).lifecycle(
            VmLifecycleCommand(
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
              vmId: run.vmId!,
              action: VmLifecycleAction.delete,
            ),
          );
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      await SqliteOperationWaiter(
        operations: SqliteOperationRepository(database),
        events: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 1),
        ),
      ).wait(
        OperationWaitCommand(
          operationId: deletion.operationId,
          timeout: const Duration(seconds: 5),
        ),
      );
      await runtime.registry.reconcileVm(run.vmId!);
      expect(await SqliteVmRepository(database).get(run.vmId!), isNull);

      final outcome = (await TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      ).dispatchOnce()).single;
      final failed = (await SqliteTestRunRepository(database).get(id))!;
      expect(failed.state, TestRunState.collecting);
      expect(failed.error!.code, ErrorCode.vmNotFound);
      expect(failed.steps.single.state, TestStepState.skipped);
      expect(outcome.error, isNull);
      expect(
        (await SqliteOperationRepository(
          database,
        ).list()).where((op) => op.type == 'vm.start'),
        isEmpty,
      );
      expect(
        (await SqliteOperationRepository(database).get(run.operationId))!.state,
        OperationState.running,
      );
    },
  );

  test(
    'an accepted VM deletion fails its TestRun without starving another',
    () async {
      final bad = await accept();
      final good = await accept();
      await provision();
      final runtime = await openRuntime();
      final runs = SqliteTestRunRepository(database);
      final badVm = (await runs.get(bad))!.vmId!;
      final goodVm = (await runs.get(good))!.vmId!;
      await SqliteVmLifecycleAcceptor(
        database: database,
        registry: runtime.registry,
        idempotencyRetention: const Duration(days: 1),
      ).lifecycle(
        VmLifecycleCommand(
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
          vmId: badVm,
          action: VmLifecycleAction.delete,
        ),
      );
      final outcomes = await TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      ).dispatchOnce();
      final failed = (await runs.get(bad))!;
      expect(failed.state, TestRunState.collecting);
      expect(failed.error!.code, ErrorCode.vmOperationConflict);
      expect(failed.steps.single.state, TestStepState.skipped);
      expect(outcomes.every((item) => item.error == null), isTrue);
      final start = (await SqliteOperationRepository(
        database,
      ).list()).singleWhere((op) => op.type == 'vm.start');
      expect(start.resourceId, goodVm);
      expect(start.state, OperationState.pending);
      expect(runtime.drivers.activeSessionCount, 0);
    },
  );

  test(
    'a start checkpoint fault rolls back one VM without starving another',
    () async {
      final bad = await accept();
      final good = await accept();
      await provision();
      final runtime = await openRuntime();
      final runs = SqliteTestRunRepository(database);
      final badVm = (await runs.get(bad))!.vmId!;
      final goodVm = (await runs.get(good))!.vmId!;
      final events = SqliteEventRepository(database);
      final beforeRun = await events.list(testRunId: bad);
      final beforeVm = await events.list(vmId: badVm);
      await database.transaction((db) {
        db.execute('''CREATE TRIGGER reject_start_checkpoint
        BEFORE INSERT ON test_run_vm_start WHEN NEW.test_run_id = '${bad.value}'
        BEGIN SELECT RAISE(ABORT, 'start checkpoint fault'); END''');
      });
      final worker = TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      );
      final outcomes = await worker.dispatchOnce();
      expect(
        outcomes.singleWhere((item) => item.testRunId == bad).error,
        isA<SqliteException>(),
      );
      expect(
        outcomes.singleWhere((item) => item.testRunId == good).error,
        isNull,
      );
      expect((await runs.get(bad))!.state, TestRunState.startingVm);
      expect(
        (await SqliteVmRepository(database).get(badVm))!.status.desiredState,
        DesiredState.stopped,
      );
      expect(await events.list(testRunId: bad), beforeRun);
      expect(await events.list(vmId: badVm), beforeVm);
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.list())
            .singleWhere((op) => op.type == 'vm.start')
            .resourceId,
        goodVm,
      );
      await database.transaction(
        (db) => db.execute('DROP TRIGGER reject_start_checkpoint'),
      );
      expect(
        (await worker.dispatchOnce()).every((item) => item.error == null),
        isTrue,
      );
      final starts = (await operations.list())
          .where((op) => op.type == 'vm.start')
          .toList();
      expect(starts, hasLength(2));
      expect(starts.map((op) => op.resourceId).toSet(), {badVm, goodVm});
      expect(runtime.drivers.activeSessionCount, 0);
    },
  );

  test(
    'a provisioned TestRun starts its VM through durable lifecycle dispatch',
    () async {
      final id = await accept();
      await provision();
      final runtime = await openRuntime();
      final worker = TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      );
      await worker.dispatchOnce();
      final starts = (await SqliteOperationRepository(
        database,
      ).list()).where((operation) => operation.type == 'vm.start').toList();
      expect(starts, hasLength(1));
      expect(starts.single.state, OperationState.pending);
      expect(runtime.drivers.activeSessionCount, 0);
      final run = (await SqliteTestRunRepository(database).get(id))!;
      expect(starts.single.resourceId, run.vmId);
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      await (await runtime.registry.get(run.vmId!))!.waitUntilIdle();
      runtime.clock.runUntilIdle();
      final finished =
          await SqliteOperationWaiter(
            operations: SqliteOperationRepository(database),
            events: SqliteDurableEventFeed(
              database,
              pollInterval: const Duration(milliseconds: 1),
            ),
          ).wait(
            OperationWaitCommand(
              operationId: starts.single.id,
              timeout: const Duration(seconds: 5),
            ),
          );
      expect(finished.state, OperationState.succeeded);
      await worker.dispatchOnce();
      expect(
        (await SqliteTestRunRepository(database).get(id))!.state,
        TestRunState.waitingReady,
      );
      expect(
        (await SqliteVmRepository(database).get(run.vmId!))!.status.phase,
        VmPhase.running,
      );
    },
  );

  test(
    'cancelling an unfinished TestRun start drains a durable VM stop before collection',
    () async {
      final id = await accept();
      await provision();
      final runtime = await openRuntime();
      final worker = TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      );
      await worker.dispatchOnce();
      final run = (await SqliteTestRunRepository(database).get(id))!;
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      final controller = (await runtime.registry.get(run.vmId!))!;
      await controller.waitUntilIdle();
      expect(controller.state.phase, VmPhase.starting);
      final action = await TestRunApplicationService(database: database)
          .cancelRun(
            TestRunCancelCommand(
              testRunId: id,
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
            ),
          );
      await worker.dispatchOnce();
      final stops = (await SqliteOperationRepository(
        database,
      ).list()).where((op) => op.type == 'vm.stop').toList();
      expect(stops, hasLength(1));
      expect(
        (await SqliteTestRunRepository(database).get(id))!.state,
        TestRunState.startingVm,
      );
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      await (await runtime.registry.get(run.vmId!))!.waitUntilIdle();
      await SqliteOperationWaiter(
        operations: SqliteOperationRepository(database),
        events: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 1),
        ),
      ).wait(
        OperationWaitCommand(
          operationId: stops.single.id,
          timeout: const Duration(seconds: 5),
        ),
      );
      await worker.dispatchOnce();
      final cancelled = (await SqliteTestRunRepository(database).get(id))!;
      expect(cancelled.state, TestRunState.collecting);
      expect(cancelled.error, isNull);
      expect(cancelled.steps.single.state, TestStepState.skipped);
      expect(
        (await SqliteVmRepository(database).get(run.vmId!))!.status.phase,
        VmPhase.stopped,
      );
      expect(runtime.drivers.activeSessionCount, 0);
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(stops.single.id))!.state,
        OperationState.succeeded,
      );
      expect(
        (await operations.get(run.operationId))!.state,
        OperationState.running,
      );
      expect(
        (await operations.get(action.operationId))!.state,
        OperationState.pending,
      );
    },
  );

  test(
    'a TestRun start deadline drains once and remains the primary outcome',
    () async {
      final created = DateTime.now().toUtc();
      var observed = created;
      final id = await accept(timeoutSeconds: 60, now: () => created);
      await provision();
      final runtime = await openRuntime();
      final worker = TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
        now: () => observed,
      );
      await worker.dispatchOnce();
      final run = (await SqliteTestRunRepository(database).get(id))!;
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      final controller = (await runtime.registry.get(run.vmId!))!;
      await controller.waitUntilIdle();
      expect(controller.state.phase, VmPhase.starting);
      observed = created.add(const Duration(seconds: 61));
      expect((await worker.dispatchOnce()).single.error, isNull);
      final action = await TestRunApplicationService(database: database)
          .cancelRun(
            TestRunCancelCommand(
              testRunId: id,
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
            ),
          );
      expect((await worker.dispatchOnce()).single.error, isNull);
      final operations = SqliteOperationRepository(database);
      final stops = (await operations.list())
          .where((op) => op.type == 'vm.stop')
          .toList();
      expect(stops, hasLength(1));
      expect(stops.single.deadlineAt, isNull);
      expect(
        (await SqliteTestRunRepository(database).get(id))!.state,
        TestRunState.startingVm,
      );
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      expect(
        (await waitOperation(stops.single.id)).state,
        OperationState.succeeded,
      );
      expect((await worker.dispatchOnce()).single.error, isNull);
      final expired = (await SqliteTestRunRepository(database).get(id))!;
      expect(expired.state, TestRunState.collecting);
      expect(expired.error!.code, ErrorCode.waitTimeout);
      expect(expired.steps.single.state, TestStepState.skipped);
      expect(
        (await SqliteVmRepository(database).get(run.vmId!))!.status.phase,
        VmPhase.stopped,
      );
      expect(runtime.drivers.activeSessionCount, 0);
      expect(
        (await operations.get(run.operationId))!.state,
        OperationState.running,
      );
      expect(
        (await operations.get(action.operationId))!.state,
        OperationState.pending,
      );
    },
  );

  test(
    'v12 catalog upgrade preserves and starts a provisioned TestRun once',
    () async {
      final id = await accept();
      await provision();
      final original = (await SqliteTestRunRepository(database).get(id))!;
      database.close();
      final legacy = sqlite3.open('${temporary.path}/catalog.db');
      legacy.execute('DROP INDEX test_runs_starting_idx');
      legacy.execute('DROP TABLE test_run_vm_start');
      legacy.execute('DELETE FROM schema_migrations WHERE version = 13');
      legacy.userVersion = 12;
      legacy.dispose();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect(database.schemaVersion, 13);
      final restored = (await SqliteTestRunRepository(database).get(id))!;
      expect(restored.toJson()['spec'], original.toJson()['spec']);
      expect(restored.vmId, original.vmId);
      expect(restored.operationId, original.operationId);
      expect(restored.state, TestRunState.startingVm);
      final runtime = await openRuntime();
      final worker = TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      );
      expect((await worker.dispatchOnce()).single.error, isNull);
      final starts = (await SqliteOperationRepository(
        database,
      ).list()).where((op) => op.type == 'vm.start').toList();
      expect(starts, hasLength(1));
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      await (await runtime.registry.get(restored.vmId!))!.waitUntilIdle();
      runtime.clock.runUntilIdle();
      expect(
        (await waitOperation(starts.single.id)).state,
        OperationState.succeeded,
      );
      expect((await worker.dispatchOnce()).single.error, isNull);
      expect(
        (await SqliteTestRunRepository(database).get(id))!.state,
        TestRunState.waitingReady,
      );
      expect(await SqliteVmRepository(database).list(), hasLength(1));
    },
  );

  test(
    'an unrelated driver generation cannot satisfy TestRun start ownership',
    () async {
      final id = await accept();
      await provision();
      final runtime = await openRuntime();
      final worker = TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      );
      expect((await worker.dispatchOnce()).single.error, isNull);
      final run = (await SqliteTestRunRepository(database).get(id))!;
      final original = (await SqliteOperationRepository(
        database,
      ).list()).singleWhere((op) => op.type == 'vm.start');
      final controller = (await runtime.registry.get(run.vmId!))!;
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      await controller.waitUntilIdle();
      runtime.clock.runUntilIdle();
      expect(
        (await waitOperation(original.id)).state,
        OperationState.succeeded,
      );
      final generation = (await SqliteVmRepository(
        database,
      ).get(run.vmId!))!.status.driverGeneration;
      final stopped = await acceptLifecycle(
        runtime.registry,
        run.vmId!,
        VmLifecycleAction.stop,
      );
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      expect(
        (await waitOperation(stopped.operationId)).state,
        OperationState.succeeded,
      );
      final restarted = await acceptLifecycle(
        runtime.registry,
        run.vmId!,
        VmLifecycleAction.start,
      );
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      await controller.waitUntilIdle();
      runtime.clock.runUntilIdle();
      expect(
        (await waitOperation(restarted.operationId)).state,
        OperationState.succeeded,
      );
      expect(
        (await SqliteVmRepository(
          database,
        ).get(run.vmId!))!.status.driverGeneration,
        greaterThan(generation),
      );
      expect((await worker.dispatchOnce()).single.error, isNull);
      final failed = (await SqliteTestRunRepository(database).get(id))!;
      expect(failed.state, TestRunState.collecting);
      expect(failed.error!.code, ErrorCode.vmOperationConflict);
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: id,
        )).where((event) => event.type == 'test_run.vm_started'),
        isEmpty,
      );
      expect(
        (await SqliteVmRepository(database).get(run.vmId!))!.status.phase,
        VmPhase.running,
      );
      expect(runtime.drivers.activeSessionCount, 1);
    },
  );

  test(
    'a VM start failure retains its cause while another TestRun progresses',
    () async {
      final bad = await accept();
      final good = await accept();
      await provision();
      final runs = SqliteTestRunRepository(database);
      final badVm = (await runs.get(bad))!.vmId!;
      final runtime = await openRuntime(
        scenarioForLaunch: (launch) => launch.correlation.vmId == badVm
            ? FakeRuntimeDriverScenario(
                startFailures: [
                  RuntimeDriverError(
                    code: RuntimeDriverErrorCode.runtimeStartFailed,
                    message: 'Injected TestRun boot rejection',
                    retryable: false,
                    details: JsonObjectValue.fromJson({
                      'test_fault': 'native_start',
                    }),
                  ),
                ],
              )
            : const FakeRuntimeDriverScenario(),
      );
      final worker = TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      );
      expect(
        (await worker.dispatchOnce()).every((item) => item.error == null),
        isTrue,
      );
      expect(
        (await runtime.commands.dispatchOnce()).every(
          (item) => item.error == null,
        ),
        isTrue,
      );
      for (final id in [bad, good]) {
        await (await runtime.registry.get(
          (await runs.get(id))!.vmId!,
        ))!.waitUntilIdle();
      }
      runtime.clock.runUntilIdle();
      final children = (await SqliteOperationRepository(
        database,
      ).list()).where((op) => op.type == 'vm.start').toList();
      expect(children, hasLength(2));
      final badStart = await waitOperation(
        children.singleWhere((op) => op.resourceId == badVm).id,
      );
      expect(badStart.state, OperationState.failed);
      expect(badStart.error!.code, ErrorCode.driverStartFailed);
      await waitOperation(
        children.singleWhere((op) => op.resourceId != badVm).id,
      );
      expect(
        (await worker.dispatchOnce()).every((item) => item.error == null),
        isTrue,
      );
      final failed = (await runs.get(bad))!;
      expect(failed.state, TestRunState.collecting);
      expect(failed.error!.code, badStart.error!.code);
      expect(failed.error!.message, badStart.error!.message);
      expect(failed.error!.retryable, badStart.error!.retryable);
      expect(failed.error!.details.toJson()['cause'], badStart.error!.toJson());
      expect(
        failed.error!.details.toJson()['start_operation_id'],
        badStart.id.value,
      );
      expect(failed.steps.single.state, TestStepState.skipped);
      expect((await runs.get(good))!.state, TestRunState.waitingReady);
      expect(runtime.drivers.activeSessionCount, 1);
    },
  );

  for (final deadline in [false, true]) {
    test(
      deadline
          ? 'a TestRun deadline stays primary after a conflicting restart'
          : 'a newer runtime cannot be reported as a drained TestRun cancellation',
      () async {
        final created = DateTime.now().toUtc();
        var observed = created;
        final id = await accept(
          timeoutSeconds: deadline ? 60 : null,
          now: () => created,
        );
        await provision();
        final runtime = await openRuntime();
        final worker = TestRunVmStartWorker(
          database: database,
          registry: runtime.registry,
          now: () => observed,
        );
        await worker.dispatchOnce();
        final run = (await SqliteTestRunRepository(database).get(id))!;
        final controller = (await runtime.registry.get(run.vmId!))!;
        final operations = SqliteOperationRepository(database);
        final first = (await operations.list()).singleWhere(
          (op) => op.type == 'vm.start',
        );
        expect((await runtime.commands.dispatchOnce()).single.error, isNull);
        await controller.waitUntilIdle();
        runtime.clock.runUntilIdle();
        await waitOperation(first.id);
        if (deadline) {
          observed = created.add(const Duration(seconds: 61));
        } else {
          await TestRunApplicationService(database: database).cancelRun(
            TestRunCancelCommand(
              testRunId: id,
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
            ),
          );
        }
        expect((await worker.dispatchOnce()).single.error, isNull);
        final stop = (await operations.list()).singleWhere(
          (op) => op.type == 'vm.stop',
        );
        expect((await runtime.commands.dispatchOnce()).single.error, isNull);
        expect((await waitOperation(stop.id)).state, OperationState.succeeded);
        final restart = await acceptLifecycle(
          runtime.registry,
          run.vmId!,
          VmLifecycleAction.start,
        );
        expect((await runtime.commands.dispatchOnce()).single.error, isNull);
        await controller.waitUntilIdle();
        runtime.clock.runUntilIdle();
        expect(
          (await waitOperation(restart.operationId)).state,
          OperationState.succeeded,
        );
        expect((await worker.dispatchOnce()).single.error, isNull);
        final failed = (await SqliteTestRunRepository(database).get(id))!;
        expect(failed.state, TestRunState.collecting);
        if (deadline) {
          expect(failed.error!.code, ErrorCode.waitTimeout);
          final recorded = (await SqliteEventRepository(database).list(
            testRunId: id,
          )).singleWhere((event) => event.type == 'test_run.failure_recorded');
          final failure =
              recorded.payload.toJson()['failure'] as Map<String, Object?>;
          expect(failure['code'], 'VM_OPERATION_CONFLICT');
          expect(failure['retryable'], isFalse);
          expect(
            failure['details'],
            containsPair('stop_operation_id', stop.id.value),
          );
        } else {
          expect(failed.error!.code, ErrorCode.vmOperationConflict);
          expect(
            failed.error!.details.toJson()['stop_operation_id'],
            stop.id.value,
          );
          expect(
            failed.error!.details.toJson().containsKey('start_operation_id'),
            isFalse,
          );
        }
        expect(
          (await SqliteVmRepository(database).get(run.vmId!))!.status.phase,
          VmPhase.running,
        );
        expect(runtime.drivers.activeSessionCount, 1);
      },
    );
  }

  test(
    'registry shutdown defers a TestRun start without failing the run',
    () async {
      final id = await accept();
      await provision();
      final runtime = await openRuntime();
      await runtime.registry.shutdown();
      final outcome = (await TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      ).dispatchOnce()).single;
      expect(outcome.error, isA<VmRegistryClosedException>());
      final run = (await SqliteTestRunRepository(database).get(id))!;
      expect(run.state, TestRunState.startingVm);
      expect(run.error, isNull);
      expect(run.steps.single.state, TestStepState.pending);
      expect(
        (await SqliteOperationRepository(
          database,
        ).list()).where((op) => op.type == 'vm.start'),
        isEmpty,
      );
      await runtime.close();
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final restored = await openRuntime();
      expect(
        (await TestRunVmStartWorker(
          database: database,
          registry: restored.registry,
        ).dispatchOnce()).single.error,
        isNull,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).list()).where((op) => op.type == 'vm.start'),
        hasLength(1),
      );
      expect(restored.drivers.activeSessionCount, 0);
    },
  );

  test(
    'a failed start observation retains request and generation correlation',
    () async {
      final id = await accept();
      await provision();
      final runtime = await openRuntime();
      final worker = TestRunVmStartWorker(
        database: database,
        registry: runtime.registry,
      );
      await worker.dispatchOnce();
      final run = (await SqliteTestRunRepository(database).get(id))!;
      final operations = SqliteOperationRepository(database);
      final requestId = (await operations.get(run.operationId))!.requestId;
      final start = (await operations.list()).singleWhere(
        (op) => op.type == 'vm.start',
      );
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      await (await runtime.registry.get(run.vmId!))!.waitUntilIdle();
      runtime.clock.runUntilIdle();
      await waitOperation(start.id);
      final generation = (await SqliteVmRepository(
        database,
      ).get(run.vmId!))!.status.driverGeneration;
      final events = SqliteEventRepository(database);
      final before = await events.list(testRunId: id);
      await database.transaction(
        (db) => db.execute('''CREATE TRIGGER reject_ready
      BEFORE UPDATE OF state ON test_runs WHEN NEW.id = '${id.value}'
        AND NEW.state = 'waiting_ready'
      BEGIN SELECT RAISE(ABORT, 'ready checkpoint fault'); END'''),
      );
      final outcome = (await worker.dispatchOnce()).single;
      expect(outcome.error, isA<SqliteException>());
      expect(outcome.testRunId, id);
      expect(outcome.operationId, run.operationId);
      expect(outcome.vmId, run.vmId);
      expect(outcome.requestId, requestId);
      expect(outcome.driverGeneration, generation);
      expect(
        (await SqliteTestRunRepository(database).get(id))!.state,
        TestRunState.startingVm,
      );
      expect(await events.list(testRunId: id), before);
      await database.transaction(
        (db) => db.execute('DROP TRIGGER reject_ready'),
      );
      expect((await worker.dispatchOnce()).single.error, isNull);
      expect(
        (await SqliteTestRunRepository(database).get(id))!.state,
        TestRunState.waitingReady,
      );
      expect(
        (await operations.list()).where((op) => op.type == 'vm.start'),
        hasLength(1),
      );
      expect(runtime.drivers.activeSessionCount, 1);
    },
  );

  test(
    'concurrent start scans after reopen reuse one durable intent beyond cache retention',
    () async {
      final id = await accept();
      await provision();
      final first = await openRuntime();
      await TestRunVmStartWorker(
        database: database,
        registry: first.registry,
      ).dispatchOnce();
      final original = (await SqliteOperationRepository(
        database,
      ).list()).singleWhere((op) => op.type == 'vm.start');
      await first.close();
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final restored = await openRuntime();
      final other = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      try {
        final outcomes = await Future.wait([
          TestRunVmStartWorker(
            database: database,
            registry: restored.registry,
            now: () => DateTime.now().add(const Duration(days: 31)),
          ).dispatchOnce(),
          TestRunVmStartWorker(
            database: other,
            registry: restored.registry,
          ).dispatchOnce(),
        ]);
        expect(
          outcomes.expand((pass) => pass).every((item) => item.error == null),
          isTrue,
        );
      } finally {
        other.close();
      }
      final starts = (await SqliteOperationRepository(
        database,
      ).list()).where((op) => op.type == 'vm.start').toList();
      expect(starts, hasLength(1));
      expect(starts.single.id, original.id);
      expect(restored.drivers.activeSessionCount, 0);
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: id,
        )).where((event) => event.type == 'test_run.vm_start_accepted'),
        hasLength(1),
      );
      expect((await restored.commands.dispatchOnce()).single.error, isNull);
      final run = (await SqliteTestRunRepository(database).get(id))!;
      await (await restored.registry.get(run.vmId!))!.waitUntilIdle();
      restored.clock.runUntilIdle();
      await SqliteOperationWaiter(
        operations: SqliteOperationRepository(database),
        events: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 1),
        ),
      ).wait(
        OperationWaitCommand(
          operationId: original.id,
          timeout: const Duration(seconds: 5),
        ),
      );
      await TestRunVmStartWorker(
        database: database,
        registry: restored.registry,
      ).dispatchOnce();
      expect(
        (await SqliteTestRunRepository(database).get(id))!.state,
        TestRunState.waitingReady,
      );
    },
  );

  test('accepted image TestRun provisions one durable temporary VM', () async {
    final id = await accept(overrides: VmSpecPatch(cpu: 4));
    await TestRunProvisioningWorker(database: database).dispatchOnce();
    final runs = SqliteTestRunRepository(database);
    expect((await runs.get(id))!.state, TestRunState.provisioning);
    final vms = await SqliteVmRepository(database).list();
    expect(vms, hasLength(1));
    final vm = vms.single;
    expect(vm.spec.cpu, 4);
    expect(vm.spec.memoryBytes, 2 * 1024 * 1024 * 1024);
    expect(vm.spec.graphics.enabled, isFalse);
    expect(vm.spec.autostart, isFalse);
    expect(
      (vm.spec.boot as LinuxKernelBoot).commandLine,
      'console=hvc0 root=/dev/vda',
    );
    final results = await VmProvisioningWorker(
      work: SqliteVmProvisioningWorkRepository(database),
      bundles: VmBundleStore(
        database: database,
        bundles: bundles,
        images: images,
      ),
      owner: 'test',
    ).dispatchOnce();
    expect(results.single.completion, VmProvisioningCompletionKind.succeeded);
    await TestRunProvisioningWorker(database: database).dispatchOnce();
    final run = (await runs.get(id))!;
    expect(run.state, TestRunState.startingVm);
    expect(run.vmId, vm.metadata.id);
    expect(
      await File(
        '${bundles.path}/${run.vmId!.value}.gaovm/disks/root.raw',
      ).readAsString(),
      'original disk',
    );
    expect(
      (await SqliteOperationRepository(database).get(run.operationId))!.state,
      OperationState.running,
    );
  });

  test(
    'background dispatch automatically provisions successive bounded runs',
    () async {
      final ids = [await accept(), await accept()];
      final done = Completer<void>();
      final outcomes = <TestRunProvisioningOutcome>[];
      final loop = TestRunProvisioningDispatchLoop(
        worker: TestRunProvisioningWorker(database: database),
        batchLimit: 1,
        interval: const Duration(milliseconds: 1),
        onDispatch: (pass) {
          expect(pass.length, lessThanOrEqualTo(1));
          outcomes.addAll(pass);
          if (outcomes.length == 2 && !done.isCompleted) done.complete();
        },
        onError: done.completeError,
      );
      try {
        loop.start();
        await done.future.timeout(const Duration(seconds: 5));
        expect(outcomes.every((item) => item.error == null), isTrue);
        for (final id in ids) {
          expect(
            (await SqliteTestRunRepository(database).get(id))!.state,
            TestRunState.provisioning,
          );
        }
        expect(await SqliteVmRepository(database).list(), hasLength(2));
      } finally {
        await loop.close();
      }
    },
  );

  test(
    'parallel scans and reopen keep one isolated VM per run from the same image',
    () async {
      final ids = [await accept(), await accept()];
      final other = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      try {
        final outcomes = await Future.wait([
          TestRunProvisioningWorker(database: database).dispatchOnce(),
          TestRunProvisioningWorker(database: other).dispatchOnce(),
        ]);
        expect(
          outcomes.expand((pass) => pass).every((item) => item.error == null),
          isTrue,
        );
      } finally {
        other.close();
      }
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      expect(await SqliteVmRepository(database).list(), hasLength(2));
      expect(
        (await SqliteOperationRepository(
          database,
        ).list()).where((op) => op.type == 'vm.create'),
        hasLength(2),
      );
      final published = await VmProvisioningWorker(
        work: SqliteVmProvisioningWorkRepository(database),
        bundles: VmBundleStore(
          database: database,
          bundles: bundles,
          images: images,
        ),
        owner: 'test',
      ).dispatchOnce();
      expect(published, hasLength(2));
      expect(
        published.every(
          (item) => item.completion == VmProvisioningCompletionKind.succeeded,
        ),
        isTrue,
      );
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      final runs = [
        for (final id in ids)
          (await SqliteTestRunRepository(database).get(id))!,
      ];
      expect(runs.every((run) => run.state == TestRunState.startingVm), isTrue);
      expect(runs.map((run) => run.vmId).toSet(), hasLength(2));
      final first = File(
        '${bundles.path}/${runs.first.vmId!.value}.gaovm/disks/root.raw',
      );
      final second = File(
        '${bundles.path}/${runs.last.vmId!.value}.gaovm/disks/root.raw',
      );
      await first.writeAsString('guest mutation');
      expect(await second.readAsString(), 'original disk');
      expect(
        await File(
          '${images.path}/sha256-${source.digest.substring(7)}/objects/disk',
        ).readAsString(),
        'original disk',
      );
    },
  );

  test(
    'a checkpoint failure rolls back one run without starving another',
    () async {
      final bad = await accept();
      final good = await accept();
      final events = SqliteEventRepository(database);
      final before = await events.list(testRunId: bad);
      await database.transaction((db) async {
        db.execute(
          '''CREATE TRIGGER reject_checkpoint BEFORE INSERT ON test_run_vm_provisioning
        WHEN NEW.test_run_id = '${bad.value}' BEGIN SELECT RAISE(ABORT, 'checkpoint fault'); END;''',
        );
      });
      final outcomes = await TestRunProvisioningWorker(
        database: database,
      ).dispatchOnce();
      expect(
        outcomes.singleWhere((item) => item.testRunId == bad).error,
        isA<SqliteException>(),
      );
      expect(
        outcomes.singleWhere((item) => item.testRunId == good).error,
        isNull,
      );
      final runs = SqliteTestRunRepository(database);
      expect((await runs.get(bad))!.state, TestRunState.pending);
      expect((await runs.get(good))!.state, TestRunState.provisioning);
      expect(await events.list(testRunId: bad), before);
      expect(
        (await SqliteVmRepository(
          database,
        ).list()).single.metadata.labels['gaovm.test-run'],
        good.value,
      );
      await database.transaction((db) async {
        db.execute('DROP TRIGGER reject_checkpoint');
      });
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      expect(await SqliteVmRepository(database).list(), hasLength(2));
    },
  );

  test(
    'autostart cannot bypass TestRun execution and cancellation phases',
    () async {
      final id = await accept(overrides: VmSpecPatch(autostart: true));
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      final run = (await SqliteTestRunRepository(database).get(id))!;
      expect(run.state, TestRunState.collecting);
      expect(run.error!.code, ErrorCode.vmSpecInvalid);
      expect(await SqliteVmRepository(database).list(), isEmpty);
    },
  );

  test(
    'a real bundle publication failure advances to collection with its cause',
    () async {
      final id = await accept();
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      await File(
        '${images.path}/sha256-${source.digest.substring(7)}/objects/kernel',
      ).delete();
      final result = (await VmProvisioningWorker(
        work: SqliteVmProvisioningWorkRepository(database),
        bundles: VmBundleStore(
          database: database,
          bundles: bundles,
          images: images,
        ),
        owner: 'test',
      ).dispatchOnce()).single;
      expect(result.completion, VmProvisioningCompletionKind.failed);
      final child = (await SqliteOperationRepository(
        database,
      ).get(result.operationId))!;
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      final run = (await SqliteTestRunRepository(database).get(id))!;
      expect(run.state, TestRunState.collecting);
      expect(run.vmId, child.resourceId);
      expect(run.error!.code, child.error!.code);
      expect(
        run.error!.details.toJson()['provisioning_operation_id'],
        child.id.value,
      );
      expect(run.steps.single.state, TestStepState.skipped);
    },
  );

  test('standalone disk sources use an explicit boot override', () async {
    final store = ImageStore(database, Directory(images.path));
    final file = await File(
      '${temporary.path}/standalone',
    ).writeAsString('disk');
    final disk = await store.importFile(file, type: ImageType.rawDisk);
    final kernel = await store.importFile(file, type: ImageType.linuxKernel);
    final id = await accept(
      from: disk,
      overrides: VmSpecPatch(boot: LinuxKernelBoot(kernelImageId: kernel.id)),
    );
    await TestRunProvisioningWorker(database: database).dispatchOnce();
    expect(
      (await SqliteTestRunRepository(database).get(id))!.state,
      TestRunState.provisioning,
    );
    final vm = (await SqliteVmRepository(database).list()).single;
    expect((vm.spec.boot as LinuxKernelBoot).kernelImageId, kernel.id);
    expect(
      (vm.spec.disks.single.source as ManagedImageDiskSource).imageId,
      disk.id,
    );
  });

  test(
    'invalid provisioning fails durably without orphaning a VM or starving another run',
    () async {
      final file = await File(
        '${temporary.path}/bad-disk',
      ).writeAsString('kernel');
      final kernel = await ImageStore(
        database,
        Directory(images.path),
      ).importFile(file, type: ImageType.linuxKernel);
      final bad = await accept(
        overrides: VmSpecPatch(
          disks: [
            VmDisk(
              id: 'root',
              source: ManagedImageDiskSource(kernel.id),
              writable: true,
            ),
          ],
        ),
      );
      final good = await accept();
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      final runs = SqliteTestRunRepository(database);
      final failed = (await runs.get(bad))!;
      expect(failed.state, TestRunState.collecting);
      expect(failed.error!.code, ErrorCode.vmSpecInvalid);
      expect(failed.steps.single.state, TestStepState.skipped);
      expect((await runs.get(good))!.state, TestRunState.provisioning);
      final vms = await SqliteVmRepository(database).list();
      expect(vms, hasLength(1));
      expect(vms.single.metadata.labels['gaovm.test-run'], good.value);
      final operations = await SqliteOperationRepository(database).list();
      expect(operations.where((op) => op.type == 'vm.create'), hasLength(1));
      expect(
        operations.singleWhere((op) => op.id == failed.operationId).state,
        OperationState.running,
      );
    },
  );

  test(
    'cancellation before provisioning creates no VM and awaits real cleanup',
    () async {
      final id = await accept();
      final action = await TestRunApplicationService(database: database)
          .cancelRun(
            TestRunCancelCommand(
              testRunId: id,
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
            ),
          );
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      final run = (await SqliteTestRunRepository(database).get(id))!;
      expect(run.state, TestRunState.collecting);
      expect(run.vmId, isNull);
      expect(run.steps.single.state, TestStepState.skipped);
      expect(await SqliteVmRepository(database).list(), isEmpty);
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(run.operationId))!.state,
        OperationState.running,
      );
      expect(
        (await operations.get(action.operationId))!.state,
        OperationState.pending,
      );
    },
  );
}

final class _Metrics implements HostMetricsSource {
  @override
  Future<HostMetrics> sample() async => const HostMetrics(
    logicalCpuCount: 8,
    totalMemoryBytes: 16 * 1024 * 1024 * 1024,
    availableMemoryBytes: 8 * 1024 * 1024 * 1024,
    freeDiskBytes: 1024 * 1024 * 1024,
    unmanagedDriverProcesses: 0,
  );
}

final class _StartTimerScheduler implements VmTimerScheduler {
  final handles = <_StartTimerHandle>[];
  int get activeCount => handles.where((handle) => handle.isActive).length;

  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) {
    final handle = _StartTimerHandle(callback);
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

final class _StartTimerHandle implements VmTimerHandle {
  _StartTimerHandle(this.callback);
  final void Function() callback;

  @override
  bool isActive = true;

  @override
  void cancel() => isActive = false;
}
