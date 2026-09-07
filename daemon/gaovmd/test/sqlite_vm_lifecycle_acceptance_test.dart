import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late GaoVmDatabase database;
  late Directory directory;
  late VirtualMachine vm;
  late VmController controller;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vm-accept-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    vm = await SqliteVmRepository(
      database,
    ).create(name: 'acceptance', spec: _spec);
    controller = VmController(
      initialState: VmControllerState.initial(
        vmId: vm.metadata.id,
        specGeneration: 1,
        restartPolicy: RestartPolicy.never,
      ),
      effectRunner: _Runner(),
    );
  });
  tearDown(() async {
    await controller.shutdown();
    database.close();
    await directory.delete(recursive: true);
  });
  Future<OperationAcceptance> accept(
    VmLifecycleAction action,
    String key, {
    List<int> body = const [],
  }) => controller.accept(
    SqliteVmLifecycleAcceptance(
      database: database,
      idempotencyRetention: const Duration(days: 1),
      command: VmLifecycleCommand(
        requestId: RequestId.generate(),
        idempotencyKey: key,
        requestBody: body,
        vmId: vm.metadata.id,
        action: action,
      ),
    ),
  );

  test(
    'atomically accepts desired state, operation, FIFO command and event',
    () async {
      final first = await accept(VmLifecycleAction.start, 'start');
      final second = await accept(VmLifecycleAction.stop, 'stop');
      expect(first.state, OperationState.pending);
      expect(second.state, OperationState.pending);
      expect(controller.acceptedIntentRevision, 2);
      final stored = await SqliteVmRepository(database).get(vm.metadata.id);
      expect(stored!.status.desiredState, DesiredState.stopped);
      expect(await SqliteOperationRepository(database).list(), hasLength(2));
      final claims = await SqliteVmCommandRepository(
        database,
      ).claim(owner: 'worker', lease: const Duration(seconds: 30));
      expect(claims, hasLength(1));
      expect(claims.single.record.operationId, first.operationId);
      expect(claims.single.record.payload.toJson()['intent_revision'], 1);
      final events = await SqliteEventRepository(database).list();
      expect(
        events.where((event) => event.type == 'vm.action_accepted'),
        hasLength(2),
      );
    },
  );

  test(
    'concurrent acceptances retain submission order and revisions',
    () async {
      final accepted = await Future.wait([
        accept(VmLifecycleAction.start, 'first'),
        accept(VmLifecycleAction.stop, 'second'),
        accept(VmLifecycleAction.start, 'third'),
      ]);
      final operations = SqliteOperationRepository(database);
      for (var index = 0; index < accepted.length; index++) {
        final operation = await operations.get(accepted[index].operationId);
        expect(operation!.request.toJson()['intent_revision'], index + 1);
      }
      expect(controller.acceptedIntentRevision, 3);
      expect(controller.state.appliedIntentRevision, 0);
      expect(
        (await SqliteVmRepository(
          database,
        ).get(vm.metadata.id))!.status.desiredState,
        DesiredState.running,
      );
    },
  );

  test('conflicting request bytes do not create another intent', () async {
    final original = await accept(
      VmLifecycleAction.start,
      'key',
      body: [123, 125],
    );
    final events = await SqliteEventRepository(database).list();
    await expectLater(
      accept(VmLifecycleAction.start, 'key', body: [123, 32, 125]),
      throwsA(isA<IdempotencyConflictException>()),
    );
    expect(controller.acceptedIntentRevision, 1);
    expect(await SqliteOperationRepository(database).list(), hasLength(1));
    expect(
      await SqliteEventRepository(database).list(),
      hasLength(events.length),
    );
    final claims = await SqliteVmCommandRepository(
      database,
    ).claim(owner: 'worker', lease: const Duration(seconds: 30));
    expect(claims.single.record.operationId, original.operationId);
    expect(
      (await accept(VmLifecycleAction.start, 'key', body: [123, 125])).toJson(),
      original.toJson(),
    );
  });

  test('replays original acceptance even after operation failure', () async {
    final original = await accept(VmLifecycleAction.start, 'key');
    final operations = SqliteOperationRepository(database);
    await operations.start(original.operationId);
    await operations.fail(
      original.operationId,
      error: OperationError(
        code: ErrorCode.internalError,
        message: 'failed',
        retryable: false,
        details: JsonObjectValue.empty,
      ),
    );
    final replay = await accept(VmLifecycleAction.start, 'key');
    expect(replay.toJson(), original.toJson());
    expect(await operations.list(), hasLength(1));
    expect(controller.acceptedIntentRevision, 1);
  });

  test(
    'outbox failure rolls back desired, operation and controller cache',
    () async {
      await database.transaction(
        (db) => db.execute(
          '''CREATE TRIGGER reject_command BEFORE INSERT ON outbox
      WHEN NEW.topic = 'vm.commands' BEGIN SELECT RAISE(ABORT, 'injected'); END''',
        ),
      );
      await expectLater(
        accept(VmLifecycleAction.start, 'key'),
        throwsA(anything),
      );
      expect(controller.acceptedIntentRevision, 0);
      expect(
        (await SqliteVmRepository(
          database,
        ).get(vm.metadata.id))!.status.desiredState,
        DesiredState.stopped,
      );
      expect(await SqliteOperationRepository(database).list(), isEmpty);
      expect(await SqliteEventRepository(database).list(), isEmpty);
      expect(
        await database.read(
          (db) => db.select('SELECT * FROM idempotency_keys'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'accepted delete blocks new mutations but permits its own replay',
    () async {
      final deleted = await accept(VmLifecycleAction.delete, 'delete');
      await expectLater(
        SqliteOperationRepository(database).cancel(deleted.operationId),
        throwsA(isA<OperationNotCancellableException>()),
      );
      await expectLater(
        accept(VmLifecycleAction.start, 'start'),
        throwsA(isA<VmAcceptanceConflict>()),
      );
      expect(
        (await accept(VmLifecycleAction.delete, 'delete')).toJson(),
        deleted.toJson(),
      );
    },
  );

  test('failed deletion permits one fresh cleanup attempt', () async {
    final original = await accept(VmLifecycleAction.delete, 'original');
    final operations = SqliteOperationRepository(database);
    await expectLater(
      accept(VmLifecycleAction.delete, 'concurrent'),
      throwsA(isA<VmAcceptanceConflict>()),
    );
    await operations.start(original.operationId);
    await operations.fail(
      original.operationId,
      error: OperationError(
        code: ErrorCode.internalError,
        message: 'managed file cleanup failed',
        retryable: true,
        details: JsonObjectValue.empty,
      ),
    );
    final retry = await accept(VmLifecycleAction.delete, 'retry');
    expect(retry.operationId, isNot(original.operationId));
    expect(retry.state, OperationState.pending);
    expect(controller.acceptedIntentRevision, 2);
    await expectLater(
      accept(VmLifecycleAction.start, 'start'),
      throwsA(isA<VmAcceptanceConflict>()),
    );
    await expectLater(
      accept(VmLifecycleAction.delete, 'another'),
      throwsA(isA<VmAcceptanceConflict>()),
    );
    expect(await operations.list(), hasLength(2));
    expect(
      (await accept(VmLifecycleAction.delete, 'original')).toJson(),
      original.toJson(),
    );
  });

  test(
    'old persistence cannot replace a newer accepted desired state',
    () async {
      await accept(VmLifecycleAction.start, 'start');
      await SqliteVmStateEffectAdapter(database).persistVm(controller.state);
      expect(
        (await SqliteVmRepository(
          database,
        ).get(vm.metadata.id))!.status.desiredState,
        DesiredState.running,
      );
    },
  );

  test(
    'rejects caller-owned transaction before publishing acceptance',
    () async {
      await database.transaction((_) async {
        await expectLater(
          accept(VmLifecycleAction.start, 'start'),
          throwsStateError,
        );
      });
      expect(controller.acceptedIntentRevision, 0);
    },
  );
}

final class _Runner implements VmEffectRunner {
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async =>
      null;
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
