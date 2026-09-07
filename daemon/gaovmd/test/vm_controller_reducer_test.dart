import 'dart:math';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  group('VmController reducer', () {
    test('start records the desired state and requests a host lease', () {
      final state = VmControllerState.initial(
        vmId: _vmId,
        specGeneration: 1,
        restartPolicy: RestartPolicy.onFailure,
      );

      final transition = reduce(state, StartRequested(_operation1));

      expect(transition.state.desiredState, DesiredState.running);
      expect(transition.state.phase, VmPhase.stopped);
      expect(transition.state.leaseState, VmLeaseState.acquiring);
      expect(transition.state.currentOperation?.id, _operation1);
      expect(transition.state.currentOperation?.kind, VmOperationKind.start);
      expect(transition.effects, [
        isA<PersistVm>(),
        isA<AcquireHostLease>()
            .having((effect) => effect.vmId, 'vmId', _vmId)
            .having((effect) => effect.operationId, 'operationId', _operation1),
      ]);
    });

    test('an acquired lease starts exactly one correlated generation', () {
      final starting = reduce(_initial(), StartRequested(_operation1)).state;

      final transition = reduce(starting, HostLeaseAcquired(_operation1));

      expect(transition.state.leaseState, VmLeaseState.held);
      expect(transition.state.phase, VmPhase.spawningDriver);
      expect(transition.state.driverGeneration, 1);
      expect(transition.state.activeDriverGeneration, 1);
      expect(transition.effects, [
        isA<PersistRuntime>(),
        isA<SpawnDriver>()
            .having((effect) => effect.operationId, 'operation', _operation1)
            .having((effect) => effect.driverGeneration, 'generation', 1),
      ]);
    });

    test('scheduler rejection fails start without creating a generation', () {
      final acquiring = reduce(_initial(), StartRequested(_operation1)).state;
      final resourceError = OperationError(
        code: ErrorCode.hostResourceExhausted,
        message: 'memory budget exhausted',
        retryable: true,
        details: JsonObjectValue.empty,
      );

      final transition = reduce(
        acquiring,
        HostLeaseFailed(operationId: _operation1, error: resourceError),
      );

      expect(transition.state.desiredState, DesiredState.stopped);
      expect(transition.state.phase, VmPhase.failed);
      expect(transition.state.leaseState, VmLeaseState.none);
      expect(transition.state.activeDriverGeneration, isNull);
      expect(transition.state.currentOperation?.state, OperationState.failed);
      expect(transition.effects.whereType<SpawnDriver>(), isEmpty);
      expect(transition.effects.whereType<FailOperation>(), hasLength(1));
    });

    test(
      'successful driver lifecycle applies the spec and completes start',
      () {
        var state = _spawning();

        var transition = reduce(
          state,
          DriverSpawned(operationId: _operation1, driverGeneration: 1),
        );
        expect(transition.state.phase, VmPhase.handshaking);
        expect(transition.effects.single, isA<ConnectDriver>());

        transition = reduce(
          transition.state,
          DriverHandshakeCompleted(
            operationId: _operation1,
            driverGeneration: 1,
          ),
        );
        expect(transition.state.phase, VmPhase.configuring);
        expect(transition.effects.single, isA<ConfigureRuntime>());

        transition = reduce(
          transition.state,
          DriverCommandSucceeded(
            operationId: _operation1,
            driverGeneration: 1,
            command: RuntimeCommandKind.configure,
          ),
        );
        expect(transition.state.phase, VmPhase.starting);
        expect(transition.effects.single, isA<StartRuntime>());

        transition = reduce(
          transition.state,
          VmStateChanged(
            operationId: _operation1,
            driverGeneration: 1,
            phase: VmPhase.running,
          ),
        );
        expect(transition.state.phase, VmPhase.running);
        expect(transition.state.observedGeneration, 1);
        expect(
          transition.state.currentOperation?.state,
          OperationState.succeeded,
        );
        expect(transition.effects, [
          isA<MarkHostLeaseRunning>(),
          isA<PersistRuntime>(),
          isA<CompleteOperation>(),
          isA<EmitEvent>().having(
            (effect) => effect.type,
            'type',
            'vm.running',
          ),
        ]);
      },
    );

    test('runtime phase events are persisted without polling', () {
      for (final phase in const [
        VmPhase.stopping,
        VmPhase.stopped,
        VmPhase.crashed,
        VmPhase.failed,
      ]) {
        final transition = reduce(
          _starting(),
          VmStateChanged(
            operationId: _operation1,
            driverGeneration: 1,
            phase: phase,
          ),
        );

        expect(transition.state.phase, phase);
        expect(transition.effects, [
          isA<PersistRuntime>(),
          isA<EmitEvent>().having(
            (effect) => effect.type,
            'type',
            'vm.state_changed',
          ),
        ]);
      }
      final duplicate = reduce(
        _starting(),
        VmStateChanged(
          operationId: _operation1,
          driverGeneration: 1,
          phase: VmPhase.starting,
        ),
      );
      expect(duplicate.effects, isEmpty);
    });

    test(
      'stop during spawn cancels that generation and ignores its callback',
      () {
        final spawning = _spawning();

        final stopping = reduce(spawning, StopRequested(_operation2));

        expect(stopping.state.desiredState, DesiredState.stopped);
        expect(stopping.state.phase, VmPhase.stopping);
        expect(stopping.state.currentOperation?.id, _operation2);
        expect(stopping.effects, [
          isA<FailOperation>().having(
            (effect) => effect.operationId,
            'superseded operation',
            _operation1,
          ),
          isA<PersistVm>(),
          isA<PersistRuntime>(),
          isA<KillDriver>()
              .having((effect) => effect.operationId, 'operation', _operation2)
              .having((effect) => effect.driverGeneration, 'generation', 1),
        ]);

        final stale = reduce(
          stopping.state,
          DriverSpawned(operationId: _operation1, driverGeneration: 1),
        );
        expect(stale.state, same(stopping.state));
        expect(stale.effects, isEmpty);
      },
    );

    test('stop while acquiring a lease cancels scheduler admission', () {
      final acquiring = reduce(_initial(), StartRequested(_operation1)).state;

      final transition = reduce(acquiring, StopRequested(_operation2));

      expect(transition.state.desiredState, DesiredState.stopped);
      expect(transition.state.leaseState, VmLeaseState.releasing);
      expect(transition.effects.last, isA<ReleaseHostLease>());
    });

    test('stop releases the lease after its active generation exits', () {
      final running = _running();

      var transition = reduce(running, StopRequested(_operation2));
      expect(transition.state.phase, VmPhase.stopping);
      expect(transition.effects.last, isA<StopRuntime>());

      transition = reduce(
        transition.state,
        DriverExited(
          operationId: _operation2,
          driverGeneration: 1,
          cleanShutdown: true,
        ),
      );
      expect(transition.state.activeDriverGeneration, isNull);
      expect(transition.state.leaseState, VmLeaseState.releasing);
      expect(transition.effects, [
        isA<PersistRuntime>(),
        isA<ReleaseHostLease>(),
      ]);

      transition = reduce(transition.state, HostLeaseReleased(_operation2));
      expect(transition.state.phase, VmPhase.stopped);
      expect(transition.state.leaseState, VmLeaseState.none);
      expect(
        transition.state.currentOperation?.state,
        OperationState.succeeded,
      );
      expect(transition.effects, [
        isA<PersistRuntime>(),
        isA<CompleteOperation>(),
        isA<EmitEvent>().having((effect) => effect.type, 'type', 'vm.stopped'),
      ]);
    });

    test(
      'kill immediately terminates a running generation and waits for lease release',
      () {
        var transition = reduce(_running(), KillRequested(_operation2));
        expect(transition.state.desiredState, DesiredState.stopped);
        expect(transition.state.currentOperation?.kind, VmOperationKind.kill);
        expect(transition.effects.last, isA<KillDriver>());
        expect(transition.effects.whereType<StopRuntime>(), isEmpty);
        transition = reduce(
          transition.state,
          DriverExited(
            operationId: _operation2,
            driverGeneration: 1,
            cleanShutdown: false,
          ),
        );
        expect(transition.state.leaseState, VmLeaseState.releasing);
        transition = reduce(transition.state, HostLeaseReleased(_operation2));
        expect(
          transition.state.currentOperation?.state,
          OperationState.succeeded,
        );
        expect(transition.state.phase, VmPhase.stopped);
      },
    );

    test('kill supersedes a pending graceful stop', () {
      final stopping = reduce(_running(), StopRequested(_operation1)).state;
      final transition = reduce(stopping, KillRequested(_operation2));
      expect(transition.state.currentOperation?.id, _operation2);
      expect(transition.effects.last, isA<KillDriver>());
      expect(
        transition.effects.whereType<FailOperation>().single.operationId,
        _operation1,
      );
    });

    test(
      'kill consumes a queued superseded stop exit but fences old generations',
      () {
        final stopping = reduce(_running(), StopRequested(_operation1)).state;
        final killing = reduce(stopping, KillRequested(_operation2)).state;
        final stale = reduce(
          killing,
          DriverExited(
            operationId: _operation1,
            driverGeneration: 0,
            cleanShutdown: true,
          ),
        );
        expect(stale.state, same(killing));
        var transition = reduce(
          killing,
          DriverExited(
            operationId: _operation1,
            driverGeneration: 1,
            cleanShutdown: true,
          ),
        );
        expect(transition.state.activeDriverGeneration, isNull);
        expect(
          transition.effects.whereType<ReleaseHostLease>().single.operationId,
          _operation2,
        );
        transition = reduce(transition.state, HostLeaseReleased(_operation2));
        expect(
          transition.state.currentOperation?.state,
          OperationState.succeeded,
        );
      },
    );

    test('restart replaces the generation and rejects a late old exit', () {
      var transition = reduce(_running(), RestartRequested(_operation2));
      expect(transition.state.desiredState, DesiredState.running);
      expect(transition.state.phase, VmPhase.stopping);
      expect(transition.effects.last, isA<StopRuntime>());

      transition = reduce(
        transition.state,
        DriverExited(
          operationId: _operation2,
          driverGeneration: 1,
          cleanShutdown: true,
        ),
      );
      transition = reduce(transition.state, HostLeaseReleased(_operation2));
      expect(transition.state.leaseState, VmLeaseState.acquiring);
      expect(transition.effects.last, isA<AcquireHostLease>());

      transition = reduce(transition.state, HostLeaseAcquired(_operation2));
      expect(transition.state.driverGeneration, 2);
      expect(transition.state.activeDriverGeneration, 2);

      final stale = reduce(
        transition.state,
        DriverExited(
          operationId: _operation2,
          driverGeneration: 1,
          cleanShutdown: true,
        ),
      );
      expect(stale.state, same(transition.state));
      expect(stale.effects, isEmpty);
    });

    test('clean and crash exits follow distinct restart policies', () {
      final cleanOnFailure = reduce(
        _running(policy: RestartPolicy.onFailure),
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: true,
        ),
      );
      expect(cleanOnFailure.state.desiredState, DesiredState.stopped);
      expect(cleanOnFailure.state.phase, VmPhase.stopped);
      expect(cleanOnFailure.state.retryState.retryScheduled, isFalse);
      expect(
        cleanOnFailure.state.currentOperation?.state,
        OperationState.succeeded,
      );

      final cleanAlways = reduce(
        _running(policy: RestartPolicy.always),
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: true,
        ),
      );
      expect(cleanAlways.state.desiredState, DesiredState.running);
      expect(cleanAlways.state.retryState.attempts, 1);
      expect(
        cleanAlways.state.retryState.scheduledDelay,
        const Duration(seconds: 1),
      );

      final crashNever = reduce(
        _running(policy: RestartPolicy.never),
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      );
      expect(crashNever.state.desiredState, DesiredState.stopped);
      expect(crashNever.state.phase, VmPhase.failed);
      expect(crashNever.state.retryState.retryScheduled, isFalse);

      var crashOnFailure = reduce(
        _running(policy: RestartPolicy.onFailure),
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      );
      expect(crashOnFailure.state.desiredState, DesiredState.running);
      expect(crashOnFailure.state.phase, VmPhase.crashed);
      expect(crashOnFailure.state.retryState.retryScheduled, isTrue);

      crashOnFailure = reduce(
        crashOnFailure.state,
        HostLeaseReleased(_operation1),
      );
      crashOnFailure = reduce(
        crashOnFailure.state,
        RecoveryOperationCreated(
          operationId: _operation2,
          failedDriverGeneration: 1,
        ),
      );
      expect(crashOnFailure.effects.last, isA<ScheduleRetry>());

      final retrying = reduce(
        crashOnFailure.state,
        RetryTimerFired(operationId: _operation2, driverGeneration: 1),
      );
      expect(retrying.state.leaseState, VmLeaseState.acquiring);
      expect(retrying.effects.last, isA<AcquireHostLease>());

      final spawned = reduce(retrying.state, HostLeaseAcquired(_operation2));
      expect(spawned.state.driverGeneration, 2);
      expect(spawned.state.activeDriverGeneration, 2);
      expect(spawned.state.currentOperation?.kind, VmOperationKind.recovery);
      expect(spawned.state.currentOperation?.state, OperationState.running);
    });

    test('retry budget exhaustion is permanent until an explicit start', () {
      final exhausted = _spawning().copyWith(
        retryState: VmRetryState(attempts: 5, maxAttempts: 5),
      );

      var transition = reduce(
        exhausted,
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      );

      expect(transition.state.desiredState, DesiredState.stopped);
      expect(transition.state.phase, VmPhase.failed);
      expect(transition.state.retryState.retryScheduled, isFalse);
      expect(transition.state.currentOperation?.state, OperationState.failed);
      expect(transition.effects.whereType<FailOperation>(), hasLength(1));
      expect(
        transition.effects.whereType<EmitEvent>().single.type,
        'vm.permanent_failure',
      );

      transition = reduce(transition.state, HostLeaseReleased(_operation1));
      final restarted = reduce(transition.state, StartRequested(_operation2));
      expect(restarted.state.desiredState, DesiredState.running);
      expect(restarted.state.retryState.attempts, 0);
      expect(restarted.state.currentOperation?.id, _operation2);
      expect(restarted.effects.last, isA<AcquireHostLease>());
    });

    test('retry backoff is exponential and capped at thirty seconds', () {
      final lateRetry = _spawning().copyWith(
        retryState: VmRetryState(attempts: 5, maxAttempts: 7),
      );

      final transition = reduce(
        lateRetry,
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      );

      expect(
        transition.state.retryState.scheduledDelay,
        const Duration(seconds: 30),
      );
    });

    test('delete stops a running VM and deleted VMs can never start', () {
      var transition = reduce(_running(), DeleteRequested(_operation2));
      expect(transition.state.desiredState, DesiredState.stopped);
      expect(transition.state.phase, VmPhase.deleting);
      expect(transition.state.deletionState, VmDeletionState.deleting);
      expect(transition.effects.last, isA<StopRuntime>());

      transition = reduce(
        transition.state,
        DriverExited(
          operationId: _operation2,
          driverGeneration: 1,
          cleanShutdown: true,
        ),
      );
      transition = reduce(transition.state, HostLeaseReleased(_operation2));
      expect(transition.state.deletionState, VmDeletionState.removingFiles);
      expect(transition.effects.last, isA<RemoveManagedFiles>());
      transition = reduce(transition.state, ManagedFilesRemoved(_operation2));
      expect(transition.state.phase, VmPhase.deleted);
      expect(transition.state.deletionState, VmDeletionState.deleted);
      expect(
        transition.state.currentOperation?.state,
        OperationState.succeeded,
      );
      expect(
        transition.effects.whereType<EmitEvent>().single.type,
        'vm.deleted',
      );

      final rejected = reduce(transition.state, StartRequested(_operation3));
      expect(rejected.state, same(transition.state));
      expect(rejected.effects, [
        isA<FailOperation>().having(
          (effect) => effect.operationId,
          'operation',
          _operation3,
        ),
      ]);
      expect(rejected.effects.whereType<AcquireHostLease>(), isEmpty);
      expect(rejected.effects.whereType<SpawnDriver>(), isEmpty);
    });

    test(
      'spec updates preserve applied generation until runtime applies it',
      () {
        final running = _running();

        final transition = reduce(
          running,
          const SpecUpdated(
            specGeneration: 2,
            restartPolicy: RestartPolicy.always,
            restartRequired: true,
          ),
        );

        expect(transition.state.specGeneration, 2);
        expect(transition.state.observedGeneration, 1);
        expect(transition.state.restartPolicy, RestartPolicy.always);
        expect(transition.state.restartRequired, isTrue);
        expect(transition.effects, [
          isA<PersistVm>(),
          isA<PersistRuntime>(),
          isA<EmitEvent>().having(
            (effect) => effect.type,
            'type',
            'vm.spec_updated',
          ),
        ]);

        final stale = reduce(
          transition.state,
          const SpecUpdated(
            specGeneration: 1,
            restartPolicy: RestartPolicy.never,
            restartRequired: false,
          ),
        );
        expect(stale.state, same(transition.state));
        expect(stale.effects, isEmpty);
      },
    );

    test('idempotent lifecycle requests never create a second runtime', () {
      final running = _running();

      final duplicateStart = reduce(running, StartRequested(_operation2));
      expect(duplicateStart.state, same(running));
      expect(duplicateStart.effects, [isA<CompleteOperation>()]);
      expect(duplicateStart.effects.whereType<AcquireHostLease>(), isEmpty);
      expect(duplicateStart.effects.whereType<SpawnDriver>(), isEmpty);

      final stopped = _initial();
      final duplicateStop = reduce(stopped, StopRequested(_operation2));
      expect(duplicateStop.state, same(stopped));
      expect(duplicateStop.effects, [isA<CompleteOperation>()]);
    });

    test('reconcile converges desired state without duplicating effects', () {
      final restored = _initial().copyWith(
        desiredState: DesiredState.running,
        phase: VmPhase.defined,
      );

      final transition = reduce(restored, const ReconcileRequested());
      expect(transition.state.pendingRecoveryGeneration, 0);
      expect(transition.effects.last, isA<CreateRecoveryOperation>());

      final duplicate = reduce(transition.state, const ReconcileRequested());
      expect(duplicate.state, same(transition.state));
      expect(duplicate.effects, isEmpty);

      var recovering = reduce(
        transition.state,
        RecoveryOperationCreated(
          operationId: _operation2,
          failedDriverGeneration: 0,
        ),
      );
      recovering = reduce(
        recovering.state,
        RetryTimerFired(operationId: _operation2, driverGeneration: 0),
      );
      expect(recovering.state.leaseState, VmLeaseState.acquiring);
      expect(recovering.effects.last, isA<AcquireHostLease>());

      final shouldStop = _running().copyWith(
        desiredState: DesiredState.stopped,
      );
      final stopping = reduce(shouldStop, const ReconcileRequested());
      expect(stopping.state.phase, VmPhase.stopping);
      expect(stopping.effects.last, isA<StopRuntime>());
    });

    test('driver failures and heartbeat loss are generation correlated', () {
      var configuring = _spawning();
      configuring = reduce(
        configuring,
        DriverSpawned(operationId: _operation1, driverGeneration: 1),
      ).state;
      configuring = reduce(
        configuring,
        DriverHandshakeCompleted(operationId: _operation1, driverGeneration: 1),
      ).state;

      final failed = reduce(
        configuring,
        DriverCommandFailed(
          operationId: _operation1,
          driverGeneration: 1,
          command: RuntimeCommandKind.configure,
          error: _driverError,
        ),
      );
      expect(failed.state.phase, VmPhase.crashed);
      expect(failed.state.lastError, _driverError);
      expect(failed.effects.whereType<KillDriver>(), hasLength(1));

      final stale = reduce(
        configuring,
        DriverCommandFailed(
          operationId: _operation1,
          driverGeneration: 99,
          command: RuntimeCommandKind.configure,
          error: _driverError,
        ),
      );
      expect(stale.state, same(configuring));
      expect(stale.effects, isEmpty);

      final unhealthy = reduce(
        _running(),
        HeartbeatMissed(operationId: _operation1, driverGeneration: 1),
      );
      expect(unhealthy.state.phase, VmPhase.crashed);
      expect(unhealthy.state.lastError?.code, ErrorCode.driverUnhealthy);
      expect(unhealthy.effects.whereType<KillDriver>(), hasLength(1));

      final disconnected = reduce(
        _running(),
        DriverChannelClosed(
          operationId: _operation1,
          driverGeneration: 1,
          error: _driverError,
        ),
      );
      expect(disconnected.state.activeDriverGeneration, isNull);
      expect(disconnected.state.retryState.retryScheduled, isTrue);
      expect(disconnected.effects.last, isA<ReleaseHostLease>());
    });

    test('operation cancellation is terminal and converges toward stopped', () {
      final spawning = _spawning();

      final cancelled = reduce(spawning, OperationCancelled(_operation1));
      expect(cancelled.state.desiredState, DesiredState.stopped);
      expect(cancelled.state.phase, VmPhase.stopping);
      expect(cancelled.state.currentOperation?.state, OperationState.cancelled);
      expect(
        cancelled.effects.whereType<CompleteOperation>().single.cancelled,
        isTrue,
      );
      expect(cancelled.effects.last, isA<KillDriver>());

      final repeated = reduce(cancelled.state, OperationCancelled(_operation1));
      expect(repeated.state, same(cancelled.state));
      expect(repeated.effects, isEmpty);

      final lateSuccess = reduce(
        cancelled.state,
        DriverCommandSucceeded(
          operationId: _operation1,
          driverGeneration: 1,
          command: RuntimeCommandKind.configure,
        ),
      );
      expect(lateSuccess.state, same(cancelled.state));
      expect(lateSuccess.effects, isEmpty);
    });

    test(
      'automatic recovery owns a fresh operation until the stable window',
      () {
        var transition = reduce(
          _running(policy: RestartPolicy.onFailure),
          DriverExited(
            operationId: _operation1,
            driverGeneration: 1,
            cleanShutdown: false,
            error: _driverError,
          ),
        );
        expect(transition.state.currentOperation, isNull);
        expect(
          transition.effects.whereType<CreateRecoveryOperation>(),
          hasLength(1),
        );
        transition = reduce(transition.state, HostLeaseReleased(_operation1));
        transition = reduce(
          transition.state,
          RecoveryOperationCreated(
            operationId: _operation2,
            failedDriverGeneration: 1,
          ),
        );
        expect(
          transition.state.currentOperation?.kind,
          VmOperationKind.recovery,
        );
        expect(transition.effects.last, isA<ScheduleRetry>());
        transition = reduce(
          transition.state,
          RetryTimerFired(operationId: _operation2, driverGeneration: 1),
        );
        transition = reduce(transition.state, HostLeaseAcquired(_operation2));
        transition = reduce(
          transition.state,
          DriverSpawned(operationId: _operation2, driverGeneration: 2),
        );
        transition = reduce(
          transition.state,
          DriverHandshakeCompleted(
            operationId: _operation2,
            driverGeneration: 2,
          ),
        );
        transition = reduce(
          transition.state,
          DriverCommandSucceeded(
            operationId: _operation2,
            driverGeneration: 2,
            command: RuntimeCommandKind.configure,
          ),
        );
        transition = reduce(
          transition.state,
          VmStateChanged(
            operationId: _operation2,
            driverGeneration: 2,
            phase: VmPhase.running,
          ),
        );
        expect(
          transition.state.currentOperation?.state,
          OperationState.running,
        );
        expect(
          transition.effects.whereType<ScheduleStableReset>(),
          hasLength(1),
        );
        transition = reduce(
          transition.state,
          StableWindowElapsed(operationId: _operation2, driverGeneration: 2),
        );
        expect(
          transition.state.currentOperation?.state,
          OperationState.succeeded,
        );
        expect(transition.state.retryState.attempts, 0);
        expect(transition.effects.whereType<CompleteOperation>(), hasLength(1));
      },
    );

    test('stop cancels a scheduled recovery and completes', () {
      var transition = reduce(
        _running(policy: RestartPolicy.onFailure),
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      );
      transition = reduce(transition.state, HostLeaseReleased(_operation1));
      transition = reduce(
        transition.state,
        RecoveryOperationCreated(
          operationId: _operation2,
          failedDriverGeneration: 1,
        ),
      );
      transition = reduce(transition.state, StopRequested(_operation3));
      expect(transition.state.phase, VmPhase.stopped);
      expect(transition.state.retryState.retryScheduled, isFalse);
      expect(
        transition.state.currentOperation?.state,
        OperationState.succeeded,
      );
      expect(transition.effects.whereType<CancelRetry>(), hasLength(1));
    });

    test('a failed initial start with restart never fails its operation', () {
      var transition = reduce(
        _spawning(policy: RestartPolicy.never),
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      );
      expect(transition.state.currentOperation?.state, OperationState.failed);
      expect(transition.effects.whereType<FailOperation>(), hasLength(1));
      transition = reduce(transition.state, HostLeaseReleased(_operation1));
      expect(transition.state.phase, VmPhase.failed);
      expect(transition.effects.whereType<CompleteOperation>(), isEmpty);
    });

    test('a failed replacement generation uses retry policy and budget', () {
      var transition = reduce(_running(), RestartRequested(_operation2));
      transition = reduce(
        transition.state,
        DriverExited(
          operationId: _operation2,
          driverGeneration: 1,
          cleanShutdown: true,
        ),
      );
      transition = reduce(transition.state, HostLeaseReleased(_operation2));
      transition = reduce(transition.state, HostLeaseAcquired(_operation2));
      transition = reduce(
        transition.state,
        DriverExited(
          operationId: _operation2,
          driverGeneration: 2,
          cleanShutdown: false,
          error: _driverError,
        ),
      );
      expect(transition.state.phase, VmPhase.crashed);
      expect(transition.state.retryState.retryScheduled, isTrue);
      expect(transition.state.currentOperation?.state, OperationState.running);
    });

    test('running applies only the spec captured by its driver generation', () {
      var transition = reduce(
        _starting(),
        const SpecUpdated(
          specGeneration: 2,
          restartPolicy: RestartPolicy.onFailure,
          restartRequired: true,
        ),
      );
      transition = reduce(
        transition.state,
        VmStateChanged(
          operationId: _operation1,
          driverGeneration: 1,
          phase: VmPhase.running,
        ),
      );
      expect(transition.state.observedGeneration, 1);
      expect(transition.state.restartRequired, isTrue);
      transition = reduce(
        transition.state,
        const SpecUpdated(
          specGeneration: 3,
          restartPolicy: RestartPolicy.always,
          restartRequired: false,
        ),
      );
      expect(transition.state.restartRequired, isTrue);
    });

    test('deletion fails superseded admission and waits for file removal', () {
      var transition = reduce(_initial(), StartRequested(_operation1));
      transition = reduce(transition.state, DeleteRequested(_operation2));
      expect(
        transition.effects.whereType<FailOperation>().single.operationId,
        _operation1,
      );
      transition = reduce(transition.state, HostLeaseReleased(_operation2));
      expect(transition.state.deletionState, VmDeletionState.removingFiles);
      expect(transition.effects.last, isA<RemoveManagedFiles>());
      transition = reduce(transition.state, ManagedFilesRemoved(_operation2));
      expect(transition.state.deletionState, VmDeletionState.deleted);
      expect(
        transition.state.currentOperation?.state,
        OperationState.succeeded,
      );
    });

    test(
      'same-generation phase regressions and wrong running events are ignored',
      () {
        final running = _running();
        final regressed = reduce(
          running,
          VmStateChanged(
            operationId: _operation1,
            driverGeneration: 1,
            phase: VmPhase.starting,
          ),
        );
        expect(regressed.state, same(running));
        expect(regressed.effects, isEmpty);
        final stopping = reduce(running, StopRequested(_operation2));
        final wrongRunning = reduce(
          stopping.state,
          VmStateChanged(
            operationId: _operation2,
            driverGeneration: 1,
            phase: VmPhase.running,
          ),
        );
        expect(wrongRunning.state.phase, VmPhase.stopping);
        expect(wrongRunning.effects, isEmpty);
      },
    );

    test('cancelled start exit converges to stopped without failure', () {
      var transition = reduce(_spawning(), OperationCancelled(_operation1));
      transition = reduce(
        transition.state,
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      );
      expect(transition.state.phase, VmPhase.stopped);
      transition = reduce(transition.state, HostLeaseReleased(_operation1));
      expect(transition.state.phase, VmPhase.stopped);
      expect(
        transition.state.currentOperation?.state,
        OperationState.cancelled,
      );
    });

    test(
      'repeated stop and restart return conflicts without duplicate runtime effects',
      () {
        final stopping = reduce(_running(), StopRequested(_operation2));
        final repeatedStop = reduce(stopping.state, StopRequested(_operation3));
        expect(repeatedStop.effects.whereType<FailOperation>(), hasLength(1));
        expect(repeatedStop.effects.whereType<StopRuntime>(), isEmpty);
        final restarting = reduce(_running(), RestartRequested(_operation2));
        final repeatedRestart = reduce(
          restarting.state,
          RestartRequested(_operation3),
        );
        expect(
          repeatedRestart.effects.whereType<FailOperation>(),
          hasLength(1),
        );
        expect(repeatedRestart.effects.whereType<StopRuntime>(), isEmpty);
      },
    );

    test(
      'effect failures are representable and unhealthy repeats are idempotent',
      () {
        final spawnFailure = reduce(
          _spawning(policy: RestartPolicy.never),
          DriverSpawnFailed(
            operationId: _operation1,
            driverGeneration: 1,
            error: _driverError,
          ),
        );
        expect(
          spawnFailure.state.currentOperation?.state,
          OperationState.failed,
        );
        final unhealthy = reduce(
          _running(),
          HeartbeatMissed(operationId: _operation1, driverGeneration: 1),
        );
        final repeated = reduce(
          unhealthy.state,
          HeartbeatMissed(operationId: _operation1, driverGeneration: 1),
        );
        expect(repeated.effects, isEmpty);
        var releaseFailure = reduce(_running(), StopRequested(_operation2));
        releaseFailure = reduce(
          releaseFailure.state,
          DriverExited(
            operationId: _operation2,
            driverGeneration: 1,
            cleanShutdown: true,
          ),
        );
        releaseFailure = reduce(
          releaseFailure.state,
          HostLeaseReleaseFailed(_operation2, _driverError),
        );
        expect(releaseFailure.state.phase, VmPhase.failed);
        expect(releaseFailure.effects.whereType<FailOperation>(), hasLength(1));
      },
    );

    test('delete reconcile resumes managed file cleanup', () {
      final deleting = _initial().copyWith(
        desiredState: DesiredState.stopped,
        phase: VmPhase.deleting,
        deletionState: VmDeletionState.deleting,
        currentOperation: VmControllerOperation(
          id: _operation2,
          kind: VmOperationKind.delete,
          state: OperationState.running,
        ),
      );
      final transition = reduce(deleting, const ReconcileRequested());
      expect(transition.state.deletionState, VmDeletionState.removingFiles);
      expect(transition.effects, [isA<RemoveManagedFiles>()]);
    });

    test('budget exhaustion creates and fails a fresh recovery operation', () {
      final runningAtBudget = _running().copyWith(
        retryState: VmRetryState(attempts: 1, maxAttempts: 1),
      );
      var transition = reduce(
        runningAtBudget,
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      );
      expect(
        transition.effects.whereType<CreateRecoveryOperation>(),
        hasLength(1),
      );
      transition = reduce(transition.state, HostLeaseReleased(_operation1));
      transition = reduce(
        transition.state,
        RecoveryOperationCreated(
          operationId: _operation2,
          failedDriverGeneration: 1,
        ),
      );
      expect(transition.state.phase, VmPhase.failed);
      expect(transition.state.currentOperation?.state, OperationState.failed);
      expect(transition.effects.whereType<FailOperation>(), hasLength(1));
      expect(
        transition.effects.whereType<EmitEvent>().single.type,
        'vm.permanent_failure',
      );
    });

    test('retry accounting expires failures outside the sliding window', () {
      final now = DateTime.utc(2026, 9, 4, 12);
      final state = _running().copyWith(
        retryState: VmRetryState(
          attempts: 2,
          maxAttempts: 2,
          failureTimes: [
            now.subtract(const Duration(minutes: 10)),
            now.subtract(const Duration(minutes: 9)),
          ],
        ),
      );
      final transition = reduce(
        state,
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
          occurredAt: now,
        ),
      );
      expect(transition.state.retryState.attempts, 1);
      expect(transition.state.retryState.failureTimes, [now]);
      expect(transition.state.retryState.retryScheduled, isTrue);
      expect(
        transition.effects.whereType<CreateRecoveryOperation>(),
        hasLength(1),
      );
    });

    test('spec updates preserve an already scheduled recovery', () {
      var transition = reduce(
        _running(),
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      );
      transition = reduce(
        transition.state,
        const SpecUpdated(
          specGeneration: 2,
          restartPolicy: RestartPolicy.onFailure,
          restartRequired: true,
        ),
      );
      expect(transition.state.retryState.retryScheduled, isTrue);
      expect(transition.effects.whereType<CancelRetry>(), isEmpty);
    });

    test(
      'stop during lease release cancels recovery and release still completes',
      () {
        var transition = reduce(
          _running(),
          DriverExited(
            operationId: _operation1,
            driverGeneration: 1,
            cleanShutdown: false,
            error: _driverError,
          ),
        );
        transition = reduce(transition.state, StopRequested(_operation3));
        expect(
          transition.state.currentOperation?.state,
          OperationState.succeeded,
        );
        expect(transition.state.leaseState, VmLeaseState.releasing);
        transition = reduce(transition.state, HostLeaseReleased(_operation1));
        expect(transition.state.leaseState, VmLeaseState.none);
        expect(transition.state.retryState.retryScheduled, isFalse);
        expect(transition.effects.whereType<ScheduleRetry>(), isEmpty);
      },
    );

    test('running clears restart required when the active spec is current', () {
      final state = _starting().copyWith(
        specGeneration: 2,
        activeSpecGeneration: 2,
        restartRequired: true,
      );
      final transition = reduce(
        state,
        VmStateChanged(
          operationId: _operation1,
          driverGeneration: 1,
          phase: VmPhase.running,
        ),
      );
      expect(transition.state.observedGeneration, 2);
      expect(transition.state.restartRequired, isFalse);
    });

    test('delete from scheduled recovery fails the recovery operation', () {
      var transition = reduce(
        _running(),
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      );
      transition = reduce(transition.state, HostLeaseReleased(_operation1));
      transition = reduce(
        transition.state,
        RecoveryOperationCreated(
          operationId: _operation2,
          failedDriverGeneration: 1,
        ),
      );
      transition = reduce(transition.state, DeleteRequested(_operation3));
      expect(
        transition.effects.whereType<FailOperation>().single.operationId,
        _operation2,
      );
      expect(transition.state.deletionState, VmDeletionState.removingFiles);
    });

    test('start and restart wait for an in-flight lease release', () {
      final releasing = reduce(
        _running(),
        DriverExited(
          operationId: _operation1,
          driverGeneration: 1,
          cleanShutdown: false,
          error: _driverError,
        ),
      ).state;
      var started = reduce(releasing, StartRequested(_operation2));
      expect(started.state.leaseState, VmLeaseState.releasing);
      started = reduce(started.state, HostLeaseReleased(_operation1));
      expect(started.state.leaseState, VmLeaseState.acquiring);
      expect(started.effects.last, isA<AcquireHostLease>());

      var restarted = reduce(releasing, RestartRequested(_operation3));
      expect(restarted.state.leaseState, VmLeaseState.releasing);
      restarted = reduce(restarted.state, HostLeaseReleased(_operation1));
      expect(restarted.state.leaseState, VmLeaseState.acquiring);
      expect(restarted.effects.last, isA<AcquireHostLease>());
    });

    test('reconcile never reuses a retained terminal operation', () {
      final restored = _running().copyWith(
        phase: VmPhase.defined,
        clearActiveDriverGeneration: true,
        clearActiveSpecGeneration: true,
        clearDriverOperationId: true,
        leaseState: VmLeaseState.none,
      );
      final transition = reduce(restored, const ReconcileRequested());
      expect(
        transition.effects.whereType<CreateRecoveryOperation>(),
        hasLength(1),
      );
      expect(transition.effects.whereType<AcquireHostLease>(), isEmpty);
    });

    test(
      'superseding operations correlate old lease release success and failure',
      () {
        final releasing = reduce(
          _running(),
          DriverExited(
            operationId: _operation1,
            driverGeneration: 1,
            cleanShutdown: false,
            error: _driverError,
          ),
        ).state;

        var started = reduce(releasing, StartRequested(_operation2));
        started = reduce(
          started.state,
          HostLeaseReleaseFailed(_operation1, _driverError),
        );
        expect(started.state.phase, VmPhase.failed);
        expect(
          started.effects.whereType<FailOperation>().single.operationId,
          _operation2,
        );

        var stopped = reduce(releasing, StopRequested(_operation2));
        stopped = reduce(
          stopped.state,
          HostLeaseReleaseFailed(_operation1, _driverError),
        );
        expect(stopped.state.leaseState, VmLeaseState.held);
        expect(
          stopped.effects.whereType<EmitEvent>().single.operationId,
          _operation2,
        );

        var deleting = reduce(releasing, DeleteRequested(_operation2));
        deleting = reduce(deleting.state, HostLeaseReleased(_operation1));
        expect(
          deleting.effects.whereType<RemoveManagedFiles>().single.operationId,
          _operation2,
        );
        deleting = reduce(deleting.state, ManagedFilesRemoved(_operation2));
        expect(deleting.state.deletionState, VmDeletionState.deleted);
      },
    );

    test('seeded command sequences preserve controller invariants', () {
      for (var seed = 0; seed < 32; seed++) {
        final random = Random(0x5a17 + seed);
        var operationSequence = 10;
        var state = _initial();

        for (var step = 0; step < 250; step++) {
          final before = state;
          final terminalBefore = before.currentOperation;
          final correlation =
              before.driverOperationId ??
              before.currentOperation?.id ??
              _operation(900);
          final generation =
              before.activeDriverGeneration ?? before.driverGeneration;
          final command = switch (random.nextInt(20)) {
            0 => StartRequested(_operation(operationSequence++)),
            1 => StopRequested(_operation(operationSequence++)),
            2 => RestartRequested(_operation(operationSequence++)),
            3 when step > 200 => DeleteRequested(
              _operation(operationSequence++),
            ),
            3 || 4 => const ReconcileRequested(),
            5 => SpecUpdated(
              specGeneration: before.specGeneration + 1,
              restartPolicy: RestartPolicy
                  .values[random.nextInt(RestartPolicy.values.length)],
              restartRequired: random.nextBool(),
            ),
            6 => HostLeaseAcquired(correlation),
            7 => HostLeaseReleased(correlation),
            8 => HostLeaseFailed(operationId: correlation, error: _driverError),
            9 => DriverSpawned(
              operationId: correlation,
              driverGeneration: generation,
            ),
            10 => DriverHandshakeCompleted(
              operationId: correlation,
              driverGeneration: generation,
            ),
            11 => DriverCommandSucceeded(
              operationId: correlation,
              driverGeneration: generation,
              command: RuntimeCommandKind
                  .values[random.nextInt(RuntimeCommandKind.values.length)],
            ),
            12 => DriverCommandFailed(
              operationId: correlation,
              driverGeneration: random.nextBool()
                  ? generation
                  : generation + 100,
              command: RuntimeCommandKind
                  .values[random.nextInt(RuntimeCommandKind.values.length)],
              error: _driverError,
            ),
            13 => VmStateChanged(
              operationId: correlation,
              driverGeneration: generation,
              phase: const [
                VmPhase.starting,
                VmPhase.running,
                VmPhase.stopping,
                VmPhase.stopped,
                VmPhase.crashed,
                VmPhase.failed,
              ][random.nextInt(6)],
            ),
            14 => DriverExited(
              operationId: correlation,
              driverGeneration: generation,
              cleanShutdown: random.nextBool(),
              error: random.nextBool() ? null : _driverError,
            ),
            15 => DriverChannelClosed(
              operationId: correlation,
              driverGeneration: generation,
              error: _driverError,
            ),
            16 => HeartbeatMissed(
              operationId: correlation,
              driverGeneration: generation,
            ),
            17 => RetryTimerFired(
              operationId: correlation,
              driverGeneration: before.driverGeneration,
            ),
            18 => OperationCancelled(correlation),
            _ => DriverExited(
              operationId: _operation(950),
              driverGeneration: generation + 100,
              cleanShutdown: false,
              error: _driverError,
            ),
          };

          final transition = reduce(before, command);
          state = transition.state;

          expect(
            state.activeDriverGeneration == null ||
                state.activeDriverGeneration == state.driverGeneration,
            isTrue,
            reason: 'seed=$seed step=$step keeps at most one generation',
          );
          expect(
            state.observedGeneration,
            lessThanOrEqualTo(state.specGeneration),
          );
          expect(
            state.retryState.attempts,
            lessThanOrEqualTo(state.retryState.maxAttempts),
          );
          if (state.deletionState == VmDeletionState.deleted) {
            expect(state.desiredState, DesiredState.stopped);
            expect(state.activeDriverGeneration, isNull);
          }
          if (state.desiredState == DesiredState.stopped ||
              state.deletionState != VmDeletionState.active) {
            expect(
              transition.effects.whereType<SpawnDriver>(),
              isEmpty,
              reason:
                  'seed=$seed step=$step command=${command.runtimeType} '
                  'desired=${state.desiredState} deletion=${state.deletionState}',
            );
          }
          for (final effect in transition.effects) {
            expect(effect.vmId, _vmId);
          }
          for (final effect in transition.effects.whereType<SpawnDriver>()) {
            expect(effect.driverGeneration, state.activeDriverGeneration);
            expect(state.desiredState, DesiredState.running);
          }
          if (terminalBefore != null &&
              terminalBefore.isTerminal &&
              state.currentOperation?.id == terminalBefore.id) {
            expect(state.currentOperation?.state, terminalBefore.state);
          }
        }
      }
    });
  });
}

VmControllerState _initial({RestartPolicy policy = RestartPolicy.onFailure}) =>
    VmControllerState.initial(
      vmId: _vmId,
      specGeneration: 1,
      restartPolicy: policy,
    );

VmControllerState _spawning({RestartPolicy policy = RestartPolicy.onFailure}) {
  final starting = reduce(
    _initial(policy: policy),
    StartRequested(_operation1),
  );
  return reduce(starting.state, HostLeaseAcquired(_operation1)).state;
}

VmControllerState _starting({RestartPolicy policy = RestartPolicy.onFailure}) {
  var state = _spawning(policy: policy);
  state = reduce(
    state,
    DriverSpawned(operationId: _operation1, driverGeneration: 1),
  ).state;
  state = reduce(
    state,
    DriverHandshakeCompleted(operationId: _operation1, driverGeneration: 1),
  ).state;
  state = reduce(
    state,
    DriverCommandSucceeded(
      operationId: _operation1,
      driverGeneration: 1,
      command: RuntimeCommandKind.configure,
    ),
  ).state;
  return state;
}

VmControllerState _running({RestartPolicy policy = RestartPolicy.onFailure}) {
  final state = _starting(policy: policy);
  return reduce(
    state,
    VmStateChanged(
      operationId: _operation1,
      driverGeneration: 1,
      phase: VmPhase.running,
    ),
  ).state;
}

final _vmId = VmId('vm_01J00000000000000000000000');
final _operation1 = OperationId('op_01J00000000000000000000000');
final _operation2 = OperationId('op_01J00000000000000000000001');
final _operation3 = OperationId('op_01J00000000000000000000002');
final _driverError = OperationError(
  code: ErrorCode.driverStartFailed,
  message: 'driver exited',
  retryable: true,
  details: JsonObjectValue.empty,
);

OperationId _operation(int value) {
  const crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final high = crockford[(value ~/ 32) % 32];
  final low = crockford[value % 32];
  return OperationId('op_01J000000000000000000000$high$low');
}
