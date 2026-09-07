import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/vm_controller.dart';
import 'package:gaovmd/src/vm_controller_reducer.dart';
import 'package:test/test.dart';

void main() {
  test('queued adoption commits in its enqueue caller Zone', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final marker = Object();
    final controller = VmController(
      initialState: _state(),
      effectRunner: _Runner(
        onRun: (effect) async {
          if (effect is AcquireHostLease) {
            started.complete();
            await release.future;
          }
        },
      ),
    );
    final command = StartRequested(OperationId.generate());
    await controller.adopt(
      _Action((state) async {
        final transition = reduce(state, command);
        return VmIntentAdoption(
          disposition: VmIntentAdoptionDisposition.adopted,
          state: transition.state,
          remainingEffects: transition.effects,
          sourceCommand: command,
        );
      }),
    );
    await started.future;
    final next = runZoned(
      () => controller.adopt(
        _Action((state) async {
          expect(Zone.current[marker], 'enqueue transaction context');
          return VmIntentAdoption(
            disposition: VmIntentAdoptionDisposition.deferred,
            state: state,
            remainingEffects: const [],
          );
        }),
      ),
      zoneValues: {marker: 'enqueue transaction context'},
    );
    release.complete();
    expect(await next, VmIntentAdoptionDisposition.deferred);
    await controller.shutdown();
  });

  test(
    'pending or rolled-back adoption cannot cancel the live retry timer',
    () async {
      final scheduler = _Timers();
      final controller = VmController(
        initialState: _state(),
        effectRunner: _Runner(),
        timerScheduler: scheduler,
      );
      await controller.adopt(
        _Action(
          (state) async => VmIntentAdoption(
            disposition: VmIntentAdoptionDisposition.adopted,
            state: state.copyWith(
              retryState: VmRetryState(
                scheduledDelay: const Duration(seconds: 10),
              ),
            ),
            remainingEffects: [
              ScheduleRetry(
                vmId: state.vmId,
                operationId: OperationId.generate(),
                driverGeneration: 1,
                delay: const Duration(seconds: 10),
              ),
            ],
          ),
        ),
      );
      await controller.waitUntilIdle();
      expect(controller.hasPendingTimers, isTrue);
      final before = controller.state;
      final started = Completer<void>();
      final commit = Completer<VmIntentAdoption>();
      final adoption = controller.adopt(
        _Action((state) {
          started.complete();
          return commit.future;
        }),
      );
      final failed = expectLater(adoption, throwsStateError);
      await started.future;
      expect(controller.hasPendingTimers, isTrue);
      commit.completeError(StateError('rollback'));
      await failed;
      expect(controller.state, same(before));
      expect(controller.hasPendingTimers, isTrue);
      await controller.adopt(
        _Action(
          (state) async => VmIntentAdoption(
            disposition: VmIntentAdoptionDisposition.adopted,
            state: state.copyWith(retryState: VmRetryState()),
            remainingEffects: const [],
          ),
        ),
      );
      expect(controller.hasPendingTimers, isFalse);
      await controller.shutdown();
    },
  );

  test('adoption and ordinary commands share the external FIFO', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final runner = _Runner(
      onRun: (effect) async {
        if (effect is PersistVm && !started.isCompleted) {
          started.complete();
          await release.future;
        }
      },
    );
    final controller = VmController(
      initialState: _state(),
      effectRunner: runner,
    );
    final first = controller.submit(
      const SpecUpdated(
        specGeneration: 2,
        restartPolicy: RestartPolicy.never,
        restartRequired: true,
      ),
    );
    await started.future;
    var adoptionStarted = false;
    final middle = controller.adopt(
      _Action((state) async {
        adoptionStarted = true;
        expect(state.specGeneration, 2);
        return VmIntentAdoption(
          disposition: VmIntentAdoptionDisposition.adopted,
          state: state.copyWith(appliedIntentRevision: 1),
          remainingEffects: const [],
        );
      }),
    );
    final last = controller.submit(
      const SpecUpdated(
        specGeneration: 3,
        restartPolicy: RestartPolicy.never,
        restartRequired: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(adoptionStarted, isFalse);
    release.complete();
    expect((await first).appliedIntentRevision, 0);
    expect(await middle, VmIntentAdoptionDisposition.adopted);
    expect((await last).appliedIntentRevision, 1);
    expect(controller.state.specGeneration, 3);
    await controller.shutdown();
  });

  for (final disposition in [
    VmIntentAdoptionDisposition.duplicate,
    VmIntentAdoptionDisposition.deferred,
  ]) {
    test('$disposition leaves execution and observers unchanged', () async {
      final initial = _state();
      final observed = <VmControllerState>[];
      final runner = _Runner();
      final controller = VmController(
        initialState: initial,
        effectRunner: runner,
        onStateChanged: observed.add,
      );
      expect(
        await controller.adopt(
          _Action(
            (state) async => VmIntentAdoption(
              disposition: disposition,
              state: state,
              remainingEffects: const [],
            ),
          ),
        ),
        disposition,
      );
      await controller.waitUntilIdle();
      expect(controller.state, same(initial));
      expect(observed, isEmpty);
      expect(runner.effects, isEmpty);
      await controller.shutdown();
    });
  }

  test(
    'shutdown rejects queued adoption and waits for active commit',
    () async {
      final initial = _state();
      final observed = <VmControllerState>[];
      final runner = _Runner();
      final controller = VmController(
        initialState: initial,
        effectRunner: runner,
        onStateChanged: observed.add,
      );
      final started = Completer<void>();
      final commit = Completer<VmIntentAdoption>();
      final active = controller.adopt(
        _Action((state) {
          started.complete();
          return commit.future;
        }),
      );
      await started.future;
      final queued = controller.adopt(
        _Action((_) async => throw StateError('must not execute')),
      );
      final rejected = expectLater(
        queued,
        throwsA(isA<VmControllerClosedException>()),
      );
      var stopped = false;
      final shutdown = controller.shutdown().then((_) => stopped = true);
      await rejected;
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      expect(controller.state, same(initial));
      expect(observed, isEmpty);
      expect(runner.effects, isEmpty);
      commit.complete(
        VmIntentAdoption(
          disposition: VmIntentAdoptionDisposition.adopted,
          state: initial.copyWith(appliedIntentRevision: 1),
          remainingEffects: const [],
        ),
      );
      expect(await active, VmIntentAdoptionDisposition.adopted);
      await shutdown;
      expect(controller.state.appliedIntentRevision, 1);
      await expectLater(
        controller.adopt(
          _Action((_) async => throw StateError('must not execute')),
        ),
        throwsA(isA<VmControllerClosedException>()),
      );
    },
  );

  test(
    'shutdown bounds active commit wait without abandoning adoption',
    () async {
      final initial = _state();
      final controller = VmController(
        initialState: initial,
        effectRunner: _Runner(),
        shutdownTimeout: const Duration(milliseconds: 20),
      );
      final started = Completer<void>();
      final commit = Completer<VmIntentAdoption>();
      final active = controller.adopt(
        _Action((state) {
          started.complete();
          return commit.future;
        }),
      );
      await started.future;
      await expectLater(
        controller.shutdown(),
        throwsA(isA<VmControllerShutdownException>()),
      );
      expect(controller.state, same(initial));
      commit.complete(
        VmIntentAdoption(
          disposition: VmIntentAdoptionDisposition.adopted,
          state: initial.copyWith(appliedIntentRevision: 1),
          remainingEffects: const [],
        ),
      );
      expect(await active, VmIntentAdoptionDisposition.adopted);
      await controller.shutdown();
      expect(controller.state.appliedIntentRevision, 1);
    },
  );

  test(
    'adoption ACK precedes blocked effects without completing submit',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final runner = _Runner(
        onRun: (effect) async {
          if (effect is AcquireHostLease) {
            started.complete();
            await release.future;
          }
        },
      );
      final controller = VmController(
        initialState: _state(),
        effectRunner: runner,
      );
      final command = StartRequested(OperationId.generate());
      final disposition = await controller
          .adopt(
            _Action((state) async {
              final transition = reduce(
                state.copyWith(appliedIntentRevision: 1),
                command,
              );
              return VmIntentAdoption(
                disposition: VmIntentAdoptionDisposition.adopted,
                state: transition.state,
                remainingEffects: transition.effects
                    .where((effect) => effect is! PersistVm)
                    .toList(),
                sourceCommand: command,
              );
            }),
          )
          .timeout(const Duration(seconds: 1));
      expect(disposition, VmIntentAdoptionDisposition.adopted);
      await started.future;
      expect(controller.state.appliedIntentRevision, 1);
      var submitted = false;
      final submit = controller
          .submit(
            const SpecUpdated(
              specGeneration: 2,
              restartPolicy: RestartPolicy.never,
              restartRequired: true,
            ),
          )
          .then((_) => submitted = true);
      await Future<void>.delayed(Duration.zero);
      expect(submitted, isFalse);
      expect(controller.isIdle, isFalse);
      release.complete();
      await submit;
      expect(controller.state.specGeneration, 2);
      await controller.shutdown();
    },
  );

  test(
    'rollback preserves execution and leaves adoption gate reusable',
    () async {
      final initial = _state();
      final observed = <VmControllerState>[];
      final runner = _Runner();
      final controller = VmController(
        initialState: initial,
        effectRunner: runner,
        onStateChanged: observed.add,
      );
      final started = Completer<void>();
      final commit = Completer<VmIntentAdoption>();
      final adoption = controller.adopt(
        _Action((state) {
          expect(state, same(initial));
          started.complete();
          return commit.future;
        }),
      );
      final failed = expectLater(adoption, throwsStateError);
      await started.future;
      expect(controller.state, same(initial));
      expect(observed, isEmpty);
      expect(runner.effects, isEmpty);
      commit.completeError(StateError('transaction rolled back'));
      await failed;
      expect(controller.state, same(initial));
      expect(observed, isEmpty);
      expect(runner.effects, isEmpty);
      expect(
        await controller.adopt(
          _Action(
            (state) async => VmIntentAdoption(
              disposition: VmIntentAdoptionDisposition.adopted,
              state: state.copyWith(appliedIntentRevision: 1),
              remainingEffects: const [],
            ),
          ),
        ),
        VmIntentAdoptionDisposition.adopted,
      );
      expect(controller.state.appliedIntentRevision, 1);
      expect(observed, hasLength(1));
      await controller.shutdown();
    },
  );
}

VmControllerState _state() => VmControllerState.initial(
  vmId: VmId.generate(),
  specGeneration: 1,
  restartPolicy: RestartPolicy.never,
);

final class _Action implements VmIntentAdoptionAction {
  _Action(this.action);
  final Future<VmIntentAdoption> Function(VmControllerState) action;
  @override
  Future<VmIntentAdoption> commit(VmControllerState state) => action(state);
}

final class _Runner implements VmEffectRunner {
  _Runner({this.onRun});
  final Future<void> Function(VmEffect)? onRun;
  final effects = <VmEffect>[];
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    effects.add(effect);
    await onRun?.call(effect);
    return null;
  }
}

final class _Timers implements VmTimerScheduler {
  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) => _Timer();
}

final class _Timer implements VmTimerHandle {
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
}
