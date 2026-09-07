import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_command_dispatcher.dart';
import 'package:gaovmd/src/vm_command_repository.dart';
import 'package:gaovmd/src/vm_controller.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteVmCommandRepository commands;
  late DateTime now;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vm-dispatch-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    now = DateTime.utc(2026, 9, 7);
    commands = SqliteVmCommandRepository(database, now: () => now);
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

  test('bounds each batch and propagates claim validation errors', () async {
    final first = await enqueue(VmId.generate());
    final second = await enqueue(VmId.generate());
    final delivered = <int>[];
    final dispatcher = VmCommandDispatcher(
      commands: commands,
      owner: 'worker',
      target: _Target((record) async {
        delivered.add(record.id);
        return VmIntentAdoptionDisposition.adopted;
      }),
    );
    await expectLater(dispatcher.dispatchOnce(limit: 0), throwsArgumentError);
    expect(delivered, isEmpty);
    expect(
      (await dispatcher.dispatchOnce(limit: 1)).single.record.id,
      first.id,
    );
    expect(delivered, [first.id]);
    expect(
      (await dispatcher.dispatchOnce(limit: 1)).single.record.id,
      second.id,
    );
  });

  test(
    'failed adoption retains its error when its release fence expires',
    () async {
      await enqueue(VmId.generate());
      final error = StateError('adoption error');
      final outcome = (await VmCommandDispatcher(
        commands: commands,
        owner: 'worker',
        target: _Target((_) async {
          now = now.add(const Duration(seconds: 30));
          throw error;
        }),
      ).dispatchOnce()).single;
      expect(outcome.status, VmCommandDispatchStatus.failed);
      expect(outcome.error, same(error));
      expect(outcome.released, isFalse);
    },
  );

  test(
    'delivers different VM heads concurrently while preserving each VM FIFO',
    () async {
      final vm = VmId.generate();
      final first = await enqueue(vm);
      final second = await enqueue(vm);
      final other = await enqueue(VmId.generate());
      final started = <int>[];
      final bothStarted = Completer<void>();
      final release = Completer<VmIntentAdoptionDisposition>();
      final dispatcher = VmCommandDispatcher(
        commands: commands,
        owner: 'worker',
        target: _Target((record) {
          started.add(record.id);
          if (started.length == 2) bothStarted.complete();
          return release.future;
        }),
      );
      final pending = dispatcher.dispatchOnce();
      await bothStarted.future.timeout(const Duration(seconds: 1));
      expect(started, [first.id, other.id]);
      expect(await dispatcher.dispatchOnce(), isEmpty);
      release.complete(VmIntentAdoptionDisposition.adopted);
      expect(
        (await pending).map((result) => result.status),
        everyElement(VmCommandDispatchStatus.acknowledged),
      );
      expect((await dispatcher.dispatchOnce()).single.record.id, second.id);
      expect(started, [first.id, other.id, second.id]);
    },
  );

  test('deferred and failed heads are released for a later delivery', () async {
    final deferred = await enqueue(VmId.generate());
    final failed = await enqueue(VmId.generate());
    final error = StateError('adoption rolled back');
    final first = await VmCommandDispatcher(
      commands: commands,
      owner: 'worker',
      target: _Target((record) async {
        if (record.id == failed.id) throw error;
        return VmIntentAdoptionDisposition.deferred;
      }),
    ).dispatchOnce();
    expect(first[0].status, VmCommandDispatchStatus.deferred);
    expect(first[0].released, isTrue);
    expect(first[1].status, VmCommandDispatchStatus.failed);
    expect(first[1].error, same(error));
    expect(first[1].stackTrace, isNotNull);
    expect(first[1].released, isTrue);
    final next = await VmCommandDispatcher(
      commands: commands,
      owner: 'retry',
      target: _Target((_) async => VmIntentAdoptionDisposition.duplicate),
    ).dispatchOnce();
    expect(next.map((result) => result.record.id), [deferred.id, failed.id]);
    expect(
      next.map((result) => result.status),
      everyElement(VmCommandDispatchStatus.acknowledged),
    );
  });

  test('expired delivery cannot acknowledge a replacement claim', () async {
    final record = await enqueue(VmId.generate());
    final started = Completer<void>();
    final adoption = Completer<VmIntentAdoptionDisposition>();
    final pending = VmCommandDispatcher(
      commands: commands,
      owner: 'same-owner',
      lease: const Duration(seconds: 10),
      target: _Target((_) {
        started.complete();
        return adoption.future;
      }),
    ).dispatchOnce();
    await started.future;
    now = now.add(const Duration(seconds: 10));
    final replacement = (await commands.claim(
      owner: 'same-owner',
      lease: const Duration(seconds: 10),
    )).single;
    adoption.complete(VmIntentAdoptionDisposition.adopted);
    expect((await pending).single.status, VmCommandDispatchStatus.lostClaim);
    expect(replacement.record.id, record.id);
    expect(await commands.acknowledge(replacement), isTrue);
  });

  test('expired deferred delivery reports a lost claim', () async {
    await enqueue(VmId.generate());
    final results = await VmCommandDispatcher(
      commands: commands,
      owner: 'worker',
      target: _Target((_) async {
        now = now.add(const Duration(seconds: 30));
        return VmIntentAdoptionDisposition.deferred;
      }),
    ).dispatchOnce();
    expect(results.single.status, VmCommandDispatchStatus.lostClaim);
    expect(results.single.released, isFalse);
    expect(
      (await commands.claim(
        owner: 'retry',
        lease: const Duration(seconds: 30),
      )),
      hasLength(1),
    );
  });

  test(
    'retains the adoption error when releasing the claim also fails',
    () async {
      await enqueue(VmId.generate());
      await database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER reject_release BEFORE UPDATE ON outbox
      WHEN OLD.claimed_by IS NOT NULL AND NEW.claimed_by IS NULL AND NEW.published_at IS NULL
      BEGIN SELECT RAISE(ABORT, 'release failed'); END
    '''),
      );
      final error = StateError('original adoption error');
      final result = (await VmCommandDispatcher(
        commands: commands,
        owner: 'worker',
        target: _Target((_) async => throw error),
      ).dispatchOnce()).single;
      expect(result.status, VmCommandDispatchStatus.failed);
      expect(result.error, same(error));
      expect(result.stackTrace, isNotNull);
      expect(result.releaseError, isNotNull);
      expect(result.releaseStackTrace, isNotNull);
      expect(result.released, isNull);
    },
  );

  test(
    'acknowledgment errors remain visible and release for duplicate replay',
    () async {
      final record = await enqueue(VmId.generate());
      await database.transaction(
        (db) => db.execute('''
      CREATE TRIGGER reject_ack BEFORE UPDATE ON outbox
      WHEN NEW.published_at IS NOT NULL
      BEGIN SELECT RAISE(ABORT, 'ack failed'); END
    '''),
      );
      final dispatcher = VmCommandDispatcher(
        commands: commands,
        owner: 'worker',
        target: _Target((_) async => VmIntentAdoptionDisposition.duplicate),
      );
      final result = (await dispatcher.dispatchOnce()).single;
      expect(result.status, VmCommandDispatchStatus.failed);
      expect(result.error, isNotNull);
      expect(result.released, isTrue);
      await database.transaction((db) => db.execute('DROP TRIGGER reject_ack'));
      final replay = (await dispatcher.dispatchOnce()).single;
      expect(replay.record.id, record.id);
      expect(replay.status, VmCommandDispatchStatus.acknowledged);
    },
  );

  test('does not acknowledge until adoption resolves', () async {
    final record = await enqueue(VmId.generate());
    final started = Completer<void>();
    final adoption = Completer<VmIntentAdoptionDisposition>();
    final dispatcher = VmCommandDispatcher(
      commands: commands,
      owner: 'worker',
      target: _Target((command) {
        expect(command.id, record.id);
        started.complete();
        return adoption.future;
      }),
    );
    final dispatched = dispatcher.dispatchOnce();
    await started.future;
    await database.read((db) {
      expect(
        db.select('SELECT published_at FROM outbox WHERE id = ?', [
          record.id,
        ]).single['published_at'],
        isNull,
      );
    });
    adoption.complete(VmIntentAdoptionDisposition.adopted);
    final outcome = (await dispatched).single;
    expect(outcome.record.id, record.id);
    expect(outcome.status, VmCommandDispatchStatus.acknowledged);
    expect(outcome.error, isNull);
    expect(await dispatcher.dispatchOnce(), isEmpty);
  });
}

final class _Target implements VmCommandTarget {
  _Target(this.action);
  final Future<VmIntentAdoptionDisposition> Function(VmCommandRecord) action;
  @override
  Future<VmIntentAdoptionDisposition> adopt(VmCommandRecord record) =>
      action(record);
}
