import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/host_lease_repository.dart';
import 'package:gaovmd/src/host_scheduler.dart';
import 'package:gaovmd/src/host_scheduler_models.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/macos_host_metrics.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/sqlite_host_capacity_catalog.dart';
import 'package:gaovmd/src/sqlite_vm_lifecycle_acceptance.dart';
import 'package:gaovmd/src/sqlite_vm_state_effect_adapter.dart';
import 'package:gaovmd/src/vm_application_service.dart';
import 'package:gaovmd/src/vm_controller.dart';
import 'package:gaovmd/src/vm_controller_reducer.dart';
import 'package:gaovmd/src/vm_registry.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late GaoVmDatabase database;
  late SqliteHostLeaseRepository sqliteLeases;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'gaovmd-host-scheduler-',
    );
    database = await GaoVmDatabase.open('${temporaryDirectory.path}/gaovm.db');
    sqliteLeases = SqliteHostLeaseRepository(database);
  });

  tearDown(() async {
    database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('native host sampling feeds real SQLite admission', () async {
    final storage = await OwnedImageDirectory.open(temporaryDirectory);
    final scheduler = _scheduler(
      leases: sqliteLeases,
      catalog: _Catalog([_request(_vm1)]),
      metrics: MacOsHostMetricsSource(
        storage: storage,
        countUnmanagedDrivers: () => 0,
      ),
      limits: _limits(),
    );
    try {
      await scheduler.acquire(_state(_vm1), _operation1);
      final lease = (await sqliteLeases.list()).single;
      expect(lease.request.vmId, _vm1);
      expect(lease.request.driverGeneration, 1);
      await scheduler.release(_state(_vm1), _operation1);
    } finally {
      await scheduler.shutdown();
      storage.close();
    }
  }, skip: !Platform.isMacOS);

  test(
    'runtime expiry reserves capacity before and after loss delivery',
    () async {
      var clock = _now;
      final timers = _ManualRenewalScheduler();
      final observed = <HostLeasePhase>[];
      final scheduler = _scheduler(
        leases: sqliteLeases,
        catalog: _Catalog([_request(_vm1), _request(_vm2)]),
        metrics: _MetricsSource(),
        limits: _limits(maxRunningVms: 1),
        leaseTtl: const Duration(seconds: 10),
        renewalInterval: const Duration(seconds: 4),
        renewalScheduler: timers,
        now: () => clock,
        onLeaseLost: (_, _, _, _, _) async {
          observed.add(
            (await sqliteLeases.list(activeAt: clock)).single.request.phase,
          );
        },
      );
      await scheduler.acquire(_state(_vm1), _operation1);
      clock = clock.add(const Duration(seconds: 11));
      await expectLater(
        scheduler.acquire(_state(_vm2), _operation2),
        throwsA(isA<VmEffectException>()),
      );
      timers.fireNext();
      await _settleAsyncWork();
      expect(observed, [HostLeasePhase.cleanup]);
      clock = clock.add(const Duration(hours: 1));
      await expectLater(
        scheduler.acquire(_state(_vm2), _operation2),
        throwsA(isA<VmEffectException>()),
      );
      await scheduler.release(_state(_vm1), _operation1);
      await scheduler.acquire(_state(_vm2), _operation2);
      await scheduler.release(_state(_vm2), _operation2);
      await scheduler.shutdown();
    },
  );

  test(
    'failed cleanup retention retries while expired runtime capacity stays reserved',
    () async {
      var clock = _now;
      final timers = _ManualRenewalScheduler();
      var attempts = 0;
      var delivered = false;
      final leases = _TracingLeaseRepository(
        sqliteLeases,
        [],
        beforeRetention: () async {
          if (++attempts == 1) throw StateError('injected retention failure');
        },
      );
      final scheduler = _scheduler(
        leases: leases,
        catalog: _Catalog([_request(_vm1), _request(_vm2)]),
        metrics: _MetricsSource(),
        limits: _limits(maxRunningVms: 1),
        leaseTtl: const Duration(seconds: 10),
        renewalInterval: const Duration(seconds: 4),
        renewalScheduler: timers,
        now: () => clock,
        onLeaseLost: (_, _, _, _, _) {
          delivered = true;
        },
      );
      await scheduler.acquire(_state(_vm1), _operation1);
      clock = clock.add(const Duration(seconds: 11));
      timers.fireNext();
      await _settleAsyncWork();
      expect(delivered, isFalse);
      expect(attempts, 1);
      await expectLater(
        scheduler.acquire(_state(_vm2), _operation2),
        throwsA(isA<VmEffectException>()),
      );
      timers.fireNext();
      await _settleAsyncWork();
      expect(attempts, 2);
      expect(delivered, isTrue);
      expect(
        (await sqliteLeases.list()).single.request.phase,
        HostLeasePhase.cleanup,
      );
      await scheduler.release(_state(_vm1), _operation1);
      await scheduler.shutdown();
    },
  );

  test(
    'release drains an in-flight cleanup reservation without resurrection',
    () async {
      var clock = _now;
      final entered = Completer<void>();
      final allow = Completer<void>();
      final timers = _ManualRenewalScheduler();
      final leases = _TracingLeaseRepository(
        sqliteLeases,
        [],
        beforeRetention: () async {
          entered.complete();
          await allow.future;
        },
      );
      var deliveries = 0;
      final scheduler = _scheduler(
        leases: leases,
        catalog: _Catalog([_request(_vm1)]),
        metrics: _MetricsSource(),
        limits: _limits(),
        leaseTtl: const Duration(seconds: 10),
        renewalInterval: const Duration(seconds: 4),
        renewalScheduler: timers,
        now: () => clock,
        onLeaseLost: (_, _, _, _, _) => deliveries++,
      );
      await scheduler.acquire(_state(_vm1), _operation1);
      clock = clock.add(const Duration(seconds: 11));
      timers.fireNext();
      await entered.future;
      var released = false;
      final releasing = scheduler
          .release(_state(_vm1), _operation1)
          .then((_) => released = true);
      await _settleAsyncWork();
      expect(released, isFalse);
      allow.complete();
      await releasing;
      await _settleAsyncWork();
      expect(await sqliteLeases.list(), isEmpty);
      expect(deliveries, 0);
      expect(scheduler.pendingLeaseLossCount, 0);
      await scheduler.shutdown();
    },
  );

  test(
    'admission reserves the execution spec after a newer spec is accepted',
    () async {
      final repository = SqliteVmRepository(database);
      final vm = await repository.create(
        name: 'pinned-capacity',
        spec: _vmSpec,
      );
      await repository.patch(
        vm.metadata.id,
        expectedRevision: vm.metadata.revision,
        spec: VmSpecPatch.fromJson({'cpu': 8, 'memory_bytes': 536870912}),
      );
      final scheduler = _scheduler(
        leases: sqliteLeases,
        catalog: SqliteHostCapacityCatalog(database, diskBytes: (_) => 0),
        metrics: _MetricsSource(),
        limits: _limits(),
      );
      addTearDown(scheduler.shutdown);
      await scheduler.acquire(_state(vm.metadata.id), _operation1);
      final lease = (await sqliteLeases.list(activeAt: _now)).single;
      expect(lease.request.specGeneration, 1);
      expect(lease.request.cpuCount, 2);
      expect(lease.request.memoryBytes, 268435456);
    },
  );

  test('explicit admission and cleanup preserve the requested spec', () async {
    final repository = SqliteVmRepository(database);
    final vm = await repository.create(name: 'pinned-cleanup', spec: _vmSpec);
    await repository.patch(
      vm.metadata.id,
      expectedRevision: vm.metadata.revision,
      spec: VmSpecPatch.fromJson({'cpu': 8, 'memory_bytes': 536870912}),
    );
    var clock = _now;
    final scheduler = _scheduler(
      leases: sqliteLeases,
      catalog: SqliteHostCapacityCatalog(
        database,
        diskBytes: (spec) => spec.cpu,
      ),
      metrics: _MetricsSource(),
      limits: _limits(),
      renewalScheduler: _ManualRenewalScheduler(),
      now: () => clock,
    );
    addTearDown(scheduler.shutdown);
    final decision = await scheduler.admit(
      vm.metadata.id,
      specGeneration: 1,
      operationId: _operation1,
    );
    expect(decision.request.cpuCount, 2);
    expect(decision.request.diskBytes, 2);
    clock = clock.add(const Duration(minutes: 1));
    await expectLater(
      scheduler.markRunning(
        _state(
          vm.metadata.id,
        ).copyWith(specGeneration: 2, activeSpecGeneration: 1),
        _operation1,
      ),
      throwsA(isA<VmEffectException>()),
    );
    final cleanup = (await sqliteLeases.list(activeAt: clock)).single;
    expect(cleanup.request.phase, HostLeasePhase.cleanup);
    expect(cleanup.request.specGeneration, 1);
    expect(cleanup.request.cpuCount, 2);
    expect(cleanup.request.memoryBytes, 268435456);
  });

  test(
    'recovery reserves applied capacity before newer catalog specs',
    () async {
      final repository = SqliteVmRepository(database);
      final vm = await repository.create(
        name: 'pinned-recovery',
        spec: _vmSpec,
      );
      final state = _state(vm.metadata.id);
      final accepted = await SqliteVmLifecycleAcceptance(
        database: database,
        idempotencyRetention: const Duration(days: 1),
        command: VmLifecycleCommand(
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
          vmId: vm.metadata.id,
          action: VmLifecycleAction.start,
        ),
      ).commit(state);
      final catalog = SqliteHostCapacityCatalog(database, diskBytes: (_) => 0);
      expect(await catalog.recoveryRequests(), isEmpty);
      await SqliteVmStateEffectAdapter(database).persistRuntime(
        state.copyWith(
          appliedIntentRevision: 1,
          desiredState: DesiredState.running,
          phase: VmPhase.starting,
          currentOperation: VmControllerOperation(
            id: accepted.result.operationId,
            kind: VmOperationKind.start,
            state: OperationState.pending,
          ),
        ),
      );
      final current = (await repository.get(vm.metadata.id))!;
      await repository.patch(
        vm.metadata.id,
        expectedRevision: current.metadata.revision,
        spec: VmSpecPatch.fromJson({'cpu': 8, 'memory_bytes': 536870912}),
      );
      final request = (await catalog.recoveryRequests()).single;
      expect(request.specGeneration, 1);
      expect(request.cpuCount, 2);
      expect(request.memoryBytes, 268435456);
    },
  );

  test(
    'metrics are sampled before atomic admission and errors stay typed',
    () async {
      final trace = <String>[];
      final metrics = _MetricsSource(trace: trace);
      final leases = _TracingLeaseRepository(sqliteLeases, trace);
      final scheduler = _scheduler(
        leases: leases,
        catalog: _Catalog([_request(_vm1), _request(_vm2)]),
        metrics: metrics,
        limits: _limits(maxRunningVms: 1),
      );

      await scheduler.acquire(_state(_vm1), _operation1);
      await expectLater(
        scheduler.acquire(_state(_vm2), _operation2),
        throwsA(
          isA<VmEffectException>()
              .having(
                (error) => error.operationError.code,
                'code',
                ErrorCode.hostResourceExhausted,
              )
              .having(
                (error) => error.operationError.retryable,
                'retryable',
                isTrue,
              )
              .having(
                (error) => error.operationError.message,
                'message',
                'host capacity exhausted: max_running_vms',
              ),
        ),
      );

      expect(trace, ['metrics', 'repository', 'metrics', 'repository']);
    },
  );

  test(
    'running transition frees boot capacity without releasing runtime lease',
    () async {
      final scheduler = _scheduler(
        leases: sqliteLeases,
        catalog: _Catalog([_request(_vm1), _request(_vm2)]),
        metrics: _MetricsSource(),
        limits: _limits(maxConcurrentBoots: 1),
      );
      await scheduler.acquire(_state(_vm1), _operation1);
      await expectLater(
        scheduler.acquire(_state(_vm2), _operation2),
        throwsA(isA<VmEffectException>()),
      );

      expect(await scheduler.markLeaseRunning(_vm1, _operation1), isTrue);
      await scheduler.acquire(_state(_vm2), _operation2);

      final leases = await sqliteLeases.list(activeAt: _now);
      expect(leases, hasLength(2));
      expect(
        leases.singleWhere((lease) => lease.request.vmId == _vm1).request.phase,
        HostLeasePhase.running,
      );
    },
  );

  test(
    'recovery takes ownership before PR009 controller reconciliation',
    () async {
      await sqliteLeases.acquire(
        request: _request(_vm1),
        limits: _limits(),
        metrics: _hostMetrics,
        ownerId: 'old-daemon',
        now: _now,
        ttl: const Duration(minutes: 1),
      );
      final scheduler = _scheduler(
        leases: sqliteLeases,
        catalog: _Catalog([_request(_vm2), _request(_vm1)]),
        metrics: _MetricsSource(),
        limits: _limits(maxRunningVms: 1),
        ownerId: 'new-daemon',
      );

      final recovery = await scheduler.recover();
      expect(recovery.map((decision) => decision.request.vmId), [_vm1, _vm2]);
      expect(recovery.first.admitted, isTrue);
      expect(recovery.last.admitted, isFalse);

      final controller = VmController(
        initialState: _state(_vm1),
        effectRunner: _SchedulerControllerRunner(scheduler),
      );
      await controller.submit(StartRequested(_operation1));

      expect(controller.state.leaseState, VmLeaseState.held);
      expect(controller.state.activeDriverGeneration, 1);
      expect(await sqliteLeases.list(activeAt: _now), hasLength(1));
      await controller.shutdown();
      expect(await sqliteLeases.list(activeAt: _now), isEmpty);
    },
  );

  test('acquire cancellation and release are idempotent', () async {
    final scheduler = _scheduler(
      leases: sqliteLeases,
      catalog: _Catalog([_request(_vm1), _request(_vm2)]),
      metrics: _MetricsSource(),
      limits: _limits(maxRunningVms: 1),
    );
    final state = _state(_vm1);
    await scheduler.acquire(state, _operation1);

    await scheduler.cancel(
      AcquireHostLease(vmId: _vm1, operationId: _operation1),
      state,
    );
    await scheduler.release(state, _operation1);

    expect(await sqliteLeases.list(activeAt: _now), isEmpty);
  });

  test(
    'renewal is deterministic, stops on release, and surfaces lease loss',
    () async {
      var clock = _now;
      final timers = _ManualRenewalScheduler();
      final losses = <({VmId vmId, OperationError error})>[];
      final scheduler = _scheduler(
        leases: sqliteLeases,
        catalog: _Catalog([_request(_vm1), _request(_vm2)]),
        metrics: _MetricsSource(),
        limits: _limits(),
        leaseTtl: const Duration(seconds: 10),
        renewalInterval: const Duration(seconds: 4),
        renewalScheduler: timers,
        now: () => clock,
        onLeaseLost: (vmId, _, _, _, error) {
          losses.add((vmId: vmId, error: error));
        },
      );
      await scheduler.acquire(_state(_vm1), _operation1);
      expect(scheduler.pendingRenewalCount, 1);

      clock = clock.add(const Duration(seconds: 4));
      timers.fireNext();
      await _settleAsyncWork();
      final renewed = (await sqliteLeases.list(activeAt: clock)).single;
      expect(renewed.expiresAt, clock.add(const Duration(seconds: 10)));
      expect(scheduler.pendingRenewalCount, 1);

      await scheduler.release(_state(_vm1), _operation1);
      expect(scheduler.pendingRenewalCount, 0);
      expect(timers.activeCount, 0);

      await scheduler.acquire(_state(_vm2), _operation2);
      clock = clock.add(const Duration(seconds: 11));
      timers.fireNext();
      await _settleAsyncWork();
      expect(losses.single.vmId, _vm2);
      expect(losses.single.error.code, ErrorCode.hostResourceExhausted);
      expect(losses.single.error.retryable, isTrue);
      expect(scheduler.pendingRenewalCount, 0);

      await scheduler.acquire(_state(_vm1), _operation1);
      expect(scheduler.pendingRenewalCount, 1);
      await scheduler.shutdown();
      expect(scheduler.pendingRenewalCount, 0);
      expect(timers.activeCount, 0);
    },
  );

  test(
    'release racing an in-flight renewal cannot emit false lease loss',
    () async {
      var clock = _now;
      final delayed = _DelayedAcquireRepository(
        sqliteLeases,
        delayAcquire: false,
        delayRenew: true,
      );
      final timers = _ManualRenewalScheduler();
      final losses = <OperationError>[];
      final scheduler = _scheduler(
        leases: delayed,
        catalog: _Catalog([_request(_vm1)]),
        metrics: _MetricsSource(),
        limits: _limits(),
        leaseTtl: const Duration(seconds: 10),
        renewalInterval: const Duration(seconds: 4),
        renewalScheduler: timers,
        now: () => clock,
        onLeaseLost: (_, _, _, _, error) => losses.add(error),
      );
      await scheduler.acquire(_state(_vm1), _operation1);
      clock = clock.add(const Duration(seconds: 4));
      timers.fireNext();
      await delayed.renewEntered.future;

      await scheduler.release(_state(_vm1), _operation1);
      delayed.releaseRenew.complete();
      await _settleAsyncWork();

      expect(losses, isEmpty);
      expect(scheduler.pendingRenewalCount, 0);
      expect(await sqliteLeases.list(activeAt: clock), isEmpty);
    },
  );

  test(
    'identical reacquire refreshes expiry and replaces renewal timer',
    () async {
      var clock = _now;
      final timers = _ManualRenewalScheduler();
      final scheduler = _scheduler(
        leases: sqliteLeases,
        catalog: _Catalog([_request(_vm1)]),
        metrics: _MetricsSource(),
        limits: _limits(),
        leaseTtl: const Duration(seconds: 10),
        renewalInterval: const Duration(seconds: 4),
        renewalScheduler: timers,
        now: () => clock,
      );
      await scheduler.acquire(_state(_vm1), _operation1);
      final firstHandle = timers.handles.single;
      clock = clock.add(const Duration(seconds: 8));

      await scheduler.acquire(_state(_vm1), _operation1);

      expect(firstHandle.isActive, isFalse);
      expect(timers.activeCount, 1);
      expect(
        (await sqliteLeases.list(activeAt: clock)).single.expiresAt,
        clock.add(const Duration(seconds: 10)),
      );
      await scheduler.shutdown();
    },
  );

  test('lease-loss delivery is fenced and retried deterministically', () async {
    var clock = _now;
    final timers = _ManualRenewalScheduler();
    final deliveries = <({VmId vmId, int spec, OperationId? operation})>[];
    var attempts = 0;
    final scheduler = _scheduler(
      leases: sqliteLeases,
      catalog: _Catalog([_request(_vm1), _request(_vm2)]),
      metrics: _MetricsSource(),
      limits: _limits(maxRunningVms: 1),
      leaseTtl: const Duration(seconds: 10),
      renewalInterval: const Duration(seconds: 4),
      lossRetryInterval: const Duration(seconds: 2),
      renewalScheduler: timers,
      now: () => clock,
      onLeaseLost: (vmId, spec, operation, generation, _) {
        expect(generation, 5);
        attempts++;
        deliveries.add((vmId: vmId, spec: spec, operation: operation));
        if (attempts == 1) throw StateError('receiver unavailable');
      },
    );
    await scheduler.acquire(
      _state(_vm1).copyWith(driverGeneration: 4),
      _operation1,
    );
    clock = clock.add(const Duration(seconds: 4));
    timers.fireNext();
    await _settleAsyncWork();
    expect(attempts, 0);
    clock = clock.add(const Duration(seconds: 11));
    timers.fireNext();
    await _settleAsyncWork();

    expect(attempts, 1);
    expect(scheduler.pendingLeaseLossCount, 1);
    timers.fireNext();
    await _settleAsyncWork();

    expect(attempts, 2);
    expect(deliveries.last.vmId, _vm1);
    expect(deliveries.last.spec, 1);
    expect(deliveries.last.operation, _operation1);
    expect(scheduler.pendingLeaseLossCount, 0);
    await scheduler.shutdown();
  });

  test(
    'asynchronous lease-loss delivery waits and retries rejection',
    () async {
      var clock = _now;
      final timers = _ManualRenewalScheduler();
      final firstDelivery = Completer<void>();
      var attempts = 0;
      final scheduler = _scheduler(
        leases: sqliteLeases,
        catalog: _Catalog([_request(_vm1)]),
        metrics: _MetricsSource(),
        limits: _limits(),
        leaseTtl: const Duration(seconds: 10),
        renewalInterval: const Duration(seconds: 4),
        renewalScheduler: timers,
        now: () => clock,
        onLeaseLost: (_, _, _, _, _) async {
          attempts++;
          if (attempts == 1) await firstDelivery.future;
        },
      );
      await scheduler.acquire(_state(_vm1), _operation1);
      clock = clock.add(const Duration(seconds: 11));
      timers.fireNext();
      await _settleAsyncWork();
      expect(attempts, 1);
      expect(scheduler.pendingLeaseLossCount, 1);

      firstDelivery.completeError(StateError('receiver unavailable'));
      await _settleAsyncWork();
      expect(scheduler.pendingLeaseLossCount, 1);
      timers.fireNext();
      await _settleAsyncWork();
      expect(attempts, 2);
      expect(scheduler.pendingLeaseLossCount, 0);
      await scheduler.shutdown();
    },
  );

  test('shutdown drains an asynchronous lease-loss receiver', () async {
    var clock = _now;
    final timers = _ManualRenewalScheduler();
    final delivery = Completer<void>();
    final entered = Completer<void>();
    final scheduler = _scheduler(
      leases: sqliteLeases,
      catalog: _Catalog([_request(_vm1)]),
      metrics: _MetricsSource(),
      limits: _limits(),
      leaseTtl: const Duration(seconds: 10),
      renewalInterval: const Duration(seconds: 4),
      renewalScheduler: timers,
      now: () => clock,
      onLeaseLost: (_, _, _, _, _) async {
        entered.complete();
        await delivery.future;
      },
    );
    await scheduler.acquire(_state(_vm1), _operation1);
    clock = clock.add(const Duration(seconds: 11));
    timers.fireNext();
    await entered.future;
    var closed = false;
    final closing = scheduler.shutdown().then((_) => closed = true);
    await _settleAsyncWork();
    expect(closed, isFalse);
    delivery.completeError(StateError('receiver closed'));
    await closing;
    expect(scheduler.pendingLeaseLossCount, 0);
    expect(timers.activeCount, 0);
  });

  for (final fails in [false, true]) {
    test(
      'stale async loss completion preserves new lease (fails=$fails)',
      () async {
        var clock = _now;
        final timers = _ManualRenewalScheduler();
        final delivery = Completer<void>();
        final entered = Completer<void>();
        var attempts = 0;
        final scheduler = _scheduler(
          leases: sqliteLeases,
          catalog: _Catalog([_request(_vm1)]),
          metrics: _MetricsSource(),
          limits: _limits(),
          leaseTtl: const Duration(seconds: 10),
          renewalInterval: const Duration(seconds: 4),
          renewalScheduler: timers,
          now: () => clock,
          onLeaseLost: (_, _, _, _, _) async {
            attempts++;
            entered.complete();
            await delivery.future;
          },
        );
        await scheduler.acquire(_state(_vm1), _operation1);
        clock = clock.add(const Duration(seconds: 11));
        timers.fireNext();
        await entered.future;
        expect(timers.activeCount, 0);
        await scheduler.release(_state(_vm1), _operation1);
        await scheduler.acquire(_state(_vm1), _operation2);
        if (fails) {
          delivery.completeError(StateError('old receiver rejected'));
        } else {
          delivery.complete();
        }
        await _settleAsyncWork();
        expect(attempts, 1);
        expect(scheduler.pendingLeaseLossCount, 0);
        expect(scheduler.pendingRenewalCount, 1);
        expect(timers.activeCount, 1);
        expect(
          (await sqliteLeases.list(activeAt: clock)).single.request.operationId,
          _operation2,
        );
        await scheduler.shutdown();
      },
    );
  }

  test('new acquisition cancels stale fenced loss retry', () async {
    var clock = _now;
    final timers = _ManualRenewalScheduler();
    var attempts = 0;
    final scheduler = _scheduler(
      leases: sqliteLeases,
      catalog: _Catalog([_request(_vm1)]),
      metrics: _MetricsSource(),
      limits: _limits(),
      leaseTtl: const Duration(seconds: 10),
      renewalInterval: const Duration(seconds: 4),
      renewalScheduler: timers,
      now: () => clock,
      onLeaseLost: (_, _, _, _, _) {
        attempts++;
        throw StateError('enqueue unavailable');
      },
    );
    await scheduler.acquire(_state(_vm1), _operation1);
    clock = clock.add(const Duration(seconds: 11));
    timers.fireNext();
    await _settleAsyncWork();
    expect(attempts, 1);
    expect(scheduler.pendingLeaseLossCount, 1);

    await scheduler.release(_state(_vm1), _operation1);
    await scheduler.acquire(_state(_vm1), _operation2);

    expect(scheduler.pendingLeaseLossCount, 0);
    expect(scheduler.pendingRenewalCount, 1);
    expect(attempts, 1);
    expect(
      (await sqliteLeases.list(activeAt: clock)).single.request.operationId,
      _operation2,
    );
    await scheduler.shutdown();
  });

  test(
    'cancel fences an exact delayed acquisition without blocking a newer operation',
    () async {
      final delayed = _DelayedAcquireRepository(sqliteLeases);
      final scheduler = _scheduler(
        leases: delayed,
        catalog: _Catalog([_request(_vm1)]),
        metrics: _MetricsSource(),
        limits: _limits(),
      );
      final state = _state(_vm1);
      final first = scheduler.acquire(state, _operation1);
      await delayed.firstAcquireEntered.future;

      await scheduler.cancel(
        AcquireHostLease(vmId: _vm1, operationId: _operation1),
        state,
      );
      final second = scheduler.acquire(state, _operation2);
      await second;
      delayed.releaseFirstAcquire.complete();

      await expectLater(
        first,
        throwsA(
          isA<VmEffectException>().having(
            (error) => error.operationError.message,
            'message',
            'host lease acquisition cancelled',
          ),
        ),
      );
      final lease = (await sqliteLeases.list(activeAt: _now)).single;
      expect(lease.request.operationId, _operation2);
      expect(scheduler.pendingRenewalCount, 1);
      await scheduler.release(state, _operation2);
    },
  );

  test('cancel fences acquisition delayed in catalog lookup', () async {
    final catalog = _DelayedCatalog(_Catalog([_request(_vm1)]));
    final scheduler = _scheduler(
      leases: sqliteLeases,
      catalog: catalog,
      metrics: _MetricsSource(),
      limits: _limits(),
    );
    final state = _state(_vm1);
    final acquisition = scheduler.acquire(state, _operation1);
    await catalog.entered.future;

    await scheduler.cancel(
      AcquireHostLease(vmId: _vm1, operationId: _operation1),
      state,
    );
    catalog.release.complete();

    await expectLater(acquisition, throwsA(isA<VmEffectException>()));
    expect(await sqliteLeases.list(activeAt: _now), isEmpty);
    await scheduler.acquire(state, _operation2);
    await scheduler.release(state, _operation2);
  });

  test('cancel fences acquisition delayed in host metric sampling', () async {
    final metrics = _DelayedMetricsSource();
    final scheduler = _scheduler(
      leases: sqliteLeases,
      catalog: _Catalog([_request(_vm1)]),
      metrics: metrics,
      limits: _limits(),
    );
    final state = _state(_vm1);
    final acquisition = scheduler.acquire(state, _operation1);
    await metrics.entered.future;

    await scheduler.cancel(
      AcquireHostLease(vmId: _vm1, operationId: _operation1),
      state,
    );
    metrics.release.complete();

    await expectLater(acquisition, throwsA(isA<VmEffectException>()));
    expect(await sqliteLeases.list(activeAt: _now), isEmpty);
    await scheduler.acquire(state, _operation2);
    await scheduler.release(state, _operation2);
  });

  test(
    'shutdown fences paused acquisition and rejects new scheduler work',
    () async {
      final catalog = _DelayedCatalog(_Catalog([_request(_vm1)]));
      final timers = _ManualRenewalScheduler();
      final scheduler = _scheduler(
        leases: sqliteLeases,
        catalog: catalog,
        metrics: _MetricsSource(),
        limits: _limits(),
        renewalScheduler: timers,
      );
      final state = _state(_vm1);
      final acquisition = scheduler.acquire(state, _operation1);
      await catalog.entered.future;
      var shutdownCompleted = false;
      final shutdown = scheduler.shutdown()
        ..then((_) => shutdownCompleted = true);

      expect(scheduler.isClosed, isTrue);
      expect(shutdownCompleted, isFalse);
      await expectLater(
        scheduler.acquire(state, _operation2),
        throwsA(isA<HostSchedulerClosedException>()),
      );
      await expectLater(
        scheduler.admit(_vm1, operationId: _operation2),
        throwsA(isA<HostSchedulerClosedException>()),
      );
      await expectLater(
        scheduler.recover(),
        throwsA(isA<HostSchedulerClosedException>()),
      );
      await expectLater(
        scheduler.markLeaseRunning(_vm1, _operation1),
        throwsA(isA<HostSchedulerClosedException>()),
      );
      await expectLater(
        scheduler.renew(_vm1),
        throwsA(isA<HostSchedulerClosedException>()),
      );

      catalog.release.complete();
      await expectLater(acquisition, throwsA(isA<VmEffectException>()));
      await shutdown;
      expect(shutdownCompleted, isTrue);
      expect(await sqliteLeases.list(activeAt: _now), isEmpty);
      expect(scheduler.pendingRenewalCount, 0);
      expect(scheduler.pendingLeaseLossCount, 0);
      expect(timers.activeCount, 0);
    },
  );

  test(
    'shutdown times out bounded and later retry converges delayed insertion',
    () async {
      final delayed = _DelayedAcquireRepository(sqliteLeases);
      final scheduler = _scheduler(
        leases: delayed,
        catalog: _Catalog([_request(_vm1)]),
        metrics: _MetricsSource(),
        limits: _limits(),
        shutdownTimeout: const Duration(milliseconds: 10),
      );
      final acquisition = scheduler.acquire(_state(_vm1), _operation1);
      await delayed.firstAcquireEntered.future;

      await expectLater(
        scheduler.shutdown(),
        throwsA(
          isA<HostSchedulerShutdownException>().having(
            (error) => error.pendingOperations,
            'pendingOperations',
            1,
          ),
        ),
      );
      expect(scheduler.isClosed, isTrue);
      delayed.releaseFirstAcquire.complete();
      await expectLater(acquisition, throwsA(isA<VmEffectException>()));
      await scheduler.shutdown();

      expect(await sqliteLeases.list(activeAt: _now), isEmpty);
      expect(scheduler.pendingRenewalCount, 0);
    },
  );

  test(
    'shutdown cancels retained synchronous loss retry bookkeeping',
    () async {
      var clock = _now;
      final timers = _ManualRenewalScheduler();
      final scheduler = _scheduler(
        leases: sqliteLeases,
        catalog: _Catalog([_request(_vm1)]),
        metrics: _MetricsSource(),
        limits: _limits(),
        leaseTtl: const Duration(seconds: 10),
        renewalInterval: const Duration(seconds: 4),
        renewalScheduler: timers,
        now: () => clock,
        onLeaseLost: (_, _, _, _, _) {
          throw StateError('enqueue unavailable');
        },
      );
      await scheduler.acquire(_state(_vm1), _operation1);
      clock = clock.add(const Duration(seconds: 11));
      timers.fireNext();
      await _settleAsyncWork();
      expect(scheduler.pendingLeaseLossCount, 1);

      await scheduler.shutdown();

      expect(scheduler.pendingLeaseLossCount, 0);
      expect(scheduler.pendingRenewalCount, 0);
      expect(timers.activeCount, 0);
    },
  );

  test('expired lease at running transition fails operation safely', () async {
    var clock = _now;
    final scheduler = _scheduler(
      leases: sqliteLeases,
      catalog: _Catalog([_request(_vm1), _request(_vm2)]),
      metrics: _MetricsSource(),
      limits: _limits(maxRunningVms: 1),
      leaseTtl: const Duration(seconds: 10),
      renewalInterval: const Duration(seconds: 4),
      renewalScheduler: _ManualRenewalScheduler(),
      now: () => clock,
    );
    await scheduler.acquire(_state(_vm1), _operation1);
    clock = clock.add(const Duration(seconds: 11));
    final runner = _SchedulerControllerRunner(scheduler);
    final controller = VmController(
      initialState: _startingState(_vm1),
      effectRunner: runner,
    );

    await controller.submit(
      VmStateChanged(
        operationId: _operation1,
        driverGeneration: 1,
        phase: VmPhase.running,
      ),
    );

    expect(controller.state.phase, VmPhase.failed);
    expect(controller.state.currentOperation?.state, OperationState.failed);
    expect(controller.state.lastError?.code, ErrorCode.hostResourceExhausted);
    expect(controller.state.activeDriverGeneration, 1);
    expect(controller.state.leaseState, VmLeaseState.held);
    expect(runner.calls, contains('KillDriver'));
    expect(runner.eventTypes, contains('vm.host_lease_lost'));
    final cleanupLease = (await sqliteLeases.list(activeAt: clock)).single;
    expect(cleanupLease.request.phase, HostLeasePhase.cleanup);
    await controller.submit(
      DriverCommandFailed(
        operationId: _operation1,
        driverGeneration: 1,
        command: RuntimeCommandKind.kill,
        error: OperationError(
          code: ErrorCode.driverUnhealthy,
          message: 'kill failed',
          retryable: true,
          details: JsonObjectValue.empty,
        ),
      ),
    );
    expect(controller.state.activeDriverGeneration, 1);
    expect(controller.state.leaseState, VmLeaseState.held);
    expect(runner.eventTypes, contains('vm.driver_cleanup_failed'));
    await expectLater(
      scheduler.acquire(_state(_vm2), _operation2),
      throwsA(
        isA<VmEffectException>().having(
          (error) => error.operationError.code,
          'code',
          ErrorCode.hostResourceExhausted,
        ),
      ),
    );
    await controller.submit(
      DriverExited(
        operationId: _operation1,
        driverGeneration: 1,
        cleanShutdown: false,
      ),
    );
    expect(controller.state.activeDriverGeneration, isNull);
    expect(controller.state.leaseState, VmLeaseState.none);
    await controller.shutdown();
  });

  test('lease recovery precedes VmRegistry startup reconciliation', () async {
    final vmRepository = SqliteVmRepository(
      database,
      newVmId: () => _vm1,
      now: () => _now,
    );
    await vmRepository.create(name: 'primary', spec: _vmSpec);
    await database.transaction(
      (connection) => connection.execute(
        '''
          UPDATE vm_runtime
          SET desired_state = 'running', phase = 'stopped'
          WHERE vm_id = ?
        ''',
        [_vm1.value],
      ),
    );
    final eventIds = [
      EventId('evt_01J00000000000000000000040'),
      EventId('evt_01J00000000000000000000041'),
    ].iterator;
    final operations = SqliteOperationRepository(
      database,
      newOperationId: () => _operation1,
      newEventId: () {
        eventIds.moveNext();
        return eventIds.current;
      },
      now: () => _now,
    );
    await operations.createAndStart(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: _vm1,
      requestId: RequestId('req_01J00000000000000000000040'),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    final scheduler = _scheduler(
      leases: sqliteLeases,
      // PR021 will provide precise managed-disk reservation. PR013 requires
      // callers to choose an explicit conservative headroom meanwhile.
      catalog: VmRepositoryHostCapacityCatalog(
        vmRepository,
        diskBytes: (_) => 0,
      ),
      metrics: _MetricsSource(),
      limits: _limits(),
      ownerId: 'restarted-daemon',
    );

    final recovered = await scheduler.recover();
    expect(recovered.single.admitted, isTrue);
    final registry = VmRegistry(
      repository: vmRepository,
      operations: operations,
      effectRunner: _SchedulerControllerRunner(scheduler),
    );
    await registry.reconcileOnStartup();

    final controller = await registry.get(_vm1);
    expect(controller?.state.leaseState, VmLeaseState.held);
    expect(controller?.state.activeDriverGeneration, 1);
    await controller!.submit(
      DriverSpawned(operationId: _operation1, driverGeneration: 1),
    );
    await controller.submit(
      DriverHandshakeCompleted(operationId: _operation1, driverGeneration: 1),
    );
    await controller.submit(
      DriverCommandSucceeded(
        operationId: _operation1,
        driverGeneration: 1,
        command: RuntimeCommandKind.configure,
      ),
    );
    await controller.submit(
      VmStateChanged(
        operationId: _operation1,
        driverGeneration: 1,
        phase: VmPhase.running,
      ),
    );
    final activeLease = (await sqliteLeases.list(activeAt: _now)).single;
    expect(activeLease.request.phase, HostLeasePhase.running);
    expect(activeLease.request.specGeneration, 1);
    expect(activeLease.request.operationId, _operation1);
    await registry.shutdown();
    expect(await sqliteLeases.list(activeAt: _now), isEmpty);
  });
}

final class _Catalog implements HostCapacityCatalog {
  _Catalog(Iterable<HostCapacityRequest> requests)
    : requests = {for (final request in requests) request.vmId: request};

  final Map<VmId, HostCapacityRequest> requests;

  @override
  Future<HostCapacityRequest> requestFor(
    VmId vmId, {
    required HostLeasePhase phase,
    int? specGeneration,
  }) async => requests[vmId]!.copyWith(phase: phase);

  @override
  Future<List<HostCapacityRequest>> recoveryRequests() async =>
      requests.values.toList();
}

final class _MetricsSource implements HostMetricsSource {
  _MetricsSource({this.trace});

  final List<String>? trace;

  @override
  Future<HostMetrics> sample() async {
    trace?.add('metrics');
    return _hostMetrics;
  }
}

final class _DelayedCatalog implements HostCapacityCatalog {
  _DelayedCatalog(this.delegate);

  final HostCapacityCatalog delegate;
  final entered = Completer<void>();
  final release = Completer<void>();
  var _delayNext = true;

  @override
  Future<HostCapacityRequest> requestFor(
    VmId vmId, {
    required HostLeasePhase phase,
    int? specGeneration,
  }) async {
    if (_delayNext) {
      _delayNext = false;
      entered.complete();
      await release.future;
    }
    return delegate.requestFor(
      vmId,
      phase: phase,
      specGeneration: specGeneration,
    );
  }

  @override
  Future<List<HostCapacityRequest>> recoveryRequests() =>
      delegate.recoveryRequests();
}

final class _DelayedMetricsSource implements HostMetricsSource {
  final entered = Completer<void>();
  final release = Completer<void>();
  var _delayNext = true;

  @override
  Future<HostMetrics> sample() async {
    if (_delayNext) {
      _delayNext = false;
      entered.complete();
      await release.future;
    }
    return _hostMetrics;
  }
}

final class _TracingLeaseRepository implements HostLeaseRepository {
  const _TracingLeaseRepository(
    this.delegate,
    this.trace, {
    this.beforeRetention,
  });

  final HostLeaseRepository delegate;
  final List<String> trace;
  final Future<void> Function()? beforeRetention;

  @override
  Future<HostLeaseDecision> acquire({
    required HostCapacityRequest request,
    required HostSchedulerLimits limits,
    required HostMetrics metrics,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  }) {
    trace.add('repository');
    return delegate.acquire(
      request: request,
      limits: limits,
      metrics: metrics,
      ownerId: ownerId,
      now: now,
      ttl: ttl,
    );
  }

  @override
  Future<List<HostLease>> list({DateTime? activeAt}) =>
      delegate.list(activeAt: activeAt);

  @override
  Future<bool> markRunning(
    VmId vmId, {
    required String ownerId,
    required OperationId operationId,
    required DateTime now,
  }) => delegate.markRunning(
    vmId,
    ownerId: ownerId,
    operationId: operationId,
    now: now,
  );

  @override
  Future<HostLease?> retainForCleanup({
    required HostCapacityRequest request,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  }) async {
    await beforeRetention?.call();
    return delegate.retainForCleanup(
      request: request,
      ownerId: ownerId,
      now: now,
      ttl: ttl,
    );
  }

  @override
  Future<List<HostLeaseDecision>> recover({
    required List<HostCapacityRequest> requests,
    required HostSchedulerLimits limits,
    required HostMetrics metrics,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  }) => delegate.recover(
    requests: requests,
    limits: limits,
    metrics: metrics,
    ownerId: ownerId,
    now: now,
    ttl: ttl,
  );

  @override
  Future<bool> release(VmId vmId, {required String ownerId}) =>
      delegate.release(vmId, ownerId: ownerId);

  @override
  Future<bool> renew(
    VmId vmId, {
    required String ownerId,
    required OperationId? operationId,
    required DateTime now,
    required Duration ttl,
  }) => delegate.renew(
    vmId,
    ownerId: ownerId,
    operationId: operationId,
    now: now,
    ttl: ttl,
  );

  @override
  Future<bool> releaseAcquisition(
    VmId vmId, {
    required String ownerId,
    required OperationId operationId,
  }) => delegate.releaseAcquisition(
    vmId,
    ownerId: ownerId,
    operationId: operationId,
  );
}

final class _DelayedAcquireRepository implements HostLeaseRepository {
  _DelayedAcquireRepository(
    this.delegate, {
    bool delayAcquire = true,
    this.delayRenew = false,
  }) : _delayNext = delayAcquire;

  final HostLeaseRepository delegate;
  final firstAcquireEntered = Completer<void>();
  final releaseFirstAcquire = Completer<void>();
  final renewEntered = Completer<void>();
  final releaseRenew = Completer<void>();
  final bool delayRenew;
  bool _delayNext;

  @override
  Future<HostLeaseDecision> acquire({
    required HostCapacityRequest request,
    required HostSchedulerLimits limits,
    required HostMetrics metrics,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  }) async {
    if (_delayNext) {
      _delayNext = false;
      firstAcquireEntered.complete();
      await releaseFirstAcquire.future;
    }
    return delegate.acquire(
      request: request,
      limits: limits,
      metrics: metrics,
      ownerId: ownerId,
      now: now,
      ttl: ttl,
    );
  }

  @override
  Future<List<HostLease>> list({DateTime? activeAt}) =>
      delegate.list(activeAt: activeAt);

  @override
  Future<bool> markRunning(
    VmId vmId, {
    required String ownerId,
    required OperationId operationId,
    required DateTime now,
  }) => delegate.markRunning(
    vmId,
    ownerId: ownerId,
    operationId: operationId,
    now: now,
  );

  @override
  Future<HostLease?> retainForCleanup({
    required HostCapacityRequest request,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  }) => delegate.retainForCleanup(
    request: request,
    ownerId: ownerId,
    now: now,
    ttl: ttl,
  );

  @override
  Future<List<HostLeaseDecision>> recover({
    required List<HostCapacityRequest> requests,
    required HostSchedulerLimits limits,
    required HostMetrics metrics,
    required String ownerId,
    required DateTime now,
    required Duration ttl,
  }) => delegate.recover(
    requests: requests,
    limits: limits,
    metrics: metrics,
    ownerId: ownerId,
    now: now,
    ttl: ttl,
  );

  @override
  Future<bool> release(VmId vmId, {required String ownerId}) =>
      delegate.release(vmId, ownerId: ownerId);

  @override
  Future<bool> releaseAcquisition(
    VmId vmId, {
    required String ownerId,
    required OperationId operationId,
  }) => delegate.releaseAcquisition(
    vmId,
    ownerId: ownerId,
    operationId: operationId,
  );

  @override
  Future<bool> renew(
    VmId vmId, {
    required String ownerId,
    required OperationId? operationId,
    required DateTime now,
    required Duration ttl,
  }) async {
    if (delayRenew) {
      if (!renewEntered.isCompleted) renewEntered.complete();
      await releaseRenew.future;
    }
    return delegate.renew(
      vmId,
      ownerId: ownerId,
      operationId: operationId,
      now: now,
      ttl: ttl,
    );
  }
}

final class _ManualRenewalScheduler implements VmTimerScheduler {
  final handles = <_ManualRenewalHandle>[];

  int get activeCount => handles.where((handle) => handle.isActive).length;

  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) {
    final handle = _ManualRenewalHandle(callback);
    handles.add(handle);
    return handle;
  }

  void fireNext() => handles.firstWhere((handle) => handle.isActive).fire();
}

final class _ManualRenewalHandle implements VmTimerHandle {
  _ManualRenewalHandle(this.callback);

  final void Function() callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }
}

final class _SchedulerControllerRunner implements VmEffectRunner {
  _SchedulerControllerRunner(this.scheduler);

  final HostScheduler scheduler;
  final calls = <String>[];
  final eventTypes = <String>[];

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    calls.add(effect.runtimeType.toString());
    if (effect is EmitEvent) eventTypes.add(effect.type);
    if (effect is AcquireHostLease) {
      await scheduler.acquire(state, effect.operationId!);
      return HostLeaseAcquired(effect.operationId!);
    }
    if (effect is MarkHostLeaseRunning) {
      await scheduler.markRunning(state, effect.operationId!);
    }
    if (effect is ReleaseHostLease) {
      await scheduler.release(state, effect.operationId);
      return HostLeaseReleased(effect.operationId);
    }
    if (effect is ShutdownDriver) {
      return ControllerDriverShutdownSucceeded(
        effect.driverGeneration!,
        effect.operationId!,
      );
    }
    if (effect is ShutdownLease) {
      await scheduler.release(state, effect.operationId);
      return const ControllerLeaseShutdownSucceeded();
    }
    return null;
  }
}

HostScheduler _scheduler({
  required HostLeaseRepository leases,
  required HostCapacityCatalog catalog,
  required HostMetricsSource metrics,
  required HostSchedulerLimits limits,
  String ownerId = 'daemon-a',
  HostLeaseLostHandler? onLeaseLost,
  Duration leaseTtl = const Duration(minutes: 1),
  Duration? renewalInterval,
  Duration? lossRetryInterval,
  Duration shutdownTimeout = const Duration(seconds: 10),
  VmTimerScheduler renewalScheduler = const DartVmTimerScheduler(),
  DateTime Function()? now,
}) => HostScheduler(
  leases: leases,
  catalog: catalog,
  metrics: metrics,
  limits: limits,
  ownerId: ownerId,
  onLeaseLost: onLeaseLost ?? ((_, _, _, _, _) {}),
  leaseTtl: leaseTtl,
  renewalInterval: renewalInterval,
  lossRetryInterval: lossRetryInterval,
  shutdownTimeout: shutdownTimeout,
  renewalScheduler: renewalScheduler,
  now: now ?? (() => _now),
);

VmControllerState _state(VmId vmId) => VmControllerState.initial(
  vmId: vmId,
  specGeneration: 1,
  restartPolicy: RestartPolicy.onFailure,
);

VmControllerState _startingState(VmId vmId) => _state(vmId).copyWith(
  desiredState: DesiredState.running,
  phase: VmPhase.starting,
  driverGeneration: 1,
  activeDriverGeneration: 1,
  activeSpecGeneration: 1,
  driverOperationId: _operation1,
  leaseState: VmLeaseState.held,
  currentOperation: VmControllerOperation(
    id: _operation1,
    kind: VmOperationKind.start,
    state: OperationState.running,
  ),
);

HostCapacityRequest _request(VmId vmId) => HostCapacityRequest(
  vmId: vmId,
  cpuCount: 2,
  memoryBytes: 1024,
  diskBytes: 0,
  phase: HostLeasePhase.booting,
  specGeneration: 1,
  operationId: _operation1,
);

HostSchedulerLimits _limits({
  int maxRunningVms = 8,
  int maxConcurrentBoots = 8,
  int maxDriverProcesses = 8,
}) => HostSchedulerLimits(
  maxRunningVms: maxRunningVms,
  maxConcurrentBoots: maxConcurrentBoots,
  maxDriverProcesses: maxDriverProcesses,
  maxCpuCount: 64,
  maxMemoryBytes: 1 << 30,
  minFreeDiskBytes: 0,
);

const _hostMetrics = HostMetrics(
  logicalCpuCount: 64,
  totalMemoryBytes: 1 << 30,
  availableMemoryBytes: 1 << 30,
  freeDiskBytes: 1 << 30,
  unmanagedDriverProcesses: 0,
);
final _now = DateTime.utc(2026, 9, 4, 10);
final _vm1 = VmId('vm_01J00000000000000000000000');
final _vm2 = VmId('vm_01J00000000000000000000001');
final _operation1 = OperationId('op_01J00000000000000000000000');
final _operation2 = OperationId('op_01J00000000000000000000001');

Future<void> _settleAsyncWork() =>
    Future<void>.delayed(const Duration(milliseconds: 5));

final _vmSpec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [SharedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.onFailure,
);
