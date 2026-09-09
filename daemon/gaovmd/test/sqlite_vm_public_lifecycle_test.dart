import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

// Public acceptance only: no dispatcher or runtime is installed in this fixture.
void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late PublicApiServer server;
  late HttpClient client;
  late VmRegistry registry;
  late VirtualMachine vm;
  late _RuntimeBoundary runtime;

  Future<void> openServer() async {
    runtime = _RuntimeBoundary();
    registry = VmRegistry(
      repository: SqliteVmRepository(database),
      operations: SqliteOperationRepository(database),
      recovery: SqliteVmIntentRecoveryRepository(database),
      effectRunner: runtime,
    );
    final unrelated = _OutsideLifecycle();
    final router = PublicApiRouter();
    ResourceApiHandlers(
      vms: VmApplicationService.composed(
        repository: SqliteVmRepository(database),
        creates: unrelated,
        patches: unrelated,
        lifecycle: SqliteVmLifecycleAcceptor(
          database: database,
          registry: registry,
          idempotencyRetention: const Duration(days: 30),
        ),
        waiter: _OutsideVmWait(),
      ),
      operations: OperationApplicationService(
        repository: SqliteOperationRepository(database),
        mutations: unrelated,
        waiter: unrelated,
      ),
    ).register(router);
    server = PublicApiServer(
      socketPath: '${directory.path}/api.sock',
      openApiDocument: const {},
      systemHealth: _Health(),
      router: router,
    );
    await server.start();
    client = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) => Socket.startConnect(
        InternetAddress(
          '${directory.path}/api.sock',
          type: InternetAddressType.unix,
        ),
        0,
      );
  }

  Future<void> closeServer() async {
    client.close(force: true);
    await server.close();
    await registry.shutdown();
  }

  Future<({int status, Map<String, dynamic> json, String? location})> request(
    String method,
    String path, {
    String? body,
    String? key,
  }) async {
    final outgoing = await client.openUrl(
      method,
      Uri.parse('http://localhost$path'),
    );
    if (key != null) outgoing.headers.set('Idempotency-Key', key);
    if (body != null) {
      outgoing.headers.contentType = ContentType.json;
      outgoing.add(utf8.encode(body));
    }
    final incoming = await outgoing.close();
    return (
      status: incoming.statusCode,
      json:
          jsonDecode(await utf8.decoder.bind(incoming).join())
              as Map<String, dynamic>,
      location: incoming.headers.value('location'),
    );
  }

  String path(VmLifecycleAction action, [VmId? id]) =>
      '/v1/vms/${(id ?? vm.metadata.id).value}${action == VmLifecycleAction.delete ? '' : '/actions/${action.name}'}';
  String method(VmLifecycleAction action) =>
      action == VmLifecycleAction.delete ? 'DELETE' : 'POST';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vm-http-lifecycle-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    vm = await SqliteVmRepository(
      database,
    ).create(name: 'stopped', spec: _spec);
    await SqliteVmStateEffectAdapter(database).persistRuntime(
      VmControllerState.initial(
        vmId: vm.metadata.id,
        specGeneration: 1,
        restartPolicy: RestartPolicy.never,
      ).copyWith(phase: VmPhase.stopped),
    );
    await openServer();
  });
  tearDown(() async {
    await closeServer();
    database.close();
    await directory.delete(recursive: true);
  });

  for (final action in VmLifecycleAction.values) {
    test(
      'HTTP ${action.name} returns durable pending acceptance without runtime dispatch',
      () async {
        final accepted = await request(
          method(action),
          path(action),
          body: '{"reason":"test"}',
          key: 'once',
        );
        expect(accepted.status, 202);
        expect(accepted.json['state'], 'pending');
        expect(accepted.json['resource_id'], vm.metadata.id.value);
        expect(
          accepted.location,
          '/v1/operations/${accepted.json['operation_id']}',
        );
        expect(runtime.effects, isEmpty);
        final operation = await request('GET', accepted.location!);
        expect(operation.status, 200);
        expect(operation.json['state'], 'pending');
        expect(operation.json['type'], 'vm.${action.name}');
        final replay = await request(
          method(action),
          path(action),
          body: '{"reason":"test"}',
          key: 'once',
        );
        expect(replay.status, 202);
        expect(replay.json, accepted.json);
        expect(await SqliteOperationRepository(database).list(), hasLength(1));
        final claims = await SqliteVmCommandRepository(
          database,
        ).claim(owner: 'evidence', lease: const Duration(seconds: 30));
        expect(
          claims.single.record.operationId.value,
          accepted.json['operation_id'],
        );
        expect(claims.single.record.action.name, action.name);
        expect(runtime.effects, isEmpty);
      },
    );
  }

  test(
    'HTTP delete retry replays after tombstone and cold registry restart',
    () async {
      final accepted = await request(
        'DELETE',
        path(VmLifecycleAction.delete),
        body: '{}',
        key: 'delete',
      );
      expect(accepted.status, 202);
      // Seed the durable outcome of completed deletion. This fixture does not
      // claim that runtime or filesystem cleanup has executed.
      await database.transaction((_) async {
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
        final operationId = OperationId(
          accepted.json['operation_id'] as String,
        );
        await operations.start(operationId);
        await operations.succeed(operationId);
      });
      await closeServer();
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      await openServer();
      final replay = await request(
        'DELETE',
        path(VmLifecycleAction.delete),
        body: '{}',
        key: 'delete',
      );
      expect(replay.status, 202);
      expect(replay.json, accepted.json);
      expect(
        (await request('GET', accepted.location!)).json['state'],
        'succeeded',
      );
      expect(registry.activeCount, 0);
      expect(runtime.effects, isEmpty);
      final conflict = await request(
        'DELETE',
        path(VmLifecycleAction.delete),
        body: '{} ',
        key: 'delete',
      );
      expect(conflict.status, 409);
      expect(conflict.json['code'], 'IDEMPOTENCY_CONFLICT');
      final fresh = await request(
        'DELETE',
        path(VmLifecycleAction.delete),
        body: '{}',
        key: 'fresh',
      );
      expect(fresh.status, 404);
      expect(fresh.json['code'], 'VM_NOT_FOUND');
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(registry.activeCount, 0);
      expect(runtime.effects, isEmpty);
    },
  );

  test(
    'HTTP lifecycle rejects provisioning VMs before controller activation',
    () async {
      final accepted =
          await SqliteVmCreateAcceptance(
            database: database,
            idempotencyRetention: const Duration(days: 30),
          ).accept(
            VmCreateCommand(
              requestId: RequestId.generate(),
              idempotencyKey: 'provisional',
              requestBody: const [],
              name: 'provisional',
              spec: _spec,
            ),
          );
      final id = accepted.resourceId as VmId;
      for (final action in VmLifecycleAction.values) {
        final response = await request(
          method(action),
          path(action, id),
          body: '{}',
          key: action.name,
        );
        expect(response.status, 409, reason: action.name);
        expect(response.json['code'], 'VM_OPERATION_CONFLICT');
      }
      expect(registry.activeCount, 0);
      expect(runtime.effects, isEmpty);
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.pending,
      );
    },
  );

  test(
    'HTTP new lifecycle requests conflict with accepted deletion without losing its replay',
    () async {
      final deletion = await request(
        'DELETE',
        path(VmLifecycleAction.delete),
        body: '{}',
        key: 'delete',
      );
      expect(deletion.status, 202);
      for (final action in VmLifecycleAction.values) {
        final blocked = await request(
          method(action),
          path(action),
          body: '{}',
          key: 'new-${action.name}',
        );
        expect(blocked.status, 409, reason: action.name);
        expect(blocked.json['code'], 'VM_OPERATION_CONFLICT');
      }
      final replay = await request(
        'DELETE',
        path(VmLifecycleAction.delete),
        body: '{}',
        key: 'delete',
      );
      expect(replay.status, 202);
      expect(replay.json, deletion.json);
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
      expect(runtime.effects, isEmpty);
    },
  );
}

final class _RuntimeBoundary implements VmEffectRunner {
  final effects = <VmEffect>[];
  @override
  Future<VmCommand?> run(VmEffect effect, VmControllerState state) async {
    effects.add(effect);
    return null;
  }
}

final class _OutsideLifecycle
    implements
        VmCreateAcceptor,
        VmPatchAcceptor,
        OperationMutationAcceptor,
        OperationWaiter {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('Outside lifecycle slice: ${invocation.memberName}');
}

final class _OutsideVmWait implements VmConditionWaiter {
  @override
  Future<DateTime> wait(VmWaitCommand command) async =>
      fail('VM wait is outside lifecycle slice');
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}

final _spec = VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/external/root.raw'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
