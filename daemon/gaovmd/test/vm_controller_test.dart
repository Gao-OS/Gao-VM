import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  test(
    'lease loss still kills its driver when the durable batch fails',
    () async {
      final runner = _FailFirstTransactionalRunner();
      final controller = VmController(
        initialState: _startingOperationState(),
        effectRunner: runner,
      );
      await controller.submit(
        HostLeaseLost(
          driverGeneration: 1,
          specGeneration: 1,
          error: _driverError,
        ),
      );
      expect(runner.effects, contains('KillDriver'));
      expect(runner.batches.last, contains('FailOperation'));
      expect(controller.state.activeDriverGeneration, 1);
      expect(controller.state.leaseState, VmLeaseState.held);
      await controller.shutdown();
    },
  );
  group('VmController command queue', () {
    test(
      'same-VM concurrent submissions stay FIFO with one effect in flight',
      () async {
        final firstEffect = Completer<void>();
        final runner = _RecordingRunner(blockFirstEffect: firstEffect.future);
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: runner,
        );

        final first = controller.submit(
          const SpecUpdated(
            specGeneration: 2,
            restartPolicy: RestartPolicy.onFailure,
            restartRequired: true,
          ),
        );
        final second = controller.submit(
          const SpecUpdated(
            specGeneration: 3,
            restartPolicy: RestartPolicy.always,
            restartRequired: true,
          ),
        );

        await runner.firstEffectStarted.future;
        expect(runner.maxInFlight, 1);
        expect(controller.state.specGeneration, 2);
        firstEffect.complete();
        await Future.wait([first, second]);
        await controller.waitUntilIdle();

        expect(controller.state.specGeneration, 3);
        expect(runner.stateGenerations, [2, 2, 2, 3, 3, 3]);
        expect(runner.maxInFlight, 1);
        await controller.shutdown();
      },
    );

    test('different VM controllers run effects concurrently', () async {
      final releaseEffects = Completer<void>();
      final runner = _ConcurrentRunner(releaseEffects.future);
      final first = VmController(
        initialState: _initialState(),
        effectRunner: runner,
      );
      final second = VmController(
        initialState: _initialState(
          vmId: VmId('vm_01J00000000000000000000001'),
        ),
        effectRunner: runner,
      );

      final firstSubmission = first.submit(
        const SpecUpdated(
          specGeneration: 2,
          restartPolicy: RestartPolicy.onFailure,
          restartRequired: true,
        ),
      );
      final secondSubmission = second.submit(
        const SpecUpdated(
          specGeneration: 2,
          restartPolicy: RestartPolicy.onFailure,
          restartRequired: true,
        ),
      );

      await runner.twoEffectsStarted.future;
      expect(runner.maxInFlight, 2);
      releaseEffects.complete();
      await Future.wait([firstSubmission, secondSubmission]);
      await Future.wait([first.shutdown(), second.shutdown()]);
    });

    test(
      'effect results re-enter in order and stale correlations are ignored',
      () async {
        final runner = _LifecycleRunner();
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: runner,
        );

        await controller.submit(StartRequested(_operation1));
        await controller.waitUntilIdle();

        expect(controller.state.phase, VmPhase.starting);
        expect(controller.state.driverGeneration, 1);
        expect(runner.effectTypes, [
          'PersistVm',
          'AcquireHostLease',
          'PersistRuntime',
          'SpawnDriver',
          'ConnectDriver',
          'ConfigureRuntime',
          'StartRuntime',
        ]);

        final before = controller.state;
        await controller.submit(
          DriverSpawned(
            operationId: _operation2,
            driverGeneration: before.driverGeneration,
          ),
        );
        expect(controller.state, same(before));
        expect(runner.effectTypes, hasLength(7));
        await controller.shutdown();
      },
    );

    test('stop cancels retry and stable-reset timers', () async {
      final retryScheduler = _ManualTimerScheduler();
      final retryController = VmController(
        initialState: _pendingRecoveryState(),
        effectRunner: _NullRunner(),
        timerScheduler: retryScheduler,
      );
      await retryController.submit(
        RecoveryOperationCreated(
          operationId: _operation2,
          failedDriverGeneration: 1,
        ),
      );
      await retryController.waitUntilIdle();
      expect(retryController.hasPendingTimers, isTrue);

      await retryController.submit(
        StopRequested(OperationId('op_01J00000000000000000000002')),
      );
      expect(retryScheduler.handles.single.cancelled, isTrue);
      expect(retryController.hasPendingTimers, isFalse);

      final stableScheduler = _ManualTimerScheduler();
      final stableController = VmController(
        initialState: _recoveringStartState(),
        effectRunner: _NullRunner(),
        timerScheduler: stableScheduler,
      );
      await stableController.submit(
        VmStateChanged(
          operationId: _operation2,
          driverGeneration: 2,
          phase: VmPhase.running,
        ),
      );
      expect(stableController.hasPendingTimers, isTrue);

      await stableController.submit(
        StopRequested(OperationId('op_01J00000000000000000000003')),
      );
      expect(stableScheduler.handles.single.cancelled, isTrue);
      expect(stableController.hasPendingTimers, isFalse);
      await Future.wait([
        retryController.shutdown(),
        stableController.shutdown(),
      ]);
    });

    test(
      'shutdown drains work, cancels timers, and rejects new commands',
      () async {
        final releaseEffect = Completer<void>();
        final runner = _RecordingRunner(blockFirstEffect: releaseEffect.future);
        final scheduler = _ManualTimerScheduler();
        final controller = VmController(
          initialState: _pendingRecoveryState(),
          effectRunner: runner,
          timerScheduler: scheduler,
        );
        final submission = controller.submit(
          RecoveryOperationCreated(
            operationId: _operation2,
            failedDriverGeneration: 1,
          ),
        );
        await runner.firstEffectStarted.future;
        final queued = controller.submit(
          const SpecUpdated(
            specGeneration: 2,
            restartPolicy: RestartPolicy.always,
            restartRequired: true,
          ),
        );

        final shutdown = controller.shutdown();
        await expectLater(queued, throwsA(isA<VmControllerClosedException>()));
        await expectLater(
          controller.submit(const ReconcileRequested()),
          throwsA(isA<VmControllerClosedException>()),
        );
        releaseEffect.complete();
        await submission;
        await shutdown;

        expect(controller.isIdle, isTrue);
        expect(controller.hasPendingTimers, isFalse);
        expect(scheduler.handles, isEmpty);
      },
    );

    test('effect failures re-enter as correlated failure commands', () async {
      final controller = VmController(
        initialState: _initialState(),
        effectRunner: _FailingAcquireRunner(),
      );

      await controller.submit(StartRequested(_operation1));
      await controller.waitUntilIdle();

      expect(controller.state.phase, VmPhase.failed);
      expect(controller.state.desiredState, DesiredState.stopped);
      expect(controller.state.currentOperation?.state, OperationState.failed);
      expect(controller.state.lastError?.code, ErrorCode.internalError);
      await controller.shutdown();
    });

    test(
      'persistence failure stops the batch and retains acquired resources',
      () async {
        final runner = _FailingRuntimePersistenceRunner();
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: runner,
        );

        await controller.submit(StartRequested(_operation1));
        await controller.waitUntilIdle();

        expect(controller.state.phase, VmPhase.failed);
        expect(controller.state.activeDriverGeneration, 1);
        expect(controller.state.leaseState, VmLeaseState.held);
        expect(runner.calls, isNot(contains('SpawnDriver')));
        await controller.shutdown();
      },
    );

    test(
      'internal effect results overtake already queued external commands',
      () async {
        final runner = _BlockingAcquireLifecycleRunner();
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: runner,
        );
        final start = controller.submit(StartRequested(_operation1));
        await runner.acquireStarted.future;
        final stop = controller.submit(
          StopRequested(OperationId('op_01J00000000000000000000004')),
        );

        runner.releaseAcquire.complete();
        await Future.wait([start, stop]);
        await controller.waitUntilIdle();

        expect(runner.calls.indexOf('SpawnDriver'), greaterThan(-1));
        expect(
          runner.calls.indexOf('SpawnDriver'),
          lessThan(runner.calls.indexOf('KillDriver')),
        );
        await controller.shutdown();
      },
    );

    test('shutdown compensates an in-flight lease acquisition', () async {
      final runner = _BlockingAcquireLifecycleRunner();
      final controller = VmController(
        initialState: _initialState(),
        effectRunner: runner,
      );
      final start = controller.submit(StartRequested(_operation1));
      await runner.acquireStarted.future;

      final shutdown = controller.shutdown();
      runner.releaseAcquire.complete();
      await start;
      await shutdown;

      expect(
        runner.calls,
        containsAllInOrder(['AcquireHostLease', 'ShutdownLease']),
      );
      expect(runner.calls, isNot(contains('SpawnDriver')));
      expect(controller.state.activeDriverGeneration, isNull);
      expect(controller.state.leaseState, VmLeaseState.none);
      expect(controller.isIdle, isTrue);
      expect(controller.hasPendingTimers, isFalse);
    });

    test(
      'shutdown kills an in-flight spawned driver and releases its lease',
      () async {
        final runner = _BlockingSpawnLifecycleRunner();
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: runner,
        );
        final start = controller.submit(StartRequested(_operation1));
        await runner.spawnStarted.future;

        final shutdown = controller.shutdown();
        runner.releaseSpawn.complete();
        await start;
        await shutdown;

        expect(
          runner.calls,
          containsAllInOrder([
            'AcquireHostLease',
            'SpawnDriver',
            'ShutdownDriver',
            'ShutdownLease',
          ]),
        );
        expect(runner.calls, isNot(contains('ConnectDriver')));
        expect(controller.state.activeDriverGeneration, isNull);
        expect(controller.state.leaseState, VmLeaseState.none);
        expect(controller.isIdle, isTrue);
      },
    );

    test('submit completes only after its causal internal chain', () async {
      final runner = _BlockingSpawnLifecycleRunner();
      final controller = VmController(
        initialState: _initialState(),
        effectRunner: runner,
      );
      var completed = false;
      final submission = controller.submit(StartRequested(_operation1))
        ..then((_) => completed = true);
      await runner.spawnStarted.future;

      expect(completed, isFalse);
      runner.releaseSpawn.complete();
      await submission;

      expect(controller.state.phase, VmPhase.handshaking);
      await controller.shutdown();
    });

    test('hung effects time out and invoke adapter cancellation', () async {
      final runner = _HangingAcquireRunner(completeWhenCancelled: true);
      final controller = VmController(
        initialState: _initialState(),
        effectRunner: runner,
        effectTimeout: const Duration(milliseconds: 10),
        shutdownTimeout: const Duration(milliseconds: 100),
      );

      await controller.submit(StartRequested(_operation1));

      expect(runner.cancelled, isTrue);
      expect(controller.state.phase, VmPhase.failed);
      expect(controller.state.lastError?.code, ErrorCode.waitTimeout);
      await controller.shutdown();
    });

    test(
      'shutdown is bounded when cancellation cannot stop a hung adapter',
      () async {
        final runner = _HangingAcquireRunner(completeWhenCancelled: false);
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: runner,
          effectTimeout: const Duration(milliseconds: 60),
          shutdownTimeout: const Duration(milliseconds: 10),
        );
        final start = controller.submit(StartRequested(_operation1));
        await runner.started.future;

        await expectLater(
          controller.shutdown(),
          throwsA(isA<VmControllerShutdownException>()),
        );
        expect(runner.cancelled, isTrue);
        expect(controller.state.leaseState, VmLeaseState.acquiring);
        runner.complete();
        await start;
      },
    );

    test(
      'shutdown teardown failure retains resource ownership and typed error',
      () async {
        final typedError = OperationError(
          code: ErrorCode.driverUnhealthy,
          message: 'kill was rejected',
          retryable: false,
          details: JsonObjectValue.empty,
        );
        final runner = _FailingShutdownRunner(typedError);
        final controller = VmController(
          initialState: _recoveringStartState(),
          effectRunner: runner,
        );

        await expectLater(
          controller.shutdown(),
          throwsA(isA<VmControllerShutdownException>()),
        );

        expect(controller.state.activeDriverGeneration, 2);
        expect(controller.state.leaseState, VmLeaseState.held);
        expect(controller.state.phase, VmPhase.failed);
        expect(controller.state.lastError, typedError);
        expect(runner.calls, isNot(contains('ShutdownLease')));
      },
    );

    test('failed shutdown can be retried to confirmed teardown', () async {
      final runner = _RetryShutdownRunner();
      final controller = VmController(
        initialState: _recoveringStartState(),
        effectRunner: runner,
      );

      await expectLater(
        controller.shutdown(),
        throwsA(isA<VmControllerShutdownException>()),
      );
      await controller.shutdown();

      expect(runner.driverAttempts, 2);
      expect(controller.state.activeDriverGeneration, isNull);
      expect(controller.state.leaseState, VmLeaseState.none);
    });

    test('concurrent shutdown callers share one in-progress attempt', () async {
      final runner = _BlockingShutdownRunner();
      final controller = VmController(
        initialState: _recoveringStartState(),
        effectRunner: runner,
      );

      final first = controller.shutdown();
      final second = controller.shutdown();
      expect(identical(first, second), isTrue);
      await runner.started.future;
      runner.release.complete();
      await Future.wait([first, second]);

      expect(runner.driverAttempts, 1);
    });

    test(
      'shutdown supplies teardown correlation when runtime operation is absent',
      () async {
        final teardownId = OperationId('op_01J00000000000000000000009');
        final runner = _CorrelationShutdownRunner();
        final controller = VmController(
          initialState: _initialState().copyWith(
            phase: VmPhase.running,
            activeDriverGeneration: 3,
            leaseState: VmLeaseState.held,
          ),
          effectRunner: runner,
          newTeardownOperationId: () => teardownId,
        );

        await controller.shutdown();

        expect(runner.driverOperationId, teardownId);
        expect(controller.state.activeDriverGeneration, isNull);
        expect(controller.state.leaseState, VmLeaseState.none);
      },
    );

    test(
      'typed adapter errors are preserved without generic remapping',
      () async {
        final typedError = OperationError(
          code: ErrorCode.hostResourceExhausted,
          message: 'typed admission failure',
          retryable: false,
          details: JsonObjectValue.empty,
        );
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: _TypedAcquireFailureRunner(typedError),
        );

        await controller.submit(StartRequested(_operation1));

        expect(controller.state.lastError, typedError);
        await controller.shutdown();
      },
    );

    test(
      'contiguous durable effects execute as one transaction batch',
      () async {
        final runner = _RecordingTransactionalRunner();
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: runner,
        );

        await controller.submit(
          const SpecUpdated(
            specGeneration: 2,
            restartPolicy: RestartPolicy.always,
            restartRequired: true,
          ),
        );

        expect(runner.batches, [
          ['PersistVm', 'PersistRuntime', 'EmitEvent'],
        ]);
        await controller.shutdown();
      },
    );

    test(
      'generic failure persistence is retried as one durable batch',
      () async {
        final runner = _FailFirstTransactionalRunner();
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: runner,
        );

        await controller.submit(
          const SpecUpdated(
            specGeneration: 2,
            restartPolicy: RestartPolicy.always,
            restartRequired: true,
          ),
        );

        expect(controller.state.phase, VmPhase.failed);
        expect(runner.batches, [
          ['PersistVm', 'PersistRuntime', 'EmitEvent'],
          ['PersistVm', 'PersistRuntime', 'EmitEvent'],
        ]);
        await controller.shutdown();
      },
    );

    test(
      'timed-out spawn retains ownership until late completion is compensated',
      () async {
        final runner = _LateSpawnRunner();
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: runner,
          effectTimeout: const Duration(milliseconds: 10),
          shutdownTimeout: const Duration(milliseconds: 15),
        );
        var completed = false;
        final start = controller.submit(StartRequested(_operation1))
          ..then((_) => completed = true);
        await runner.spawnStarted.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(completed, isFalse);
        expect(controller.state.activeDriverGeneration, 1);
        expect(controller.state.leaseState, VmLeaseState.held);
        expect(controller.pendingCancellationCount, 1);
        await expectLater(
          controller.shutdown(),
          throwsA(isA<VmControllerShutdownException>()),
        );
        expect(controller.state.activeDriverGeneration, 1);

        runner.completeSpawn();
        await start;
        await controller.waitUntilIdle();
        expect(controller.pendingCancellationCount, 0);
        expect(controller.state.activeDriverGeneration, isNull);
        expect(controller.state.leaseState, VmLeaseState.none);
        await controller.shutdown();
      },
    );

    test(
      'timed-out durable batch cannot commit after actor advancement',
      () async {
        final runner = _LateDurableRunner();
        final controller = VmController(
          initialState: _initialState(),
          effectRunner: runner,
          effectTimeout: const Duration(milliseconds: 10),
        );
        var completed = false;
        final submission = controller.submit(
          const SpecUpdated(
            specGeneration: 2,
            restartPolicy: RestartPolicy.always,
            restartRequired: true,
          ),
        )..then((_) => completed = true);
        await runner.started.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(completed, isFalse);
        runner.commit();
        await submission;

        expect(controller.state.phase, VmPhase.stopped);
        expect(controller.state.lastError, isNull);
        await controller.shutdown();
      },
    );

    test(
      'rolled-back completion is forced failed and durably compensated',
      () async {
        final runner = _RollbackCompletionRunner();
        final controller = VmController(
          initialState: _startingOperationState(),
          effectRunner: runner,
        );

        await controller.submit(
          VmStateChanged(
            operationId: _operation1,
            driverGeneration: 1,
            phase: VmPhase.running,
          ),
        );

        expect(controller.state.currentOperation?.state, OperationState.failed);
        expect(runner.batches[1], contains('FailOperation'));
        await controller.shutdown();
      },
    );
  });
}

final class _RecordingRunner implements VmEffectRunner {
  _RecordingRunner({this.blockFirstEffect});

  final Future<void>? blockFirstEffect;
  final firstEffectStarted = Completer<void>();
  final stateGenerations = <int>[];
  var inFlight = 0;
  var maxInFlight = 0;
  var _calls = 0;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    _calls++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    stateGenerations.add(state.specGeneration);
    if (_calls == 1) {
      firstEffectStarted.complete();
      await blockFirstEffect;
    }
    inFlight--;
    return null;
  }
}

final class _ConcurrentRunner implements VmEffectRunner {
  _ConcurrentRunner(this.releaseEffects);

  final Future<void> releaseEffects;
  final twoEffectsStarted = Completer<void>();
  var inFlight = 0;
  var maxInFlight = 0;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    if (inFlight == 2 && !twoEffectsStarted.isCompleted) {
      twoEffectsStarted.complete();
    }
    await releaseEffects;
    inFlight--;
    return null;
  }
}

final class _LifecycleRunner implements VmEffectRunner {
  final effectTypes = <String>[];

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    effectTypes.add(effect.runtimeType.toString());
    final operationId = effect.operationId;
    final driverGeneration = effect.driverGeneration;
    return switch (effect) {
      AcquireHostLease() => HostLeaseAcquired(operationId!),
      SpawnDriver() => DriverSpawned(
        operationId: operationId!,
        driverGeneration: driverGeneration!,
      ),
      ConnectDriver() => DriverHandshakeCompleted(
        operationId: operationId!,
        driverGeneration: driverGeneration!,
      ),
      ConfigureRuntime() => DriverCommandSucceeded(
        operationId: operationId!,
        driverGeneration: driverGeneration!,
        command: RuntimeCommandKind.configure,
      ),
      StartRuntime() => DriverCommandSucceeded(
        operationId: operationId!,
        driverGeneration: driverGeneration!,
        command: RuntimeCommandKind.start,
      ),
      _ => null,
    };
  }
}

final class _NullRunner implements VmEffectRunner {
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async =>
      null;
}

final class _FailingAcquireRunner implements VmEffectRunner {
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is AcquireHostLease) throw StateError('scheduler unavailable');
    return null;
  }
}

final class _FailingRuntimePersistenceRunner implements VmEffectRunner {
  final calls = <String>[];

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    calls.add(effect.runtimeType.toString());
    if (effect is AcquireHostLease) {
      return HostLeaseAcquired(effect.operationId!);
    }
    if (effect is ShutdownLease) {
      return const ControllerLeaseShutdownSucceeded();
    }
    if (effect is PersistRuntime) throw StateError('database unavailable');
    return null;
  }
}

final class _BlockingAcquireLifecycleRunner implements VmEffectRunner {
  final acquireStarted = Completer<void>();
  final releaseAcquire = Completer<void>();
  final calls = <String>[];

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    calls.add(effect.runtimeType.toString());
    if (effect is AcquireHostLease) {
      acquireStarted.complete();
      await releaseAcquire.future;
      return HostLeaseAcquired(effect.operationId!);
    }
    if (effect is ShutdownLease) {
      return const ControllerLeaseShutdownSucceeded();
    }
    return null;
  }
}

final class _BlockingSpawnLifecycleRunner implements VmEffectRunner {
  final spawnStarted = Completer<void>();
  final releaseSpawn = Completer<void>();
  final calls = <String>[];

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    calls.add(effect.runtimeType.toString());
    if (effect is AcquireHostLease) {
      return HostLeaseAcquired(effect.operationId!);
    }
    if (effect is SpawnDriver) {
      spawnStarted.complete();
      await releaseSpawn.future;
      return DriverSpawned(
        operationId: effect.operationId!,
        driverGeneration: effect.driverGeneration!,
      );
    }
    if (effect is ShutdownDriver) {
      return ControllerDriverShutdownSucceeded(
        effect.driverGeneration!,
        effect.operationId!,
      );
    }
    if (effect is ShutdownLease) {
      return const ControllerLeaseShutdownSucceeded();
    }
    return null;
  }
}

final class _HangingAcquireRunner
    implements VmEffectRunner, CancellableVmEffectRunner {
  _HangingAcquireRunner({required this.completeWhenCancelled});

  final bool completeWhenCancelled;
  final started = Completer<void>();
  final _effect = Completer<VmCommand?>();
  bool cancelled = false;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is AcquireHostLease) {
      if (!started.isCompleted) started.complete();
      return _effect.future;
    }
    if (effect is ShutdownLease) {
      return const ControllerLeaseShutdownSucceeded();
    }
    return null;
  }

  @override
  Future<void> cancel(VmEffect effect, VmControllerState state) async {
    cancelled = true;
    if (completeWhenCancelled && !_effect.isCompleted) {
      _effect.complete(null);
    }
  }

  void complete() {
    if (!_effect.isCompleted) _effect.complete(null);
  }
}

final class _FailingShutdownRunner implements VmEffectRunner {
  _FailingShutdownRunner(this.error);

  final OperationError error;
  final calls = <String>[];

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    calls.add(effect.runtimeType.toString());
    if (effect is ShutdownDriver) throw VmEffectException(error);
    if (effect is PersistVm) throw StateError('persistence also unavailable');
    if (effect is ShutdownLease) {
      return const ControllerLeaseShutdownSucceeded();
    }
    return null;
  }
}

final class _RetryShutdownRunner implements VmEffectRunner {
  var driverAttempts = 0;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is ShutdownDriver) {
      driverAttempts++;
      if (driverAttempts == 1) {
        throw VmEffectException(_driverError);
      }
      return ControllerDriverShutdownSucceeded(
        effect.driverGeneration!,
        effect.operationId!,
      );
    }
    if (effect is ShutdownLease) {
      return const ControllerLeaseShutdownSucceeded();
    }
    return null;
  }
}

final class _BlockingShutdownRunner implements VmEffectRunner {
  final started = Completer<void>();
  final release = Completer<void>();
  var driverAttempts = 0;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is ShutdownDriver) {
      driverAttempts++;
      started.complete();
      await release.future;
      return ControllerDriverShutdownSucceeded(
        effect.driverGeneration!,
        effect.operationId!,
      );
    }
    if (effect is ShutdownLease) {
      return const ControllerLeaseShutdownSucceeded();
    }
    return null;
  }
}

final class _CorrelationShutdownRunner implements VmEffectRunner {
  OperationId? driverOperationId;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is ShutdownDriver) {
      driverOperationId = effect.operationId;
      return ControllerDriverShutdownSucceeded(
        effect.driverGeneration!,
        effect.operationId!,
      );
    }
    if (effect is ShutdownLease) {
      return const ControllerLeaseShutdownSucceeded();
    }
    return null;
  }
}

final class _TypedAcquireFailureRunner implements VmEffectRunner {
  const _TypedAcquireFailureRunner(this.error);

  final OperationError error;

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is AcquireHostLease) throw VmEffectException(error);
    return null;
  }
}

final class _RecordingTransactionalRunner
    implements TransactionalVmEffectRunner {
  final batches = <List<String>>[];

  @override
  bool isDurable(VmEffect effect) =>
      effect is PersistVm || effect is PersistRuntime || effect is EmitEvent;

  @override
  Future<List<VmCommand?>> runDurableBatch(
    List<VmEffect> effects,
    VmControllerState state,
  ) async {
    batches.add(
      effects.map((effect) => effect.runtimeType.toString()).toList(),
    );
    return List<VmCommand?>.filled(effects.length, null);
  }

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async =>
      null;
}

final class _FailFirstTransactionalRunner
    implements TransactionalVmEffectRunner {
  final batches = <List<String>>[];
  final effects = <String>[];

  @override
  bool isDurable(VmEffect effect) =>
      effect is PersistVm ||
      effect is PersistRuntime ||
      effect is FailOperation ||
      effect is EmitEvent;

  @override
  Future<List<VmCommand?>> runDurableBatch(
    List<VmEffect> effects,
    VmControllerState state,
  ) async {
    batches.add(
      effects.map((effect) => effect.runtimeType.toString()).toList(),
    );
    if (batches.length == 1) {
      throw VmEffectBatchException(
        effects.first,
        StateError('first durable batch failed'),
        StackTrace.current,
      );
    }
    return List<VmCommand?>.filled(effects.length, null);
  }

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    effects.add(effect.runtimeType.toString());
    return null;
  }
}

final class _LateSpawnRunner
    implements VmEffectRunner, CancellableVmEffectRunner {
  final spawnStarted = Completer<void>();
  final _spawn = Completer<VmCommand?>();
  final _neverCancelled = Completer<void>();

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is AcquireHostLease) {
      return HostLeaseAcquired(effect.operationId!);
    }
    if (effect is SpawnDriver) {
      spawnStarted.complete();
      return _spawn.future;
    }
    if (effect is ShutdownDriver) {
      return ControllerDriverShutdownSucceeded(
        effect.driverGeneration!,
        effect.operationId!,
      );
    }
    if (effect is ShutdownLease) {
      return const ControllerLeaseShutdownSucceeded();
    }
    return null;
  }

  @override
  Future<void> cancel(VmEffect effect, VmControllerState state) async {
    if (effect is SpawnDriver) await _neverCancelled.future;
  }

  void completeSpawn() {
    _spawn.complete(
      DriverSpawned(operationId: _operation1, driverGeneration: 1),
    );
  }
}

final class _LateDurableRunner implements TransactionalVmEffectRunner {
  final started = Completer<void>();
  final _commit = Completer<List<VmCommand?>>();

  @override
  bool isDurable(VmEffect effect) => true;

  @override
  Future<List<VmCommand?>> runDurableBatch(
    List<VmEffect> effects,
    VmControllerState state,
  ) {
    started.complete();
    return _commit.future;
  }

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async =>
      null;

  void commit() => _commit.complete([null, null, null]);
}

final class _RollbackCompletionRunner implements TransactionalVmEffectRunner {
  final batches = <List<String>>[];

  @override
  bool isDurable(VmEffect effect) =>
      effect is PersistVm ||
      effect is PersistRuntime ||
      effect is CompleteOperation ||
      effect is FailOperation ||
      effect is EmitEvent;

  @override
  Future<List<VmCommand?>> runDurableBatch(
    List<VmEffect> effects,
    VmControllerState state,
  ) async {
    batches.add(
      effects.map((effect) => effect.runtimeType.toString()).toList(),
    );
    if (batches.length == 1) {
      throw VmEffectBatchException(
        effects.last,
        StateError('event append rolled back completion'),
        StackTrace.current,
      );
    }
    return List<VmCommand?>.filled(effects.length, null);
  }

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async =>
      null;
}

final class _ManualTimerScheduler implements VmTimerScheduler {
  final handles = <_ManualTimerHandle>[];

  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) {
    final handle = _ManualTimerHandle(callback);
    handles.add(handle);
    return handle;
  }
}

final class _ManualTimerHandle implements VmTimerHandle {
  _ManualTimerHandle(this._callback);

  final void Function() _callback;
  bool cancelled = false;
  bool fired = false;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  void cancel() => cancelled = true;

  void fire() {
    if (!isActive) return;
    fired = true;
    _callback();
  }
}

final _operation1 = OperationId('op_01J00000000000000000000000');
final _operation2 = OperationId('op_01J00000000000000000000001');

VmControllerState _initialState({VmId? vmId}) => VmControllerState.initial(
  vmId: vmId ?? VmId('vm_01J00000000000000000000000'),
  specGeneration: 1,
  restartPolicy: RestartPolicy.onFailure,
);

VmControllerState _pendingRecoveryState() => _initialState().copyWith(
  desiredState: DesiredState.running,
  phase: VmPhase.crashed,
  driverGeneration: 1,
  pendingRecoveryGeneration: 1,
  pendingRecoveryError: _driverError,
  retryState: VmRetryState(
    attempts: 1,
    scheduledDelay: const Duration(seconds: 1),
  ),
);

VmControllerState _recoveringStartState() => _initialState().copyWith(
  desiredState: DesiredState.running,
  phase: VmPhase.starting,
  driverGeneration: 2,
  activeDriverGeneration: 2,
  activeSpecGeneration: 1,
  driverOperationId: _operation2,
  leaseState: VmLeaseState.held,
  currentOperation: VmControllerOperation(
    id: _operation2,
    kind: VmOperationKind.recovery,
    state: OperationState.running,
  ),
  retryState: VmRetryState(attempts: 1),
);

VmControllerState _startingOperationState() => _initialState().copyWith(
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

final _driverError = OperationError(
  code: ErrorCode.driverUnhealthy,
  message: 'driver failed',
  retryable: true,
  details: JsonObjectValue.empty,
);
