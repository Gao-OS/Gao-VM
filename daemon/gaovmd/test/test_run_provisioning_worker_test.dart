import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/test_run_provisioning_worker.dart';
import 'package:gaovmd/src/test_run_provisioning_dispatch_loop.dart';
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
  openRuntime() async {
    final clock = ManualRuntimeScheduler();
    late VmRegistry registry;
    final drivers = RuntimeDriverEffectAdapter.scopedConfiguration(
      factory: FakeRuntimeDriverFactory(scheduler: clock),
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
