import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteVmCommandRepository commands;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vm-dispatch-loop-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    commands = SqliteVmCommandRepository(database);
  });
  tearDown(() async {
    database.close();
    await directory.delete(recursive: true);
  });

  Future<VmCommandRecord> enqueue(VmId vmId) => commands.enqueue(
    action: VmCommandAction.start,
    vmId: vmId,
    operationId: OperationId.generate(),
    payload: JsonObjectValue.empty,
  );

  test('rejects invalid batch limits before scheduling work', () {
    final dispatcher = VmCommandDispatcher(
      commands: commands,
      owner: 'daemon',
      target: _Target((_) async => VmIntentAdoptionDisposition.adopted),
    );
    for (final limit in [0, -1, 1001]) {
      expect(
        () => VmCommandDispatchLoop(
          dispatcher: dispatcher,
          batchLimit: limit,
          onDispatch: (_) {},
          onError: (_, _) {},
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'automatically delivers durable FIFO heads on successive bounded passes',
    () async {
      final vmId = VmId.generate();
      final first = await enqueue(vmId);
      final second = await enqueue(vmId);
      final scheduler = _Scheduler();
      final deliveries = <int>[];
      final passes = StreamController<List<VmCommandDispatchOutcome>>();
      final results = StreamIterator(passes.stream);
      final loop = VmCommandDispatchLoop(
        dispatcher: VmCommandDispatcher(
          commands: commands,
          target: _Target((record) async {
            deliveries.add(record.id);
            return VmIntentAdoptionDisposition.adopted;
          }),
          owner: 'daemon',
        ),
        scheduler: scheduler,
        onDispatch: passes.add,
        onError: (error, stack) => fail('$error'),
      );
      try {
        loop.start();
        expect(await results.moveNext(), isTrue);
        expect(deliveries, [first.id]);
        expect(
          results.current.single.status,
          VmCommandDispatchStatus.acknowledged,
        );
        scheduler.fire();
        expect(await results.moveNext(), isTrue);
        expect(deliveries, [first.id, second.id]);
        expect(
          results.current.single.status,
          VmCommandDispatchStatus.acknowledged,
        );
      } finally {
        await loop.close();
        await results.cancel();
        await passes.close();
      }
      expect(scheduler.activeCount, 0);
    },
  );
  test('reports failed delivery and retries the same durable head', () async {
    final record = await enqueue(VmId.generate());
    final scheduler = _Scheduler();
    final passes = StreamController<List<VmCommandDispatchOutcome>>();
    final results = StreamIterator(passes.stream);
    var attempts = 0;
    final failure = StateError('temporary adoption failure');
    final loop = VmCommandDispatchLoop(
      dispatcher: VmCommandDispatcher(
        commands: commands,
        owner: 'daemon',
        target: _Target((_) async {
          if (attempts++ == 0) throw failure;
          return VmIntentAdoptionDisposition.adopted;
        }),
      ),
      scheduler: scheduler,
      onDispatch: passes.add,
      onError: (error, stack) => fail('$error'),
    );
    try {
      loop.start();
      expect(await results.moveNext(), isTrue);
      expect(results.current.single.status, VmCommandDispatchStatus.failed);
      expect(results.current.single.error, same(failure));
      scheduler.fire();
      expect(await results.moveNext(), isTrue);
      expect(results.current.single.record.id, record.id);
      expect(
        results.current.single.status,
        VmCommandDispatchStatus.acknowledged,
      );
    } finally {
      await loop.close();
      await results.cancel();
      await passes.close();
    }
  });

  test('claim failure is observable and later passes recover', () async {
    await enqueue(VmId.generate());
    await database.transaction((db) {
      db.execute('''CREATE TRIGGER reject_claim BEFORE UPDATE ON outbox
        BEGIN SELECT RAISE(ABORT, 'injected claim failure'); END''');
    });
    final scheduler = _Scheduler();
    final failed = Completer<Object>();
    final succeeded = Completer<List<VmCommandDispatchOutcome>>();
    final loop = VmCommandDispatchLoop(
      dispatcher: VmCommandDispatcher(
        commands: commands,
        owner: 'daemon',
        target: _Target((_) async => VmIntentAdoptionDisposition.adopted),
      ),
      scheduler: scheduler,
      onDispatch: succeeded.complete,
      onError: (error, stack) => failed.complete(error),
    );
    try {
      loop.start();
      expect(
        (await failed.future).toString(),
        contains('injected claim failure'),
      );
      expect(succeeded.isCompleted, isFalse);
      await database.transaction(
        (db) => db.execute('DROP TRIGGER reject_claim'),
      );
      scheduler.fire();
      expect(
        (await succeeded.future).single.status,
        VmCommandDispatchStatus.acknowledged,
      );
    } finally {
      await loop.close();
    }
  });

  test('production timers continue delivery without manual wakeups', () async {
    final vmId = VmId.generate();
    await enqueue(vmId);
    await enqueue(vmId);
    final completed = Completer<void>();
    var acknowledged = 0;
    final loop = VmCommandDispatchLoop(
      dispatcher: VmCommandDispatcher(
        commands: commands,
        owner: 'daemon',
        target: _Target((_) async => VmIntentAdoptionDisposition.adopted),
      ),
      interval: const Duration(milliseconds: 1),
      onDispatch: (outcomes) {
        acknowledged += outcomes
            .where(
              (outcome) =>
                  outcome.status == VmCommandDispatchStatus.acknowledged,
            )
            .length;
        if (acknowledged == 2 && !completed.isCompleted) completed.complete();
      },
      onError: (error, stack) => completed.completeError(error, stack),
    );
    try {
      loop.start();
      await completed.future.timeout(const Duration(seconds: 5));
    } finally {
      await loop.close();
    }
    expect(acknowledged, 2);
  });

  test(
    'shutdown drains one in-flight pass without scheduling another',
    () async {
      await enqueue(VmId.generate());
      final scheduler = _Scheduler();
      final entered = Completer<void>();
      final release = Completer<VmIntentAdoptionDisposition>();
      var deliveries = 0;
      final loop = VmCommandDispatchLoop(
        dispatcher: VmCommandDispatcher(
          commands: commands,
          owner: 'daemon',
          target: _Target((_) {
            deliveries++;
            entered.complete();
            return release.future;
          }),
        ),
        scheduler: scheduler,
        onDispatch: (_) {},
        onError: (error, stack) => fail('$error'),
      );
      loop.start();
      await entered.future;
      loop.start();
      scheduler.fire();
      expect(deliveries, 1);
      expect(scheduler.activeCount, 0);
      var closed = false;
      final closing = loop.close().then((_) => closed = true);
      await Future<void>.value();
      expect(closed, isFalse);
      release.complete(VmIntentAdoptionDisposition.adopted);
      await closing;
      await loop.close();
      expect(scheduler.activeCount, 0);
      expect(loop.start, throwsStateError);
      expect(
        await commands.claim(
          owner: 'after',
          lease: const Duration(seconds: 30),
        ),
        isEmpty,
      );
    },
  );
}

final class _Target implements VmCommandTarget {
  _Target(this.deliver);
  final Future<VmIntentAdoptionDisposition> Function(VmCommandRecord) deliver;
  @override
  Future<VmIntentAdoptionDisposition> adopt(VmCommandRecord record) =>
      deliver(record);
}

final class _Scheduler implements VmTimerScheduler {
  final handles = <_Handle>[];
  int get activeCount => handles.where((handle) => handle.isActive).length;
  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) {
    final handle = _Handle(callback);
    handles.add(handle);
    return handle;
  }

  void fire() {
    final pending = handles.where((handle) => handle.isActive).toList();
    for (final handle in pending) {
      handle.cancel();
      handle.callback();
    }
  }
}

final class _Handle implements VmTimerHandle {
  _Handle(this.callback);
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
}
