import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late GaoVmDatabase database;
  late Directory directory;
  late SqliteEventRepository events;
  late SqliteDurableEventFeed feed;
  late VmId a;
  late VmId b;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('durable-feed-');
    database = await GaoVmDatabase.open('${directory.path}/db');
    final vms = SqliteVmRepository(database);
    a = (await vms.create(name: 'a', spec: _spec)).metadata.id;
    b = (await vms.create(name: 'b', spec: _spec)).metadata.id;
    events = SqliteEventRepository(database);
    feed = SqliteDurableEventFeed(
      database,
      pageSize: 1,
      pollInterval: const Duration(milliseconds: 5),
    );
  });
  tearDown(() async {
    database.close();
    await directory.delete(recursive: true);
  });

  Future<Event> append(VmId vmId) => events.append(
    type: 'vm.test',
    resourceType: ResourceType.virtualMachine,
    resourceId: vmId,
    vmId: vmId,
    payload: JsonObjectValue.empty,
  );

  test(
    'replays bounded pages after an exclusive cursor with VM filter',
    () async {
      final first = await append(a);
      await append(b);
      final next = await append(a);
      final last = await append(a);
      expect(await feed.latestSequence(), last.sequence);
      final result = await feed
          .watch(after: first.sequence, vmId: a)
          .take(2)
          .toList();
      expect(result.map((event) => event.sequence), [
        next.sequence,
        last.sequence,
      ]);
    },
  );

  test(
    'live subscription observes committed events but never rollback',
    () async {
      final cursor = await feed.latestSequence();
      final received = feed.watch(after: cursor, vmId: a).first;
      await expectLater(
        database.transaction((_) async {
          await append(a);
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      final committed = await append(a);
      expect((await received).eventId, committed.eventId);
    },
  );

  test(
    'paused consumer does not block a second subscriber or lose its cursor',
    () async {
      final cursor = await feed.latestSequence();
      final slow = StreamIterator(feed.watch(after: cursor, vmId: a));
      addTearDown(slow.cancel);
      final fast = feed.watch(after: cursor, vmId: a).take(3).toList();
      final first = await append(a);
      expect(await slow.moveNext(), isTrue);
      expect(slow.current.eventId, first.eventId);
      final second = await append(a);
      final third = await append(a);
      expect((await fast).map((event) => event.eventId), [
        first.eventId,
        second.eventId,
        third.eventId,
      ]);
      expect(await slow.moveNext(), isTrue);
      expect(slow.current.eventId, second.eventId);
      expect(await slow.moveNext(), isTrue);
      expect(slow.current.eventId, third.eventId);
    },
  );

  test(
    'rejects caller transactions before exposing uncommitted events',
    () async {
      await database.transaction((_) async {
        await append(a);
        expect(() => feed.latestSequence(), throwsStateError);
        expect(() => feed.watch(), throwsStateError);
      });
      final stream = feed.watch();
      await database.transaction((_) async {
        await expectLater(stream.first, throwsStateError);
      });
    },
  );

  test(
    'observes another connection after consuming the current journal',
    () async {
      final other = await GaoVmDatabase.open('${directory.path}/db');
      addTearDown(other.close);
      final cursor = await feed.latestSequence();
      final iterator = StreamIterator(feed.watch(after: cursor, vmId: a));
      addTearDown(iterator.cancel);
      final first = await append(a);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current.eventId, first.eventId);
      final waiting = iterator.moveNext();
      final next = await SqliteEventRepository(other).append(
        type: 'vm.other_connection',
        resourceType: ResourceType.virtualMachine,
        resourceId: a,
        vmId: a,
        payload: JsonObjectValue.empty,
      );
      expect(await waiting, isTrue);
      expect(iterator.current.eventId, next.eventId);
    },
  );

  test('reopened catalog resumes strictly after the saved sequence', () async {
    final first = await append(a);
    expect(
      (await feed.watch(after: first.sequence - 1, vmId: a).first).eventId,
      first.eventId,
    );
    database.close();
    database = await GaoVmDatabase.open('${directory.path}/db');
    events = SqliteEventRepository(database);
    feed = SqliteDurableEventFeed(database);
    final next = await append(a);
    expect(next.sequence, greaterThan(first.sequence));
    expect(
      (await feed.watch(after: first.sequence, vmId: a).first).eventId,
      next.eventId,
    );
  });
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
