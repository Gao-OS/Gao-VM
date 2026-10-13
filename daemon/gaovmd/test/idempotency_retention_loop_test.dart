import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/idempotency_repository.dart';
import 'package:gaovmd/src/idempotency_retention_loop.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_controller.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteIdempotencyRepository repository;
  late DateTime now;
  final body = <int>[1];
  final envelope = JsonObjectValue.fromJson({'status': 202});

  Future<IdempotencyResult> accept(String scope) => repository.execute(
    scope: scope,
    key: 'retry-key',
    requestBody: body,
    action: () async => IdempotencyResponse(envelope),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gaovm-key-retention-');
    database = await GaoVmDatabase.open('${directory.path}/db.sqlite');
    now = DateTime.utc(2026, 10, 13);
    repository = SqliteIdempotencyRepository(
      database,
      retention: const Duration(days: 1),
      now: () => now,
    );
  });

  tearDown(() async {
    database.close();
    await directory.delete(recursive: true);
  });

  test('startup drains one bounded pass and preserves live replay', () async {
    for (var index = 0; index < 102; index++) {
      await accept('expired-$index');
    }
    now = now.add(const Duration(days: 1));
    final live = await accept('live');
    final errors = <Object>[];
    final loop = IdempotencyRetentionLoop(
      repository: repository,
      onError: (error, _) => errors.add(error),
    );
    addTearDown(loop.close);

    loop.start();
    loop.start();
    await loop.close();

    expect(await repository.cleanupExpired(), 2);
    final replay = await accept('live');
    expect(replay.replayed, isTrue);
    expect(replay.response.toJson(), live.response.toJson());
    expect(errors, isEmpty);
    expect(loop.start, throwsStateError);
  });

  test(
    'periodic passes expire new keys and close cancels the next pass',
    () async {
      await accept('expires-later');
      final scheduler = _Scheduler();
      final errors = <Object>[];
      final loop = IdempotencyRetentionLoop(
        repository: repository,
        scheduler: scheduler,
        onError: (error, _) => errors.add(error),
      );
      addTearDown(loop.close);

      loop.start();
      await scheduler.scheduled.future.timeout(const Duration(seconds: 3));
      expect((await accept('expires-later')).replayed, isTrue);
      expect(scheduler.activeCount, 1);
      expect(scheduler.handles.single.delay, const Duration(minutes: 1));

      now = now.add(const Duration(days: 1));
      scheduler.fire();
      await scheduler.scheduled.future.timeout(const Duration(seconds: 3));
      await loop.close();

      expect(await repository.cleanupExpired(), 0);
      expect(scheduler.activeCount, 0);
      scheduler.fire();
      expect(errors, isEmpty);
    },
  );

  test('close drains a queued pass without scheduling another', () async {
    await accept('expired');
    now = now.add(const Duration(days: 1));
    final entered = Completer<void>(), release = Completer<void>();
    final holding = database.transaction((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final scheduler = _Scheduler();
    final errors = <Object>[];
    final loop = IdempotencyRetentionLoop(
      repository: repository,
      scheduler: scheduler,
      onError: (error, _) => errors.add(error),
    );
    addTearDown(loop.close);
    loop.start();
    var closed = false;
    final closing = loop.close().then((_) => closed = true);
    try {
      await Future<void>.value();
      expect(closed, isFalse);
      expect(scheduler.activeCount, 0);
    } finally {
      release.complete();
    }
    await holding;
    await closing;

    expect(await repository.cleanupExpired(), 0);
    expect(closed, isTrue);
    expect(scheduler.activeCount, 0);
    expect(errors, isEmpty);
  });

  test('a failed catalog pass reports the error and retries later', () async {
    await accept('expired');
    now = now.add(const Duration(days: 1));
    await database.transaction((connection) {
      connection.execute('''CREATE TRIGGER abort_key_expiry
        BEFORE DELETE ON idempotency_keys BEGIN
          SELECT RAISE(ABORT, 'injected cleanup failure');
        END''');
    });
    final scheduler = _Scheduler();
    final errors = <Object>[];
    final loop = IdempotencyRetentionLoop(
      repository: repository,
      scheduler: scheduler,
      onError: (error, _) => errors.add(error),
    );
    addTearDown(loop.close);
    loop.start();
    await scheduler.scheduled.future.timeout(const Duration(seconds: 3));
    expect(errors, hasLength(1));

    await database.transaction(
      (connection) => connection.execute('DROP TRIGGER abort_key_expiry'),
    );
    scheduler.fire();
    await scheduler.scheduled.future.timeout(const Duration(seconds: 3));
    await loop.close();

    expect(await repository.cleanupExpired(), 0);
    expect(errors, hasLength(1));
    expect(scheduler.activeCount, 0);
  });
}

final class _Scheduler implements VmTimerScheduler {
  final handles = <_Handle>[];
  Completer<void> scheduled = Completer<void>();
  int get activeCount => handles.where((handle) => handle.isActive).length;

  @override
  VmTimerHandle schedule(Duration delay, void Function() callback) {
    final handle = _Handle(delay, callback);
    handles.add(handle);
    scheduled.complete();
    return handle;
  }

  void fire() {
    final pending = handles.where((handle) => handle.isActive).toList();
    if (pending.isEmpty) return;
    scheduled = Completer<void>();
    for (final handle in pending) {
      handle.cancel();
      handle.callback();
    }
  }
}

final class _Handle implements VmTimerHandle {
  _Handle(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
}
