import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/fake_runtime_driver.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:test/test.dart';

void main() {
  test('manual scheduler runs callbacks at their logical deadlines', () {
    final scheduler = ManualRuntimeScheduler();
    final observed = <Duration>[];
    scheduler.schedule(
      const Duration(seconds: 5),
      () => observed.add(scheduler.elapsed),
    );

    scheduler.advanceBy(const Duration(seconds: 10));

    expect(observed, [const Duration(seconds: 5)]);
    expect(scheduler.elapsed, const Duration(seconds: 10));
  });

  test('start delay advances only under manual scheduler control', () async {
    final scheduler = ManualRuntimeScheduler();
    final factory = FakeRuntimeDriverFactory(
      scheduler: scheduler,
      scenario: const FakeRuntimeDriverScenario(
        startDelay: Duration(seconds: 5),
      ),
    );
    final correlation = DriverCorrelation(
      vmId: _vm1,
      driverGeneration: 1,
      operationId: _operation1,
    );
    final session = await factory.spawn(
      RuntimeDriverLaunch(correlation: correlation),
    );
    final states = <RuntimeDriverState>[];
    session.events.listen((event) {
      if (event is RuntimeStateChanged) states.add(event.state);
    });
    await session.connect(DriverCapabilities.runtimeCore);

    await session.execute(
      RuntimeConfigureCommand(
        correlation: correlation,
        configuration: _configuration,
      ),
    );
    final result = await session.execute(
      RuntimeStartCommand(correlation: correlation),
    );

    expect(result.status, RuntimeCommandStatus.accepted);
    expect(states, [
      RuntimeDriverState.configured,
      RuntimeDriverState.starting,
    ]);
    scheduler.advanceBy(const Duration(seconds: 4));
    expect(states, isNot(contains(RuntimeDriverState.running)));

    scheduler.advanceBy(const Duration(seconds: 1));
    expect(states, contains(RuntimeDriverState.running));
  });

  test('configure and start failures are queued and typed', () async {
    final scheduler = ManualRuntimeScheduler();
    final factory = FakeRuntimeDriverFactory(
      scheduler: scheduler,
      scenario: FakeRuntimeDriverScenario(
        configureFailures: [
          RuntimeDriverError(
            code: RuntimeDriverErrorCode.invalidRuntimeConfig,
            message: 'injected configure failure',
            retryable: false,
          ),
        ],
      ),
    );
    final correlation = DriverCorrelation(
      vmId: _vm1,
      driverGeneration: 1,
      operationId: _operation1,
    );
    final session = await factory.spawn(
      RuntimeDriverLaunch(correlation: correlation),
    );
    final control = factory.controlFor(correlation);
    await session.connect(DriverCapabilities.runtimeCore);

    await expectLater(
      session.execute(
        RuntimeConfigureCommand(
          correlation: correlation,
          configuration: _configuration,
        ),
      ),
      throwsA(
        isA<RuntimeDriverError>().having(
          (error) => error.code,
          'code',
          RuntimeDriverErrorCode.invalidRuntimeConfig,
        ),
      ),
    );
    await session.execute(
      RuntimeConfigureCommand(
        correlation: correlation,
        configuration: _configuration,
      ),
    );
    control.failNextStart(
      RuntimeDriverError(
        code: RuntimeDriverErrorCode.runtimeStartFailed,
        message: 'injected start failure',
        retryable: true,
      ),
    );

    await expectLater(
      session.execute(RuntimeStartCommand(correlation: correlation)),
      throwsA(
        isA<RuntimeDriverError>().having(
          (error) => error.code,
          'code',
          RuntimeDriverErrorCode.runtimeStartFailed,
        ),
      ),
    );
  });

  test('heartbeat hang does not block the runtime command lane', () async {
    final scheduler = ManualRuntimeScheduler();
    final factory = FakeRuntimeDriverFactory(scheduler: scheduler);
    final correlation = DriverCorrelation(
      vmId: _vm1,
      driverGeneration: 1,
      operationId: _operation1,
    );
    final session = await factory.spawn(
      RuntimeDriverLaunch(correlation: correlation),
    );
    final control = factory.controlFor(correlation);
    await session.connect(DriverCapabilities.runtimeCore);
    control.hangHeartbeat();
    var pingCompleted = false;
    final ping = session.ping().whenComplete(() => pingCompleted = true);
    await Future<void>.value();
    expect(pingCompleted, isFalse);

    final status = await session.execute(
      RuntimeStatusCommand(correlation: correlation),
    );
    expect(status.status, RuntimeCommandStatus.succeeded);
    expect(pingCompleted, isFalse);

    control.resumeHeartbeat();
    expect((await ping).status, RuntimeCommandStatus.succeeded);
  });

  test(
    'clean shutdown, crash, out-of-order, and late events are explicit',
    () async {
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(scheduler: scheduler);
      final correlation = DriverCorrelation(
        vmId: _vm1,
        driverGeneration: 7,
        operationId: _operation1,
      );
      final session = await factory.spawn(
        RuntimeDriverLaunch(correlation: correlation),
      );
      final control = factory.controlFor(correlation);
      final events = <RuntimeEvent>[];
      session.events.listen(events.add);

      control.emitState(RuntimeDriverState.running);
      control.emitState(RuntimeDriverState.configured);
      control.guestShutdown();
      control.crash();
      final exit = await session.exited;
      control.emitState(RuntimeDriverState.running, late: true);

      expect(exit.clean, isFalse);
      expect(exit.exitCode, 42);
      expect(
        events.whereType<RuntimeStateChanged>().map((event) => event.state),
        [
          RuntimeDriverState.running,
          RuntimeDriverState.configured,
          RuntimeDriverState.stopped,
          RuntimeDriverState.running,
        ],
      );
      expect(events.whereType<RuntimeCleanShutdown>(), hasLength(1));
      expect(
        events.every(
          (event) =>
              event.correlation.vmId == _vm1 &&
              event.correlation.driverGeneration == 7,
        ),
        isTrue,
      );
    },
  );

  test(
    'cancellation and large event or log delivery are deterministic',
    () async {
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(
        scheduler: scheduler,
        scenario: const FakeRuntimeDriverScenario(
          startDelay: Duration(seconds: 10),
        ),
      );
      final correlation = DriverCorrelation(
        vmId: _vm1,
        driverGeneration: 1,
        operationId: _operation1,
      );
      final session = await factory.spawn(
        RuntimeDriverLaunch(correlation: correlation),
      );
      final control = factory.controlFor(correlation);
      final events = <RuntimeEvent>[];
      final logs = <RuntimeDriverLogChunk>[];
      session.events.listen(events.add);
      session.logs.listen(logs.add);
      await session.connect(DriverCapabilities.runtimeCore);
      await session.execute(
        RuntimeConfigureCommand(
          correlation: correlation,
          configuration: _configuration,
        ),
      );
      expect(
        (await session.execute(
          RuntimeConfigureCommand(
            correlation: correlation,
            configuration: _configuration,
          ),
        )).status,
        RuntimeCommandStatus.noop,
      );
      await session.execute(RuntimeStartCommand(correlation: correlation));

      await session.cancel(_operation1);
      scheduler.runUntilIdle();
      control.emitLargeWarning(1024 * 1024);
      control.emitLog(1024 * 1024);

      expect(
        events.whereType<RuntimeStateChanged>().map((event) => event.state),
        isNot(contains(RuntimeDriverState.running)),
      );
      expect(
        events.whereType<RuntimeDriverWarning>().single.message.length,
        1024 * 1024,
      );
      expect(logs.single.bytes.length, 1024 * 1024);
    },
  );

  test(
    'lifecycle oracle enforces connection, state, noop, and terminal guards',
    () async {
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(
        scheduler: scheduler,
        scenario: const FakeRuntimeDriverScenario(
          startDelay: Duration(seconds: 1),
        ),
      );
      final correlation = DriverCorrelation(
        vmId: _vm1,
        driverGeneration: 1,
        operationId: _operation1,
      );
      final session = await factory.spawn(
        RuntimeDriverLaunch(correlation: correlation),
      );
      final control = factory.controlFor(correlation);

      await expectLater(session.ping(), _invalidRuntimeState);
      await expectLater(
        session.execute(RuntimeStatusCommand(correlation: correlation)),
        _invalidRuntimeState,
      );
      await session.connect(DriverCapabilities.runtimeCore);
      await expectLater(
        session.execute(RuntimeStartCommand(correlation: correlation)),
        _invalidRuntimeState,
      );
      await session.execute(
        RuntimeConfigureCommand(
          correlation: correlation,
          configuration: _configuration,
        ),
      );
      expect(
        (await session.execute(
          RuntimeStartCommand(correlation: correlation),
        )).status,
        RuntimeCommandStatus.accepted,
      );
      expect(
        (await session.execute(
          RuntimeStartCommand(correlation: correlation),
        )).status,
        RuntimeCommandStatus.noop,
      );
      scheduler.advanceBy(const Duration(seconds: 1));
      expect(
        (await session.execute(
          RuntimeStartCommand(correlation: correlation),
        )).status,
        RuntimeCommandStatus.noop,
      );
      expect(
        (await session.execute(
          RuntimeStopCommand(correlation: correlation),
        )).status,
        RuntimeCommandStatus.accepted,
      );

      await expectLater(
        session.execute(RuntimeStatusCommand(correlation: correlation)),
        _invalidRuntimeState,
      );
      await expectLater(
        session.execute(RuntimeKillCommand(correlation: correlation)),
        _invalidRuntimeState,
      );
      expect(
        () => control.emitState(RuntimeDriverState.running),
        _throwsInvalidRuntimeState,
      );
      expect(
        () => control.emitState(RuntimeDriverState.running, late: true),
        returnsNormally,
      );
    },
  );

  test(
    'stop cancels delayed lifecycle work from an earlier operation',
    () async {
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(
        scheduler: scheduler,
        scenario: const FakeRuntimeDriverScenario(
          startDelay: Duration(seconds: 10),
        ),
      );
      final launchCorrelation = DriverCorrelation(
        vmId: _vm1,
        driverGeneration: 1,
        operationId: _operation1,
      );
      final session = await factory.spawn(
        RuntimeDriverLaunch(correlation: launchCorrelation),
      );
      final control = factory.controlFor(launchCorrelation);
      final states = <RuntimeDriverState>[];
      session.events.listen((event) {
        if (event is RuntimeStateChanged) states.add(event.state);
      });
      await session.connect(DriverCapabilities.runtimeCore);
      await session.execute(
        RuntimeConfigureCommand(
          correlation: launchCorrelation,
          configuration: _configuration,
        ),
      );
      await session.execute(
        RuntimeStartCommand(correlation: launchCorrelation),
      );

      await session.execute(
        RuntimeStopCommand(
          correlation: launchCorrelation.withOperation(_operation2),
        ),
      );
      scheduler.runUntilIdle();

      expect(states.last, RuntimeDriverState.stopped);
      expect(control.state, RuntimeDriverState.stopped);
      expect(
        states.where((state) => state == RuntimeDriverState.running),
        isEmpty,
      );
    },
  );
}

final _invalidRuntimeState = throwsA(
  isA<RuntimeDriverError>().having(
    (error) => error.code,
    'code',
    RuntimeDriverErrorCode.invalidRuntimeState,
  ),
);

final _throwsInvalidRuntimeState = throwsA(
  isA<RuntimeDriverError>().having(
    (error) => error.code,
    'code',
    RuntimeDriverErrorCode.invalidRuntimeState,
  ),
);

final _vm1 = VmId('vm_01J00000000000000000000000');
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
