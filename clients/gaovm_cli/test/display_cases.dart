part of 'public_api_cli_test.dart';

void _displayCliTests() {
  test(
    'CLI display completes through real API, SQLite outbox, registry and runtime adapter',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'display-public-execution-',
      );
      final database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      final operations = SqliteOperationRepository(database);
      final vms = SqliteVmRepository(database);
      final persistence = SqliteVmStateEffectAdapter(database);
      final scheduler = ManualRuntimeScheduler();
      final factory = FakeRuntimeDriverFactory(scheduler: scheduler);
      late VmRegistry registry;
      final driver = RuntimeDriverEffectAdapter(
        factory: factory,
        requiredCapabilities: DriverCapabilities.all,
        resolveConfiguration: (_) async => RuntimeDriverConfiguration(
          architecture: Architecture.arm64,
          cpu: 2,
          memoryBytes: 268435456,
          boot: RuntimeLinuxBootConfiguration(
            kernelPath: '/fixture/kernel',
            commandLine: '',
          ),
          disks: [
            RuntimeDiskConfiguration(
              id: 'root',
              path: '/fixture/root.raw',
              writable: true,
            ),
          ],
          networks: [
            RuntimeNetworkConfiguration(
              id: 'net0',
              mode: RuntimeNetworkMode.none,
            ),
          ],
          graphics: RuntimeGraphicsConfiguration(
            enabled: true,
            width: 1280,
            height: 800,
            pixelsPerInch: 144,
          ),
          serial: RuntimeSerialConfiguration(
            enabled: false,
            capture: false,
            logPath: '/fixture/serial.log',
          ),
          guestAgent: RuntimeGuestAgentConfiguration(
            enabled: false,
            vsockPort: 1024,
          ),
          bundlePath: '/fixture/vm.gaovm',
          driverLogPath: '/fixture/driver.log',
        ),
        dispatch: (id, command) async {
          await (await registry.get(id))?.submit(command);
        },
      );
      final host = _DisplayHostBoundary();
      final runner = RepositoryVmEffectRunner(
        database: database,
        operations: operations,
        events: SqliteEventRepository(database),
        persistence: persistence,
        leases: host,
        drivers: driver,
        managedFiles: host,
      );
      registry = VmRegistry(
        repository: vms,
        operations: operations,
        effectRunner: runner,
        recovery: SqliteVmIntentRecoveryRepository(database),
      );
      final commandRepository = SqliteVmCommandRepository(database);
      final dispatcher = VmCommandDispatcher(
        commands: commandRepository,
        target: SqliteVmCommandTarget(
          database: database,
          registry: registry,
          effectRunner: runner,
        ),
        owner: 'display-test',
      );
      final unrelated = _OutsideDisplayApi();
      try {
        final vm = await vms.create(
          name: 'public-display',
          spec: VmSpec(
            cpu: 2,
            memoryBytes: 268435456,
            boot: EfiBoot(),
            disks: [
              VmDisk(
                id: 'root',
                source: ExternalDiskSource('/fixture/root.raw'),
                writable: true,
              ),
            ],
            networks: [DisconnectedNetwork(id: 'net0')],
            graphics: GraphicsConfig(enabled: true, width: 1280, height: 800),
            serial: const SerialConfig(enabled: false, capture: false),
            guestAgent: GuestAgentConfig(
              enabled: false,
              requiredForReady: false,
            ),
            restartPolicy: RestartPolicy.never,
          ),
        );
        await persistence.persistRuntime(
          VmControllerState.initial(
            vmId: vm.metadata.id,
            specGeneration: 1,
            restartPolicy: RestartPolicy.never,
          ),
        );
        final router = PublicApiRouter();
        ResourceApiHandlers(
          vms: VmApplicationService.composed(
            repository: vms,
            creates: unrelated,
            patches: unrelated,
            waiter: unrelated,
            lifecycle: SqliteVmLifecycleAcceptor(
              database: database,
              registry: registry,
              idempotencyRetention: const Duration(days: 1),
            ),
            display: SqliteVmDisplayRepository(database),
          ),
          operations: OperationApplicationService(
            repository: operations,
            mutations: unrelated,
            waiter: unrelated,
          ),
        ).register(router);
        await _withServer(router, (server) async {
          Future<void> drain() async {
            expect(
              (await dispatcher.dispatchOnce()).single.status,
              VmCommandDispatchStatus.acknowledged,
            );
            await (await registry.get(vm.metadata.id))!.waitUntilIdle();
            await driver.waitUntilEventsDispatched();
          }

          final start = await _invoke(server, [
            'vm',
            'start',
            vm.metadata.id.value,
          ]);
          expect(start.code, 0, reason: start.error);
          await drain();
          scheduler.advanceBy(const Duration(seconds: 1));
          await driver.waitUntilEventsDispatched();
          final controller = (await registry.get(vm.metadata.id))!;
          expect(controller.state.phase, VmPhase.running);
          final originalRuntimeOwner = controller.state.driverOperationId;
          for (final action in ['open-display', 'close-display']) {
            final arguments = [
              'vm',
              action,
              vm.metadata.id.value,
              '--idempotency-key',
              'display-replay',
            ];
            final accepted = await _invoke(server, arguments);
            expect(accepted.code, 0, reason: accepted.error);
            final operationId = OperationId(
              jsonDecode(accepted.output)['operation_id'] as String,
            );
            expect(
              (await operations.get(operationId))!.state,
              OperationState.pending,
            );
            expect((await operations.get(operationId))!.cancellable, isFalse);
            await drain();
            final complete = await _invoke(server, [
              'operation',
              'get',
              operationId.value,
            ]);
            final operation = Operation.fromJson(jsonDecode(complete.output));
            expect(operation.state, OperationState.succeeded);
            expect(
              operation.result!.toJson()['state'],
              action == 'open-display' ? 'open' : 'closed',
            );
            final replay = await _invoke(server, arguments);
            expect(replay.code, 0, reason: replay.error);
            expect(jsonDecode(replay.output), jsonDecode(accepted.output));
            expect(await dispatcher.dispatchOnce(), isEmpty);
            final snapshot = await _invoke(server, [
              'vm',
              'display',
              vm.metadata.id.value,
            ]);
            expect(snapshot.code, 0, reason: snapshot.error);
            expect(
              VmDisplayStatus.fromJson(jsonDecode(snapshot.output)).state,
              action == 'open-display'
                  ? VmDisplayState.open
                  : VmDisplayState.closed,
            );
            expect(controller.state.phase, VmPhase.running);
            expect(controller.state.desiredState, DesiredState.running);
            expect(controller.state.driverOperationId, originalRuntimeOwner);
          }
          final control = factory.controlFor(
            DriverCorrelation(
              vmId: vm.metadata.id,
              driverGeneration: 1,
              operationId: originalRuntimeOwner,
            ),
          );
          expect(
            control.commandHistory.whereType<DisplayOpenCommand>(),
            hasLength(1),
          );
          expect(
            control.commandHistory.whereType<DisplayCloseCommand>(),
            hasLength(1),
          );
          expect(
            control.commandHistory.whereType<RuntimeStopCommand>(),
            isEmpty,
          );
          expect(control.state, RuntimeDriverState.running);
        });
      } finally {
        await registry.shutdown();
        await driver.close();
        database.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'CLI display status uses a read-only typed snapshot and validates VM identity',
    () async {
      final vm = VmId.generate();
      var calls = 0;
      var wrongVm = false;
      final snapshot = {
        'vm_id': vm.value,
        'driver_generation': null,
        'state': 'unknown',
        'observed_at': null,
      };
      final router = PublicApiRouter()
        ..add('GET', '/v1/vms/{vm_id}/display', (request) async {
          calls++;
          expect(request.headers['idempotency-key'], isNull);
          expect(request.jsonBody, isNull);
          return PublicApiResponse.json(
            status: 200,
            body: {...snapshot, if (wrongVm) 'vm_id': VmId.generate().value},
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, ['vm', 'display', vm.value]);
        expect(result.code, 0, reason: result.error);
        expect(jsonDecode(result.output), snapshot);
        wrongVm = true;
        final rejected = await _invoke(server, ['vm', 'display', vm.value]);
        expect(rejected.code, 4);
        expect(rejected.output, isEmpty);
        expect(jsonDecode(rejected.error)['code'], 'CLI_PROTOCOL');
        expect(calls, 2);
      });
    },
  );

  test(
    'CLI display actions reject misbound acceptance and preserve Problems without retries',
    () async {
      final vm = VmId.generate();
      var calls = 0;
      var reject = false;
      final router = PublicApiRouter()
        ..add('POST', '/v1/vms/{vm_id}/actions/open-display', (_) async {
          calls++;
          if (reject)
            return PublicApiResponse.problem(
              status: 409,
              code: ErrorCode.vmOperationConflict,
              type: 'display-conflict',
              title: 'Display conflict',
              detail: 'No display operation was accepted.',
              retryable: true,
            );
          return PublicApiResponse.json(
            status: 202,
            body: {
              'operation_id': OperationId.generate().value,
              'state': 'pending',
              'resource_type': 'virtual_machine',
              'resource_id': VmId.generate().value,
            },
          );
        });
      await _withServer(router, (server) async {
        final malformed = await _invoke(server, [
          'vm',
          'open-display',
          vm.value,
        ]);
        expect(malformed.code, 4);
        expect(jsonDecode(malformed.error)['code'], 'CLI_PROTOCOL');
        reject = true;
        final rejected = await _invoke(server, [
          'vm',
          'open-display',
          vm.value,
        ]);
        expect(rejected.code, 1);
        expect(rejected.output, isEmpty);
        expect(
          Problem.fromJson(jsonDecode(rejected.error)).code,
          ErrorCode.vmOperationConflict,
        );
        expect(calls, 2);
      });
    },
  );

  test(
    'CLI display has explicit targets, generated keys, and a local timeout that never retries',
    () async {
      final vm = VmId.generate();
      final release = Completer<void>();
      var calls = 0;
      final router = PublicApiRouter()
        ..add('POST', '/v1/vms/{vm_id}/actions/close-display', (request) async {
          calls++;
          expect(
            request.headers['idempotency-key']!.single,
            matches(RegExp(r'^[\x21-\x7e]{1,255}$')),
          );
          await release.future;
          return PublicApiResponse.json(
            status: 202,
            body: {
              'operation_id': OperationId.generate().value,
              'state': 'pending',
              'resource_type': 'virtual_machine',
              'resource_id': vm.value,
            },
          );
        });
      await _withServer(router, (server) async {
        try {
          final timedOut = await _invoke(server, [
            'vm',
            'close-display',
            vm.value,
            '--timeout-seconds',
            '1',
          ]);
          expect(timedOut.code, 124);
          expect(timedOut.output, isEmpty);
          expect(jsonDecode(timedOut.error)['code'], 'CLI_TIMEOUT');
          expect(calls, 1);
        } finally {
          release.complete();
        }
        for (final arguments in [
          ['vm', 'open-display'],
          ['vm', 'open-display', 'default'],
          ['vm', 'close-display', OperationId.generate().value],
          ['vm', 'display', vm.value, '--idempotency-key', 'bad-read-key'],
          ['vm', 'open-display', vm.value, '--body-json', '{}'],
        ]) {
          final invalid = await _invoke(server, arguments);
          expect(invalid.code, 2, reason: arguments.join(' '));
          expect(jsonDecode(invalid.error)['code'], 'CLI_USAGE');
        }
        expect(calls, 1);
      });
    },
  );

  test(
    'CLI display actions preserve the public target, request key, and asynchronous acceptance',
    () async {
      final vm = VmId.generate();
      final acceptance = {
        'operation_id': OperationId.generate().value,
        'state': 'pending',
        'resource_type': 'virtual_machine',
        'resource_id': vm.value,
      };
      final calls = <String>[];
      final router = PublicApiRouter();
      for (final action in ['open-display', 'close-display']) {
        router.add('POST', '/v1/vms/{vm_id}/actions/$action', (request) async {
          calls.add(action);
          expect(request.pathParameters['vm_id'], vm.value);
          expect(request.headers['idempotency-key'], ['display-once']);
          expect(request.jsonBody!.toJson(), {});
          return PublicApiResponse.json(status: 202, body: acceptance);
        });
      }
      await _withServer(router, (server) async {
        for (final action in ['open-display', 'close-display']) {
          final result = await _invoke(server, [
            'vm',
            action,
            vm.value,
            '--idempotency-key',
            'display-once',
          ]);
          expect(result.code, 0, reason: result.error);
          expect(jsonDecode(result.output), acceptance);
        }
        expect(calls, ['open-display', 'close-display']);
      });
    },
  );
}

// External host/driver SDK boundaries only. Public handlers, controllers,
// transactional persistence, command delivery and CLI are real implementations.
final class _DisplayHostBoundary
    implements VmLeaseEffectAdapter, VmManagedFileEffectAdapter {
  @override
  Future<void> acquire(
    VmControllerState state,
    OperationId operationId,
  ) async {}
  @override
  Future<void> markRunning(
    VmControllerState state,
    OperationId operationId,
  ) async {}
  @override
  Future<void> release(
    VmControllerState state,
    OperationId? operationId,
  ) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected managed file operation');
}

final class _OutsideDisplayApi
    implements
        VmCreateAcceptor,
        VmPatchAcceptor,
        VmConditionWaiter,
        OperationMutationAcceptor,
        OperationWaiter {
  @override
  Future<Never> wait(Object command) async =>
      fail('unrelated wait API was called');
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unrelated API operation was called');
}
