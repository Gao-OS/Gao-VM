import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/test_run_cleanup_worker.dart';
import 'package:gaovmd/src/test_run_cleanup_dispatch_loop.dart';
import 'package:gaovmd/src/test_run_collection_worker.dart';
import 'package:gaovmd/src/test_run_provisioning_worker.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OwnedImageDirectory bundles;
  late OwnedImageDirectory artifactRoot;
  late Image source;

  TestRunApplicationService service() =>
      TestRunApplicationService(database: database);
  ArtifactApplicationService artifacts() =>
      ArtifactApplicationService(database: database, directory: artifactRoot);
  TestRunCollectionWorker collector() => TestRunCollectionWorker(
    database: database,
    bundles: bundles,
    artifacts: artifacts(),
  );
  TestRunCleanupWorker cleanup() => TestRunCleanupWorker(database: database);

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tr-cleanup-');
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
    source = await ImageStore(database, Directory('${temporary.path}/images'))
        .importFile(
          await File('${temporary.path}/kernel').writeAsString('kernel'),
          type: ImageType.linuxKernel,
        );
  });

  tearDown(() async {
    bundles.close();
    artifactRoot.close();
    database.close();
    await temporary.delete(recursive: true);
  });

  Future<OperationAcceptance> accept({
    DateTime? now,
    double? timeoutSeconds,
    Image? image,
    VmSpecPatch? overrides,
  }) {
    final spec = TestRunSpec(
      source: ImageTestRunSource(image?.id ?? source.id),
      vmOverrides: overrides,
      wait: VmWaitSpec(
        condition: WaitCondition.runtimeRunning,
        timeoutSeconds: 30,
      ),
      steps: [
        TestStepRequest(argv: ['true'], timeoutSeconds: 30),
      ],
      cleanup: CleanupPolicy.deleteOnSuccess,
      retainOnFailure: true,
      timeoutSeconds: timeoutSeconds,
    );
    return TestRunApplicationService(
      database: database,
      now: now == null ? null : () => now,
    ).create(
      TestRunCreateCommand(
        spec: spec,
        requestId: RequestId.generate(),
        idempotencyKey: null,
        requestBody: utf8.encode(jsonEncode(spec.toJson())),
      ),
    );
  }

  test(
    'an unprovisioned cancellation completes only after durable collection',
    () async {
      final acceptance = await accept();
      final id = acceptance.resourceId as TestRunId;
      final cancelCommand = TestRunCancelCommand(
        testRunId: id,
        requestId: RequestId.generate(),
        idempotencyKey: 'cancel-before-provision',
        requestBody: const [],
      );
      final cancellation = await service().cancelRun(cancelCommand);
      final operationCancellation = await service().cancel(
        OperationCancelCommand(
          operationId: acceptance.operationId,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
        ),
      );
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      expect(await cleanup().dispatchOnce(), isEmpty);
      expect((await service().get(id)).state, TestRunState.collecting);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(acceptance.operationId))!.state,
        OperationState.running,
      );

      expect((await collector().dispatchOnce()).single.collected, isTrue);
      final outcome = (await cleanup().dispatchOnce()).single;
      expect(outcome.testRunId, id);
      expect(outcome.operationId, acceptance.operationId);
      expect(outcome.vmId, isNull);
      expect(outcome.error, isNull);
      expect(outcome.completed, isTrue);
      final completed = await service().get(id);
      expect(completed.state, TestRunState.cancelled);
      expect(completed.cleanupDecision, 'not_required');
      expect(completed.completedAt, isNotNull);
      expect(completed.steps.single.state, TestStepState.skipped);
      expect(await SqliteVmRepository(database).list(), isEmpty);
      final parent = (await SqliteOperationRepository(
        database,
      ).get(acceptance.operationId))!;
      expect(parent.state, OperationState.cancelled);
      expect(outcome.requestId, parent.requestId);
      for (final action in [cancellation, operationCancellation]) {
        expect(
          (await SqliteOperationRepository(
            database,
          ).get(action.operationId))!.state,
          OperationState.succeeded,
        );
      }
      final result = (await artifacts().listForTestRun(id)).items.single;
      final body =
          jsonDecode(
                await utf8.decoder
                    .bind((await artifacts().download(result.id)).bytes)
                    .join(),
              )
              as Map;
      expect(body['execution_outcome'], 'cancelled');
      expect(body['vm_id'], isNull);
      expect(
        (await service().cancelRun(cancelCommand)).operationId,
        cancellation.operationId,
      );

      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect(await cleanup().dispatchOnce(), isEmpty);
      expect(await service().get(id), completed);
      expect((await artifacts().listForTestRun(id)).items, [result]);
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: id,
        )).where((event) => event.type == 'test_run.completed'),
        hasLength(1),
      );
    },
  );

  test(
    'a completion fault rolls back cleanup and cancellation until recovery',
    () async {
      final acceptance = await accept();
      final id = acceptance.resourceId as TestRunId;
      final cancellation = await service().cancelRun(
        TestRunCancelCommand(
          testRunId: id,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
        ),
      );
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      await collector().dispatchOnce();
      final before = await service().get(id);
      final events = await SqliteEventRepository(database).list();
      final outbox = await SqliteEventRepository(
        database,
      ).readUnpublishedOutbox();
      final retained = (await artifacts().listForTestRun(id)).items;
      await database.transaction(
        (db) => db.execute('''
        CREATE TRIGGER reject_cleanup_completion BEFORE INSERT ON events
        WHEN NEW.type = 'test_run.completed'
        BEGIN SELECT RAISE(ABORT, 'injected cleanup completion fault'); END
      '''),
      );

      final attempt = (await cleanup().dispatchOnce()).single;
      expect(attempt.error, isA<SqliteException>());
      expect(attempt.testRunId, id);
      expect(attempt.operationId, acceptance.operationId);
      expect(attempt.completed, isFalse);
      expect(await service().get(id), before);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(acceptance.operationId))!.state,
        OperationState.running,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(cancellation.operationId))!.state,
        OperationState.pending,
      );
      expect(await SqliteEventRepository(database).list(), events);
      expect(
        (await SqliteEventRepository(
          database,
        ).readUnpublishedOutbox()).map((row) => row.key),
        outbox.map((row) => row.key),
      );

      await database.transaction(
        (db) => db.execute('DROP TRIGGER reject_cleanup_completion'),
      );
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect((await cleanup().dispatchOnce()).single.completed, isTrue);
      expect((await service().get(id)).state, TestRunState.cancelled);
      expect((await artifacts().listForTestRun(id)).items, retained);
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(cancellation.operationId))!.state,
        OperationState.succeeded,
      );
      expect(
        (await SqliteEventRepository(database).list(
          testRunId: id,
        )).where((event) => event.type == 'test_run.completed'),
        hasLength(1),
      );
    },
  );

  test(
    'a run expiring before VM allocation retains its primary timeout failure',
    () async {
      final now = DateTime.utc(2026, 10, 9, 12);
      final acceptance = await accept(now: now, timeoutSeconds: 1);
      final id = acceptance.resourceId as TestRunId;
      await TestRunProvisioningWorker(
        database: database,
        now: () => now.add(const Duration(seconds: 1)),
      ).dispatchOnce();
      final before = await service().get(id);
      expect(before.state, TestRunState.collecting);
      expect(before.vmId, isNull);
      expect(before.error!.code, ErrorCode.waitTimeout);
      expect(await cleanup().dispatchOnce(), isEmpty);
      expect((await collector().dispatchOnce()).single.collected, isTrue);
      expect((await cleanup().dispatchOnce()).single.completed, isTrue);
      final completed = await service().get(id);
      expect(completed.state, TestRunState.failed);
      expect(completed.cleanupDecision, 'not_required');
      expect(completed.error, before.error);
      expect(await SqliteVmRepository(database).list(), isEmpty);
      final parent = (await SqliteOperationRepository(
        database,
      ).get(acceptance.operationId))!;
      expect(parent.state, OperationState.failed);
      expect(parent.error, before.error);
      final result = (await artifacts().listForTestRun(id)).items.single;
      final body =
          jsonDecode(
                await utf8.decoder
                    .bind((await artifacts().download(result.id)).bytes)
                    .join(),
              )
              as Map;
      expect(body['execution_outcome'], 'failed');
      expect((body['execution'] as Map)['error'], before.error!.toJson());
    },
  );

  test(
    'background cleanup completes successive runs without client polling',
    () async {
      final ids = <TestRunId>[];
      for (var index = 0; index < 2; index++) {
        final id = (await accept()).resourceId as TestRunId;
        ids.add(id);
        await service().cancelRun(
          TestRunCancelCommand(
            testRunId: id,
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
          ),
        );
      }
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      await collector().dispatchOnce();
      final completed = Completer<void>();
      final observed = <TestRunId>{};
      final loop = TestRunCleanupDispatchLoop(
        worker: cleanup(),
        interval: const Duration(milliseconds: 1),
        batchLimit: 1,
        onDispatch: (pass) {
          expect(pass.length, lessThanOrEqualTo(1));
          for (final item in pass) {
            expect(item.error, isNull);
            if (item.completed) observed.add(item.testRunId);
          }
          if (observed.length == ids.length && !completed.isCompleted)
            completed.complete();
        },
        onError: completed.completeError,
      );
      try {
        loop.start();
        loop.start();
        await completed.future.timeout(const Duration(seconds: 5));
        for (final id in ids) {
          expect((await service().get(id)).state, TestRunState.cancelled);
          expect((await artifacts().listForTestRun(id)).items, hasLength(1));
        }
      } finally {
        await loop.close();
      }
    },
  );

  test(
    'shutdown drains an in-flight cleanup pass without scheduling another',
    () async {
      final id = (await accept()).resourceId as TestRunId;
      await service().cancelRun(
        TestRunCancelCommand(
          testRunId: id,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
        ),
      );
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      await collector().dispatchOnce();
      final scheduler = _CleanupTimerScheduler();
      final entered = Completer<void>();
      final release = Completer<void>();
      final held = database.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final passes = <List<TestRunCleanupOutcome>>[];
      final loop = TestRunCleanupDispatchLoop(
        worker: cleanup(),
        scheduler: scheduler,
        onDispatch: passes.add,
        onError: (error, _) => fail('$error'),
      );
      try {
        loop.start();
        loop.start();
        var closed = false;
        final closing = loop.close().then((_) => closed = true);
        await Future<void>.value();
        expect(closed, isFalse);
        release.complete();
        await held;
        await closing;
        expect(passes, hasLength(1));
        expect(passes.single.single.testRunId, id);
        expect(passes.single.single.completed, isTrue);
        expect(passes.single.single.error, isNull);
        expect(scheduler.activeCount, 0);
        expect(loop.start, throwsStateError);
        expect((await service().get(id)).state, TestRunState.cancelled);
      } finally {
        if (!release.isCompleted) release.complete();
        await held;
        await loop.close();
      }
    },
  );

  test(
    'an unbound run with provisioning ownership is not finalized as VM-free',
    () async {
      final image =
          await ImageStore(
            database,
            Directory('${temporary.path}/images'),
          ).importFile(
            await File('${temporary.path}/disk').writeAsString('disk'),
            type: ImageType.rawDisk,
          );
      final acceptance = await accept(
        image: image,
        overrides: VmSpecPatch.fromJson({
          'boot': {'type': 'linux_kernel', 'kernel_image_id': source.id.value},
        }),
      );
      final id = acceptance.resourceId as TestRunId;
      final provision = (await TestRunProvisioningWorker(
        database: database,
      ).dispatchOnce()).single;
      expect(provision.error, isNull);
      final allocated = (await SqliteVmRepository(database).list()).single;
      final run = await service().get(id);
      expect(run.state, TestRunState.provisioning);
      expect(run.vmId, isNull);
      await service().cancelRun(
        TestRunCancelCommand(
          testRunId: id,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
        ),
      );
      // Reproduce a durable phase with a VM owned by provisioning but not yet
      // exposed in the TestRun binding. A null DTO field is not cleanup evidence.
      await SqliteTestRunRepository(database).transition(
        id,
        expectedState: TestRunState.provisioning,
        nextState: TestRunState.collecting,
        outcome: TestRunState.cancelled,
      );
      expect((await collector().dispatchOnce()).single.collected, isTrue);
      expect(
        (await cleanup().dispatchOnce()).every((item) => !item.completed),
        isTrue,
      );
      expect((await service().get(id)).state, TestRunState.collecting);
      expect((await service().get(id)).cleanupDecision, isNull);
      expect(
        await SqliteVmRepository(database).get(allocated.metadata.id),
        allocated,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(acceptance.operationId))!.state,
        OperationState.running,
      );
    },
  );

  test(
    'a standalone cleanup loop drains and exits naturally',
    () async {
      final id = (await accept()).resourceId as TestRunId;
      await service().cancelRun(
        TestRunCancelCommand(
          testRunId: id,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
        ),
      );
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      await collector().dispatchOnce();
      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '${Directory.current.path}/test/helpers/test_run_cleanup_child.dart',
        temporary.path,
      ]);
      var exited = false;
      child.exitCode.then((_) => exited = true);
      final output = child.stdout.transform(utf8.decoder).join();
      final errors = child.stderr.transform(utf8.decoder).join();
      try {
        final code = await child.exitCode.timeout(const Duration(seconds: 20));
        expect(code, 0, reason: await errors);
        expect(await output, contains('cleanup drained'));
        expect((await service().get(id)).state, TestRunState.cancelled);
        expect((await artifacts().listForTestRun(id)).items, hasLength(1));
        expect(
          (await SqliteEventRepository(database).list(
            testRunId: id,
          )).where((event) => event.type == 'test_run.completed'),
          hasLength(1),
        );
      } finally {
        if (!exited) child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        await output;
        await errors;
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'cleanup work is bounded and cannot borrow a caller transaction',
    () async {
      for (final limit in [0, 201]) {
        await expectLater(
          cleanup().dispatchOnce(limit: limit),
          throwsRangeError,
        );
        expect(
          () => TestRunCleanupDispatchLoop(
            worker: cleanup(),
            batchLimit: limit,
            onDispatch: (_) {},
            onError: (_, _) {},
          ),
          throwsRangeError,
        );
      }
      await database.transaction((_) async {
        await expectLater(cleanup().dispatchOnce(), throwsStateError);
      });
      expect(
        () => TestRunCleanupDispatchLoop(
          worker: cleanup(),
          interval: Duration.zero,
          onDispatch: (_) {},
          onError: (_, _) {},
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'a failed cleanup pass does not starve another run and later wraps to retry',
    () async {
      final runs = <OperationAcceptance>[];
      for (var index = 0; index < 2; index++) {
        final acceptance = await accept();
        runs.add(acceptance);
        await service().cancelRun(
          TestRunCancelCommand(
            testRunId: acceptance.resourceId as TestRunId,
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: const [],
          ),
        );
      }
      await TestRunProvisioningWorker(database: database).dispatchOnce();
      await collector().dispatchOnce();
      final blocked = runs.first.resourceId as TestRunId;
      final independent = runs.last.resourceId as TestRunId;
      await database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER reject_one_cleanup BEFORE INSERT ON events
      WHEN NEW.type = 'test_run.completed' AND NEW.test_run_id = '${blocked.value}'
      BEGIN SELECT RAISE(ABORT, 'injected single-run cleanup fault'); END
    '''),
      );
      final worker = cleanup();
      final observed = <TestRunCleanupOutcome>[];
      for (var pass = 0; pass < 2; pass++) {
        final batch = await worker.dispatchOnce(limit: 1);
        expect(batch, hasLength(1));
        observed.addAll(batch);
      }
      expect(
        observed.singleWhere((item) => item.testRunId == blocked).error,
        isA<SqliteException>(),
      );
      expect(
        observed.singleWhere((item) => item.testRunId == independent).completed,
        isTrue,
      );
      expect((await service().get(blocked)).state, TestRunState.collecting);
      expect((await service().get(independent)).state, TestRunState.cancelled);
      await database.transaction(
        (db) => db.execute('DROP TRIGGER reject_one_cleanup'),
      );
      expect((await worker.dispatchOnce(limit: 1)).single.testRunId, blocked);
      expect((await service().get(blocked)).state, TestRunState.cancelled);
      expect(await worker.dispatchOnce(limit: 1), isEmpty);
    },
  );
}

final class _CleanupTimerScheduler implements VmTimerScheduler {
  final handles = <_CleanupTimerHandle>[];
  int get activeCount => handles.where((handle) => handle.isActive).length;

  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) {
    final handle = _CleanupTimerHandle();
    handles.add(handle);
    return handle;
  }
}

final class _CleanupTimerHandle implements VmTimerHandle {
  @override
  bool isActive = true;

  @override
  void cancel() => isActive = false;
}
