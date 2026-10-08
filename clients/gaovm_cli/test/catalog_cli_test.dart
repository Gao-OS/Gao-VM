import 'dart:convert';
import 'dart:io';

import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late PublicApiServer server;
  late SqliteVmRepository vms;
  late SqliteOperationRepository operations;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gaovm-cli-catalog-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    vms = SqliteVmRepository(database);
    operations = SqliteOperationRepository(database);
    final outside = _Outside();
    final router = PublicApiRouter();
    ResourceApiHandlers(
      vms: VmApplicationService(
        repository: vms,
        mutations: outside,
        waiter: outside,
      ),
      operations: OperationApplicationService(
        repository: operations,
        mutations: _OutsideOperationMutation(),
        waiter: SqliteOperationWaiter(
          operations: operations,
          events: SqliteDurableEventFeed(database),
        ),
      ),
    ).register(router);
    server = PublicApiServer(
      socketPath: '${directory.path}/api.sock',
      openApiDocument: const {},
      systemHealth: _Health(),
      router: router,
    );
    await server.start();
  });
  tearDown(() async {
    await server.close();
    database.close();
    await directory.delete(recursive: true);
  });

  test(
    'VM list filters and resumes an opaque cursor through the public API',
    () async {
      final first = await vms.create(
        name: 'alpha+一',
        labels: const {'channel': 'nightly', 'team': 'agent'},
        spec: _spec(),
      );
      final second = await vms.create(
        name: 'beta 二',
        labels: const {'channel': 'nightly', 'team': 'agent'},
        spec: _spec(),
      );
      await vms.create(
        name: 'excluded',
        labels: const {'channel': 'stable'},
        spec: _spec(),
      );
      final args = [
        'vm',
        'list',
        '--label-selector',
        'channel=nightly,team=agent',
        '--sort',
        'name',
        '--limit',
        '1',
      ];
      final page = await _invoke(server, args);
      expect(page.code, 0, reason: page.error);
      final json = jsonDecode(page.output) as Map;
      expect(
        (json['items'] as List).single['metadata']['id'],
        first.metadata.id.value,
      );
      final cursor = json['next_cursor'] as String;
      final next = await _invoke(server, [...args, '--cursor', cursor]);
      expect(next.code, 0, reason: next.error);
      final nextJson = jsonDecode(next.output) as Map;
      expect(
        (nextJson['items'] as List).single['metadata']['id'],
        second.metadata.id.value,
      );
      expect(nextJson['next_cursor'], isNull);
      final wrongScope = await _invoke(server, [
        'vm',
        'list',
        '--label-selector',
        'channel=stable',
        '--sort',
        'name',
        '--limit',
        '1',
        '--cursor',
        cursor,
      ]);
      expect(wrongScope.code, 1);
      expect(
        Problem.fromJson(jsonDecode(wrongScope.error)).code,
        ErrorCode.invalidRequest,
      );
    },
  );

  test(
    'Operation list combines resource and state filters with cursor resume',
    () async {
      final vm = await vms.create(name: 'operations', spec: _spec());
      Future<Operation> create(VmId id) => operations.create(
        type: 'vm.start',
        resourceType: ResourceType.virtualMachine,
        resourceId: id,
        requestId: RequestId.generate(),
        cancellable: false,
        request: JsonObjectValue.empty,
      );
      final first = await create(vm.metadata.id);
      final second = await create(vm.metadata.id);
      final running = await create(vm.metadata.id);
      await operations.start(running.id);
      final other = await vms.create(name: 'other', spec: _spec());
      await create(other.metadata.id);
      final args = [
        'operation',
        'list',
        '--resource-type',
        'virtual_machine',
        '--resource-id',
        vm.metadata.id.value,
        '--state',
        'pending',
        '--limit',
        '1',
      ];
      final page = await _invoke(server, args);
      expect(page.code, 0, reason: page.error);
      final json = jsonDecode(page.output) as Map;
      expect((json['items'] as List).single['id'], first.id.value);
      final next = await _invoke(server, [
        ...args,
        '--cursor',
        json['next_cursor'] as String,
      ]);
      expect(next.code, 0, reason: next.error);
      final nextJson = jsonDecode(next.output) as Map;
      expect((nextJson['items'] as List).single['id'], second.id.value);
      expect(nextJson['next_cursor'], isNull);
    },
  );
}

VmSpec _spec() => VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: LinuxKernelBoot(kernelImageId: ImageId.generate()),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/fixture/disk.raw'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);

Future<({int code, String output, String error})> _invoke(
  PublicApiServer server,
  List<String> args,
) async {
  final output = StringBuffer(), error = StringBuffer();
  final code = await runCli(
    ['--socket-path', server.socketPath, ...args, '--json'],
    output: output.writeln,
    error: error.writeln,
  );
  return (code: code, output: output.toString(), error: error.toString());
}

final class _Outside implements VmMutationAcceptor, VmConditionWaiter {
  @override
  Future<OperationAcceptance> create(VmCreateCommand _) =>
      throw UnimplementedError('read-only catalog fixture');
  @override
  Future<OperationAcceptance> patch(VmPatchCommand _) =>
      throw UnimplementedError('read-only catalog fixture');
  @override
  Future<OperationAcceptance> lifecycle(VmLifecycleCommand _) =>
      throw UnimplementedError('read-only catalog fixture');
  @override
  Future<DateTime> wait(VmWaitCommand _) =>
      throw UnimplementedError('read-only catalog fixture');
}

final class _OutsideOperationMutation implements OperationMutationAcceptor {
  @override
  Future<OperationAcceptance> cancel(OperationCancelCommand _) =>
      throw UnimplementedError('read-only catalog fixture');
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
