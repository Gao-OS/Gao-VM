import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/fake_runtime_driver.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:gaovmd/src/runtime_driver_effect_adapter.dart';
import 'package:gaovmd/src/vm_controller.dart';
import 'package:gaovmd/src/vm_controller_reducer.dart';
import 'package:test/test.dart';

void main() {
  test(
    'routes correlated state and deduplicates terminal observations',
    () async {
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(
        scheduler: scheduler,
        scenario: const FakeRuntimeDriverScenario(
          startDelay: Duration(seconds: 2),
        ),
      );
      final commands = <VmCommand>[];
      final adapter = RuntimeDriverEffectAdapter(
        factory: factory,
        resolveConfiguration: (_) async => _configuration,
        dispatch: (vmId, command) async {
          expect(vmId, _vm1);
          commands.add(command);
        },
      );
      addTearDown(adapter.close);
      final state = _state(_vm1);

      await adapter.spawn(state, _operation1, 1);
      await adapter.connect(state, _operation1, 1);
      await adapter.configure(state, _operation1, 1);
      await adapter.start(state, _operation1, 1);
      scheduler.advanceBy(const Duration(seconds: 2));
      final correlation = DriverCorrelation(
        vmId: _vm1,
        driverGeneration: 1,
        operationId: _operation1,
      );
      final control = factory.controlFor(correlation);
      control.guestShutdown();
      await adapter.waitUntilEventsDispatched();
      expect(commands.whereType<DriverExited>(), isEmpty);
      control.crash();
      await Future<void>.value();
      await adapter.waitUntilEventsDispatched();

      expect(
        commands.whereType<VmStateChanged>().map((command) => command.phase),
        containsAllInOrder([
          VmPhase.configuring,
          VmPhase.starting,
          VmPhase.running,
          VmPhase.stopped,
        ]),
      );
      expect(commands.whereType<DriverExited>(), hasLength(1));
      final exited = commands.whereType<DriverExited>().single;
      expect(exited.operationId, _operation1);
      expect(exited.driverGeneration, 1);
      expect(exited.cleanShutdown, isTrue);
      expect(
        exited.occurredAt,
        DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
      );
      expect(adapter.activeSessionCount, 0);
      expect(factory.activeSessionCount, 0);
    },
  );

  test('a delayed VM does not block another VM controller', () async {
    final scheduler = ManualRuntimeScheduler();
    final factory = FakeRuntimeDriverFactory(
      scheduler: scheduler,
      scenarioForLaunch: (launch) => FakeRuntimeDriverScenario(
        startDelay: launch.correlation.vmId == _vm1
            ? const Duration(seconds: 10)
            : Duration.zero,
      ),
    );
    final controllers = <VmId, VmController>{};
    final adapter = RuntimeDriverEffectAdapter(
      factory: factory,
      resolveConfiguration: (_) async => _configuration,
      dispatch: (vmId, command) =>
          controllers[vmId]!.submit(command).then((_) {}),
    );
    final runner = _DriverOnlyRunner(adapter);
    controllers[_vm1] = VmController(
      initialState: _state(_vm1),
      effectRunner: runner,
    );
    controllers[_vm2] = VmController(
      initialState: _state(_vm2),
      effectRunner: runner,
    );
    addTearDown(() async {
      await Future.wait(
        controllers.values.map((controller) => controller.shutdown()),
      );
      await adapter.close();
    });

    await Future.wait([
      controllers[_vm1]!.submit(StartRequested(_operation1)),
      controllers[_vm2]!.submit(StartRequested(_operation2)),
    ]);
    scheduler.advanceBy(Duration.zero);
    await adapter.waitUntilEventsDispatched();

    expect(controllers[_vm1]!.state.phase, VmPhase.starting);
    expect(controllers[_vm2]!.state.phase, VmPhase.running);

    scheduler.advanceBy(const Duration(seconds: 10));
    await adapter.waitUntilEventsDispatched();
    expect(controllers[_vm1]!.state.phase, VmPhase.running);
  });

  test('typed fake failures remain stable VmEffectException errors', () async {
    final scheduler = ManualRuntimeScheduler();
    final factory = FakeRuntimeDriverFactory(scheduler: scheduler);
    final adapter = RuntimeDriverEffectAdapter(
      factory: factory,
      resolveConfiguration: (_) async => _configuration,
      dispatch: (_, _) async {},
    );
    addTearDown(adapter.close);
    final state = _state(_vm1);
    final correlation = DriverCorrelation(
      vmId: _vm1,
      driverGeneration: 1,
      operationId: _operation1,
    );
    await adapter.spawn(state, _operation1, 1);
    await adapter.connect(state, _operation1, 1);
    factory
        .controlFor(correlation)
        .failNextConfigure(
          RuntimeDriverError(
            code: RuntimeDriverErrorCode.invalidRuntimeConfig,
            message: 'invalid fake configuration',
            retryable: false,
          ),
        );

    await expectLater(
      adapter.configure(state, _operation1, 1),
      throwsA(
        isA<VmEffectException>()
            .having(
              (error) => error.operationError.code,
              'code',
              ErrorCode.vmSpecInvalid,
            )
            .having(
              (error) => error.operationError.retryable,
              'retryable',
              isFalse,
            ),
      ),
    );
    await adapter.configure(state, _operation1, 1);
    factory
        .controlFor(correlation)
        .failNextStart(
          RuntimeDriverError(
            code: RuntimeDriverErrorCode.runtimeStartFailed,
            message: 'fake VM start failed',
            retryable: true,
          ),
        );
    await expectLater(
      adapter.start(state, _operation1, 1),
      throwsA(
        isA<VmEffectException>()
            .having(
              (error) => error.operationError.code,
              'code',
              ErrorCode.driverStartFailed,
            )
            .having(
              (error) => error.operationError.retryable,
              'retryable',
              isTrue,
            ),
      ),
    );
  });

  test('effect cancellation cancels delayed session work', () async {
    final scheduler = ManualRuntimeScheduler();
    final observed = <RuntimeEvent>[];
    final factory = FakeRuntimeDriverFactory(
      scheduler: scheduler,
      scenario: const FakeRuntimeDriverScenario(
        startDelay: Duration(minutes: 1),
      ),
    );
    final adapter = RuntimeDriverEffectAdapter(
      factory: factory,
      resolveConfiguration: (_) async => _configuration,
      dispatch: (_, _) async {},
      observeEvent: observed.add,
    );
    addTearDown(adapter.close);
    final state = _state(_vm1);
    await adapter.spawn(state, _operation1, 1);
    await adapter.connect(state, _operation1, 1);
    await adapter.configure(state, _operation1, 1);
    await adapter.start(state, _operation1, 1);

    await adapter.cancel(
      StartRuntime(vmId: _vm1, operationId: _operation1, driverGeneration: 1),
      state,
    );
    scheduler.runUntilIdle();

    expect(
      observed.whereType<RuntimeStateChanged>().map((event) => event.state),
      isNot(contains(RuntimeDriverState.running)),
    );
  });

  test('one VM cannot install a second active driver generation', () async {
    final scheduler = ManualRuntimeScheduler();
    final factory = FakeRuntimeDriverFactory(scheduler: scheduler);
    final commands = <VmCommand>[];
    final adapter = RuntimeDriverEffectAdapter(
      factory: factory,
      resolveConfiguration: (_) async => _configuration,
      dispatch: (_, command) async => commands.add(command),
    );
    addTearDown(adapter.close);
    final state = _state(_vm1);
    await adapter.spawn(state, _operation1, 1);
    final oldCorrelation = DriverCorrelation(
      vmId: _vm1,
      driverGeneration: 1,
      operationId: _operation1,
    );

    await expectLater(
      adapter.spawn(state, _operation2, 2),
      throwsA(isA<VmEffectException>()),
    );

    final oldControl = factory.controlFor(oldCorrelation);
    oldControl.crash();
    oldControl.emitState(RuntimeDriverState.running, late: true);
    await Future<void>.value();
    await adapter.waitUntilEventsDispatched();

    expect(commands.whereType<DriverExited>().single.driverGeneration, 1);
    final late = commands.whereType<VmStateChanged>().single;
    expect(late.driverGeneration, 1);
    expect(late.operationId, _operation1);
    expect(adapter.activeSessionCount, 0);
    expect(factory.activeSessionCount, 0);
    await adapter.spawn(state, _operation2, 2);
    expect(adapter.activeSessionCount, 1);
  });

  test('foreign event, log, and exit correlations are contained', () async {
    final scheduler = ManualRuntimeScheduler();
    final factory = FakeRuntimeDriverFactory(scheduler: scheduler);
    final commands = <VmCommand>[];
    final logs = <RuntimeDriverLogChunk>[];
    final adapter = RuntimeDriverEffectAdapter(
      factory: factory,
      resolveConfiguration: (_) async => _configuration,
      dispatch: (_, command) async => commands.add(command),
      observeLog: logs.add,
    );
    addTearDown(adapter.close);
    final sessions = [(_vm1, 1), (_vm2, 2), (_vm3, 3)];
    for (final (vmId, generation) in sessions) {
      await adapter.spawn(_state(vmId), _operation1, generation);
    }
    final foreign = DriverCorrelation(
      vmId: _vm4,
      driverGeneration: 99,
      operationId: _operation2,
    );

    factory
        .controlFor(
          DriverCorrelation(
            vmId: _vm1,
            driverGeneration: 1,
            operationId: _operation1,
          ),
        )
        .emitEventForTest(
          RuntimeStateChanged(
            correlation: foreign,
            occurredAt: scheduler.now,
            state: RuntimeDriverState.running,
          ),
        );
    factory
        .controlFor(
          DriverCorrelation(
            vmId: _vm2,
            driverGeneration: 2,
            operationId: _operation1,
          ),
        )
        .emitLogForTest(
          RuntimeDriverLogChunk(
            correlation: foreign,
            stream: RuntimeDriverLogStream.stdout,
            bytes: Uint8List(1),
          ),
        );
    factory
        .controlFor(
          DriverCorrelation(
            vmId: _vm3,
            driverGeneration: 3,
            operationId: _operation1,
          ),
        )
        .exitForTest(
          RuntimeDriverExit(
            correlation: foreign,
            occurredAt: scheduler.now,
            clean: false,
            exitCode: 42,
          ),
        );
    await Future<void>.value();
    await adapter.waitUntilEventsDispatched();

    expect(commands.whereType<VmStateChanged>(), isEmpty);
    expect(logs, isEmpty);
    expect(commands.whereType<DriverChannelClosed>(), hasLength(3));
    expect(
      commands.whereType<DriverChannelClosed>().map(
        (event) => event.driverGeneration,
      ),
      {1, 2, 3},
    );
    expect(adapter.activeSessionCount, 0);
    expect(factory.activeSessionCount, 0);
  });

  test(
    'close cancels in-flight spawn and prevents late installation',
    () async {
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(
        scheduler: scheduler,
        scenario: const FakeRuntimeDriverScenario(
          spawnDelay: Duration(seconds: 10),
        ),
      );
      final adapter = RuntimeDriverEffectAdapter(
        factory: factory,
        resolveConfiguration: (_) async => _configuration,
        dispatch: (_, _) async {},
      );
      final state = _state(_vm1);
      final spawn = adapter.spawn(state, _operation1, 1);
      final spawnRejected = expectLater(
        spawn,
        throwsA(isA<VmEffectException>()),
      );
      await Future<void>.value();
      expect(factory.pendingSpawnCount, 1);

      await adapter.close();

      await spawnRejected;
      scheduler.runUntilIdle();
      expect(adapter.activeSessionCount, 0);
      expect(factory.activeSessionCount, 0);
      expect(factory.pendingSpawnCount, 0);
      await expectLater(
        adapter.spawn(state, _operation1, 2),
        throwsA(isA<VmEffectException>()),
      );
    },
  );

  test(
    'event EOF and event or log errors become contained channel closures',
    () async {
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(scheduler: scheduler);
      final commands = <VmCommand>[];
      final adapter = RuntimeDriverEffectAdapter(
        factory: factory,
        resolveConfiguration: (_) async => _configuration,
        dispatch: (_, command) async => commands.add(command),
      );
      addTearDown(adapter.close);
      final sessions = [(_vm1, 1), (_vm2, 2), (_vm3, 3)];
      for (final (vmId, generation) in sessions) {
        await adapter.spawn(_state(vmId), _operation1, generation);
      }

      await factory
          .controlFor(
            DriverCorrelation(
              vmId: _vm1,
              driverGeneration: 1,
              operationId: _operation1,
            ),
          )
          .closeEventStreamForTest();
      factory
          .controlFor(
            DriverCorrelation(
              vmId: _vm2,
              driverGeneration: 2,
              operationId: _operation1,
            ),
          )
          .errorEventStreamForTest(StateError('event stream failed'));
      factory
          .controlFor(
            DriverCorrelation(
              vmId: _vm3,
              driverGeneration: 3,
              operationId: _operation1,
            ),
          )
          .errorLogStreamForTest(StateError('log stream failed'));
      await Future<void>.value();
      await adapter.waitUntilEventsDispatched();

      expect(commands.whereType<DriverChannelClosed>(), hasLength(3));
      expect(adapter.activeSessionCount, 0);
      expect(factory.activeSessionCount, 0);
    },
  );

  test(
    'null-correlated events use the latest accepted lifecycle operation',
    () async {
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(scheduler: scheduler);
      final commands = <VmCommand>[];
      final adapter = RuntimeDriverEffectAdapter(
        factory: factory,
        resolveConfiguration: (_) async => _configuration,
        dispatch: (_, command) async => commands.add(command),
      );
      addTearDown(adapter.close);
      final state = _state(_vm1);
      await adapter.spawn(state, _operation1, 1);
      await adapter.connect(state, _operation1, 1);
      await adapter.configure(state, _operation1, 1);
      await adapter.waitUntilEventsDispatched();
      commands.clear();

      factory
          .controlFor(
            DriverCorrelation(
              vmId: _vm1,
              driverGeneration: 1,
              operationId: _operation1,
            ),
          )
          .emitNullStateOnNextLifecycle(RuntimeDriverState.stopping);
      await adapter.start(state, _operation2, 1);
      await adapter.waitUntilEventsDispatched();

      expect(commands.whereType<VmStateChanged>(), isNotEmpty);
      expect(
        commands.whereType<VmStateChanged>().every(
          (command) => command.operationId == _operation2,
        ),
        isTrue,
      );
    },
  );

  test(
    'failed terminal dispatch is surfaced and releases driver ownership',
    () async {
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(scheduler: scheduler);
      var dispatchAttempts = 0;
      final adapter = RuntimeDriverEffectAdapter(
        factory: factory,
        resolveConfiguration: (_) async => _configuration,
        dispatch: (_, _) async {
          dispatchAttempts++;
          throw StateError('controller unavailable');
        },
      );
      final state = _state(_vm1);
      final correlation = DriverCorrelation(
        vmId: _vm1,
        driverGeneration: 1,
        operationId: _operation1,
      );
      await adapter.spawn(state, _operation1, 1);
      final control = factory.controlFor(correlation);

      control.crash();
      await Future<void>.value();
      await expectLater(
        adapter.waitUntilEventsDispatched(),
        throwsA(isA<RuntimeDriverDispatchException>()),
      );

      expect(dispatchAttempts, 1);
      expect(adapter.activeSessionCount, 0);
      expect(factory.activeSessionCount, 0);
      await expectLater(
        adapter.waitUntilEventsDispatched(),
        throwsA(isA<RuntimeDriverDispatchException>()),
      );
      expect(dispatchAttempts, 1);
      expect(adapter.activeSessionCount, 0);

      await adapter.close();
      expect(factory.activeSessionCount, 0);
    },
  );

  test(
    'failed nonterminal dispatch is surfaced and releases the session',
    () async {
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(scheduler: scheduler);
      var dispatchAttempts = 0;
      final adapter = RuntimeDriverEffectAdapter(
        factory: factory,
        resolveConfiguration: (_) async => _configuration,
        dispatch: (_, _) async {
          dispatchAttempts++;
          throw StateError('controller unavailable');
        },
      );
      final state = _state(_vm1);
      final correlation = DriverCorrelation(
        vmId: _vm1,
        driverGeneration: 1,
        operationId: _operation1,
      );
      await adapter.spawn(state, _operation1, 1);
      final control = factory.controlFor(correlation);

      control.emitState(RuntimeDriverState.starting);
      control.emitState(RuntimeDriverState.running);
      await expectLater(
        adapter.waitUntilEventsDispatched(),
        throwsA(isA<RuntimeDriverDispatchException>()),
      );

      expect(dispatchAttempts, 1);
      expect(adapter.activeSessionCount, 0);
      expect(factory.activeSessionCount, 0);
      await adapter.close();
    },
  );
}

final class _DriverOnlyRunner implements VmEffectRunner {
  _DriverOnlyRunner(this.drivers);

  final RuntimeDriverEffectAdapter drivers;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    final operationId = effect.operationId;
    final generation = effect.driverGeneration;
    switch (effect) {
      case AcquireHostLease():
        return HostLeaseAcquired(operationId!);
      case ReleaseHostLease() || ShutdownLease():
        return HostLeaseReleased(operationId);
      case SpawnDriver():
        await drivers.spawn(state, operationId!, generation!);
        return DriverSpawned(
          operationId: operationId,
          driverGeneration: generation,
        );
      case ConnectDriver():
        await drivers.connect(state, operationId!, generation!);
        return DriverHandshakeCompleted(
          operationId: operationId,
          driverGeneration: generation,
        );
      case ConfigureRuntime():
        await drivers.configure(state, operationId!, generation!);
        return DriverCommandSucceeded(
          operationId: operationId,
          driverGeneration: generation,
          command: RuntimeCommandKind.configure,
        );
      case StartRuntime():
        await drivers.start(state, operationId!, generation!);
        return DriverCommandSucceeded(
          operationId: operationId,
          driverGeneration: generation,
          command: RuntimeCommandKind.start,
        );
      case StopRuntime():
        await drivers.stop(state, operationId!, generation!);
        return DriverCommandSucceeded(
          operationId: operationId,
          driverGeneration: generation,
          command: RuntimeCommandKind.stop,
        );
      case KillDriver() || ShutdownDriver():
        await drivers.kill(state, operationId!, generation!);
        return DriverCommandSucceeded(
          operationId: operationId,
          driverGeneration: generation,
          command: RuntimeCommandKind.kill,
        );
      default:
        return null;
    }
  }
}

VmControllerState _state(VmId vmId) => VmControllerState.initial(
  vmId: vmId,
  specGeneration: 1,
  restartPolicy: RestartPolicy.onFailure,
);

final _vm1 = VmId('vm_01J00000000000000000000000');
final _vm2 = VmId('vm_01J00000000000000000000002');
final _vm3 = VmId('vm_01J00000000000000000000003');
final _vm4 = VmId('vm_01J00000000000000000000004');
final _operation1 = OperationId('op_01J00000000000000000000001');
final _operation2 = OperationId('op_01J00000000000000000000002');

final _configuration = RuntimeDriverConfiguration(
  architecture: Architecture.arm64,
  cpu: 2,
  memoryBytes: 1073741824,
  boot: RuntimeLinuxBootConfiguration(
    kernelPath: '/runtime/kernel',
    commandLine: '',
  ),
  disks: [
    RuntimeDiskConfiguration(
      id: 'root',
      path: '/runtime/root.img',
      writable: true,
    ),
  ],
  networks: [
    RuntimeNetworkConfiguration(
      id: 'net0',
      mode: RuntimeNetworkMode.shared,
      macAddress: '02:00:00:00:00:01',
    ),
  ],
  graphics: RuntimeGraphicsConfiguration(enabled: false),
  serial: RuntimeSerialConfiguration(
    enabled: true,
    capture: true,
    logPath: '/runtime/serial.log',
  ),
  guestAgent: RuntimeGuestAgentConfiguration(enabled: false, vsockPort: 1024),
  bundlePath: '/runtime/vm.gaovm',
  driverLogPath: '/runtime/driver.log',
);
