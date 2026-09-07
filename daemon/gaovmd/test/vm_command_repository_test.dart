import 'dart:io';
import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/vm_command_repository.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteVmCommandRepository repository;
  late DateTime now;
  final vm = VmId('vm_01J00000000000000000000000');
  final op = OperationId('op_01J00000000000000000000000');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gaovm-command-');
    database = await GaoVmDatabase.open('${directory.path}/db');
    now = DateTime.utc(2026, 9, 7);
    repository = SqliteVmCommandRepository(database, now: () => now);
  });
  tearDown(() async {
    database.close();
    await directory.delete(recursive: true);
  });

  test(
    'command acceptance joins caller transaction and rolls back with it',
    () async {
      await expectLater(
        database.transaction((_) async {
          await repository.enqueue(
            action: VmCommandAction.start,
            vmId: vm,
            operationId: op,
            payload: JsonObjectValue.fromJson({'spec_generation': 1}),
          );
          throw StateError('abort acceptance');
        }),
        throwsStateError,
      );
      expect(
        await repository.claim(
          owner: 'dispatcher',
          lease: const Duration(seconds: 10),
        ),
        isEmpty,
      );
      final record = await repository.enqueue(
        action: VmCommandAction.start,
        vmId: vm,
        operationId: op,
        payload: JsonObjectValue.fromJson({'spec_generation': 1}),
      );
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/db');
      repository = SqliteVmCommandRepository(database, now: () => now);
      final claim = (await repository.claim(
        owner: 'dispatcher',
        lease: const Duration(seconds: 10),
      )).single;
      expect(claim.record.id, record.id);
      expect(claim.record.vmId, vm);
      expect(claim.record.operationId, op);
      expect(claim.record.action, VmCommandAction.start);
      expect(claim.record.payload.toJson(), {'spec_generation': 1});
      expect(await repository.acknowledge(claim), isTrue);
      expect(
        await repository.claim(
          owner: 'dispatcher',
          lease: const Duration(seconds: 10),
        ),
        isEmpty,
      );
    },
  );

  test(
    'claims only the first unpublished command per VM while other VMs progress',
    () async {
      final otherVm = VmId.generate();
      Future<VmCommandRecord> add(VmId id, VmCommandAction action) =>
          repository.enqueue(
            action: action,
            vmId: id,
            operationId: OperationId.generate(),
            payload: JsonObjectValue.empty,
          );
      final first = await add(vm, VmCommandAction.start);
      final second = await add(vm, VmCommandAction.stop);
      final other = await add(otherVm, VmCommandAction.start);
      final claims = await repository.claim(
        owner: 'one',
        lease: const Duration(seconds: 10),
      );
      expect(claims.map((claim) => claim.record.id), [first.id, other.id]);
      expect(
        await repository.claim(
          owner: 'two',
          lease: const Duration(seconds: 10),
        ),
        isEmpty,
      );
      expect(await repository.acknowledge(claims.first), isTrue);
      final next = (await repository.claim(
        owner: 'two',
        lease: const Duration(seconds: 10),
      )).single;
      expect(next.record.id, second.id);
      expect(await repository.acknowledge(next), isTrue);
      expect(await repository.acknowledge(claims.last), isTrue);
    },
  );

  test(
    'expiry and reclaim fence stale acknowledgements even for reused owner names',
    () async {
      await repository.enqueue(
        action: VmCommandAction.kill,
        vmId: vm,
        operationId: op,
        payload: JsonObjectValue.empty,
      );
      final first = (await repository.claim(
        owner: 'worker',
        lease: const Duration(seconds: 10),
      )).single;
      now = now.add(const Duration(seconds: 10));
      expect(await repository.acknowledge(first), isFalse);
      expect(await repository.release(first), isFalse);
      final second = (await repository.claim(
        owner: 'worker',
        lease: const Duration(seconds: 10),
      )).single;
      expect(second.attempt, first.attempt + 1);
      expect(await repository.acknowledge(first), isFalse);
      expect(await repository.release(first), isFalse);
      expect(await repository.release(second), isTrue);
      final third = (await repository.claim(
        owner: 'new-worker',
        lease: const Duration(seconds: 10),
      )).single;
      expect(third.record.id, first.record.id);
      expect(third.attempt, second.attempt + 1);
      expect(await repository.acknowledge(second), isFalse);
      expect(await repository.acknowledge(third), isTrue);
      expect(await repository.acknowledge(third), isFalse);
    },
  );

  test(
    'event and VM command dispatchers cannot consume each other topics',
    () async {
      final events = SqliteEventRepository(database, now: () => now);
      await events.append(
        type: 'system.ready',
        resourceType: ResourceType.system,
        payload: JsonObjectValue.empty,
      );
      final record = await repository.enqueue(
        action: VmCommandAction.create,
        vmId: vm,
        operationId: op,
        payload: JsonObjectValue.empty,
      );
      final eventClaims = await events.claimOutbox(
        owner: 'events',
        lease: const Duration(seconds: 10),
      );
      expect(eventClaims, hasLength(1));
      final command = (await repository.claim(
        owner: 'commands',
        lease: const Duration(seconds: 10),
      )).single;
      expect(command.record.id, record.id);
      expect(
        await events.markOutboxPublished(record.id, owner: 'commands'),
        isFalse,
      );
      expect(await events.releaseOutbox(record.id, owner: 'commands'), isFalse);
      expect(await repository.acknowledge(command), isTrue);
      expect(
        await events.markOutboxPublished(
          eventClaims.single.id,
          owner: 'events',
        ),
        isTrue,
      );
    },
  );

  test(
    'strict decoding rejects unknown actions and mismatched envelope correlation',
    () async {
      final record = await repository.enqueue(
        action: VmCommandAction.restart,
        vmId: vm,
        operationId: op,
        payload: JsonObjectValue.empty,
      );
      for (final mutation in [
        {
          'version': 1,
          'action': 'exec',
          'vm_id': vm.value,
          'operation_id': op.value,
          'payload': {},
        },
        {
          'version': 1,
          'action': 'restart',
          'vm_id': VmId.generate().value,
          'operation_id': op.value,
          'payload': {},
        },
        {
          'version': 1,
          'action': 'restart',
          'vm_id': vm.value,
          'operation_id': vm.value,
          'payload': {},
        },
        {
          'version': 1.0,
          'action': 'restart',
          'vm_id': vm.value,
          'operation_id': op.value,
          'payload': {},
        },
        {
          'version': 1,
          'action': 'restart',
          'vm_id': vm.value,
          'operation_id': op.value,
          'payload': {},
          'unknown': true,
        },
      ]) {
        await database.transaction(
          (db) => db.execute(
            'UPDATE outbox SET payload_json = ? WHERE id = ?',
            [jsonEncode(mutation), record.id],
          ),
        );
        await expectLater(
          repository.claim(owner: 'worker', lease: const Duration(seconds: 10)),
          throwsFormatException,
        );
        await database.read((db) {
          final row = db.select(
            'SELECT claimed_by, attempts FROM outbox WHERE id = ?',
            [record.id],
          ).single;
          expect(row['claimed_by'], isNull);
          expect(row['attempts'], 0);
        });
      }
    },
  );

  test(
    'independent database connections do not claim the same delivery',
    () async {
      final otherDatabase = await GaoVmDatabase.open('${directory.path}/db');
      try {
        final other = SqliteVmCommandRepository(otherDatabase, now: () => now);
        await repository.enqueue(
          action: VmCommandAction.delete,
          vmId: vm,
          operationId: op,
          payload: JsonObjectValue.empty,
        );
        final batches = await Future.wait([
          repository.claim(owner: 'one', lease: const Duration(seconds: 10)),
          other.claim(owner: 'two', lease: const Duration(seconds: 10)),
        ]);
        expect(batches.expand((batch) => batch), hasLength(1));
        final claim = batches.expand((batch) => batch).single;
        expect(await other.acknowledge(claim), isTrue);
      } finally {
        otherDatabase.close();
      }
    },
  );

  test(
    'claim handles are fenced across distinct catalogs even with matching counters',
    () async {
      final otherDatabase = await GaoVmDatabase.open(
        '${directory.path}/other-db',
      );
      try {
        final other = SqliteVmCommandRepository(otherDatabase, now: () => now);
        await repository.enqueue(
          action: VmCommandAction.start,
          vmId: vm,
          operationId: op,
          payload: JsonObjectValue.empty,
        );
        await other.enqueue(
          action: VmCommandAction.start,
          vmId: VmId.generate(),
          operationId: OperationId.generate(),
          payload: JsonObjectValue.empty,
        );
        final first = (await repository.claim(
          owner: 'same-worker',
          lease: const Duration(seconds: 10),
        )).single;
        final second = (await other.claim(
          owner: 'same-worker',
          lease: const Duration(seconds: 10),
        )).single;
        expect(await other.acknowledge(first), isFalse);
        expect(await other.release(first), isFalse);
        expect(await repository.acknowledge(first), isTrue);
        expect(await other.acknowledge(second), isTrue);
      } finally {
        otherDatabase.close();
      }
    },
  );
}
