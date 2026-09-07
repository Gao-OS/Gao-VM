import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';

import 'durable_event_feed.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';

/// Waits for committed terminal state; events are wakeups, never state truth.
final class SqliteOperationWaiter implements OperationWaiter {
  const SqliteOperationWaiter({
    required OperationRepository operations,
    required DurableEventFeed events,
  }) : _operations = operations,
       _events = events;

  final OperationRepository _operations;
  final DurableEventFeed _events;

  @override
  Future<Operation> wait(OperationWaitCommand command) {
    final result = Completer<Operation>();
    StreamSubscription<Event>? subscription;
    late Timer deadline;

    void cleanup() {
      deadline.cancel();
      final active = subscription;
      subscription = null;
      // Cancellation is requested immediately, but a broken feed's cleanup
      // cannot extend the caller's deadline or replace the operation result.
      if (active != null)
        unawaited(Future<void>.sync(active.cancel).catchError((Object _) {}));
    }

    void fail(Object error, [StackTrace? stackTrace]) {
      if (result.isCompleted) return;
      cleanup();
      result.completeError(error, stackTrace);
    }

    deadline = Timer(
      command.timeout,
      () => fail(TimeoutException('operation wait timed out', command.timeout)),
    );

    Future<void> readOnce() async {
      if (result.isCompleted) return;
      try {
        final operation = await _operations.get(command.operationId);
        if (result.isCompleted) return;
        if (operation == null)
          throw OperationNotFoundException(command.operationId);
        if (operation.state != OperationState.pending &&
            operation.state != OperationState.running) {
          cleanup();
          result.complete(operation);
        }
      } catch (error, stackTrace) {
        fail(error, stackTrace);
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
            .watch(after: cursor, operationId: command.operationId)
            .listen(
              (event) {
                if (event.sequence > cursor &&
                    event.operationId == command.operationId) {
                  unawaited(recheck());
                }
              },
              onError: (Object error, StackTrace stackTrace) =>
                  fail(error, stackTrace),
              onDone: () async {
                await recheck();
                if (!result.isCompleted)
                  fail(
                    StateError('operation event feed closed before completion'),
                  );
              },
            );
        // Also covers streams that synchronously signal during listen().
        if (result.isCompleted) cleanup();
      } catch (error, stackTrace) {
        fail(error, stackTrace);
      }
    }

    unawaited(begin());
    return result.future;
  }
}
