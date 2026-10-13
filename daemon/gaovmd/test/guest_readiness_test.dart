import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/guest_bridge_client.dart';
import 'package:gaovmd/src/guest_session_reconcile_loop.dart';
import 'package:gaovmd/src/host_guest_session.dart';
import 'package:test/test.dart';

import 'fixtures/completed_runtime_owner.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteVmRepository catalog;
  late SqliteEventRepository events;
  late SqliteVmStateEffectAdapter persistence;
  late VmControllerState running;
  late VmController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('guest-readiness-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    catalog = SqliteVmRepository(database);
    final vm = await catalog.create(name: 'guest', spec: _spec);
    events = SqliteEventRepository(database);
    persistence = SqliteVmStateEffectAdapter(database);
    running =
        VmControllerState.initial(
          vmId: vm.metadata.id,
          specGeneration: 1,
          restartPolicy: RestartPolicy.never,
        ).copyWith(
          desiredState: DesiredState.running,
          phase: VmPhase.running,
          observedGeneration: 1,
          driverGeneration: 3,
          activeDriverGeneration: 3,
          activeSpecGeneration: 1,
          driverOperationId: await seedCompletedRuntimeOwner(
            database,
            vm.metadata.id,
          ),
        );
    await persistence.persistVm(running);
    await persistence.persistRuntime(running);
    final boundary = _RuntimeBoundary();
    controller = VmController(
      initialState: running,
      effectRunner: RepositoryVmEffectRunner(
        database: database,
        operations: SqliteOperationRepository(database),
        events: events,
        persistence: persistence,
        leases: boundary,
        drivers: boundary,
        managedFiles: boundary,
      ),
    );
  });

  tearDown(() async {
    await controller.shutdown();
    database.close();
    await directory.delete(recursive: true);
  });

  Future<(_GuestDriverFactory, RuntimeDriverEffectAdapter)> child({
    String scenario = 'guest-bridge-session',
    bool enabled = true,
    Future<void> Function(VmCommand)? beforeDispatch,
  }) async {
    final root =
        await (Platform.isMacOS
                ? Directory('/private/tmp')
                : Directory.systemTemp)
            .createTemp('ggr-');
    final factory = _GuestDriverFactory(root, scenario);
    final adapter = RuntimeDriverEffectAdapter(
      factory: factory,
      resolveConfiguration: (_) async =>
          _configuration(root.path, enabled: enabled),
      dispatch: (_, command) async {
        await beforeDispatch?.call(command);
        await controller.submit(command);
      },
    );
    addTearDown(() async {
      await adapter.close();
      await factory.manager.close();
      await root.delete(recursive: true);
    });
    final operation = running.driverOperationId!;
    await adapter.spawn(running, operation, 3);
    await adapter.connect(running, operation, 3);
    await adapter.configure(running, operation, 3);
    return (factory, adapter);
  }

  test(
    'validated guest readiness commits with its durable event and outbox',
    () async {
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.unavailable,
      );
      await controller.submit(
        GuestReadinessObserved(
          vmId: running.vmId,
          driverGeneration: 3,
          revision: 1,
          ready: true,
        ),
      );
      final vm = (await catalog.get(running.vmId))!;
      expect(vm.status.guestAgent, GuestAgentState.ready);
      expect(vm.status.phase, VmPhase.running);
      expect(vm.status.desiredState, DesiredState.running);
      final journal = await events.list(vmId: running.vmId);
      expect(journal.map((event) => event.type), ['vm.guest_agent_ready']);
      expect(journal.single.payload.toJson(), {'driver_generation': 3});
      expect(await events.readUnpublishedOutbox(), hasLength(1));
      expect(controller.state.currentOperation, isNull);
    },
  );

  test(
    'failed readiness publication rolls back and leaves the VM lifecycle intact',
    () async {
      await database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER fail_guest_event BEFORE INSERT ON events
      WHEN NEW.type = 'vm.guest_agent_ready'
      BEGIN SELECT RAISE(ABORT, 'fixture event failure'); END;
    '''),
      );
      await expectLater(
        controller.submit(
          GuestReadinessObserved(
            vmId: running.vmId,
            driverGeneration: 3,
            revision: 1,
            ready: true,
          ),
        ),
        throwsA(isA<VmEffectBatchException>()),
      );
      expect(controller.state.phase, VmPhase.running);
      expect(controller.state.desiredState, DesiredState.running);
      expect(controller.state.guestObservationRevision, 0);
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.unavailable,
      );
      expect(await events.list(vmId: running.vmId), isEmpty);
      expect(await events.readUnpublishedOutbox(), isEmpty);
      await database.transaction(
        (db) => db.execute('DROP TRIGGER fail_guest_event'),
      );
      await controller.submit(
        GuestReadinessObserved(
          vmId: running.vmId,
          driverGeneration: 3,
          revision: 1,
          ready: true,
        ),
      );
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.ready,
      );
    },
  );

  test(
    'stopping runtime revokes guest readiness before process cleanup',
    () async {
      await controller.submit(
        GuestReadinessObserved(
          vmId: running.vmId,
          driverGeneration: 3,
          revision: 1,
          ready: true,
        ),
      );
      final transition = running.copyWith(phase: VmPhase.stopping);
      await persistence.persistRuntime(transition);
      final vm = (await catalog.get(running.vmId))!;
      expect(vm.status.phase, VmPhase.stopping);
      expect(vm.status.guestAgent, GuestAgentState.unavailable);
    },
  );

  test(
    'old VM, generation and same-generation observations cannot revive readiness',
    () async {
      GuestReadinessObserved observation(
        int revision,
        bool ready, {
        VmId? vmId,
        int generation = 3,
      }) => GuestReadinessObserved(
        vmId: vmId ?? running.vmId,
        driverGeneration: generation,
        revision: revision,
        ready: ready,
      );
      await controller.submit(observation(1, true));
      await controller.submit(observation(3, false));
      await controller.submit(observation(2, true));
      await controller.submit(observation(4, true, generation: 2));
      await controller.submit(observation(4, true, vmId: VmId.generate()));
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.unavailable,
      );
      expect(controller.state.guestObservationRevision, 3);
      expect(await events.list(vmId: running.vmId), hasLength(2));
      await controller.submit(observation(4, true));
      await controller.submit(observation(4, false));
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.ready,
      );
      expect(await events.list(vmId: running.vmId), hasLength(3));
    },
  );

  test(
    'a committed stop or deletion fences readiness before controller adoption',
    () async {
      await database.transaction(
        (db) => db.execute(
          "UPDATE vm_runtime SET desired_state = 'stopped' WHERE vm_id = ?",
          [running.vmId.value],
        ),
      );
      await controller.submit(
        GuestReadinessObserved(
          vmId: running.vmId,
          driverGeneration: 3,
          revision: 1,
          ready: true,
        ),
      );
      await database.transaction((db) {
        db.execute(
          "UPDATE vm_runtime SET desired_state = 'running' WHERE vm_id = ?",
          [running.vmId.value],
        );
        db.execute('UPDATE vms SET deleting_at = ? WHERE id = ?', [
          '2026-10-11T00:00:00.000000Z',
          running.vmId.value,
        ]);
      });
      await controller.submit(
        GuestReadinessObserved(
          vmId: running.vmId,
          driverGeneration: 3,
          revision: 2,
          ready: true,
        ),
      );
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.unavailable,
      );
      expect(await events.list(vmId: running.vmId), isEmpty);
      expect(await events.readUnpublishedOutbox(), isEmpty);
    },
  );

  test(
    'readiness uses the applied spec rather than a newer unapplied guest setting',
    () async {
      final disabledSpec = VmSpec.fromJson({
        ..._spec.toJson(),
        'guest_agent': {..._spec.guestAgent.toJson(), 'enabled': false},
      });
      await catalog.updateSpec(
        running.vmId,
        expectedRevision: 1,
        spec: disabledSpec,
      );
      await controller.submit(
        GuestReadinessObserved(
          vmId: running.vmId,
          driverGeneration: 3,
          revision: 1,
          ready: true,
        ),
      );
      final current = (await catalog.get(running.vmId))!;
      expect(current.spec.guestAgent.enabled, isFalse);
      expect(current.status.observedGeneration, 1);
      expect(current.status.guestAgent, GuestAgentState.ready);
      final replacement = running.copyWith(
        driverGeneration: 4,
        activeDriverGeneration: 4,
        activeSpecGeneration: 2,
        observedGeneration: 2,
      );
      await persistence.persistRuntime(replacement);
      await persistence.persistGuestReadiness(replacement, true);
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.disabled,
      );
      expect(await events.list(vmId: running.vmId), hasLength(1));
      expect(replacement.guestObservationRevision, 0);
    },
  );

  test(
    'daemon recovery cannot retain readiness without a live driver owner',
    () async {
      await controller.submit(
        GuestReadinessObserved(
          vmId: running.vmId,
          driverGeneration: 3,
          revision: 1,
          ready: true,
        ),
      );
      await persistence.persistRuntime(
        running.copyWith(clearActiveDriverGeneration: true),
      );
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.unavailable,
      );
    },
  );

  test(
    'a superseded live observation cannot publish readiness after its epoch closes',
    () async {
      var current = true;
      await controller.submit(
        GuestReadinessObserved(
          vmId: running.vmId,
          driverGeneration: 3,
          revision: 1,
          ready: true,
          stillCurrent: () => current,
        ),
      );
      current = false;
      await controller.submit(
        GuestReadinessObserved(
          vmId: running.vmId,
          driverGeneration: 3,
          revision: 2,
          ready: false,
        ),
      );
      await controller.submit(
        GuestReadinessObserved(
          vmId: running.vmId,
          driverGeneration: 3,
          revision: 3,
          ready: true,
          stillCurrent: () => current,
        ),
      );
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.unavailable,
      );
      expect(await events.list(vmId: running.vmId), hasLength(2));
      expect(controller.state.guestObservationRevision, 2);
    },
  );

  test(
    'a real child guest session drives committed readiness and preserves runtime on guest close',
    () async {
      final (factory, adapter) = await child();
      final waiter = SqliteVmConditionWaiter(
        repository: catalog,
        events: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 10),
        ),
      );
      final waiting = waiter.wait(
        VmWaitCommand(
          vmId: running.vmId,
          condition: VmWaitCondition.guestAgentReady,
          timeout: const Duration(seconds: 3),
        ),
      );
      final operation = running.driverOperationId!;
      expect(adapter.readyGuestConnection(running.vmId, 3), isNull);
      await adapter.start(running, operation, 3);
      await waiting;
      final session = factory.session!;
      expect(
        adapter.readyGuestConnection(running.vmId, 3),
        same(session.guestSession.readyConnection),
      );
      expect(adapter.readyGuestConnection(running.vmId, 2), isNull);
      expect(adapter.readyGuestConnection(VmId.generate(), 3), isNull);
      await session.guestSession.close();
      expect(adapter.readyGuestConnection(running.vmId, 3), isNull);
      await adapter.waitUntilEventsDispatched();
      final vm = (await catalog.get(running.vmId))!;
      expect(vm.status.guestAgent, GuestAgentState.unavailable);
      expect(vm.status.phase, VmPhase.running);
      expect(vm.status.desiredState, DesiredState.running);
      expect((await session.ping()).status, RuntimeCommandStatus.succeeded);
      expect(
        (await events.list(vmId: running.vmId)).map((event) => event.type),
        ['vm.guest_agent_ready', 'vm.guest_agent_unavailable'],
      );
    },
  );

  test(
    'guest reconcile reconnects a closed epoch without restarting its driver',
    () async {
      final (factory, adapter) = await child();
      final waiter = SqliteVmConditionWaiter(
        repository: catalog,
        events: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 10),
        ),
      );
      Future<void> ready() => waiter.wait(
        VmWaitCommand(
          vmId: running.vmId,
          condition: VmWaitCondition.guestAgentReady,
          timeout: const Duration(seconds: 1),
        ),
      );
      await adapter.start(running, running.driverOperationId!, 3);
      await ready();
      final guest = factory.session!.guestSession;
      final previous = await guest.connect(
        deadline: GuestBridgeDeadline.after(const Duration(seconds: 1)),
      );
      await previous.close();
      await adapter.waitUntilEventsDispatched();
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.unavailable,
      );
      adapter.reconcileGuestSessions();
      await ready();
      expect(factory.manager.activeProcessCount, 1);
      expect(guest.isReady, isTrue);
      expect(
        (await events.list(vmId: running.vmId)).map((event) => event.type),
        [
          'vm.guest_agent_ready',
          'vm.guest_agent_unavailable',
          'vm.guest_agent_ready',
        ],
      );
      expect((await catalog.get(running.vmId))!.status.phase, VmPhase.running);
    },
  );

  test(
    'guest reconcile detects degraded health and recovery on the same epoch',
    () async {
      final (factory, adapter) = await child(
        scenario: 'guest-bridge-session-health-flap',
      );
      final waiter = SqliteVmConditionWaiter(
        repository: catalog,
        events: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 10),
        ),
      );
      Future<void> ready() => waiter.wait(
        VmWaitCommand(
          vmId: running.vmId,
          condition: VmWaitCondition.guestAgentReady,
          timeout: const Duration(seconds: 1),
        ),
      );
      await adapter.start(running, running.driverOperationId!, 3);
      await ready();
      adapter.reconcileGuestSessions();
      await _until(
        () async =>
            (await catalog.get(running.vmId))!.status.guestAgent ==
            GuestAgentState.unavailable,
      );
      expect(factory.session!.guestSession.isReady, isFalse);
      expect(
        (await factory.session!.ping()).data!.toJson()['bridge_connections'],
        1,
      );
      adapter.reconcileGuestSessions();
      await ready();
      expect(
        (await factory.session!.ping()).data!.toJson()['bridge_connections'],
        1,
      );
      expect(
        (await events.list(vmId: running.vmId)).map((event) => event.type),
        [
          'vm.guest_agent_ready',
          'vm.guest_agent_unavailable',
          'vm.guest_agent_ready',
        ],
      );
      expect((await catalog.get(running.vmId))!.status.phase, VmPhase.running);
    },
  );

  test(
    'guest loop starts once and reconnects on five-second ticks until closed',
    () async {
      final (factory, adapter) = await child();
      final timers = _GuestScheduler();
      final loop = GuestSessionReconcileLoop(
        drivers: adapter,
        scheduler: timers,
        onError: (_, error, _) => fail('$error'),
      );
      addTearDown(loop.close);
      await adapter.start(running, running.driverOperationId!, 3);
      final waiter = SqliteVmConditionWaiter(
        repository: catalog,
        events: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 10),
        ),
      );
      Future<void> ready() => waiter.wait(
        VmWaitCommand(
          vmId: running.vmId,
          condition: VmWaitCondition.guestAgentReady,
          timeout: const Duration(seconds: 1),
        ),
      );
      await ready();
      loop.start();
      loop.start();
      expect(timers.activeCount, 1);
      expect(timers.handles.single.delay, const Duration(seconds: 5));
      final guest = factory.session!.guestSession;
      await guest.refresh(
        deadline: GuestBridgeDeadline.after(const Duration(seconds: 1)),
      );
      await (await guest.connect(
        deadline: GuestBridgeDeadline.after(const Duration(seconds: 1)),
      )).close();
      await adapter.waitUntilEventsDispatched();
      timers.fire();
      await ready();
      expect(timers.activeCount, 1);
      await loop.close();
      await loop.close();
      expect(timers.activeCount, 0);
      await (await guest.connect(
        deadline: GuestBridgeDeadline.after(const Duration(seconds: 1)),
      )).close();
      await adapter.waitUntilEventsDispatched();
      timers.fire();
      expect(guest.isReady, isFalse);
      expect(loop.start, throwsStateError);
    },
  );

  test(
    'a stalled VM guest probe cannot block another VM or overlap repeated ticks',
    () async {
      final vm = await catalog.create(name: 'healthy peer', spec: _spec);
      final peerState =
          VmControllerState.initial(
            vmId: vm.metadata.id,
            specGeneration: 1,
            restartPolicy: RestartPolicy.never,
          ).copyWith(
            desiredState: DesiredState.running,
            phase: VmPhase.running,
            observedGeneration: 1,
            driverGeneration: 3,
            activeDriverGeneration: 3,
            activeSpecGeneration: 1,
            driverOperationId: await seedCompletedRuntimeOwner(
              database,
              vm.metadata.id,
            ),
          );
      await persistence.persistVm(peerState);
      await persistence.persistRuntime(peerState);
      final boundary = _RuntimeBoundary();
      final peerController = VmController(
        initialState: peerState,
        effectRunner: RepositoryVmEffectRunner(
          database: database,
          operations: SqliteOperationRepository(database),
          events: events,
          persistence: persistence,
          leases: boundary,
          drivers: boundary,
          managedFiles: boundary,
        ),
      );
      final root =
          await (Platform.isMacOS
                  ? Directory('/private/tmp')
                  : Directory.systemTemp)
              .createTemp('ggr-');
      final factory = _GuestDriverFactory(
        root,
        'guest-bridge-session-health-hang',
        scenarios: {peerState.vmId: 'guest-bridge-session'},
      );
      final adapter = RuntimeDriverEffectAdapter(
        factory: factory,
        resolveConfiguration: (_) async =>
            _configuration(root.path, enabled: true),
        dispatch: (vmId, command) async {
          await (vmId == peerState.vmId ? peerController : controller).submit(
            command,
          );
        },
      );
      final timers = _GuestScheduler();
      final loop = GuestSessionReconcileLoop(
        drivers: adapter,
        scheduler: timers,
        onError: (_, error, _) => fail('$error'),
      );
      addTearDown(() async {
        await loop.close();
        await adapter.close();
        await factory.manager.close();
        await peerController.shutdown();
        await root.delete(recursive: true);
      });
      for (final state in [running, peerState]) {
        final operation = state.driverOperationId!;
        await adapter.spawn(state, operation, 3);
        await adapter.connect(state, operation, 3);
        await adapter.configure(state, operation, 3);
        await adapter.start(state, operation, 3);
      }
      loop.start();
      for (var tick = 0; tick < 100; tick++) {
        timers.fire();
      }
      expect(timers.activeCount, 1);
      await SqliteVmConditionWaiter(
        repository: catalog,
        events: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 10),
        ),
      ).wait(
        VmWaitCommand(
          vmId: peerState.vmId,
          condition: VmWaitCondition.guestAgentReady,
          timeout: const Duration(seconds: 1),
        ),
      );
      final stalled = factory.sessions[running.vmId]!;
      await _until(
        () async =>
            (await stalled.ping()).data!.toJson()['bridge_connections'] == 1,
      );
      expect((await stalled.ping()).data!.toJson()['bridge_connections'], 1);
      expect(stalled.guestSession.isReady, isFalse);
      expect(factory.sessions[peerState.vmId]!.guestSession.isReady, isTrue);
      expect((await catalog.get(running.vmId))!.status.phase, VmPhase.running);
      expect(adapter.activeSessionCount, 2);
      await loop.close();
      await adapter.close().timeout(const Duration(seconds: 1));
      expect(factory.manager.activeProcessCount, 0);
    },
  );

  test(
    'guest publications coalesce to current evidence while delivery is blocked',
    () async {
      final delivered = <GuestReadinessObserved>[];
      final entered = Completer<void>();
      final release = Completer<void>();
      final (factory, adapter) = await child(
        scenario: 'guest-bridge-session-health-flap',
        beforeDispatch: (command) async {
          if (command is! GuestReadinessObserved) return;
          delivered.add(command);
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        },
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await adapter.start(running, running.driverOperationId!, 3);
      await entered.future;
      final guest = factory.session!.guestSession;
      await expectLater(
        guest.refresh(
          deadline: GuestBridgeDeadline.after(const Duration(seconds: 1)),
        ),
        throwsA(isA<GuestSessionException>()),
      );
      await guest.refresh(
        deadline: GuestBridgeDeadline.after(const Duration(seconds: 1)),
      );
      for (var tick = 0; tick < 100; tick++) {
        adapter.reconcileGuestSessions();
      }
      expect(delivered, hasLength(1));
      release.complete();
      await adapter.waitUntilEventsDispatched();
      expect(delivered.map((observation) => observation.revision), [1, 3]);
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.ready,
      );
      expect(
        (await events.list(vmId: running.vmId)).map((event) => event.type),
        ['vm.guest_agent_ready'],
      );
      expect(await events.readUnpublishedOutbox(), hasLength(1));
    },
  );

  test(
    'driver adapter close drains an admitted guest publication after channel cleanup',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final (factory, adapter) = await child(
        beforeDispatch: (command) async {
          if (command is GuestReadinessObserved && !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        },
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await adapter.start(running, running.driverOperationId!, 3);
      await entered.future;
      var closed = false;
      final closing = adapter.close().then((_) => closed = true);
      await _until(() async => factory.manager.activeProcessCount == 0);
      await Future<void>.value();
      expect(closed, isFalse);
      release.complete();
      await closing;
      expect(closed, isTrue);
      expect(await events.list(vmId: running.vmId), isEmpty);
      expect(await events.readUnpublishedOutbox(), isEmpty);
    },
  );

  test(
    'closing a real guest epoch while SQLite is busy never publishes queued readiness',
    () async {
      final (factory, adapter) = await child();
      final entered = Completer<void>();
      final release = Completer<void>();
      final busy = database.transaction((_) async {
        entered.complete();
        await release.future;
      });
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await entered.future;
      await adapter.start(running, running.driverOperationId!, 3);
      final guest = factory.session!.guestSession;
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!guest.isReady) {
        if (DateTime.now().isAfter(deadline))
          fail('fixture guest did not become healthy');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await guest.close();
      release.complete();
      await busy;
      await adapter.waitUntilEventsDispatched();
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.unavailable,
      );
      expect(await events.list(vmId: running.vmId), isEmpty);
      expect(await events.readUnpublishedOutbox(), isEmpty);
      expect(
        (await factory.session!.ping()).status,
        RuntimeCommandStatus.succeeded,
      );
    },
  );

  test(
    'revocation during event insertion rolls back both status and journal',
    () async {
      var current = true;
      final adapter = SqliteVmStateEffectAdapter(
        database,
        now: () {
          current = false;
          return DateTime.utc(2026, 10, 11);
        },
      );
      final boundary = _RuntimeBoundary();
      final runner = RepositoryVmEffectRunner(
        database: database,
        operations: SqliteOperationRepository(database),
        events: events,
        persistence: adapter,
        leases: boundary,
        drivers: boundary,
        managedFiles: boundary,
      );
      await runner.run(
        PersistGuestReadiness(
          vmId: running.vmId,
          driverGeneration: 3,
          ready: true,
          stillCurrent: () => current,
        ),
        running,
      );
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.unavailable,
      );
      expect(await events.list(vmId: running.vmId), isEmpty);
      expect(await events.readUnpublishedOutbox(), isEmpty);
    },
  );

  for (final (scenario, enabled) in [
    ('normal', true),
    ('guest-bridge-session', false),
  ]) {
    test(
      'optional guest support does not block runtime: $scenario enabled=$enabled',
      () async {
        final (factory, adapter) = await child(
          scenario: scenario,
          enabled: enabled,
        );
        await adapter.start(running, running.driverOperationId!, 3);
        await adapter.waitUntilEventsDispatched();
        final session = factory.session!;
        expect((await session.ping()).status, RuntimeCommandStatus.succeeded);
        expect(session.guestSession.isReady, isFalse);
        expect(
          (await catalog.get(running.vmId))!.status.phase,
          VmPhase.running,
        );
        expect(await events.list(vmId: running.vmId), isEmpty);
      },
    );
  }

  test(
    'a stalled guest health probe neither blocks ping nor delays owned shutdown',
    () async {
      final (factory, adapter) = await child(
        scenario: 'guest-bridge-session-health-hang',
      );
      await adapter.start(running, running.driverOperationId!, 3);
      final waiting =
          SqliteVmConditionWaiter(
            repository: catalog,
            events: SqliteDurableEventFeed(
              database,
              pollInterval: const Duration(milliseconds: 10),
            ),
          ).wait(
            VmWaitCommand(
              vmId: running.vmId,
              condition: VmWaitCondition.guestAgentReady,
              timeout: const Duration(milliseconds: 200),
            ),
          );
      await expectLater(waiting, throwsA(isA<TimeoutException>()));
      expect(
        (await factory.session!.ping()).status,
        RuntimeCommandStatus.succeeded,
      );
      expect((await catalog.get(running.vmId))!.status.phase, VmPhase.running);
      await adapter.close().timeout(const Duration(seconds: 1));
      expect(factory.manager.activeProcessCount, 0);
    },
  );

  test(
    'guest publication failure is surfaced without releasing the healthy child driver',
    () async {
      await database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER fail_guest_event BEFORE INSERT ON events
      WHEN NEW.type = 'vm.guest_agent_ready'
      BEGIN SELECT RAISE(ABORT, 'fixture guest publication failure'); END;
    '''),
      );
      final (factory, adapter) = await child();
      await adapter.start(running, running.driverOperationId!, 3);
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!factory.session!.guestSession.isReady) {
        if (DateTime.now().isAfter(deadline))
          fail('fixture guest was not negotiated');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await expectLater(
        adapter.waitUntilEventsDispatched(),
        throwsA(isA<RuntimeDriverDispatchException>()),
      );
      expect(factory.manager.activeProcessCount, 1);
      expect(
        (await factory.session!.ping()).status,
        RuntimeCommandStatus.succeeded,
      );
      expect((await catalog.get(running.vmId))!.status.phase, VmPhase.running);
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.unavailable,
      );
      expect(await events.list(vmId: running.vmId), isEmpty);
      expect(await events.readUnpublishedOutbox(), isEmpty);
      await database.transaction(
        (db) => db.execute('DROP TRIGGER fail_guest_event'),
      );
      adapter.reconcileGuestSessions();
      await adapter.waitUntilEventsDispatched();
      expect(
        (await catalog.get(running.vmId))!.status.guestAgent,
        GuestAgentState.ready,
      );
      expect(
        (await events.list(vmId: running.vmId)).map((event) => event.type),
        ['vm.guest_agent_ready'],
      );
      expect(await events.readUnpublishedOutbox(), hasLength(1));
      expect(factory.manager.activeProcessCount, 1);
    },
  );
}

Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition did not become true');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _GuestScheduler implements VmTimerScheduler {
  final handles = <_GuestTimer>[];
  int get activeCount => handles.where((handle) => handle.isActive).length;
  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) {
    final handle = _GuestTimer(delay, callback);
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

final class _GuestTimer implements VmTimerHandle {
  _GuestTimer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
}

final class _GuestDriverFactory implements RuntimeDriverFactory {
  _GuestDriverFactory(
    Directory root,
    String scenario, {
    Map<VmId, String> scenarios = const {},
  }) : manager = DriverProcessManager(
         layout: DriverRuntimeLayout('${root.path}/run'),
         resolveExecutable: (vmId) => DriverExecutable(
           path: Platform.resolvedExecutable,
           prefixArguments: [
             '--packages=${Directory.current.path}/.dart_tool/package_config.json',
             '${Directory.current.path}/test/fixtures/fake_driver_v2.dart',
             '--scenario',
             scenarios[vmId] ?? scenario,
           ],
         ),
         resolveBundlePath: (vmId) async {
           final path = '${root.path}/${vmId.value}.gaovm';
           await Directory('$path/logs').create(recursive: true);
           return path;
         },
         connectTimeout: const Duration(seconds: 2),
         handshakeTimeout: const Duration(seconds: 2),
         heartbeatInterval: const Duration(seconds: 30),
       );
  final DriverProcessManager manager;
  ProcessRuntimeDriverSession? session;
  final sessions = <VmId, ProcessRuntimeDriverSession>{};
  @override
  Future<RuntimeDriverSession> spawn(RuntimeDriverLaunch launch) async {
    final created = await manager.spawn(launch) as ProcessRuntimeDriverSession;
    sessions[launch.correlation.vmId] = created;
    session = created;
    return created;
  }

  @override
  Future<void> cancelSpawn(DriverCorrelation correlation) =>
      manager.cancelSpawn(correlation);
  @override
  Future<void> release(DriverCorrelation correlation) =>
      manager.release(correlation);
}

RuntimeDriverConfiguration _configuration(
  String root, {
  required bool enabled,
}) => RuntimeDriverConfiguration(
  architecture: Architecture.arm64,
  cpu: 2,
  memoryBytes: 268435456,
  boot: RuntimeEfiBootConfiguration(variableStorePath: '$root/efi.bin'),
  disks: [
    RuntimeDiskConfiguration(
      id: 'root',
      path: '$root/disk.img',
      writable: true,
    ),
  ],
  networks: [
    RuntimeNetworkConfiguration(id: 'net0', mode: RuntimeNetworkMode.none),
  ],
  graphics: RuntimeGraphicsConfiguration(enabled: false),
  serial: RuntimeSerialConfiguration(
    enabled: true,
    capture: true,
    logPath: '$root/serial.log',
  ),
  guestAgent: RuntimeGuestAgentConfiguration(
    enabled: enabled,
    vsockPort: 10777,
  ),
  bundlePath: '$root/bundle.gaovm',
  driverLogPath: '$root/driver.log',
);

final class _RuntimeBoundary
    implements
        VmDriverEffectAdapter,
        VmLeaseEffectAdapter,
        VmManagedFileEffectAdapter {
  @override
  Future<void> acquire(
    VmControllerState state,
    OperationId operationId,
  ) async {}
  @override
  Future<void> markRunning(
    VmControllerState state,
    OperationId operationId,
  ) async {}
  @override
  Future<void> release(
    VmControllerState state,
    OperationId? operationId,
  ) async {}
  @override
  Future<void> spawn(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}
  @override
  Future<void> connect(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}
  @override
  Future<void> configure(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}
  @override
  Future<void> start(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}
  @override
  Future<void> stop(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}
  @override
  Future<void> kill(
    VmControllerState state,
    OperationId operationId,
    int driverGeneration,
  ) async {}
  @override
  Future<void> remove(VmControllerState state, OperationId operationId) async {}
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/private/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: true, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
