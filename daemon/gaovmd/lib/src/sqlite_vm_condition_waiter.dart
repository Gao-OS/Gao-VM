import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';

import 'durable_event_feed.dart';
import 'vm_application_service.dart';
import 'vm_repository.dart';

/// Reads committed VM status; durable events only trigger another status read.
final class SqliteVmConditionWaiter implements VmConditionWaiter {
  const SqliteVmConditionWaiter({
    required VmRepository repository,
    required DurableEventFeed events,
  }) : _repository = repository,
       _events = events;

  final VmRepository _repository;
  final DurableEventFeed _events;

  @override
  Future<DateTime> wait(VmWaitCommand command) {
    if (command.condition == VmWaitCondition.guestServiceReady) {
      return Future.error(
        UnsupportedError(
          'guest_service_ready requires persisted guest service status',
        ),
      );
    }
    final result = Completer<DateTime>();
    StreamSubscription<Event>? subscription;
    late Timer deadline;

    void cleanup() {
      deadline.cancel();
      final active = subscription;
      subscription = null;
      // Feed cancellation cannot extend the request deadline or replace its result.
      if (active != null) {
        unawaited(Future<void>.sync(active.cancel).catchError((Object _) {}));
      }
    }

    void fail(Object error, [StackTrace? stack]) {
      if (result.isCompleted) return;
      cleanup();
      result.completeError(error, stack);
    }

    deadline = Timer(command.timeout, () {
      fail(TimeoutException('VM condition wait timed out', command.timeout));
    });

    Future<void> readOnce() async {
      if (result.isCompleted) return;
      try {
        final vm = await _repository.get(command.vmId);
        if (result.isCompleted) return;
        if (vm == null) throw VmNotFoundException(command.vmId);
        final reached =
            vm.status.phase == VmPhase.running &&
            (command.condition == VmWaitCondition.runtimeRunning ||
                command.condition == VmWaitCondition.guestAgentReady &&
                    vm.status.guestAgent == GuestAgentState.ready);
        if (reached) {
          cleanup();
          result.complete(DateTime.now().toUtc());
        }
      } catch (error, stack) {
        fail(error, stack);
      }
    }

    Future<void>? checking;
    var dirty = false;
    Future<void> recheck() {
      if (result.isCompleted) return Future<void>.value();
      dirty = true;
      final active = checking;
      if (active != null) return active;
      final drained = Completer<void>();
      checking = drained.future;
      unawaited(() async {
        try {
          do {
            dirty = false;
            await readOnce();
          } while (dirty && !result.isCompleted);
        } finally {
          checking = null;
          drained.complete();
        }
      }());
      return drained.future;
    }

    Future<void> begin() async {
      try {
        final cursor = await _events.latestSequence();
        if (result.isCompleted) return;
        await recheck();
        if (result.isCompleted) return;
        subscription = _events
            .watch(after: cursor, vmId: command.vmId)
            .listen(
              (event) {
                if (event.sequence > cursor && event.vmId == command.vmId) {
                  unawaited(recheck());
                }
              },
              onError: (Object error, StackTrace stack) => fail(error, stack),
              onDone: () async {
                await recheck();
                if (!result.isCompleted) {
                  fail(
                    StateError(
                      'VM event feed closed before condition was reached',
                    ),
                  );
                }
              },
            );
        if (result.isCompleted) cleanup();
      } catch (error, stack) {
        fail(error, stack);
      }
    }

    unawaited(begin());
    return result.future;
  }
}
