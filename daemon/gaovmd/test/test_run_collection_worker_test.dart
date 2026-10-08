import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/test_run_collection_worker.dart';
import 'package:gaovmd/src/test_run_collection_dispatch_loop.dart';
import 'package:gaovmd/src/test_run_provisioning_worker.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OwnedImageDirectory bundles;
  late OwnedImageDirectory artifactRoot;
  late OwnedImageDirectory images;
  late Image source;
  late Image kernel;

  ArtifactApplicationService artifactService() =>
      ArtifactApplicationService(database: database, directory: artifactRoot);
  TestRunCollectionWorker collector() => TestRunCollectionWorker(
    database: database,
    bundles: bundles,
    artifacts: artifactService(),
  );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tr-collection-');
    imageFileMode(temporary.path, 0x1c0);
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    for (final name in ['vms', 'artifacts']) {
      final child = await Directory('${temporary.path}/$name').create();
      imageFileMode(child.path, 0x1c0);
    }
    bundles = await OwnedImageDirectory.open(
      Directory('${temporary.path}/vms'),
    );
    artifactRoot = await OwnedImageDirectory.open(
      Directory('${temporary.path}/artifacts'),
    );
    final kernelFile = await File(
      '${temporary.path}/kernel',
    ).writeAsString('kernel');
    final store = ImageStore(database, Directory('${temporary.path}/images'));
    kernel = await store.importFile(kernelFile, type: ImageType.linuxKernel);
    source = await store.importFile(
      await File('${temporary.path}/disk').writeAsString('root disk'),
      type: ImageType.rawDisk,
    );
    images = await OwnedImageDirectory.open(
      Directory('${temporary.path}/images'),
    );
  });

  tearDown(() async {
    bundles.close();
    artifactRoot.close();
    images.close();
    database.close();
    await temporary.delete(recursive: true);
  });

  Future<TestRunId> accept() async {
    final spec = TestRunSpec(
      source: ImageTestRunSource(source.id),
      vmOverrides: VmSpecPatch.fromJson({
        'boot': {'type': 'linux_kernel', 'kernel_image_id': kernel.id.value},
      }),
      wait: VmWaitSpec(
        condition: WaitCondition.runtimeRunning,
        timeoutSeconds: 30,
      ),
      steps: [
        TestStepRequest(argv: ['true'], timeoutSeconds: 30),
      ],
      cleanup: CleanupPolicy.deleteOnSuccess,
      retainOnFailure: true,
    );
    final accepted = await TestRunApplicationService(database: database).create(
      TestRunCreateCommand(
        spec: spec,
        requestId: RequestId.generate(),
        idempotencyKey: null,
        requestBody: utf8.encode(jsonEncode(spec.toJson())),
      ),
    );
    return accepted.resourceId as TestRunId;
  }

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
      metrics: _CollectionMetrics(),
      limits: HostSchedulerLimits(
        maxRunningVms: 3,
        maxConcurrentBoots: 3,
        maxDriverProcesses: 3,
        maxCpuCount: 8,
        maxMemoryBytes: 8 * 1024 * 1024 * 1024,
        minFreeDiskBytes: 0,
      ),
      ownerId: 'collection-runtime',
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
      owner: 'collection-runtime',
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

  Future<TestRun> prepareCollectingVm() async {
    final id = await accept();
    await TestRunProvisioningWorker(database: database).dispatchOnce();
    await VmProvisioningWorker(
      work: SqliteVmProvisioningWorkRepository(database),
      bundles: VmBundleStore(
        database: database,
        bundles: bundles,
        images: images,
      ),
      owner: 'collection-test',
    ).dispatchOnce();
    await TestRunProvisioningWorker(database: database).dispatchOnce();
    return SqliteTestRunRepository(database).transition(
      id,
      expectedState: TestRunState.startingVm,
      nextState: TestRunState.collecting,
      outcome: TestRunState.failed,
      error: OperationError(
        code: ErrorCode.guestExecFailed,
        message: 'Test command failed.',
        retryable: false,
        details: JsonObjectValue.fromJson({'exit_code': 37}),
      ),
    );
  }

  test(
    'collection retries storage faults with correlation and leaves a failed VM running',
    () async {
      final run = await prepareCollectingVm();
      final runtime = await openRuntime();
      final start =
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
              action: VmLifecycleAction.start,
            ),
          );
      expect((await runtime.commands.dispatchOnce()).single.error, isNull);
      await (await runtime.registry.get(run.vmId!))!.waitUntilIdle();
      runtime.clock.runUntilIdle();
      final completed =
          await SqliteOperationWaiter(
            operations: SqliteOperationRepository(database),
            events: SqliteDurableEventFeed(
              database,
              pollInterval: const Duration(milliseconds: 1),
            ),
          ).wait(
            OperationWaitCommand(
              operationId: start.operationId,
              timeout: const Duration(seconds: 5),
            ),
          );
      expect(completed.state, OperationState.succeeded);
      final running = (await SqliteVmRepository(database).get(run.vmId!))!;
      final logs = '${bundles.path}/${run.vmId!.value}.gaovm/logs';
      await File('$logs/driver.log').writeAsString('active driver');
      final parent = (await SqliteOperationRepository(
        database,
      ).get(run.operationId))!;
      await database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER reject_artifact BEFORE INSERT ON artifacts
      BEGIN SELECT RAISE(ABORT, 'storage fault'); END
    '''),
      );
      final failed = (await collector().dispatchOnce()).single;
      expect(failed.error, isA<SqliteException>());
      expect(failed.collected, isFalse);
      expect(failed.testRunId, run.id);
      expect(failed.operationId, run.operationId);
      expect(failed.requestId, parent.requestId);
      expect(failed.vmId, run.vmId);
      expect(failed.driverGeneration, running.status.driverGeneration);
      expect(
        (await SqliteTestRunRepository(database).get(run.id))!.error,
        run.error,
      );
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: run.id,
        )).where((event) => event.type == 'test_run.failure_recorded'),
        isEmpty,
      );
      await database.transaction(
        (db) => db.execute('DROP TRIGGER reject_artifact'),
      );
      expect((await collector().dispatchOnce()).single.error, isNull);
      final result = (await artifactService().listForTestRun(
        run.id,
      )).items.singleWhere((item) => item.kind == ArtifactKind.result);
      final body =
          jsonDecode(
                await utf8.decoder
                    .bind((await artifactService().download(result.id)).bytes)
                    .join(),
              )
              as Map;
      expect(body['driver_generation'], running.status.driverGeneration);
      final retained = (await SqliteVmRepository(database).get(run.vmId!))!;
      expect(retained.status.phase, VmPhase.running);
      expect(retained.status.desiredState, DesiredState.running);
      expect(retained.status.driverGeneration, running.status.driverGeneration);
      expect(runtime.drivers.activeSessionCount, 1);
    },
  );

  test(
    'background collection completes successive runs without client polling',
    () async {
      final runs = [await prepareCollectingVm(), await prepareCollectingVm()];
      for (final run in runs) {
        await File(
          '${bundles.path}/${run.vmId!.value}.gaovm/logs/driver.log',
        ).writeAsString(run.id.value);
      }
      final completed = Completer<void>();
      final collected = <TestRunId>{};
      final loop = TestRunCollectionDispatchLoop(
        worker: collector(),
        interval: const Duration(milliseconds: 1),
        batchLimit: 1,
        onDispatch: (pass) {
          expect(pass.length, lessThanOrEqualTo(1));
          for (final item in pass) {
            expect(item.error, isNull);
            if (item.collected) collected.add(item.testRunId);
          }
          if (collected.length == runs.length && !completed.isCompleted)
            completed.complete();
        },
        onError: completed.completeError,
      );
      try {
        loop.start();
        await completed.future.timeout(const Duration(seconds: 5));
        for (final run in runs) {
          expect(
            (await artifactService().listForTestRun(run.id)).items,
            hasLength(2),
          );
          expect(
            (await SqliteTestRunRepository(database).get(run.id))!.state,
            TestRunState.collecting,
          );
        }
      } finally {
        await loop.close();
      }
    },
  );

  for (final checkpoint in ['staged', 'published', 'committed']) {
    test(
      'a collection process exit at $checkpoint reuses reserved artifact identities',
      () async {
        final run = await prepareCollectingVm();
        final logs = '${bundles.path}/${run.vmId!.value}.gaovm/logs';
        await File('$logs/driver.log').writeAsString('driver');
        await File('$logs/serial.log').writeAsString('serial');
        final child = await Process.start(Platform.resolvedExecutable, [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          'test/helpers/test_run_collection_crash_child.dart',
          temporary.path,
          checkpoint,
        ]);
        final output = child.stdout.transform(utf8.decoder).join();
        final errors = child.stderr.transform(utf8.decoder).join();
        var exited = false;
        try {
          final code = await child.exitCode.timeout(
            const Duration(seconds: 15),
          );
          exited = true;
          expect(code, 73, reason: await errors);
          await output;
        } finally {
          if (!exited) child.kill(ProcessSignal.sigkill);
          await child.exitCode;
        }
        database.close();
        database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
        final recovery = await artifactService().reconcile();
        expect(recovery.damagedArtifactIds, isEmpty);
        expect(recovery.retainedNames, isEmpty);
        final finished = (await collector().dispatchOnce()).single;
        expect(finished.error, isNull);
        expect(finished.collected, isTrue);
        final items = (await artifactService().listForTestRun(run.id)).items;
        expect(items, hasLength(3));
        expect(items.map((item) => item.kind).toSet(), {
          ArtifactKind.driver,
          ArtifactKind.serial,
          ArtifactKind.result,
        });
        expect(
          (await SqliteEventRepository(database).list(
            testRunId: run.id,
          )).where((event) => event.type == 'test_run.collection_planned'),
          hasLength(1),
        );
        expect(
          (await SqliteEventRepository(database).list(
            testRunId: run.id,
          )).where((event) => event.type == 'artifact.created'),
          hasLength(3),
        );
      },
    );
  }

  test(
    'a linked log is reported without reading it or starving another run',
    () async {
      final bad = await prepareCollectingVm();
      final good = await prepareCollectingVm();
      final badLogs = '${bundles.path}/${bad.vmId!.value}.gaovm/logs';
      final goodLogs = '${bundles.path}/${good.vmId!.value}.gaovm/logs';
      final outside = await File(
        '${temporary.path}/outside',
      ).writeAsString('private outside bytes');
      await Link('$badLogs/serial.log').create(outside.path);
      await File('$badLogs/driver.log').writeAsString('bad driver');
      await File('$goodLogs/driver.log').writeAsString('good driver');
      await File('$goodLogs/serial.log').writeAsString('good serial');
      final outcomes = await collector().dispatchOnce();
      expect(outcomes, hasLength(2));
      for (final outcome in outcomes) {
        expect(outcome.error, isNull, reason: outcome.testRunId.value);
        expect(outcome.collected, isTrue, reason: outcome.testRunId.value);
      }
      final badArtifacts = (await artifactService().listForTestRun(
        bad.id,
      )).items;
      expect(badArtifacts.map((item) => item.kind).toSet(), {
        ArtifactKind.driver,
        ArtifactKind.result,
      });
      expect(
        (await artifactService().listForTestRun(good.id)).items,
        hasLength(3),
      );
      final result = badArtifacts.singleWhere(
        (item) => item.kind == ArtifactKind.result,
      );
      final body =
          jsonDecode(
                await utf8.decoder
                    .bind((await artifactService().download(result.id)).bytes)
                    .join(),
              )
              as Map;
      final serial = (body['collection'] as List).cast<Map>().singleWhere(
        (entry) => entry['kind'] == 'serial',
      );
      expect(serial['state'], 'failed');
      expect(serial['error'], containsPair('code', 'INTERNAL_ERROR'));
      expect(jsonEncode(body), isNot(contains('private outside bytes')));
      expect(jsonEncode(body), isNot(contains(outside.path)));
      expect(
        (await SqliteTestRunRepository(database).get(bad.id))!.error,
        bad.error,
      );
      expect(await outside.readAsString(), 'private outside bytes');
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: bad.id,
        )).where((event) => event.type == 'test_run.failure_recorded'),
        hasLength(1),
      );
      expect(await collector().dispatchOnce(), isEmpty);
    },
  );

  test(
    'collection completion verifies artifacts committed before a checkpoint fault',
    () async {
      final run = await prepareCollectingVm();
      final logs = '${bundles.path}/${run.vmId!.value}.gaovm/logs';
      await File('$logs/driver.log').writeAsString('driver');
      await File('$logs/serial.log').writeAsString('serial');
      await database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER reject_collection_completion
      BEFORE UPDATE OF completed_at ON test_run_collection
      BEGIN SELECT RAISE(ABORT, 'completion fault'); END
    '''),
      );
      final first = (await collector().dispatchOnce()).single;
      expect(first.error, isA<SqliteException>());
      expect(first.collected, isFalse);
      final items = (await artifactService().listForTestRun(run.id)).items;
      expect(items, hasLength(3));
      final driver = items.singleWhere(
        (item) => item.kind == ArtifactKind.driver,
      );
      final payload = File('${artifactRoot.path}/${driver.id.value}/payload');
      imageFileMode(payload.path, 0x180);
      await payload.writeAsString('broken');
      imageFileMode(payload.path, 0x100);
      await database.transaction(
        (db) => db.execute('DROP TRIGGER reject_collection_completion'),
      );
      final damaged = (await collector().dispatchOnce()).single;
      expect(damaged.error, isA<ArtifactContentUnavailable>());
      expect(damaged.collected, isFalse);
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: run.id,
        )).where((event) => event.type == 'test_run.artifacts_collected'),
        isEmpty,
      );
      imageFileMode(payload.path, 0x180);
      await payload.writeAsString('driver');
      imageFileMode(payload.path, 0x100);
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final retried = (await collector().dispatchOnce()).single;
      expect(retried.error, isNull);
      expect(retried.collected, isTrue);
      expect((await artifactService().listForTestRun(run.id)).items, items);
    },
  );

  test(
    'collection publishes real rotated VM logs before marking artifacts complete',
    () async {
      final run = await prepareCollectingVm();
      final logs = '${bundles.path}/${run.vmId!.value}.gaovm/logs';
      await File('$logs/driver.log.3').writeAsBytes([0, 255, 10]);
      await File('$logs/driver.log.1').writeAsString('previous\n');
      await File('$logs/driver.log').writeAsString('current\n');
      await File('$logs/serial.log').writeAsString('console\n');
      final outcome = (await collector().dispatchOnce()).single;
      expect(outcome.error, isNull);
      expect(outcome.collected, isTrue);
      final items = (await artifactService().listForTestRun(run.id)).items;
      expect(items, hasLength(3));
      final driver = items.singleWhere(
        (item) => item.kind == ArtifactKind.driver,
      );
      final downloaded = await artifactService().download(driver.id);
      expect(await downloaded.bytes.expand((chunk) => chunk).toList(), [
        0,
        255,
        10,
        ...utf8.encode('previous\ncurrent\n'),
      ]);
      final serial = items.singleWhere(
        (item) => item.kind == ArtifactKind.serial,
      );
      expect(
        await utf8.decoder
            .bind((await artifactService().download(serial.id)).bytes)
            .join(),
        'console\n',
      );
      final result = items.singleWhere(
        (item) => item.kind == ArtifactKind.result,
      );
      final body =
          jsonDecode(
                await utf8.decoder
                    .bind((await artifactService().download(result.id)).bytes)
                    .join(),
              )
              as Map;
      expect(body['execution_outcome'], 'failed');
      expect((body['execution'] as Map)['error'], run.error!.toJson());
      expect(
        (body['collection'] as List)
            .map((entry) => (entry as Map)['artifact_id'])
            .toSet(),
        {driver.id.value, serial.id.value},
      );
      expect(
        (await SqliteTestRunRepository(database).get(run.id))!.error,
        run.error,
      );
      expect(
        (await SqliteVmRepository(
          database,
        ).get(run.vmId!))!.status.desiredState,
        DesiredState.stopped,
      );
    },
  );

  test(
    'a cancelled unprovisioned TestRun collects one durable execution snapshot',
    () async {
      final id = await accept();
      await TestRunApplicationService(database: database).cancelRun(
        TestRunCancelCommand(
          testRunId: id,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
        ),
      );
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      final before = (await SqliteTestRunRepository(database).get(id))!;
      expect(before.state, TestRunState.collecting);
      final outcomes = await collector().dispatchOnce();
      expect(outcomes, hasLength(1));
      expect(outcomes.single.error, isNull);
      expect(outcomes.single.collected, isTrue);
      final page = await artifactService().listForTestRun(id);
      expect(page.items, hasLength(1));
      final result = page.items.single;
      expect(result.kind, ArtifactKind.result);
      expect(result.operationId, before.operationId);
      final download = await artifactService().download(result.id);
      final body =
          jsonDecode(await utf8.decoder.bind(download.bytes).join()) as Map;
      expect(body['test_run_id'], id.value);
      expect(body['execution_outcome'], 'cancelled');
      expect(body['vm_id'], isNull);
      expect(
        (await SqliteTestRunRepository(database).get(id))!.state,
        TestRunState.collecting,
      );
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect(await collector().dispatchOnce(), isEmpty);
      expect((await artifactService().listForTestRun(id)).items, [result]);
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: id,
        )).where((event) => event.type == 'test_run.artifacts_collected'),
        hasLength(1),
      );
    },
  );
}

final class _CollectionMetrics implements HostMetricsSource {
  @override
  Future<HostMetrics> sample() async => const HostMetrics(
    logicalCpuCount: 8,
    totalMemoryBytes: 16 * 1024 * 1024 * 1024,
    availableMemoryBytes: 8 * 1024 * 1024 * 1024,
    freeDiskBytes: 1024 * 1024 * 1024,
    unmanagedDriverProcesses: 0,
  );
}
