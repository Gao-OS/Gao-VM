import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'artifact_api_handlers.dart';
import 'artifact_application_service.dart';
import 'daemon_ownership.dart';
import 'driver_process_manager.dart';
import 'driver_runtime_discovery.dart';
import 'driver_runtime_layout.dart';
import 'driver_startup_recovery.dart';
import 'event_api_handlers.dart';
import 'event_repository.dart';
import 'host_lease_repository.dart';
import 'host_scheduler.dart';
import 'host_scheduler_models.dart';
import 'image_filesystem.dart';
import 'image_api_handlers.dart';
import 'image_application_service.dart';
import 'image_store.dart';
import 'image_work_dispatch_loop.dart';
import 'legacy_vm_migration.dart';
import 'macos_driver_inventory.dart';
import 'macos_host_metrics.dart';
import 'macos_system_doctor_host.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'public_api_server.dart';
import 'resource_api_handlers.dart';
import 'rotating_logger.dart';
import 'runtime_driver_effect_adapter.dart';
import 'sqlite_database.dart';
import 'sqlite_durable_event_feed.dart';
import 'sqlite_host_capacity_catalog.dart';
import 'sqlite_operation_waiter.dart';
import 'sqlite_vm_command_target.dart';
import 'sqlite_vm_condition_waiter.dart';
import 'sqlite_vm_create_acceptance.dart';
import 'sqlite_vm_lifecycle_acceptor.dart';
import 'sqlite_vm_managed_file_effect_adapter.dart';
import 'sqlite_vm_patch_acceptor.dart';
import 'sqlite_vm_provisioning_cancellation.dart';
import 'sqlite_vm_runtime_assets.dart';
import 'sqlite_vm_state_effect_adapter.dart';
import 'system_api_handlers.dart';
import 'system_doctor_service.dart';
import 'test_run_api_handlers.dart';
import 'test_run_application_service.dart';
import 'test_run_cleanup_dispatch_loop.dart';
import 'test_run_cleanup_worker.dart';
import 'test_run_collection_dispatch_loop.dart';
import 'test_run_collection_worker.dart';
import 'test_run_provisioning_dispatch_loop.dart';
import 'test_run_provisioning_worker.dart';
import 'test_run_readiness_dispatch_loop.dart';
import 'test_run_readiness_worker.dart';
import 'test_run_vm_start_dispatch_loop.dart';
import 'test_run_vm_start_worker.dart';
import 'vm_application_service.dart';
import 'vm_bundle_store.dart';
import 'vm_command_dispatch_loop.dart';
import 'vm_command_dispatcher.dart';
import 'vm_command_repository.dart';
import 'vm_effect_runner.dart';
import 'vm_intent_recovery_repository.dart';
import 'vm_provisioning_dispatch_loop.dart';
import 'vm_provisioning_work_repository.dart';
import 'vm_provisioning_worker.dart';
import 'vm_reconcile_loop.dart';
import 'vm_registry.dart';
import 'vm_repository.dart';
import 'vm_runtime_configuration_resolver.dart';

/// Installed daemon composition: native host boundaries, durable application
/// services, and per-VM controllers. Public clients never receive a driver.
final class DaemonApplication {
  DaemonApplication._(this._server, this._shutdown);
  final PublicApiServer _server;
  final Future<void> Function() _shutdown;
  Future<void>? _closing;
  bool _closed = false;

  String get socketPath => _server.socketPath;
  Future<void> get done => _server.done;

  static Future<DaemonApplication> start({
    required Directory stateDirectory,
    required String driverBinary,
    required Map<String, Object?> openApiDocument,
    String? socketPath,
    int maxRunningVms = 8,
    int maxConcurrentBoots = 2,
  }) async {
    if (!Platform.isMacOS) throw UnsupportedError('macOS daemon required');
    if (maxRunningVms < 1 || maxConcurrentBoots < 1) {
      throw ArgumentError('VM and boot limits must be positive');
    }
    final type = await FileSystemEntity.type(
      stateDirectory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await stateDirectory.create(recursive: true);
      imageFileMode(stateDirectory.path, 0x1c0);
    } else if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'state path must be a directory',
        stateDirectory.path,
      );
    }
    final state = await OwnedImageDirectory.open(stateDirectory);
    DaemonOwnership? ownership;
    GaoVmDatabase? database;
    final roots = <OwnedImageDirectory>[];
    DaemonApplication? application;
    try {
      ownership = await DaemonOwnership.tryAcquire(state);
      if (ownership == null)
        throw StateError('another daemon owns this state directory');
      final driverPath = await File(driverBinary).resolveSymbolicLinks();
      final run = await _privateChild(state, 'run');
      roots.add(run);
      final bundles = await _privateChild(state, 'vms');
      roots.add(bundles);
      final images = await _privateChild(state, 'images');
      roots.add(images);
      final artifacts = await _privateChild(state, 'artifacts');
      roots.add(artifacts);
      final logs = await _privateChild(state, 'logs');
      roots.add(logs);
      final existingDatabase = state.fileOrNull('gaovm.db');
      existingDatabase?.close();
      database = await GaoVmDatabase.open('${state.path}/gaovm.db');
      final logger = RotatingLogger(path: '${logs.path}/gaovmd.log');
      final layout = DriverRuntimeLayout(run.path);
      final inventory = MacOsDriverInventory(executablePath: driverPath);
      final manager = DriverProcessManager(
        layout: layout,
        resolveExecutable: (_) => DriverExecutable(path: driverPath),
        resolveBundlePath: (id) => '${bundles.path}/${id.value}.gaovm',
      );
      final catalog = SqliteVmRepository(database);
      Future<DriverRecoveryBinding?> recoveryBinding(VmId id) async {
        final vm = await catalog.get(id, includeDeleted: true);
        return vm == null
            ? null
            : DriverRecoveryBinding(
                driverGeneration: vm.status.driverGeneration,
                executable: driverPath,
                bundlePath: '${bundles.path}/${id.value}.gaovm',
              );
      }

      final health = _DaemonHealth(ownership, database);
      final router = PublicApiRouter();
      final server = PublicApiServer(
        socketPath: socketPath ?? '${run.path}/api.sock',
        openApiDocument: openApiDocument,
        systemHealth: health,
        router: router,
      );
      if (File(server.socketPath).parent.absolute.path != run.path) {
        throw ArgumentError(
          'API socket must be inside the owned run directory',
        );
      }
      await server.prepare();
      await DriverStartupRecovery(
        ownership: ownership,
        layout: layout,
        discovery: DriverRuntimeDiscovery(
          root: run,
          resolveBinding: recoveryBinding,
        ),
        readInventory: inventory.snapshot,
      ).recover();
      await LegacyVmMigration(
        database: database,
        state: state,
        bundles: bundles,
        images: images,
        ownership: ownership,
      ).migrate();
      final imageStore = ImageStore(database, Directory(images.path));
      final imageRecovery = await imageStore.reconcile();
      health.imageStoreHealthy = imageRecovery.damagedImageIds.isEmpty;
      final imageService = ImageApplicationService(
        database: database,
        store: imageStore,
      );
      final artifactService = ArtifactApplicationService(
        database: database,
        directory: artifacts,
      );
      final artifactRecovery = await artifactService.reconcile();
      health.artifactStoreHealthy =
          artifactRecovery.damagedArtifactIds.isEmpty &&
          artifactRecovery.retainedNames.isEmpty;
      final metrics = MacOsHostMetricsSource(
        storage: state,
        countUnmanagedDrivers: () async => (await inventory.snapshot())
            .countUnmanaged(manager.managedProcessIdentities),
      );
      final capacity = await metrics.sample();
      late VmRegistry registry;
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
      final schedulerLimits = HostSchedulerLimits(
        maxRunningVms: maxRunningVms,
        maxConcurrentBoots: maxConcurrentBoots,
        maxDriverProcesses: maxRunningVms,
        maxCpuCount: capacity.logicalCpuCount,
        maxMemoryBytes: capacity.totalMemoryBytes * 3 ~/ 4,
        minFreeDiskBytes: 1024 * 1024 * 1024,
      );
      final scheduler = HostScheduler(
        leases: SqliteHostLeaseRepository(database),
        // Disk materialization precedes admission; boot allocates no new disk.
        catalog: SqliteHostCapacityCatalog(database, diskBytes: (_) => 0),
        metrics: metrics,
        limits: schedulerLimits,
        ownerId: RequestId.generate().value,
        onLeaseLost: (vm, spec, operation, generation, error) => registry
            .handleHostLeaseLost(vm, spec, operation, generation, error),
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
        repository: catalog,
        operations: operations,
        effectRunner: runner,
        recovery: SqliteVmIntentRecoveryRepository(database),
      );
      void report(
        String component,
        Object error, {
        VmId? vm,
        OperationId? operation,
        RequestId? request,
        TestRunId? testRun,
        int? driverGeneration,
      }) {
        unawaited(
          logger
              .error(
                jsonEncode({
                  'component': component,
                  'vm_id': vm?.value,
                  'operation_id': operation?.value,
                  'request_id': request?.value,
                  'test_run_id': testRun?.value,
                  'driver_generation': driverGeneration,
                  'message': 'background work failed',
                  'error_type': '${error.runtimeType}',
                }),
              )
              .catchError((Object _) {}),
        );
      }

      final workerOwner = RequestId.generate().value;
      final imageWork = ImageWorkDispatchLoop(
        images: imageService,
        onError: (error, _) => report('images', error),
      );
      final commands = VmCommandDispatchLoop(
        dispatcher: VmCommandDispatcher(
          commands: SqliteVmCommandRepository(database),
          target: SqliteVmCommandTarget(
            database: database,
            registry: registry,
            effectRunner: runner,
          ),
          owner: workerOwner,
        ),
        onDispatch: (results) {
          for (final result in results) {
            if (result.error case final error?)
              report(
                'vm_commands',
                error,
                vm: result.record.vmId,
                operation: result.record.operationId,
              );
          }
        },
        onError: (error, _) => report('vm_commands', error),
      );
      final provisioning = VmProvisioningDispatchLoop(
        worker: VmProvisioningWorker(
          work: SqliteVmProvisioningWorkRepository(database),
          bundles: VmBundleStore(
            database: database,
            bundles: bundles,
            images: images,
          ),
          owner: workerOwner,
        ),
        onDispatch: (results) {
          for (final result in results) {
            if (result.error case final error?)
              report('vm_provisioning', error, operation: result.operationId);
          }
        },
        onError: (error, _) => report('vm_provisioning', error),
      );
      final reconcile = VmReconcileLoop(
        registry: registry,
        onVmError: (vm, error, _) => report('vm_reconcile', error, vm: vm),
        onError: (error, _) => report('vm_reconcile', error),
      );
      const retention = Duration(days: 1);
      final feed = SqliteDurableEventFeed(database);
      final testRuns = TestRunApplicationService(
        database: database,
        idempotencyRetention: retention,
      );
      final testRunProvisioning = TestRunProvisioningDispatchLoop(
        worker: TestRunProvisioningWorker(database: database),
        onDispatch: (results) {
          for (final result in results) {
            if (result.error case final error?) {
              report(
                'test_run_provisioning',
                error,
                vm: result.vmId,
                operation: result.operationId,
              );
            }
          }
        },
        onError: (error, _) => report('test_run_provisioning', error),
      );
      final testRunVmStart = TestRunVmStartDispatchLoop(
        worker: TestRunVmStartWorker(database: database, registry: registry),
        onDispatch: (results) {
          for (final result in results) {
            if (result.error case final error?) {
              report(
                'test_run_vm_start',
                error,
                vm: result.vmId,
                operation: result.operationId,
                testRun: result.testRunId,
                request: result.requestId,
                driverGeneration: result.driverGeneration,
              );
            }
          }
        },
        onError: (error, _) => report('test_run_vm_start', error),
      );
      final testRunReadiness = TestRunReadinessDispatchLoop(
        worker: TestRunReadinessWorker(database: database),
        onDispatch: (results) {
          for (final result in results) {
            if (result.error case final error?) {
              report(
                'test_run_readiness',
                error,
                vm: result.vmId,
                operation: result.operationId,
                testRun: result.testRunId,
                request: result.requestId,
                driverGeneration: result.driverGeneration,
              );
            }
          }
        },
        onError: (error, _) => report('test_run_readiness', error),
      );
      final testRunCollection = TestRunCollectionDispatchLoop(
        worker: TestRunCollectionWorker(
          database: database,
          bundles: bundles,
          artifacts: artifactService,
        ),
        onDispatch: (results) {
          for (final result in results) {
            if (result.error case final error?) {
              report(
                'test_run_collection',
                error,
                vm: result.vmId,
                operation: result.operationId,
                testRun: result.testRunId,
                request: result.requestId,
                driverGeneration: result.driverGeneration,
              );
            }
          }
        },
        onError: (error, _) => report('test_run_collection', error),
      );
      final testRunCleanup = TestRunCleanupDispatchLoop(
        worker: TestRunCleanupWorker(database: database, registry: registry),
        onDispatch: (results) {
          for (final result in results) {
            if (result.error case final error?) {
              report(
                'test_run_cleanup',
                error,
                vm: result.vmId,
                operation: result.operationId,
                testRun: result.testRunId,
                request: result.requestId,
                driverGeneration: result.driverGeneration,
              );
            }
          }
        },
        onError: (error, _) => report('test_run_cleanup', error),
      );
      ResourceApiHandlers(
        vms: VmApplicationService.composed(
          repository: catalog,
          creates: SqliteVmCreateAcceptance(
            database: database,
            idempotencyRetention: retention,
          ),
          patches: SqliteVmPatchAcceptor(
            database: database,
            registry: registry,
            idempotencyRetention: retention,
          ),
          lifecycle: SqliteVmLifecycleAcceptor(
            database: database,
            registry: registry,
            idempotencyRetention: retention,
          ),
          waiter: SqliteVmConditionWaiter(repository: catalog, events: feed),
        ),
        operations: OperationApplicationService(
          repository: operations,
          mutations: _DaemonOperationCancellation(
            operations: operations,
            images: imageService,
            testRuns: testRuns,
            provisioning: SqliteVmProvisioningCancellation(
              database: database,
              idempotencyRetention: retention,
            ),
          ),
          waiter: SqliteOperationWaiter(operations: operations, events: feed),
        ),
      ).register(router);
      ImageApiHandlers(images: imageService).register(router);
      ArtifactApiHandlers(artifacts: artifactService).register(router);
      TestRunApiHandlers(runs: testRuns).register(router);
      EventApiHandlers(feed: feed).register(router);
      final doctor = SystemDoctorService(
        database: database,
        stateDirectory: state,
        runtimeDirectory: run,
        imageStore: imageStore,
        imageDirectory: images,
        publicServer: server,
        processManager: manager,
        resolveBinding: recoveryBinding,
        limits: schedulerLimits,
        host: MacOsDoctorHost(
          driverBinary: driverPath,
          metrics: metrics,
          processes: inventory,
        ),
      );
      SystemApiHandlers(doctor: doctor).register(router);
      final ownedDatabase = database;
      final ownedLock = ownership;
      application = DaemonApplication._(server, () async {
        health.ready = false;
        await server.close();
        // Fence worker producers before registry shutdown; controller
        // cancellation can unblock delivery already in flight. Drain all of
        // them before closing their shared catalog and filesystem roots.
        await Future.wait([
          doctor.close(),
          commands.close(),
          provisioning.close(),
          testRunProvisioning.close(),
          testRunVmStart.close(),
          testRunReadiness.close(),
          testRunCollection.close(),
          testRunCleanup.close(),
          imageWork.close(),
          reconcile.close(),
          registry.shutdown(),
          scheduler.shutdown(),
        ]);
        await drivers.close();
        await manager.close();
        await logger.flush();
        await ownedLock.verify();
        ownedDatabase.close();
        for (final root in roots) root.close();
        ownedLock.close();
        state.close();
      });
      // No reservation, controller, worker or public listener may activate
      // before previous-owner teardown and a complete driver census succeed.
      await scheduler.recover();
      await ownership.verify();
      commands.start();
      provisioning.start();
      testRunProvisioning.start();
      testRunVmStart.start();
      testRunReadiness.start();
      testRunCollection.start();
      testRunCleanup.start();
      imageWork.start();
      reconcile.start();
      health.ready = true;
      await server.start();
      return application;
    } catch (_) {
      if (application != null) {
        await application.close();
      } else {
        database?.close();
        for (final root in roots) root.close();
        ownership?.close();
        state.close();
      }
      rethrow;
    }
  }

  Future<void> close() {
    if (_closed) return Future.value();
    return _closing ??= _shutdown()
        .then<void>((_) => _closed = true)
        .whenComplete(() => _closing = null);
  }
}

Future<OwnedImageDirectory> _privateChild(
  OwnedImageDirectory parent,
  String name,
) async {
  OwnedImageDirectory child;
  try {
    child = parent.directory(name);
  } on FileSystemException catch (error) {
    if (error.osError?.errorCode != 2) rethrow;
    child = parent.createDirectory(name);
  }
  try {
    await parent.sync();
    if (child.mode & 0x3f != 0)
      throw const FormatException('daemon directories must be private');
    await child.verifyPathBinding();
    return child;
  } catch (_) {
    child.close();
    rethrow;
  }
}

final class _DaemonHealth implements SystemHealthService {
  _DaemonHealth(this.ownership, this.database);
  final DaemonOwnership ownership;
  final GaoVmDatabase database;
  bool ready = false;
  bool imageStoreHealthy = true;
  bool artifactStoreHealthy = true;

  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: {'daemon': 'live'});

  @override
  Future<SystemHealthStatus> readiness() async {
    await ownership.verify();
    await database.read((db) => db.select('SELECT 1'));
    return SystemHealthStatus(
      healthy: ready && imageStoreHealthy && artifactStoreHealthy,
      checks: {
        'catalog': 'ready',
        'image_store': imageStoreHealthy ? 'ready' : 'damaged',
        'artifact_store': artifactStoreHealthy ? 'ready' : 'damaged',
        'runtime_recovery': ready ? 'ready' : 'stopping',
      },
    );
  }
}

final class _DaemonOperationCancellation implements OperationMutationAcceptor {
  const _DaemonOperationCancellation({
    required this.operations,
    required this.images,
    required this.testRuns,
    required this.provisioning,
  });
  final OperationRepository operations;
  final ImageApplicationService images;
  final TestRunApplicationService testRuns;
  final OperationMutationAcceptor provisioning;
  @override
  Future<OperationAcceptance> cancel(OperationCancelCommand command) async {
    final target = await operations.get(command.operationId);
    return target?.type == 'image.import'
        ? images.cancel(command)
        : target?.type == 'test.run'
        ? testRuns.cancel(command)
        : provisioning.cancel(command);
  }
}
