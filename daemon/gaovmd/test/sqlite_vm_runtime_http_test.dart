import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

// Real HTTP, SQLite, filesystem, scheduler, and driver subprocesses. The fake
// subprocess replaces VZ only. Guest-service readiness is excluded.
void main() {
  test(
    'HTTP provisioning and runtime recover one crashed driver without disturbing another VM',
    () async {
      final root =
          await (Platform.isMacOS
                  ? Directory('/private/tmp')
                  : Directory.systemTemp)
              .createTemp('gvm-http-');
      final stateRoot = await OwnedImageDirectory.open(root);
      final ownership = (await DaemonOwnership.tryAcquire(stateRoot))!;
      addTearDown(() {
        ownership.close();
        stateRoot.close();
      });
      final database = await GaoVmDatabase.open('${root.path}/catalog.db');
      final imageStore = ImageStore(database, Directory('${root.path}/images'));
      final kernel = await File(
        '${root.path}/kernel',
      ).writeAsString('kernel bytes');
      final disk = await File(
        '${root.path}/disk',
      ).writeAsString('base disk bytes');
      final kernelImage = await imageStore.importFile(
        kernel,
        type: ImageType.linuxKernel,
      );
      final diskImage = await imageStore.importFile(
        disk,
        type: ImageType.rawDisk,
      );
      final vmRoot = await Directory('${root.path}/vms').create();
      imageFileMode(vmRoot.path, 0x1c0);
      final bundles = await OwnedImageDirectory.open(vmRoot);
      final images = await OwnedImageDirectory.open(
        Directory('${root.path}/images'),
      );
      final failures = <Object>[];
      final manager = DriverProcessManager(
        layout: DriverRuntimeLayout('${root.path}/run'),
        resolveExecutable: (_) => DriverExecutable(
          path: Platform.resolvedExecutable,
          prefixArguments: [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/test/fixtures/fake_driver_v2.dart',
          ],
        ),
        resolveBundlePath: (id) => '${bundles.path}/${id.value}.gaovm',
      );
      late VmRegistry registry;
      final leaseLossHandled = Completer<void>();
      final drivers = RuntimeDriverEffectAdapter.scopedConfiguration(
        factory: manager,
        withConfiguration: VmRuntimeConfigurationResolver(
          assets: SqliteVmRuntimeAssets(
            database: database,
            bundles: bundles,
            images: images,
          ),
        ).withConfiguration,
        dispatch: (id, command) async {
          final controller = await registry.get(id);
          if (controller != null) await controller.submit(command);
        },
      );
      final scheduler = HostScheduler(
        leases: SqliteHostLeaseRepository(database),
        catalog: SqliteHostCapacityCatalog(database, diskBytes: (_) => 0),
        metrics: _Metrics(),
        limits: HostSchedulerLimits(
          maxRunningVms: 3,
          maxConcurrentBoots: 3,
          maxDriverProcesses: 3,
          maxCpuCount: 8,
          maxMemoryBytes: 2147483648,
          minFreeDiskBytes: 0,
        ),
        ownerId: 'http-test',
        renewalInterval: const Duration(milliseconds: 100),
        onLeaseLost: (vmId, spec, operation, generation, error) async {
          await registry.handleHostLeaseLost(
            vmId,
            spec,
            operation,
            generation,
            error,
          );
          if (!leaseLossHandled.isCompleted) leaseLossHandled.complete();
        },
      );
      final operations = SqliteOperationRepository(database);
      final runner = RepositoryVmEffectRunner(
        database: database,
        operations: operations,
        events: SqliteEventRepository(database),
        persistence: SqliteVmStateEffectAdapter(database),
        leases: scheduler,
        drivers: drivers,
        managedFiles: SqliteVmManagedFileEffectAdapter(
          database: database,
          bundles: bundles,
        ),
      );
      registry = VmRegistry(
        repository: SqliteVmRepository(database),
        operations: operations,
        effectRunner: runner,
        recovery: SqliteVmIntentRecoveryRepository(database),
      );
      final commands = VmCommandDispatchLoop(
        dispatcher: VmCommandDispatcher(
          commands: SqliteVmCommandRepository(database),
          target: SqliteVmCommandTarget(
            database: database,
            registry: registry,
            effectRunner: runner,
          ),
          owner: 'http-test',
        ),
        interval: const Duration(milliseconds: 10),
        onDispatch: (results) => failures.addAll(
          results
              .where((result) => result.error != null)
              .map((result) => result.error!),
        ),
        onError: (error, _) => failures.add(error),
      );
      final provisioning = VmProvisioningDispatchLoop(
        worker: VmProvisioningWorker(
          work: SqliteVmProvisioningWorkRepository(database),
          bundles: VmBundleStore(
            database: database,
            bundles: bundles,
            images: images,
          ),
          owner: 'http-test',
        ),
        interval: const Duration(milliseconds: 10),
        onDispatch: (results) => failures.addAll(
          results
              .where((result) => result.error != null)
              .map((result) => result.error!),
        ),
        onError: (error, _) => failures.add(error),
      );
      final reconcile = VmReconcileLoop(
        registry: registry,
        interval: const Duration(milliseconds: 50),
        onVmError: (_, error, _) => failures.add(error),
        onError: (error, _) => failures.add(error),
      );
      final router = PublicApiRouter();
      ResourceApiHandlers(
        vms: VmApplicationService.composed(
          repository: SqliteVmRepository(database),
          creates: SqliteVmCreateAcceptance(
            database: database,
            idempotencyRetention: const Duration(days: 1),
          ),
          patches: SqliteVmPatchAcceptor(
            database: database,
            registry: registry,
            idempotencyRetention: const Duration(days: 1),
          ),
          lifecycle: SqliteVmLifecycleAcceptor(
            database: database,
            registry: registry,
            idempotencyRetention: const Duration(days: 1),
          ),
          waiter: SqliteVmConditionWaiter(
            repository: SqliteVmRepository(database),
            events: SqliteDurableEventFeed(
              database,
              pollInterval: const Duration(milliseconds: 10),
            ),
          ),
        ),
        operations: OperationApplicationService(
          repository: operations,
          mutations: SqliteVmProvisioningCancellation(
            database: database,
            idempotencyRetention: const Duration(days: 1),
          ),
          waiter: SqliteOperationWaiter(
            operations: operations,
            events: SqliteDurableEventFeed(
              database,
              pollInterval: const Duration(milliseconds: 10),
            ),
          ),
        ),
      ).register(router);
      EventApiHandlers(
        feed: SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 10),
        ),
      ).register(router);
      final server = PublicApiServer(
        socketPath: '${root.path}/api.sock',
        openApiDocument: const {},
        systemHealth: _Health(),
        router: router,
      );
      final client = HttpClient()
        ..connectionFactory = (_, _, _) => Socket.startConnect(
          InternetAddress(
            '${root.path}/api.sock',
            type: InternetAddressType.unix,
          ),
          0,
        );
      Future<Map<String, dynamic>> request(
        String method,
        String path, [
        Object? body,
        String? key,
        int? revision,
      ]) async {
        final outgoing = await client.openUrl(
          method,
          Uri.parse('http://localhost$path'),
        );
        if (key != null) outgoing.headers.set('Idempotency-Key', key);
        if (revision != null) outgoing.headers.set('If-Match', '"$revision"');
        if (body != null) {
          outgoing.headers.contentType = ContentType.json;
          outgoing.write(jsonEncode(body));
        }
        final incoming = await outgoing.close();
        final json =
            jsonDecode(await utf8.decoder.bind(incoming).join())
                as Map<String, dynamic>;
        expect(incoming.statusCode, anyOf(200, 202), reason: '$path: $json');
        return json;
      }

      Future<void> wait(Map<String, dynamic> accepted) async {
        final terminal = await request(
          'POST',
          '/v1/operations/${accepted['operation_id']}/wait',
          {'timeout_seconds': 15},
        );
        expect(terminal['state'], 'succeeded', reason: '$terminal');
      }

      Future<Event> publicEvent(int after, VmId vmId, String type) async {
        final eventsClient = HttpClient()
          ..connectionFactory = (_, _, _) => Socket.startConnect(
            InternetAddress(
              '${root.path}/api.sock',
              type: InternetAddressType.unix,
            ),
            0,
          );
        try {
          final outgoing = await eventsClient.getUrl(
            Uri.parse('http://localhost/v1/events?vm_id=${vmId.value}'),
          );
          outgoing.headers.set('Last-Event-ID', '$after');
          final response = await outgoing.close();
          expect(response.statusCode, 200);
          expect(response.headers.contentType!.mimeType, 'text/event-stream');
          return await response
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .where((line) => line.startsWith('data: '))
              .map((line) => Event.fromJson(jsonDecode(line.substring(6))))
              .firstWhere((event) => event.type == type)
              .timeout(const Duration(seconds: 15));
        } finally {
          eventsClient.close(force: true);
        }
      }

      try {
        await ownership.verify();
        expect(await DaemonOwnership.tryAcquire(stateRoot), isNull);
        await scheduler.recover();
        commands.start();
        provisioning.start();
        reconcile.start();
        await server.start();
        final spec = VmSpec(
          cpu: 2,
          memoryBytes: 268435456,
          boot: LinuxKernelBoot(kernelImageId: kernelImage.id),
          disks: [
            VmDisk(
              id: 'root',
              source: ManagedImageDiskSource(diskImage.id),
              writable: true,
            ),
          ],
          networks: [DisconnectedNetwork(id: 'net0')],
          graphics: GraphicsConfig(enabled: false),
          serial: const SerialConfig(enabled: true, capture: true),
          guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
          restartPolicy: RestartPolicy.onFailure,
        );
        final created = await Future.wait([
          for (final name in ['first', 'second'])
            request('POST', '/v1/vms', {
              'api_version': vmApiVersion,
              'kind': vmKind,
              'metadata': {'name': name},
              'spec': spec.toJson(),
            }),
        ]);
        await Future.wait(created.map(wait));
        final starts = await Future.wait([
          for (final vm in created)
            request(
              'POST',
              '/v1/vms/${vm['resource_id']}/actions/start',
              {},
              'start-${vm['resource_id']}',
            ),
        ]);
        final reached = await request(
          'POST',
          '/v1/vms/${created.first['resource_id']}/wait',
          {'condition': 'runtime_running', 'timeout_seconds': 15},
        );
        expect(reached['reached'], isTrue);
        await Future.wait(starts.map(wait));
        final replay = await request(
          'POST',
          '/v1/vms/${created.first['resource_id']}/actions/start',
          {},
          'start-${created.first['resource_id']}',
        );
        expect(replay['operation_id'], starts.first['operation_id']);
        expect(manager.activeProcessCount, 2);
        for (final vm in created) {
          final resource = await request('GET', '/v1/vms/${vm['resource_id']}');
          expect((resource['status'] as Map)['phase'], 'running');
          expect(
            await File(
              '${vmRoot.path}/${vm['resource_id']}.gaovm/disks/root.raw',
            ).readAsString(),
            'base disk bytes',
          );
        }
        final patchTarget = await request(
          'GET',
          '/v1/vms/${created.last['resource_id']}',
        );
        final patched = await request(
          'PATCH',
          '/v1/vms/${created.last['resource_id']}',
          {
            'spec': {'cpu': 3},
          },
          'patch-running',
          (patchTarget['metadata'] as Map)['revision'] as int,
        );
        await wait(patched);
        final changed = await request(
          'GET',
          '/v1/vms/${created.last['resource_id']}',
        );
        expect((changed['spec'] as Map)['cpu'], 3);
        expect((changed['status'] as Map)['spec_generation'], 2);
        expect((changed['status'] as Map)['observed_generation'], 1);
        expect((changed['status'] as Map)['restart_required'], isTrue);
        expect((changed['status'] as Map)['driver_generation'], 1);
        final firstId = VmId(created.first['resource_id'] as String);
        final metadata =
            jsonDecode(
                  await File(
                    '${root.path}/run/${firstId.value}/1/metadata.json',
                  ).readAsString(),
                )
                as Map;
        final otherMetadataPath =
            '${root.path}/run/${created.last['resource_id']}/1/metadata.json';
        final otherMetadata =
            jsonDecode(await File(otherMetadataPath).readAsString()) as Map;
        expect(metadata['pid'], isNot(otherMetadata['pid']));
        final journal = SqliteDurableEventFeed(
          database,
          pollInterval: const Duration(milliseconds: 10),
        );
        final cursor = await journal.latestSequence();
        final recovered = publicEvent(cursor, firstId, 'vm.running');
        expect(
          Process.killPid(metadata['pid'] as int, ProcessSignal.sigkill),
          isTrue,
        );
        await recovered;
        final restarted = await request('GET', '/v1/vms/${firstId.value}');
        expect((restarted['status'] as Map)['driver_generation'], 2);
        expect(manager.activeProcessCount, 2);
        // Lose the recovered VM's admission through the real lease repository.
        // Its peer must keep running and the original start remains terminal.
        final leaseCleanup = journal
            .watch(after: await journal.latestSequence(), vmId: firstId)
            .firstWhere((event) => event.type == 'vm.failed')
            .timeout(const Duration(seconds: 15));
        await SqliteHostLeaseRepository(
          database,
        ).release(firstId, ownerId: 'http-test');
        await leaseLossHandled.future.timeout(const Duration(seconds: 15));
        await leaseCleanup;
        await drivers.waitUntilEventsDispatched();
        await wait(starts.first);
        final leaseFailed = await request('GET', '/v1/vms/${firstId.value}');
        expect((leaseFailed['status'] as Map)['desired_state'], 'stopped');
        expect(
          manager.activeProcessCount,
          1,
          reason: '$leaseFailed; failures=$failures',
        );
        final stop = await request(
          'POST',
          '/v1/vms/${created.first['resource_id']}/actions/stop',
          {},
        );
        await wait(stop);
        final other = await request(
          'GET',
          '/v1/vms/${created.last['resource_id']}',
        );
        expect((other['status'] as Map)['phase'], 'running');
        expect((other['status'] as Map)['driver_generation'], 1);
        expect(
          (jsonDecode(await File(otherMetadataPath).readAsString())
              as Map)['pid'],
          otherMetadata['pid'],
        );
        final secondId = VmId(created.last['resource_id'] as String);
        final secondBundle = Directory(
          '${vmRoot.path}/${secondId.value}.gaovm',
        );
        await File(
          '${secondBundle.path}/disks/root.raw',
        ).writeAsString('mutable guest data');
        final deleteCursor = await journal.latestSequence();
        final deleted = await request(
          'DELETE',
          '/v1/vms/${secondId.value}',
          {},
          'delete-running',
        );
        await wait(deleted);
        final deletedEvent = await publicEvent(
          deleteCursor,
          secondId,
          'vm.deleted',
        );
        expect(deletedEvent.operationId!.value, deleted['operation_id']);
        expect(await secondBundle.exists(), isFalse);
        expect(manager.activeProcessCount, 0);
        expect(
          (await request(
            'DELETE',
            '/v1/vms/${secondId.value}',
            {},
            'delete-running',
          ))['operation_id'],
          deleted['operation_id'],
        );
        expect(
          (await request('GET', '/v1/vms/${firstId.value}'))['status'],
          (await SqliteVmRepository(database).get(firstId))!.status.toJson(),
        );
        expect(
          await File(
            '${vmRoot.path}/${firstId.value}.gaovm/disks/root.raw',
          ).readAsString(),
          'base disk bytes',
        );
        expect(
          await File(
            '${images.path}/sha256-${diskImage.digest.substring(7)}/objects/payload',
          ).readAsString(),
          'base disk bytes',
        );
        expect(failures, isEmpty);
      } finally {
        client.close(force: true);
        await server.close();
        await Future.wait([
          commands.close(),
          reconcile.close(),
          registry.shutdown(),
          provisioning.close(),
        ]);
        await drivers.close();
        await scheduler.shutdown();
        await manager.close();
        images.close();
        bundles.close();
        database.close();
        ownership.close();
        stateRoot.close();
        await root.delete(recursive: true);
      }
    },
  );
}

final class _Metrics implements HostMetricsSource {
  @override
  Future<HostMetrics> sample() async => const HostMetrics(
    logicalCpuCount: 8,
    totalMemoryBytes: 8589934592,
    availableMemoryBytes: 4294967296,
    freeDiskBytes: 1073741824,
    unmanagedDriverProcesses: 0,
  );
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
