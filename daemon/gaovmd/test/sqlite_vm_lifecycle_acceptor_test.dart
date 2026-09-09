import 'dart:io';
import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late VmRegistry registry;
  late VirtualMachine vm;
  late _NoRuntimeEffects effects;
  late DateTime now;

  void openRegistry() {
    effects = _NoRuntimeEffects();
    registry = VmRegistry(
      repository: SqliteVmRepository(database),
      operations: SqliteOperationRepository(database),
      recovery: SqliteVmIntentRecoveryRepository(database),
      effectRunner: effects,
    );
  }

  setUp(() async {
    now = DateTime.utc(2026, 9, 7);
    directory = await Directory.systemTemp.createTemp('lifecycle-entry-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    vm = await SqliteVmRepository(database).create(name: 'vm', spec: _spec);
    openRegistry();
  });
  tearDown(() async {
    await registry.shutdown();
    database.close();
    await directory.delete(recursive: true);
  });
  SqliteVmLifecycleAcceptor acceptor() => SqliteVmLifecycleAcceptor(
    database: database,
    registry: registry,
    idempotencyRetention: const Duration(days: 30),
    now: () => now,
  );
  VmLifecycleCommand command({
    VmLifecycleAction action = VmLifecycleAction.delete,
    String? key = 'once',
    List<int> body = const [],
    VmId? vmId,
  }) => VmLifecycleCommand(
    requestId: RequestId.generate(),
    idempotencyKey: key,
    requestBody: body,
    vmId: vmId ?? vm.metadata.id,
    action: action,
  );

  test(
    'completed delete replays after catalog reopen without activating a missing VM',
    () async {
      final accepted = await acceptor().lifecycle(command());
      expect(accepted.state, OperationState.pending);
      expect(effects.calls, isEmpty);
      // Model the durable result of deletion, without exercising runtime cleanup.
      final repository = SqliteVmRepository(database);
      final current = (await repository.get(vm.metadata.id))!;
      final deleting = await repository.markDeleting(
        vm.metadata.id,
        expectedRevision: current.metadata.revision,
      );
      await repository.tombstone(
        vm.metadata.id,
        expectedRevision: deleting.metadata.revision,
      );
      final operations = SqliteOperationRepository(database);
      await operations.start(accepted.operationId);
      await operations.succeed(accepted.operationId);
      await registry.shutdown();
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      openRegistry();
      final replay = await acceptor().lifecycle(command());
      expect(replay.toJson(), accepted.toJson());
      expect(registry.activeCount, 0);
      expect(effects.calls, isEmpty);
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
    },
  );

  test(
    'delete completing between replay lookup and VM lookup still returns its acceptance',
    () async {
      await registry.shutdown();
      late OperationAcceptance winner;
      registry = VmRegistry(
        repository: _BeforeGet(SqliteVmRepository(database), () async {
          final controller = VmController(
            initialState: VmControllerState.initial(
              vmId: vm.metadata.id,
              specGeneration: 1,
              restartPolicy: RestartPolicy.never,
            ),
            effectRunner: effects,
          );
          try {
            winner = await controller.accept(
              SqliteVmLifecycleAcceptance(
                database: database,
                command: command(),
                idempotencyRetention: const Duration(days: 30),
                now: () => now,
              ),
            );
            final repository = SqliteVmRepository(database);
            final current = (await repository.get(vm.metadata.id))!;
            final deleting = await repository.markDeleting(
              vm.metadata.id,
              expectedRevision: current.metadata.revision,
            );
            await repository.tombstone(
              vm.metadata.id,
              expectedRevision: deleting.metadata.revision,
            );
            final operations = SqliteOperationRepository(database);
            await operations.start(winner.operationId);
            await operations.succeed(winner.operationId);
          } finally {
            await controller.shutdown();
          }
        }),
        operations: SqliteOperationRepository(database),
        recovery: SqliteVmIntentRecoveryRepository(database),
        effectRunner: effects,
      );
      expect((await acceptor().lifecycle(command())).toJson(), winner.toJson());
      expect(registry.activeCount, 0);
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
    },
  );

  test(
    'concurrent same-key lifecycle requests commit one intent and no runtime effect',
    () async {
      final requests = await Future.wait([
        for (var i = 0; i < 8; i++)
          acceptor().lifecycle(command(action: VmLifecycleAction.start)),
      ]);
      expect(
        requests.map((value) => value.toJson()),
        everyElement(requests.first.toJson()),
      );
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(registry.activeCount, 1);
      final controller = (await registry.get(vm.metadata.id))!;
      expect(controller.acceptedIntentRevision, 1);
      expect(controller.state.appliedIntentRevision, 0);
      expect(effects.calls, isEmpty);
      final work = await SqliteVmCommandRepository(
        database,
      ).claim(owner: 'inspect', lease: const Duration(seconds: 30));
      expect(work, hasLength(1));
      expect(work.single.record.operationId, requests.first.operationId);
    },
  );

  test(
    'fresh lifecycle requests serialize in one controller without adopting work in API path',
    () async {
      final actions = [
        VmLifecycleAction.start,
        VmLifecycleAction.stop,
        VmLifecycleAction.restart,
        VmLifecycleAction.kill,
        VmLifecycleAction.delete,
      ];
      final responses = await Future.wait([
        for (final action in actions)
          acceptor().lifecycle(command(action: action, key: null)),
      ]);
      final operations = SqliteOperationRepository(database);
      for (var i = 0; i < actions.length; i++) {
        final operation = (await operations.get(responses[i].operationId))!;
        expect(operation.type, 'vm.${actions[i].name}');
        expect(operation.state, OperationState.pending);
        expect(operation.request.toJson()['intent_revision'], i + 1);
      }
      expect(
        (await registry.get(vm.metadata.id))!.acceptedIntentRevision,
        actions.length,
      );
      expect(effects.calls, isEmpty);
    },
  );

  test(
    'lookup conflict and missing target do not activate controllers or accept new work',
    () async {
      final accepted = await acceptor().lifecycle(
        command(action: VmLifecycleAction.start, body: [123, 125]),
      );
      await registry.shutdown();
      openRegistry();
      await expectLater(
        acceptor().lifecycle(
          command(action: VmLifecycleAction.start, body: [123, 32, 125]),
        ),
        throwsA(isA<IdempotencyConflictException>()),
      );
      expect(registry.activeCount, 0);
      await expectLater(
        acceptor().lifecycle(command(vmId: VmId.generate(), key: null)),
        throwsA(isA<VmNotFoundException>()),
      );
      expect(registry.activeCount, 0);
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(
        (await acceptor().lifecycle(
          command(action: VmLifecycleAction.start, body: [123, 125]),
        )).operationId,
        accepted.operationId,
      );
      expect(registry.activeCount, 0);
    },
  );

  test(
    'acceptance rejects caller transactions before lookup or controller activation',
    () async {
      await expectLater(
        database.transaction((_) => acceptor().lifecycle(command())),
        throwsStateError,
      );
      final other = await GaoVmDatabase.open('${directory.path}/catalog.db');
      try {
        await expectLater(
          other.transaction((_) => acceptor().lifecycle(command())),
          throwsStateError,
        );
      } finally {
        other.close();
      }
      expect(registry.activeCount, 0);
      expect(await SqliteOperationRepository(database).list(), isEmpty);
    },
  );

  test(
    'expired acceptance does not replay and creates a fresh lifecycle intent',
    () async {
      final first = await acceptor().lifecycle(
        command(action: VmLifecycleAction.start),
      );
      now = now.add(const Duration(days: 31));
      final second = await acceptor().lifecycle(
        command(action: VmLifecycleAction.start),
      );
      expect(second.operationId, isNot(first.operationId));
      expect((await registry.get(vm.metadata.id))!.acceptedIntentRevision, 2);
      expect(await SqliteOperationRepository(database).list(), hasLength(2));
    },
  );

  test(
    'closed registry allows durable replay but rejects fresh acceptance',
    () async {
      final first = await acceptor().lifecycle(
        command(action: VmLifecycleAction.start),
      );
      await registry.shutdown();
      expect(
        (await acceptor().lifecycle(
          command(action: VmLifecycleAction.start),
        )).toJson(),
        first.toJson(),
      );
      await expectLater(
        acceptor().lifecycle(
          command(action: VmLifecycleAction.start, key: 'fresh'),
        ),
        throwsA(isA<VmRegistryClosedException>()),
      );
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
    },
  );

  test(
    'malformed or wrong-VM replay fails before controller activation',
    () async {
      final request = command(action: VmLifecycleAction.start);
      await acceptor().lifecycle(request);
      final stored =
          (await SqliteIdempotencyRepository(
                database,
                retention: const Duration(days: 30),
                now: () => now,
              ).lookup(
                scope: SqliteVmLifecycleAcceptance.scopeFor(request),
                key: request.idempotencyKey!,
                requestBody: request.requestBody,
              ))!
              .response
              .toJson();
      await registry.shutdown();
      openRegistry();
      for (final corrupted in [
        {...stored, 'intent_revision': 0},
        {...stored, 'unexpected': true},
        {
          ...stored,
          'acceptance': {
            ...Map<String, Object?>.from(stored['acceptance'] as Map),
            'resource_id': VmId.generate().value,
          },
        },
      ]) {
        await database.read(
          (db) => db.execute(
            'UPDATE idempotency_keys SET response_json = ? WHERE scope = ? AND key = ?',
            [
              jsonEncode(corrupted),
              SqliteVmLifecycleAcceptance.scopeFor(request),
              request.idempotencyKey,
            ],
          ),
        );
        await expectLater(acceptor().lifecycle(request), throwsFormatException);
        expect(registry.activeCount, 0);
      }
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
    },
  );
}

final class _BeforeGet implements VmRepository {
  _BeforeGet(this.inner, this.beforeGet);
  final VmRepository inner;
  final Future<void> Function() beforeGet;
  @override
  Future<VirtualMachine?> get(VmId id, {bool includeDeleted = false}) async {
    await beforeGet();
    return inner.get(id, includeDeleted: includeDeleted);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('Unexpected repository call: ${invocation.memberName}');
}

final class _NoRuntimeEffects implements VmEffectRunner {
  final calls = <VmEffect>[];
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    calls.add(effect);
    return null;
  }
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/tmp/root.raw'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
