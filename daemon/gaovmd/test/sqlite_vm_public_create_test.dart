import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

// This slice composes real create and provisioning cancellation. Patch, lifecycle and wait
// are deliberately not exercised or claimed as installed production services.
void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late PublicApiServer server;
  late HttpClient client;
  late String body;

  Future<void> start() async {
    final unrelated = _OutsideCreateSlice();
    final router = PublicApiRouter();
    ResourceApiHandlers(
      vms: VmApplicationService.composed(
        repository: SqliteVmRepository(database),
        creates: SqliteVmCreateAcceptance(
          database: database,
          idempotencyRetention: const Duration(days: 30),
        ),
        patches: unrelated,
        lifecycle: unrelated,
        waiter: _OutsideVmWait(),
      ),
      operations: OperationApplicationService(
        repository: SqliteOperationRepository(database),
        mutations: SqliteVmProvisioningCancellation(
          database: database,
          idempotencyRetention: const Duration(days: 30),
        ),
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

  Future<({int status, Map<String, dynamic> json, String? location})> request(
    String method,
    String path, {
    String? data,
    String? key,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://localhost$path'),
    );
    if (key != null) request.headers.set('Idempotency-Key', key);
    if (data != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(data));
    }
    final response = await request.close();
    return (
      status: response.statusCode,
      json:
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
      location: response.headers.value('location'),
    );
  }

  Future<List<VmProvisioningOutcome>> dispatch() async {
    final bundles = await OwnedImageDirectory.open(
      await Directory('${directory.path}/vms').create(),
    );
    final images = await OwnedImageDirectory.open(
      await Directory('${directory.path}/images').create(),
    );
    try {
      return await VmProvisioningWorker(
        work: SqliteVmProvisioningWorkRepository(database),
        bundles: VmBundleStore(
          database: database,
          bundles: bundles,
          images: images,
        ),
        owner: 'http-test-worker',
      ).dispatchOnce();
    } finally {
      images.close();
      bundles.close();
    }
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vm-http-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    final spec = VmSpec(
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
    body = jsonEncode({
      'api_version': vmApiVersion,
      'kind': vmKind,
      'metadata': {'name': 'public-create'},
      'spec': spec.toJson(),
    });
    await start();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
    database.close();
    await directory.delete(recursive: true);
  });

  test(
    'HTTP create persists a pending provisioning operation and replays across restart',
    () async {
      final accepted = await request(
        'POST',
        '/v1/vms',
        data: body,
        key: 'once',
      );
      expect(accepted.status, 202);
      expect(accepted.json['state'], 'pending');
      expect(
        accepted.location,
        '/v1/operations/${accepted.json['operation_id']}',
      );
      final vmPath = '/v1/vms/${accepted.json['resource_id']}';
      final vm = await request('GET', vmPath);
      expect(vm.status, 200);
      expect((vm.json['status'] as Map)['phase'], 'provisioning');
      final job = await SqliteVmProvisioningRepository(
        database,
      ).get(VmId(accepted.json['resource_id'] as String));
      expect(job!.plan.operationId.value, accepted.json['operation_id']);
      expect(await Directory('${directory.path}/vms').exists(), isFalse);

      client.close(force: true);
      await server.close();
      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      await start();
      final replay = await request('POST', '/v1/vms', data: body, key: 'once');
      expect(replay.status, 202);
      expect(replay.json, accepted.json);
      final operation = await request('GET', accepted.location!);
      expect(operation.status, 200);
      expect(operation.json['state'], 'pending');
      final listed = await request('GET', '/v1/vms');
      expect(listed.json['items'], hasLength(1));
      final conflict = await request(
        'POST',
        '/v1/vms',
        data: '$body ',
        key: 'once',
      );
      expect(conflict.status, 409);
      expect(await SqliteOperationRepository(database).list(), hasLength(1));
    },
  );

  test(
    'HTTP create rejects a missing image as invalid spec without durable leftovers',
    () async {
      final value = jsonDecode(body) as Map<String, dynamic>;
      final missing = ImageId.generate();
      (value['spec'] as Map)['boot'] = LinuxKernelBoot(
        kernelImageId: missing,
      ).toJson();
      final invalid = await request(
        'POST',
        '/v1/vms',
        data: jsonEncode(value),
        key: 'missing',
      );
      expect(invalid.status, 422);
      expect(invalid.json['code'], 'VM_SPEC_INVALID');
      expect(await SqliteVmRepository(database).list(), isEmpty);
      expect(await SqliteOperationRepository(database).list(), isEmpty);
      final retry = await request(
        'POST',
        '/v1/vms',
        data: body,
        key: 'missing',
      );
      expect(retry.status, 202);
    },
  );

  test(
    'HTTP provisioning cancellation returns a distinct pending cleanup action',
    () async {
      final created = await request(
        'POST',
        '/v1/vms',
        data: body,
        key: 'create',
      );
      final target = created.json['operation_id'] as String;
      final cancelled = await request(
        'POST',
        '/v1/operations/$target/cancel',
        data: '{}',
        key: 'cancel',
      );
      expect(cancelled.status, 202);
      expect(cancelled.json['operation_id'], isNot(target));
      expect(cancelled.json['resource_id'], target);
      expect(cancelled.json['resource_type'], 'operation');
      expect(
        cancelled.location,
        '/v1/operations/${cancelled.json['operation_id']}',
      );
      expect(cancelled.json['state'], 'pending');
      final targetBeforeCleanup = await request('GET', created.location!);
      final actionBeforeCleanup = await request('GET', cancelled.location!);
      expect(targetBeforeCleanup.json['state'], 'pending');
      expect(actionBeforeCleanup.json['state'], 'pending');
      final job = await SqliteVmProvisioningRepository(
        database,
      ).get(VmId(created.json['resource_id'] as String));
      expect(job!.cancellationRequested, isTrue);
      final replay = await request(
        'POST',
        '/v1/operations/$target/cancel',
        data: '{}',
        key: 'cancel',
      );
      expect(replay.status, 202);
      expect(replay.json, cancelled.json);
      expect(await SqliteOperationRepository(database).list(), hasLength(2));
      expect(
        (await dispatch()).single.completion,
        VmProvisioningCompletionKind.cancelled,
      );
      expect(
        (await request('GET', created.location!)).json['state'],
        'cancelled',
      );
      expect(
        (await request('GET', cancelled.location!)).json['state'],
        'succeeded',
      );
      final waited = await request(
        'POST',
        '${cancelled.location!}/wait',
        data: '{"timeout_seconds":1}',
      );
      expect(waited.status, 200);
      expect(waited.json['state'], 'succeeded');
      final terminalReplay = await request(
        'POST',
        '/v1/operations/$target/cancel',
        data: '{}',
        key: 'cancel',
      );
      expect(terminalReplay.status, 202);
      expect(terminalReplay.json, cancelled.json);
      final rejected = await request(
        'POST',
        '/v1/operations/$target/cancel',
        data: '{}',
        key: 'too-late',
      );
      expect(rejected.status, 409);
      expect(rejected.json['code'], 'OPERATION_NOT_CANCELLABLE');
    },
  );

  test(
    'HTTP creates from one Linux image publish isolated managed disks with queryable completion',
    () async {
      final store = ImageStore(database, Directory('${directory.path}/images'));
      final source = await File(
        '${directory.path}/source',
      ).writeAsString('immutable guest bytes');
      final kernel = await store.importFile(
        source,
        type: ImageType.linuxKernel,
      );
      final disk = await store.importFile(source, type: ImageType.rawDisk);
      final value = jsonDecode(body) as Map<String, dynamic>;
      (value['spec'] as Map)['boot'] = LinuxKernelBoot(
        kernelImageId: kernel.id,
      ).toJson();
      (value['spec'] as Map)['disks'] = [
        VmDisk(
          id: 'root',
          source: ManagedImageDiskSource(disk.id),
          writable: true,
        ).toJson(),
      ];
      final accepted = await Future.wait([
        for (final key in ['vm-a', 'vm-b'])
          request(
            'POST',
            '/v1/vms',
            data: jsonEncode({
              ...value,
              'metadata': {'name': key},
            }),
            key: key,
          ),
      ]);
      expect(accepted.every((response) => response.status == 202), isTrue);
      expect(
        accepted[0].json['resource_id'],
        isNot(accepted[1].json['resource_id']),
      );
      expect(await Directory('${directory.path}/vms').exists(), isFalse);
      final outcomes = await dispatch();
      expect(outcomes, hasLength(2));
      expect(
        outcomes.every(
          (outcome) =>
              outcome.completion == VmProvisioningCompletionKind.succeeded,
        ),
        isTrue,
      );
      for (final response in accepted) {
        expect(
          (await request('GET', response.location!)).json['state'],
          'succeeded',
        );
        final vm = await request(
          'GET',
          '/v1/vms/${response.json['resource_id']}',
        );
        expect((vm.json['status'] as Map)['phase'], 'stopped');
        expect((vm.json['status'] as Map)['observed_generation'], 0);
      }
      final first = File(
        '${directory.path}/vms/${accepted[0].json['resource_id']}.gaovm/disks/root.raw',
      );
      final second = File(
        '${directory.path}/vms/${accepted[1].json['resource_id']}.gaovm/disks/root.raw',
      );
      await first.writeAsString('VM-A changed its disk');
      expect(await second.readAsString(), 'immutable guest bytes');
      expect(
        await File(
          '${directory.path}/images/sha256-${disk.digest.substring(7)}/objects/payload',
        ).readAsString(),
        'immutable guest bytes',
      );
      expect(await dispatch(), isEmpty);
    },
  );
}

final class _OutsideCreateSlice
    implements VmPatchAcceptor, VmLifecycleAcceptor, OperationWaiter {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('Called outside create slice: ${invocation.memberName}');
}

final class _OutsideVmWait implements VmConditionWaiter {
  @override
  Future<DateTime> wait(VmWaitCommand command) async =>
      fail('VM wait is outside create slice');
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
