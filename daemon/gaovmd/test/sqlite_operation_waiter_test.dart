import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/durable_event_feed.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:gaovmd/src/operation_application_service.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/sqlite_durable_event_feed.dart';
import 'package:gaovmd/src/sqlite_operation_waiter.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteOperationRepository operations;
  late Operation operation;
  late _BoundaryFeed feed;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('operation-wait-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    operations = SqliteOperationRepository(database);
    operation = await operations.create(
      type: 'vm.start',
      resourceType: ResourceType.virtualMachine,
      resourceId: VmId.generate(),
      requestId: RequestId.generate(),
      cancellable: true,
      request: JsonObjectValue.empty,
    );
    feed = _BoundaryFeed();
  });
  tearDown(() async {
    await feed.controller.close();
    database.close();
    await directory.delete(recursive: true);
  });
  Future<Operation> wait({
    Duration timeout = const Duration(seconds: 1),
    OperationId? id,
  }) => SqliteOperationWaiter(operations: operations, events: feed).wait(
    OperationWaitCommand(operationId: id ?? operation.id, timeout: timeout),
  );

  test('returns already terminal operation without subscribing', () async {
    await operations.start(operation.id);
    final terminal = await operations.succeed(operation.id);
    expect(await wait(), terminal);
    expect(feed.watches, 0);
  });

  test(
    'completion in the read-subscribe gap is replayed and rechecked',
    () async {
      final events = SqliteEventRepository(database);
      feed.onWatch = () async {
        for (final event in await events.list(operationId: operation.id)) {
          feed.controller.add(event);
        }
      };
      var firstRead = true;
      final waiter = SqliteOperationWaiter(
        events: feed,
        operations: _ReadRepository(() async {
          final snapshot = await operations.get(operation.id);
          if (firstRead) {
            firstRead = false;
            await operations.start(operation.id);
            await operations.succeed(operation.id);
          }
          return snapshot;
        }),
      );
      expect(
        (await waiter.wait(
          OperationWaitCommand(
            operationId: operation.id,
            timeout: const Duration(seconds: 1),
          ),
        )).state,
        OperationState.succeeded,
      );
      expect(feed.watches, 1);
      expect(feed.controller.hasListener, isFalse);
    },
  );

  test('missing operation fails without subscribing', () async {
    await expectLater(
      wait(id: OperationId.generate()),
      throwsA(isA<OperationNotFoundException>()),
    );
    expect(feed.watches, 0);
  });

  test(
    'burst coalesces behind one slow read and stream closure waits for terminal recheck',
    () async {
      final events = await SqliteEventRepository(
        database,
      ).list(operationId: operation.id);
      final blocked = Completer<Operation?>();
      final entered = Completer<void>();
      var reads = 0;
      var active = 0;
      var maxActive = 0;
      feed.onWatch = () async {
        feed.controller.add(events.single);
      };
      final waiter = SqliteOperationWaiter(
        events: feed,
        operations: _ReadRepository(() async {
          reads++;
          active++;
          if (active > maxActive) maxActive = active;
          try {
            if (reads == 2) {
              entered.complete();
              return await blocked.future;
            }
            return await operations.get(operation.id);
          } finally {
            active--;
          }
        }),
      );
      final completion = waiter.wait(
        OperationWaitCommand(
          operationId: operation.id,
          timeout: const Duration(seconds: 2),
        ),
      );
      await entered.future;
      await operations.start(operation.id);
      final terminal = await operations.succeed(operation.id);
      final completedEvent = (await SqliteEventRepository(
        database,
      ).list(operationId: operation.id)).last;
      for (var index = 0; index < 100; index++) {
        feed.controller.add(completedEvent);
      }
      await feed.controller.close();
      blocked.complete(operation); // A snapshot from before the terminal event.
      expect(await completion, terminal);
      expect(maxActive, 1);
      expect(reads, 3); // Initial, blocked, one coalesced terminal recheck.
      expect(feed.controller.hasListener, isFalse);
    },
  );

  test(
    'timeout cancels a pending subscription without mutating the operation',
    () async {
      await expectLater(
        wait(timeout: const Duration(milliseconds: 30)),
        throwsA(isA<TimeoutException>()),
      );
      expect(feed.watches, 1);
      expect(feed.controller.hasListener, isFalse);
      expect(await operations.get(operation.id), operation);
    },
  );

  test(
    'deadline includes cursor acquisition and does not subscribe after timeout',
    () async {
      final cursor = Completer<int>();
      feed.latest = () => cursor.future;
      await expectLater(
        wait(timeout: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      cursor.complete(0);
      await cursor.future;
      expect(feed.watches, 0);
    },
  );

  test(
    'deadline includes initial repository read and ignores its late result',
    () async {
      final read = Completer<Operation?>();
      final waiter = SqliteOperationWaiter(
        operations: _ReadRepository(() => read.future),
        events: feed,
      );
      await expectLater(
        waiter.wait(
          OperationWaitCommand(
            operationId: operation.id,
            timeout: const Duration(milliseconds: 10),
          ),
        ),
        throwsA(isA<TimeoutException>()),
      );
      read.complete(operation);
      await read.future;
      expect(feed.watches, 0);
    },
  );

  test('stream failure and closure cancel their subscriptions', () async {
    feed.onWatch = () async {
      feed.controller.addError(StateError('broken feed'));
    };
    await expectLater(wait(), throwsStateError);
    expect(feed.controller.hasListener, isFalse);
  });

  test('closed stream never returns a nonterminal operation', () async {
    feed.onWatch = () async {
      unawaited(feed.controller.close());
    };
    await expectLater(wait(), throwsStateError);
    expect(feed.controller.hasListener, isFalse);
  });

  test(
    'deadline covers an event-triggered read and cancels the feed',
    () async {
      final read = Completer<Operation?>();
      var reads = 0;
      feed.onWatch = () async {
        final events = await SqliteEventRepository(
          database,
        ).list(operationId: operation.id);
        feed.controller.add(events.single);
      };
      final waiter = SqliteOperationWaiter(
        operations: _ReadRepository(
          () async => ++reads == 1 ? operation : await read.future,
        ),
        events: feed,
      );
      await expectLater(
        waiter.wait(
          OperationWaitCommand(
            operationId: operation.id,
            timeout: const Duration(milliseconds: 30),
          ),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(reads, 2);
      expect(feed.controller.hasListener, isFalse);
      read.complete(operation);
      await read.future;
    },
  );

  for (final state in [
    OperationState.succeeded,
    OperationState.failed,
    OperationState.cancelled,
  ]) {
    test('real SQLite feed returns committed $state', () async {
      final realFeed = _ObservedFeed(
        SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 5),
        ),
      );
      final completion =
          SqliteOperationWaiter(operations: operations, events: realFeed).wait(
            OperationWaitCommand(
              operationId: operation.id,
              timeout: const Duration(seconds: 2),
            ),
          );
      await realFeed.subscribed.future;
      await operations.start(operation.id);
      final terminal = switch (state) {
        OperationState.succeeded => await operations.succeed(operation.id),
        OperationState.cancelled => await operations.cancel(operation.id),
        _ => await operations.fail(
          operation.id,
          error: OperationError(
            code: ErrorCode.internalError,
            message: 'failed',
            retryable: false,
            details: JsonObjectValue.empty,
          ),
        ),
      };
      expect(await completion, terminal);
    });
  }
}

final class _ObservedFeed implements DurableEventFeed {
  _ObservedFeed(this.delegate);
  final DurableEventFeed delegate;
  final subscribed = Completer<void>();
  @override
  Future<int> latestSequence() => delegate.latestSequence();
  @override
  Stream<Event> watch({
    int after = 0,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
  }) {
    final stream = delegate.watch(
      after: after,
      vmId: vmId,
      operationId: operationId,
      testRunId: testRunId,
    );
    subscribed.complete();
    return stream;
  }
}

final class _BoundaryFeed implements DurableEventFeed {
  final controller = StreamController<Event>.broadcast();
  Future<void> Function()? onWatch;
  Future<int> Function()? latest;
  int watches = 0;
  @override
  Future<int> latestSequence() async => latest == null ? 0 : await latest!();
  @override
  Stream<Event> watch({
    int after = 0,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
  }) {
    watches++;
    if (onWatch case final callback?)
      unawaited(Future<void>.microtask(callback));
    return controller.stream;
  }
}

final class _ReadRepository implements OperationRepository {
  _ReadRepository(this.read);
  final Future<Operation?> Function() read;
  @override
  Future<Operation?> get(OperationId id) => read();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected repository write');
}
