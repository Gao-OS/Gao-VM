import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/durable_event_feed.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:gaovmd/src/sqlite_durable_event_feed.dart';
import 'package:gaovmd/src/sqlite_vm_condition_waiter.dart';
import 'package:gaovmd/src/sqlite_vm_state_effect_adapter.dart';
import 'package:gaovmd/src/vm_application_service.dart';
import 'package:gaovmd/src/vm_controller_reducer.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late SqliteVmRepository repository;
  late VirtualMachine vm;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vm-condition-wait-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    repository = SqliteVmRepository(database);
    vm = await repository.create(name: 'wait', spec: _spec);
  });
  tearDown(() async {
    database.close();
    await directory.delete(recursive: true);
  });

  Future<void> setPhase(VmPhase phase) =>
      SqliteVmStateEffectAdapter(database).persistRuntime(
        VmControllerState.initial(
          vmId: vm.metadata.id,
          specGeneration: 1,
          restartPolicy: RestartPolicy.never,
        ).copyWith(phase: phase),
      );

  Future<DateTime> waitFor({
    VmWaitCondition condition = VmWaitCondition.runtimeRunning,
    Duration timeout = const Duration(seconds: 1),
    DurableEventFeed? events,
    VmRepository? vms,
    VmId? vmId,
  }) =>
      SqliteVmConditionWaiter(
        repository: vms ?? repository,
        events:
            events ??
            SqliteDurableEventFeed(
              database,
              pollInterval: const Duration(milliseconds: 1),
            ),
      ).wait(
        VmWaitCommand(
          vmId: vmId ?? vm.metadata.id,
          condition: condition,
          timeout: timeout,
        ),
      );

  test(
    'refuses to observe running state from the caller transaction',
    () async {
      await expectLater(
        database.transaction((_) async {
          await setPhase(VmPhase.running);
          await waitFor();
        }),
        throwsStateError,
      );
      expect(
        (await repository.get(vm.metadata.id))!.status.phase,
        VmPhase.defined,
      );
    },
  );

  test(
    'returns observation time for an already running committed VM',
    () async {
      await setPhase(VmPhase.running);
      final before = DateTime.now().toUtc();
      final observed =
          await SqliteVmConditionWaiter(
            repository: repository,
            events: SqliteDurableEventFeed(database),
          ).wait(
            VmWaitCommand(
              vmId: vm.metadata.id,
              condition: VmWaitCondition.runtimeRunning,
              timeout: const Duration(seconds: 1),
            ),
          );
      expect(observed.isUtc, isTrue);
      expect(observed.isBefore(before), isFalse);
      expect(observed.isAfter(DateTime.now().toUtc()), isFalse);
    },
  );

  test(
    'guest-agent wait recognizes committed ready state while running',
    () async {
      await setPhase(VmPhase.running);
      await database.transaction(
        (db) => db.execute(
          "UPDATE vm_runtime SET guest_agent = 'ready' WHERE vm_id = ?",
          [vm.metadata.id.value],
        ),
      );
      final result =
          await SqliteVmConditionWaiter(
            repository: repository,
            events: SqliteDurableEventFeed(database),
          ).wait(
            VmWaitCommand(
              vmId: vm.metadata.id,
              condition: VmWaitCondition.guestAgentReady,
              timeout: const Duration(milliseconds: 30),
            ),
          );
      expect(result, isA<DateTime>());
    },
  );

  test(
    'guest-service wait reports the missing durable service status',
    () async {
      await setPhase(VmPhase.running);
      await expectLater(
        SqliteVmConditionWaiter(
          repository: repository,
          events: SqliteDurableEventFeed(database),
        ).wait(
          VmWaitCommand(
            vmId: vm.metadata.id,
            condition: VmWaitCondition.guestServiceReady,
            serviceName: 'ssh',
            timeout: const Duration(milliseconds: 30),
          ),
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('persisted guest service'),
          ),
        ),
      );
    },
  );

  test(
    'guest-agent waits reject running alone and stale ready after stop',
    () async {
      for (final phase in [VmPhase.running, VmPhase.stopped]) {
        await setPhase(phase);
        await database.transaction(
          (db) => db.execute(
            'UPDATE vm_runtime SET guest_agent = ? WHERE vm_id = ?',
            [
              phase == VmPhase.stopped ? 'ready' : 'unavailable',
              vm.metadata.id.value,
            ],
          ),
        );
        final before = await repository.get(vm.metadata.id);
        final feed = _WatchingFeed(SqliteDurableEventFeed(database));
        await expectLater(
          waitFor(
            condition: VmWaitCondition.guestAgentReady,
            timeout: const Duration(milliseconds: 20),
            events: feed,
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(feed.cancelled, isTrue);
        expect(await repository.get(vm.metadata.id), before);
      }
    },
  );

  test(
    'deadline bounds blocked cursor and status reads without late subscription',
    () async {
      for (final blockCursor in [true, false]) {
        final release = Completer<void>();
        final feed = _BoundaryFeed();
        if (blockCursor)
          feed.latest = () async {
            await release.future;
            return 0;
          };
        final vms = blockCursor
            ? repository
            : _ReadRepository(() async {
                await release.future;
                return vm;
              });
        await expectLater(
          waitFor(
            events: feed,
            vms: vms,
            timeout: const Duration(milliseconds: 20),
          ),
          throwsA(isA<TimeoutException>()),
        );
        release.complete();
        await Future<void>.delayed(Duration.zero);
        expect(feed.watches, 0);
        await feed.controller.close();
      }
    },
  );

  test(
    'running event payload does not substitute for committed running status',
    () async {
      final feed = _WatchingFeed(
        SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 1),
        ),
      );
      final pending = expectLater(
        waitFor(events: feed, timeout: const Duration(milliseconds: 40)),
        throwsA(isA<TimeoutException>()),
      );
      await feed.started.future;
      await SqliteEventRepository(database).append(
        type: 'vm.running',
        resourceType: ResourceType.virtualMachine,
        resourceId: vm.metadata.id,
        vmId: vm.metadata.id,
        payload: JsonObjectValue.fromJson(const {'phase': 'running'}),
      );
      await pending;
      expect(
        (await repository.get(vm.metadata.id))!.status.phase,
        VmPhase.defined,
      );
      expect(feed.cancelled, isTrue);
    },
  );

  test(
    'transition between initial read and subscription is replayed',
    () async {
      final feed = _WatchingFeed(SqliteDurableEventFeed(database));
      var firstRead = true;
      final vms = _ReadRepository(() async {
        final snapshot = await repository.get(vm.metadata.id);
        if (firstRead) {
          firstRead = false;
          await database.transaction((_) async {
            await setPhase(VmPhase.running);
            await SqliteEventRepository(database).append(
              type: 'vm.running',
              resourceType: ResourceType.virtualMachine,
              resourceId: vm.metadata.id,
              vmId: vm.metadata.id,
              payload: JsonObjectValue.empty,
            );
          });
        }
        return snapshot;
      });
      expect(await waitFor(events: feed, vms: vms), isA<DateTime>());
      expect(feed.cancelled, isTrue);
    },
  );

  test(
    'feed errors and closure clean up after a final committed status check',
    () async {
      for (final outcome in ['error', 'closed', 'reached']) {
        await setPhase(VmPhase.defined);
        final feed = _BoundaryFeed();
        final failure = StateError('feed failed');
        final pending = waitFor(events: feed);
        final checked = outcome == 'reached'
            ? expectLater(pending, completion(isA<DateTime>()))
            : expectLater(
                pending,
                throwsA(outcome == 'error' ? same(failure) : isA<StateError>()),
              );
        await feed.started.future;
        if (outcome == 'error') {
          feed.controller.addError(failure);
        } else {
          if (outcome == 'reached') await setPhase(VmPhase.running);
          await feed.controller.close();
        }
        await checked;
        expect(feed.controller.hasListener, isFalse);
        await feed.controller.close();
      }
    },
  );

  test('rolled-back running state and event never satisfy the wait', () async {
    final feed = _WatchingFeed(
      SqliteDurableEventFeed(
        database,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    final checked = expectLater(
      waitFor(events: feed, timeout: const Duration(milliseconds: 40)),
      throwsA(isA<TimeoutException>()),
    );
    await feed.started.future;
    await expectLater(
      database.transaction((_) async {
        await setPhase(VmPhase.running);
        await SqliteEventRepository(database).append(
          type: 'vm.running',
          resourceType: ResourceType.virtualMachine,
          resourceId: vm.metadata.id,
          vmId: vm.metadata.id,
          payload: JsonObjectValue.empty,
        );
        throw StateError('rollback transition');
      }),
      throwsStateError,
    );
    await checked;
    expect(
      (await repository.get(vm.metadata.id))!.status.phase,
      VmPhase.defined,
    );
    expect(feed.cancelled, isTrue);
  });

  test(
    'missing VMs fail before subscribing and deleted VMs fail live waits',
    () async {
      final missingFeed = _BoundaryFeed();
      await expectLater(
        waitFor(events: missingFeed, vmId: VmId.generate()),
        throwsA(isA<VmNotFoundException>()),
      );
      expect(missingFeed.watches, 0);
      await missingFeed.controller.close();

      final feed = _WatchingFeed(
        SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 1),
        ),
      );
      final checked = expectLater(
        waitFor(events: feed),
        throwsA(isA<VmNotFoundException>()),
      );
      await feed.started.future;
      await database.transaction((_) async {
        await SqliteVmStateEffectAdapter(database).persistVm(
          VmControllerState.initial(
            vmId: vm.metadata.id,
            specGeneration: 1,
            restartPolicy: RestartPolicy.never,
          ).copyWith(
            deletionState: VmDeletionState.deleted,
            phase: VmPhase.deleted,
          ),
        );
        await SqliteEventRepository(database).append(
          type: 'vm.deleted',
          resourceType: ResourceType.virtualMachine,
          resourceId: vm.metadata.id,
          vmId: vm.metadata.id,
          payload: JsonObjectValue.empty,
        );
      });
      await checked;
      expect(feed.cancelled, isTrue);
    },
  );

  test(
    'a committed VM transition wakes the wait and rechecks status',
    () async {
      final feed = _WatchingFeed(
        SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 1),
        ),
      );
      final pending =
          SqliteVmConditionWaiter(repository: repository, events: feed).wait(
            VmWaitCommand(
              vmId: vm.metadata.id,
              condition: VmWaitCondition.runtimeRunning,
              timeout: const Duration(seconds: 1),
            ),
          );
      await feed.started.future.timeout(const Duration(milliseconds: 100));
      await database.transaction((_) async {
        await setPhase(VmPhase.running);
        await SqliteEventRepository(database).append(
          type: 'vm.running',
          resourceType: ResourceType.virtualMachine,
          resourceId: vm.metadata.id,
          vmId: vm.metadata.id,
          payload: JsonObjectValue.empty,
        );
      });
      expect(await pending, isA<DateTime>());
      expect(feed.cancelled, isTrue);
    },
  );
}

final class _BoundaryFeed implements DurableEventFeed {
  final controller = StreamController<Event>.broadcast();
  final started = Completer<void>();
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
    started.complete();
    return controller.stream;
  }
}

final class _ReadRepository implements VmRepository {
  _ReadRepository(this.read);
  final Future<VirtualMachine?> Function() read;
  @override
  Future<VirtualMachine?> get(VmId vmId, {bool includeDeleted = false}) =>
      read();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected repository write');
}

final class _WatchingFeed implements DurableEventFeed {
  _WatchingFeed(this.delegate);
  final DurableEventFeed delegate;
  final started = Completer<void>();
  bool cancelled = false;

  @override
  Future<int> latestSequence() => delegate.latestSequence();

  @override
  Stream<Event> watch({
    int after = 0,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
  }) {
    late StreamController<Event> controller;
    StreamSubscription<Event>? subscription;
    controller = StreamController<Event>(
      onListen: () {
        subscription = delegate
            .watch(
              after: after,
              vmId: vmId,
              operationId: operationId,
              testRunId: testRunId,
            )
            .listen(
              controller.add,
              onError: controller.addError,
              onDone: controller.close,
            );
        started.complete();
      },
      onCancel: () {
        cancelled = true;
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/private/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: true, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
