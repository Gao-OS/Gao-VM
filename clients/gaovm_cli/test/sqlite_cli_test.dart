import 'dart:convert';
import 'dart:io';

import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  test(
    'CLI create, replay, query and cancel use durable public services',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gaovm-cli-sqlite-',
      );
      imageFileMode(directory.path, 0x1c0);
      final database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      final outside = _Outside();
      final router = PublicApiRouter();
      ResourceApiHandlers(
        vms: VmApplicationService.composed(
          repository: SqliteVmRepository(database),
          creates: SqliteVmCreateAcceptance(
            database: database,
            idempotencyRetention: const Duration(days: 30),
          ),
          patches: outside,
          lifecycle: outside,
          waiter: outside,
        ),
        operations: OperationApplicationService(
          repository: SqliteOperationRepository(database),
          mutations: SqliteVmProvisioningCancellation(
            database: database,
            idempotencyRetention: const Duration(days: 30),
          ),
          waiter: SqliteOperationWaiter(
            operations: SqliteOperationRepository(database),
            events: SqliteDurableEventFeed(database),
          ),
        ),
      ).register(router);
      final server = PublicApiServer(
        socketPath: '${directory.path}/api.sock',
        openApiDocument: const {},
        systemHealth: _Health(),
        router: router,
      );
      try {
        final kernel = await File(
          '${directory.path}/kernel',
        ).writeAsString('kernel');
        final image = await ImageStore(
          database,
          Directory('${directory.path}/images'),
        ).importFile(kernel, type: ImageType.linuxKernel);
        final disk = await File(
          '${directory.path}/external.raw',
        ).writeAsString('external disk');
        final spec = VmSpec(
          cpu: 2,
          memoryBytes: 268435456,
          boot: LinuxKernelBoot(kernelImageId: image.id),
          disks: [
            VmDisk(
              id: 'root',
              source: ExternalDiskSource(disk.path),
              writable: true,
            ),
          ],
          networks: [DisconnectedNetwork(id: 'net0')],
          graphics: GraphicsConfig(enabled: false),
          serial: const SerialConfig(enabled: true, capture: true),
          guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
          restartPolicy: RestartPolicy.never,
        );
        final body = jsonEncode({
          'api_version': vmApiVersion,
          'kind': vmKind,
          'metadata': {'name': 'from-cli'},
          'spec': spec.toJson(),
        });
        await server.start();
        final created = await _invoke(server, [
          'vm',
          'create',
          '--body-json',
          body,
          '--idempotency-key',
          'cli-create',
        ]);
        expect(created.code, 0, reason: created.error);
        final acceptance = jsonDecode(created.output) as Map;
        final vmId = acceptance['resource_id'] as String;
        final operationId = acceptance['operation_id'] as String;
        final replay = await _invoke(server, [
          'vm',
          'create',
          '--body-json',
          body,
          '--idempotency-key',
          'cli-create',
        ]);
        expect(replay.code, 0, reason: replay.error);
        expect(jsonDecode(replay.output), acceptance);
        final fetched = await _invoke(server, ['vm', 'get', vmId]);
        expect(fetched.code, 0, reason: fetched.error);
        final vm = VirtualMachine.fromJson(jsonDecode(fetched.output));
        expect(vm.metadata.id.value, vmId);
        expect(vm.metadata.name, 'from-cli');
        final operation = await _invoke(server, [
          'operation',
          'get',
          operationId,
        ]);
        expect(operation.code, 0, reason: operation.error);
        expect(
          Operation.fromJson(jsonDecode(operation.output)).resourceId,
          vm.metadata.id,
        );
        final other = await GaoVmApiClient(
          socketPath: server.socketPath,
        ).request('GET', '/v1/vms/$vmId');
        expect(VirtualMachine.fromJson(other.body.toJson()), vm);
        final cancellation = await _invoke(server, [
          'operation',
          'cancel',
          operationId,
          '--idempotency-key',
          'cli-cancel',
        ]);
        expect(cancellation.code, 0, reason: cancellation.error);
        final cancelId =
            jsonDecode(cancellation.output)['operation_id'] as String;
        expect(cancelId, isNot(operationId));
        expect(
          (await SqliteOperationRepository(
            database,
          ).get(OperationId(operationId)))!.state,
          OperationState.pending,
        );
        final root = await OwnedImageDirectory.open(directory);
        final bundles = root.createDirectory('vms');
        final images = root.directory('images');
        try {
          final outcomes = await VmProvisioningWorker(
            work: SqliteVmProvisioningWorkRepository(database),
            bundles: VmBundleStore(
              database: database,
              bundles: bundles,
              images: images,
            ),
            owner: 'cli-test-worker',
          ).dispatchOnce();
          expect(
            outcomes.single.completion,
            VmProvisioningCompletionKind.cancelled,
          );
        } finally {
          images.close();
          bundles.close();
          root.close();
        }
        final cancelled = await _invoke(server, [
          'operation',
          'wait',
          operationId,
          '--timeout-seconds',
          '1',
        ]);
        expect(cancelled.code, 1, reason: cancelled.error);
        expect(jsonDecode(cancelled.output)['state'], 'cancelled');
        final complete = await _invoke(server, [
          'operation',
          'wait',
          cancelId,
          '--timeout-seconds',
          '1',
        ]);
        expect(complete.code, 0, reason: complete.error);
        expect(jsonDecode(complete.output)['state'], 'succeeded');
        expect(await disk.readAsString(), 'external disk');
      } finally {
        await server.close();
        database.close();
        await directory.delete(recursive: true);
      }
    },
  );
}

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

final class _Outside
    implements VmPatchAcceptor, VmLifecycleAcceptor, VmConditionWaiter {
  @override
  Future<OperationAcceptance> patch(VmPatchCommand _) =>
      throw UnimplementedError('outside create/query slice');
  @override
  Future<OperationAcceptance> lifecycle(VmLifecycleCommand _) =>
      throw UnimplementedError('outside create/query slice');
  @override
  Future<DateTime> wait(VmWaitCommand _) =>
      throw UnimplementedError('outside create/query slice');
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
