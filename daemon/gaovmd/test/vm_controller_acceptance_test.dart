import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/vm_controller.dart';
import 'package:gaovmd/src/vm_controller_reducer.dart';
import 'package:test/test.dart';

void main() {
  test('acceptance waits for an active durable batch to finish', () async {
    final runner = _BlockedDurable();
    final controller = VmController(
      initialState: _state(),
      effectRunner: runner,
    );
    final executing = controller.submit(
      const SpecUpdated(
        specGeneration: 2,
        restartPolicy: RestartPolicy.never,
        restartRequired: true,
      ),
    );
    await runner.started.future;
    var accepted = false;
    final acceptance = controller.accept(
      _Acceptance(() async {
        accepted = true;
        return VmAcceptedIntent(intentRevision: 1, result: 'committed');
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(accepted, isFalse);
    runner.release.complete();
    await acceptance;
    await executing;
    await controller.shutdown();
  });

  test(
    'timed-out acceptance shutdown retains work for a later retry',
    () async {
      final controller = VmController(
        initialState: _state(),
        effectRunner: _BlockedAcquire(),
        shutdownTimeout: const Duration(milliseconds: 20),
      );
      final started = Completer<void>();
      final commit = Completer<VmAcceptedIntent<String>>();
      final accepted = controller.accept(
        _Acceptance(() {
          started.complete();
          return commit.future;
        }),
      );
      await started.future;
      await expectLater(
        controller.shutdown(),
        throwsA(isA<VmControllerShutdownException>()),
      );
      commit.complete(VmAcceptedIntent(intentRevision: 1, result: 'committed'));
      expect(await accepted, 'committed');
      await controller.shutdown();
      expect(controller.acceptedIntentRevision, 1);
    },
  );

  test('acceptance commits while external acquisition is pending', () async {
    final runner = _BlockedAcquire();
    final controller = VmController(
      initialState: _state(),
      effectRunner: runner,
    );
    final execution = controller.submit(StartRequested(OperationId.generate()));
    await runner.started.future;
    final before = controller.state;

    final result = await controller
        .accept(
          _Acceptance(
            () async => VmAcceptedIntent(intentRevision: 2, result: 'accepted'),
          ),
        )
        .timeout(const Duration(seconds: 1));

    expect(result, 'accepted');
    expect(controller.acceptedIntentRevision, 2);
    expect(controller.state, same(before));
    runner.release.complete();
    await execution;
    await controller.shutdown();
  });

  test(
    'failed acceptance leaves revision unchanged and does not poison gate',
    () async {
      final controller = VmController(
        initialState: _state(),
        effectRunner: _BlockedAcquire(),
      );
      await expectLater(
        controller.accept(
          _Acceptance(() async => throw StateError('rollback')),
        ),
        throwsStateError,
      );
      expect(controller.acceptedIntentRevision, 0);
      await controller.accept(
        _Acceptance(
          () async => VmAcceptedIntent(intentRevision: 3, result: 'new'),
        ),
      );
      await controller.accept(
        _Acceptance(
          () async => VmAcceptedIntent(intentRevision: 1, result: 'replay'),
        ),
      );
      expect(controller.acceptedIntentRevision, 3);
      await controller.shutdown();
    },
  );

  test(
    'shutdown waits for committed acceptance and rejects subsequent work',
    () async {
      final controller = VmController(
        initialState: _state(),
        effectRunner: _BlockedAcquire(),
      );
      final started = Completer<void>();
      final commit = Completer<VmAcceptedIntent<String>>();
      final accepted = controller.accept(
        _Acceptance(() {
          started.complete();
          return commit.future;
        }),
      );
      await started.future;
      var closed = false;
      final shutdown = controller.shutdown().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      commit.complete(VmAcceptedIntent(intentRevision: 1, result: 'accepted'));
      await accepted;
      await shutdown;
      await expectLater(
        controller.accept(
          _Acceptance(
            () async => VmAcceptedIntent(intentRevision: 2, result: 'late'),
          ),
        ),
        throwsA(isA<VmControllerClosedException>()),
      );
    },
  );
}

VmControllerState _state() => VmControllerState.initial(
  vmId: VmId.generate(),
  specGeneration: 1,
  restartPolicy: RestartPolicy.never,
);

final class _Acceptance implements VmAcceptanceAction<String> {
  _Acceptance(this.action);
  final Future<VmAcceptedIntent<String>> Function() action;
  @override
  Future<VmAcceptedIntent<String>> commit(VmControllerState state) => action();
}

final class _BlockedAcquire implements VmEffectRunner {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    if (effect is AcquireHostLease) {
      started.complete();
      await release.future;
    }
    return null;
  }
}

final class _BlockedDurable implements TransactionalVmEffectRunner {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  bool isDurable(VmEffect effect) => true;
  @override
  Future<List<VmCommand?>> runDurableBatch(
    List<VmEffect> effects,
    VmControllerState state,
  ) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return List.filled(effects.length, null);
  }

  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async =>
      null;
}
