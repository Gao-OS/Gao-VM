import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

// PRD 10.3 catalog-scale acceptance. This exercises the control plane, not VZ,
// native daemon startup, or API latency. The executable resolver is a tripwire:
// even an unexpected start cannot launch a subprocess.
void main() {
  test(
    '100 stopped VM definitions survive reopen and reconcile without drivers or leases',
    () async {
      final root =
          await (Platform.isMacOS
                  ? Directory('/private/tmp')
                  : Directory.systemTemp)
              .createTemp('gvm-scale-');
      imageFileMode(root.path, 0x1c0);
      addTearDown(() => root.delete(recursive: true));
      final databasePath = '${root.path}/catalog.db';
      final seed = await GaoVmDatabase.open(databasePath);
      final definitions = <VirtualMachine>[];
      try {
        final repository = SqliteVmRepository(seed);
        final disk = await File(
          '${root.path}/disk.img',
        ).writeAsString('unused');
        final spec = VmSpec(
          cpu: 2,
          memoryBytes: 2147483648,
          boot: EfiBoot(),
          disks: [
            VmDisk(
              id: 'root',
              source: ExternalDiskSource(disk.path),
              writable: true,
            ),
          ],
          networks: [SharedNetwork(id: 'net0')],
          graphics: GraphicsConfig(enabled: false),
          serial: const SerialConfig(enabled: false, capture: false),
          guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
          restartPolicy: RestartPolicy.never,
        );
        for (var index = 0; index < 100; index++) {
          definitions.add(
            await repository.create(
              name: 'stopped-$index',
              labels: {'parity': index.isEven ? 'even' : 'odd'},
              spec: spec,
            ),
          );
        }
        expect(await repository.list(), hasLength(100));
      } finally {
        seed.close();
      }

      final database = await GaoVmDatabase.open(databasePath);
      addTearDown(database.close);
      final repository = SqliteVmRepository(database);
      final operations = SqliteOperationRepository(database);
      final leases = _ObservedLeases();
      final launchAttempts = <VmId>[];
      final runRoot = Directory('${root.path}/run');
      final manager = DriverProcessManager(
        layout: DriverRuntimeLayout(runRoot.path),
        resolveExecutable: (id) {
          launchAttempts.add(id);
          throw StateError('catalog reconciliation must not launch a driver');
        },
        resolveBundlePath: (id) => '${root.path}/${id.value}.gaovm',
      );
      addTearDown(manager.close);
      late VmRegistry registry;
      final drivers = RuntimeDriverEffectAdapter.scopedConfiguration(
        factory: manager,
        withConfiguration: (_, _) async {
          throw StateError('a stopped VM must not configure a runtime');
        },
        dispatch: (id, command) async {
          await registry.dispatch(id, command);
        },
      );
      addTearDown(drivers.close);
      registry = VmRegistry(
        repository: repository,
        operations: operations,
        recovery: SqliteVmIntentRecoveryRepository(database),
        effectRunner: RepositoryVmEffectRunner(
          database: database,
          operations: operations,
          events: SqliteEventRepository(database),
          persistence: SqliteVmStateEffectAdapter(database),
          leases: leases,
          drivers: drivers,
          managedFiles: _UnexpectedManagedFiles(),
        ),
      );
      addTearDown(registry.shutdown);

      final reopened = await repository.list();
      expect(reopened, unorderedEquals(definitions));
      expect(
        await repository.list(
          labelSelector: LabelSelector.parse('parity=even'),
        ),
        hasLength(50),
      );
      for (final definition in definitions) {
        expect(await repository.get(definition.metadata.id), definition);
      }

      expect(await registry.reconcileOnStartup(), hasLength(100));
      final errors = <Object>[];
      for (var tick = 0; tick < 2; tick++) {
        await registry.reconcileTick(
          onError: (_, error, _) => errors.add(error),
        );
        // A catalog tick schedules per-VM work. Await that work before asserting
        // absence of launches; returning from the scan is not completion.
        await Future.wait([
          for (final definition in definitions)
            registry.reconcileVm(definition.metadata.id),
        ]);
      }

      expect(errors, isEmpty);
      expect(launchAttempts, isEmpty);
      expect(leases.calls, isEmpty);
      expect(manager.activeProcessCount, 0);
      expect(manager.pendingSpawnCount, 0);
      expect(manager.activeGenerationCount, 0);
      expect(drivers.activeSessionCount, 0);
      expect(await runRoot.exists(), isFalse);
      expect(await operations.list(), isEmpty);
      expect(await repository.list(), reopened);
      for (final controller in registry.activeControllers) {
        expect(controller.state.desiredState, DesiredState.stopped);
        expect(controller.state.driverGeneration, 0);
        expect(controller.state.leaseState, VmLeaseState.none);
      }

      // Positive control: the same production path reaches the tripwire for an
      // explicit start. A permanently disconnected driver adapter could not
      // make the stopped-catalog assertions pass unnoticed.
      final target = definitions.first.metadata.id;
      final start = await operations.create(
        type: 'vm.start',
        resourceType: ResourceType.virtualMachine,
        resourceId: target,
        requestId: RequestId.generate(),
        cancellable: true,
        request: JsonObjectValue.empty,
      );
      await registry.dispatch(target, StartRequested(start.id));
      expect(launchAttempts, [target]);
      expect(leases.calls, contains('acquire'));
      expect((await operations.get(start.id))?.state, OperationState.failed);
      expect(manager.activeProcessCount, 0);
    },
  );
}

final class _ObservedLeases implements VmLeaseEffectAdapter {
  final calls = <String>[];

  @override
  Future<void> acquire(VmControllerState state, OperationId operationId) async {
    calls.add('acquire');
  }

  @override
  Future<void> markRunning(
    VmControllerState state,
    OperationId operationId,
  ) async {
    calls.add('running');
  }

  @override
  Future<void> release(
    VmControllerState state,
    OperationId? operationId,
  ) async {
    calls.add('release');
  }
}

final class _UnexpectedManagedFiles implements VmManagedFileEffectAdapter {
  @override
  Future<void> remove(VmControllerState state, OperationId operationId) async {
    throw StateError('catalog reconciliation must not remove managed files');
  }
}
