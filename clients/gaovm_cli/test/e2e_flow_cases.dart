part of 'public_api_cli_test.dart';

void _e2eFlowTests() {
  test('native multi-VM recipe rejects collateral VM stops', () async {
    final api = _MultiVmApi(collateralStop: true);
    await _withServer(api.router, (server) async {
      await expectLater(
        e2e.runVmHappyPath(
          socketPath: server.socketPath,
          kernelPath: '/fixture/kernel',
          diskPath: '/fixture/root.raw',
          multiVm: true,
          inspectRuntimes: (_) async {},
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'diagnostic',
            contains('running generation'),
          ),
        ),
      );
    });
    expect(api.stops.toSet(), api.created.toSet());
  });
  test(
    'native multi-VM recipe stops an accepted VM after its create completion mismatches',
    () async {
      final api = _MultiVmApi(mismatchCreateCompletion: true);
      await _withServer(api.router, (server) async {
        await expectLater(
          e2e.runVmHappyPath(
            socketPath: server.socketPath,
            kernelPath: '/fixture/kernel',
            diskPath: '/fixture/root.raw',
            multiVm: true,
            inspectRuntimes: (_) async {},
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'diagnostic',
              contains('completion does not match'),
            ),
          ),
        );
      });
      expect(api.created, hasLength(2));
      expect(api.starts, isEmpty);
      expect(api.stops.toSet(), api.created.toSet());
    },
  );
  test(
    'native multi-VM recipe joins sibling cleanup after one stop is refused',
    () async {
      final api = _MultiVmApi(rejectFirstStop: true);
      await _withServer(api.router, (server) async {
        await expectLater(
          e2e.runVmHappyPath(
            socketPath: server.socketPath,
            kernelPath: '/fixture/kernel',
            diskPath: '/fixture/root.raw',
            multiVm: true,
            inspectRuntimes: (_) async {},
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'diagnostic',
              allOf(
                contains('cleanup refused'),
                contains('owned VM cleanup failed'),
              ),
            ),
          ),
        );
      });
      expect(api.stops.toSet(), api.created.toSet());
      expect(api.phases[api.created.first], VmPhase.running);
      expect(
        api.created.skip(1).map((id) => api.phases[id]),
        everyElement(VmPhase.stopped),
      );
    },
  );
  test(
    'native custom state rejects oversized driver sockets before native work',
    () async {
      final parent = await Directory.systemTemp.createTemp('gvm-long-');
      final state = '${parent.path}/${List.filled(80, 's').join()}';
      try {
        await expectLater(
          e2e.createSmokeState(requested: state),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'diagnostic',
              contains('driver socket'),
            ),
          ),
        );
      } finally {
        await parent.delete(recursive: true);
      }
    },
  );
  test('native default state fits the driver Unix socket path limit', () async {
    final state = await e2e.createSmokeState();
    try {
      final paths = DriverRuntimeLayout('${state.path}/run').paths(
        DriverCorrelation(
          vmId: VmId.generate(),
          driverGeneration: 1,
          operationId: null,
        ),
      );
      expect(utf8.encode(paths.socketPath).length, lessThan(104));
    } finally {
      await state.delete(recursive: true);
    }
  });
  for (final mode in ['missing', 'matching', 'duplicate', 'unresolved']) {
    test(
      'native runtime inspection requires distinct live bindings: $mode',
      () async {
        final directory =
            await (Platform.isMacOS
                    ? Directory('/private/tmp')
                    : Directory.systemTemp)
                .createTemp('gvm-inspect-');
        imageFileMode(directory.path, 0x1c0);
        final state = Directory(await directory.resolveSymbolicLinks());
        final executable = await File(
          '${state.path}/driver',
        ).writeAsString('fixture only');
        var observed = <DriverProcessIdentity>[];
        final identities = <VmId, DriverProcessIdentity>{};
        final boundCounts = <int>[];
        final inspection = await native.NativeVmRuntimeInspection.open(
          stateDirectory: state,
          executable: executable.path,
          observe: () async => DriverInventorySnapshot(
            processes: mode == 'missing' ? [] : observed,
            unresolvedProcessIds: mode == 'unresolved' ? [300] : [],
          ),
        );
        var initialized = false;
        try {
          final api = _MultiVmApi();
          await _withServer(api.router, (server) async {
            final workflow = e2e.runVmHappyPath(
              socketPath: server.socketPath,
              kernelPath: '/fixture/kernel',
              diskPath: '/fixture/root.raw',
              multiVm: true,
              inspectRuntimes: (vms) async {
                final layout = DriverRuntimeLayout('${state.path}/run');
                for (final vm in vms.where(
                  (vm) => !initialized && vm.status.phase == VmPhase.running,
                )) {
                  final correlation = DriverCorrelation(
                    vmId: vm.metadata.id,
                    driverGeneration: vm.status.driverGeneration,
                    operationId: null,
                  );
                  final paths = await layout.create(correlation);
                  final identity = DriverProcessIdentity(
                    pid: 200 + (mode == 'duplicate' ? 0 : vms.indexOf(vm)),
                    uid: 501,
                    executablePath: executable.path,
                    startedAtMicroseconds: 1000,
                    pidVersion: 1,
                  );
                  identities[vm.metadata.id] = identity;
                  await layout.writeMetadata(
                    paths,
                    correlation: correlation,
                    pid: identity.pid,
                    executable: executable.path,
                    bundlePath:
                        '${state.path}/vms/${vm.metadata.id.value}.gaovm',
                    createdAt: DateTime.now(),
                    processIdentity: identity,
                  );
                }
                initialized = true;
                observed = [
                  for (final vm in vms.where(
                    (vm) => vm.status.phase == VmPhase.running,
                  ))
                    identities[vm.metadata.id]!,
                ];
                boundCounts.add((await inspection.check(vms)).length);
              },
            );
            if (mode == 'matching') {
              await workflow;
              expect(boundCounts, [2, 1, 0]);
            } else {
              await expectLater(
                workflow,
                throwsA(
                  isA<StateError>().having(
                    (error) => error.message,
                    'diagnostic',
                    contains('live driver inventory'),
                  ),
                ),
              );
            }
          });
        } finally {
          inspection.close();
          await state.delete(recursive: true);
        }
      },
    );
  }
  test(
    'native multi-VM recipe starts two VMs before waiting and stops them independently',
    () async {
      final api = _MultiVmApi();
      final observations = <List<VirtualMachine>>[];
      await _withServer(api.router, (server) async {
        await e2e.runVmHappyPath(
          socketPath: server.socketPath,
          kernelPath: '/fixture/kernel',
          diskPath: '/fixture/root.raw',
          multiVm: true,
          inspectRuntimes: (vms) async => observations.add(vms),
        );
      });
      expect(api.created, hasLength(3));
      expect(api.starts, api.created.take(2).toList());
      expect(api.startsAtWait, [2, 2]);
      expect(observations, hasLength(3));
      expect(observations.first.map((vm) => vm.status.phase), [
        VmPhase.running,
        VmPhase.running,
        VmPhase.stopped,
      ]);
      expect(observations[1].map((vm) => vm.status.phase), [
        VmPhase.stopped,
        VmPhase.running,
        VmPhase.stopped,
      ]);
      expect(
        observations.last.map((vm) => vm.status.phase),
        everyElement(VmPhase.stopped),
      );
      expect(observations.first.last.status.driverGeneration, 0);
      expect(api.phases.values, everyElement(VmPhase.stopped));
    },
  );
  test(
    'native harness cannot report success after a nonzero daemon shutdown',
    () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'test/fixtures/e2e_daemon.dart',
        '/fixture/api.sock',
        'fail-stop',
      ]);
      var childExited = false;
      final exited = process.exitCode.then((code) {
        childExited = true;
        return code;
      });
      final daemon = e2e.OwnedE2eDaemon(process, '/fixture/api.sock');
      try {
        await daemon.waitUntilListening();
        await expectLater(
          daemon.stop(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message.toString(),
              'diagnostic',
              contains('nonzero exit (9)'),
            ),
          ),
        );
        expect(await exited, 9);
      } finally {
        if (!childExited) process.kill(ProcessSignal.sigterm);
        await exited.timeout(const Duration(seconds: 2));
      }
    },
  );
  for (final args in [
    <String>[],
    ['--multi-vm'],
  ]) {
    test(
      'native entrypoint rejects unsupported hosts before creating state (${args.isEmpty ? 'display' : 'multi-vm'})',
      () async {
        if (Platform.isMacOS &&
            (await Process.run('/usr/bin/uname', [
                  '-m',
                ])).stdout.toString().trim() ==
                'arm64' &&
            int.parse(
                  (await Process.run('/usr/bin/sw_vers', [
                    '-productVersion',
                  ])).stdout.toString().split('.').first,
                ) >=
                14) {
          markTestSkipped('host supports native VM execution');
          return;
        }
        final directory = await Directory.systemTemp.createTemp(
          'e2e-host-guard-',
        );
        try {
          final state = '${directory.path}/must-not-exist';
          final result = await Process.run(
            '/bin/bash',
            ['../../scripts/e2e_macos14_happy_path.sh', ...args],
            includeParentEnvironment: false,
            environment: {
              'DART_BIN': Platform.resolvedExecutable,
              'PATH': '/usr/bin:/bin',
              'STATE_DIR': state,
              'KERNEL_PATH': '/missing/kernel',
              'DISK_PATH': '/missing/disk',
            },
          );
          expect(result.exitCode, 2, reason: '${result.stderr}');
          expect(result.stderr, contains('requires Apple Silicon macOS 14+'));
          expect(await Directory(state).exists(), isFalse);
        } finally {
          await directory.delete(recursive: true);
        }
      },
    );
  }
  test(
    'E2E shell entrypoint provides help without host inputs or side effects',
    () async {
      final result = await Process.run(
        '/bin/bash',
        ['../../scripts/e2e_macos14_happy_path.sh', '--help'],
        includeParentEnvironment: false,
        environment: {
          'DART_BIN': Platform.resolvedExecutable,
          'PATH': '/usr/bin:/bin',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('KERNEL_PATH'));
      expect(result.stdout, contains('DISK_PATH'));
      expect(result.stdout, contains('Apple Silicon'));
      expect(result.stdout, contains('--multi-vm'));
      expect(result.stderr, isEmpty);
    },
  );
  test(
    'native harness observes daemon readiness and confirms its owned child exit',
    () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'test/fixtures/e2e_daemon.dart',
        '/fixture/api.sock',
      ]);
      var childExited = false;
      final exited = process.exitCode.then((code) {
        childExited = true;
        return code;
      });
      try {
        final daemon = e2e.OwnedE2eDaemon(process, '/fixture/api.sock');
        await daemon.waitUntilListening();
        await daemon.stop();
        expect(await exited.timeout(const Duration(seconds: 2)), 0);
      } finally {
        if (!childExited) process.kill(ProcessSignal.sigterm);
        await exited.timeout(const Duration(seconds: 2));
      }
    },
  );
  test(
    'native harness reports a terminal pre-listener startup failure immediately',
    () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'test/fixtures/e2e_daemon.dart',
        '/fixture/api.sock',
        'fail-start',
      ]);
      var childExited = false;
      final exited = process.exitCode.then((code) {
        childExited = true;
        return code;
      });
      final daemon = e2e.OwnedE2eDaemon(process, '/fixture/api.sock');
      try {
        await expectLater(
          daemon.waitUntilListening().timeout(const Duration(seconds: 2)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message.toString(),
              'diagnostic',
              allOf(
                contains('before listening (7)'),
                contains('fixture census rejected'),
              ),
            ),
          ),
        );
        await daemon.stop();
        expect(await exited, 7);
      } finally {
        if (!childExited) process.kill(ProcessSignal.sigterm);
        await exited.timeout(const Duration(seconds: 2));
      }
    },
  );
  test(
    'native happy-path recipe imports images and waits for public VM actions',
    () async {
      final api = _HappyPathApi();
      await _withServer(api.router, (server) async {
        final id = await e2e.runVmHappyPath(
          socketPath: server.socketPath,
          kernelPath: '/fixture/kernel with spaces',
          initrdPath: '/fixture/initrd',
          diskPath: '/fixture/root.raw',
        );
        expect(id, api.vmId);
        final vm = VirtualMachine.fromJson(
          jsonDecode((await _invoke(server, ['vm', 'get', id.value])).output),
        );
        expect(vm.status.phase, VmPhase.stopped);
        expect(vm.status.desiredState, DesiredState.stopped);
        expect(
          vm.spec.boot,
          LinuxKernelBoot(
            kernelImageId: api.images['linux-kernel']!,
            initrdImageId: api.images['initrd'],
            commandLine: 'console=hvc0 root=/dev/vda rw',
          ),
        );
        expect(
          vm.spec.disks.single.source,
          ManagedImageDiskSource(api.images['raw-disk']!),
        );
        expect(api.waited, api.operations.keys.toSet());
        expect(api.sources, [
          '/fixture/kernel with spaces',
          '/fixture/initrd',
          '/fixture/root.raw',
        ]);
        expect(api.displayTransitions, [
          VmDisplayState.open,
          VmDisplayState.closed,
          VmDisplayState.open,
          VmDisplayState.closed,
        ]);
      });
    },
  );
  test(
    'failed native recipe retains the display failure when VM cleanup also fails',
    () async {
      final api = _HappyPathApi(stopOnClose: true, rejectStop: true);
      await _withServer(api.router, (server) async {
        await expectLater(
          e2e.runVmHappyPath(
            socketPath: server.socketPath,
            kernelPath: '/fixture/kernel',
            diskPath: '/fixture/root.raw',
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message.toString(),
              'diagnostic',
              allOf(
                contains('display action changed VM lifetime'),
                contains('owned VM cleanup failed'),
                contains('cleanup refused'),
              ),
            ),
          ),
        );
        expect(api.displayTransitions, [
          VmDisplayState.open,
          VmDisplayState.closed,
        ]);
      });
    },
  );
}

// External API boundary: real UDS/CLI traffic, not native VZ evidence.
final class _MultiVmApi {
  _MultiVmApi({
    this.collateralStop = false,
    this.mismatchCreateCompletion = false,
    this.rejectFirstStop = false,
  }) {
    router
      ..add(
        'POST',
        '/v1/images/import',
        (request) async => accept(
          request,
          ImageId.generate(),
          ResourceType.image,
          'image.import',
        ),
      )
      ..add('POST', '/v1/vms', (request) async {
        final id = VmId.generate();
        specs[id] = VmCreateRequest.fromJson(request.jsonBody!.toJson());
        created.add(id);
        phases[id] = VmPhase.stopped;
        generations[id] = 0;
        return accept(request, id, ResourceType.virtualMachine, 'vm.create');
      })
      ..add(
        'GET',
        '/v1/vms/{vm_id}',
        (request) async => PublicApiResponse.json(
          status: 200,
          body: vm(VmId(request.pathParameters['vm_id']!)).toJson(),
        ),
      )
      ..add(
        'POST',
        '/v1/vms/{vm_id}/wait',
        (request) async => PublicApiResponse.json(
          status: 200,
          body: {
            'vm_id': request.pathParameters['vm_id'],
            'condition': 'runtime_running',
            'reached': true,
            'observed_at': now.toIso8601String(),
          },
        ),
      )
      ..add('POST', '/v1/operations/{operation_id}/wait', (request) async {
        final operation =
            operations[OperationId(request.pathParameters['operation_id']!)]!;
        if (operation.type == 'vm.start') startsAtWait.add(starts.length);
        if (mismatchCreateCompletion &&
            operation.type == 'vm.create' &&
            created.length == 2 &&
            operation.resourceId == created.last)
          return PublicApiResponse.json(
            status: 200,
            body: {...operation.toJson(), 'type': 'vm.start'},
          );
        return PublicApiResponse.json(status: 200, body: operation.toJson());
      });
    for (final action in ['start', 'stop']) {
      router.add('POST', '/v1/vms/{vm_id}/actions/$action', (request) async {
        final id = VmId(request.pathParameters['vm_id']!);
        if (action == 'start') {
          starts.add(id);
          phases[id] = VmPhase.running;
          generations[id] = 1;
        }
        if (action == 'stop') {
          stops.add(id);
          if (rejectFirstStop && id == created.first)
            return PublicApiResponse.problem(
              status: 409,
              code: ErrorCode.vmOperationConflict,
              type: 'vm-operation-conflict',
              title: 'cleanup refused',
              detail: 'cleanup refused',
              retryable: false,
            );
          phases[id] = VmPhase.stopped;
          if (collateralStop) {
            for (final target in created) phases[target] = VmPhase.stopped;
          }
        }
        return accept(
          request,
          id,
          ResourceType.virtualMachine,
          'vm.${action.replaceAll('-', '_')}',
        );
      });
    }
  }
  final bool collateralStop;
  final bool mismatchCreateCompletion;
  final bool rejectFirstStop;
  final router = PublicApiRouter();
  final now = DateTime.now().toUtc();
  final created = <VmId>[];
  final starts = <VmId>[];
  final stops = <VmId>[];
  final startsAtWait = <int>[];
  final specs = <VmId, VmCreateRequest>{};
  final phases = <VmId, VmPhase>{};
  final generations = <VmId, int>{};
  final operations = <OperationId, Operation>{};
  PublicApiResponse accept(
    PublicApiRequest request,
    ResourceId id,
    ResourceType type,
    String action,
  ) {
    expect(request.headers['idempotency-key']?.single, isNotEmpty);
    final operation = OperationId.generate();
    operations[operation] = Operation(
      id: operation,
      type: action,
      resourceType: type,
      resourceId: id,
      state: OperationState.succeeded,
      requestId: request.requestId,
      cancellable: false,
      request: request.jsonBody ?? JsonObjectValue.empty,
      createdAt: now,
      completedAt: now,
    );
    return PublicApiResponse.json(
      status: 202,
      body: {
        'operation_id': operation.value,
        'resource_id': id.value,
        'resource_type': type == ResourceType.image
            ? 'image'
            : 'virtual_machine',
        'state': 'pending',
      },
    );
  }

  VirtualMachine vm(VmId id) => VirtualMachine(
    metadata: VmMetadata(
      id: id,
      name: specs[id]!.name,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    ),
    spec: specs[id]!.spec,
    status: VmStatus(
      desiredState: phases[id] == VmPhase.running
          ? DesiredState.running
          : DesiredState.stopped,
      phase: phases[id]!,
      specGeneration: 1,
      observedGeneration: generations[id]!,
      driverGeneration: generations[id]!,
      guestAgent: GuestAgentState.disabled,
      lastTransitionAt: now,
    ),
  );
}

// External public API fixture; this verifies orchestration, not native VZ IO.
final class _HappyPathApi {
  _HappyPathApi({this.stopOnClose = false, this.rejectStop = false}) {
    router
      ..add('POST', '/v1/images/import', (request) async {
        final body = request.jsonBody!.toJson();
        sources.add(body['source_path'] as String);
        expect(body['architecture'], 'arm64');
        final id = ImageId.generate();
        images[body['type'] as String] = id;
        return _accept(request, id, ResourceType.image, 'image.import');
      })
      ..add('POST', '/v1/vms', (request) async {
        create = VmCreateRequest.fromJson(request.jsonBody!.toJson());
        return _accept(request, vmId, ResourceType.virtualMachine, 'vm.create');
      })
      ..add('GET', '/v1/vms/{vm_id}', (request) async {
        expect(request.pathParameters['vm_id'], vmId.value);
        return PublicApiResponse.json(status: 200, body: _vm().toJson());
      })
      ..add('POST', '/v1/vms/{vm_id}/wait', (request) async {
        expect(request.pathParameters['vm_id'], vmId.value);
        expect(request.jsonBody!.toJson(), {
          'condition': 'runtime_running',
          'timeout_seconds': 120,
        });
        return PublicApiResponse.json(
          status: 200,
          body: {
            'vm_id': vmId.value,
            'condition': 'runtime_running',
            'reached': true,
            'observed_at': now.toIso8601String(),
          },
        );
      })
      ..add('POST', '/v1/operations/{operation_id}/wait', (request) async {
        final id = OperationId(request.pathParameters['operation_id']!);
        expect(request.jsonBody!.toJson(), {'timeout_seconds': 120});
        waited.add(id);
        return PublicApiResponse.json(
          status: 200,
          body: operations[id]!.toJson(),
        );
      })
      ..add('GET', '/v1/vms/{vm_id}/display', (request) async {
        expect(request.pathParameters['vm_id'], vmId.value);
        return PublicApiResponse.json(
          status: 200,
          body: VmDisplayStatus(
            vmId: vmId,
            driverGeneration: 1,
            state: display,
            observedAt: now,
          ).toJson(),
        );
      });
    for (final action in ['start', 'stop', 'open-display', 'close-display']) {
      router.add('POST', '/v1/vms/{vm_id}/actions/$action', (request) async {
        expect(request.pathParameters['vm_id'], vmId.value);
        expect(request.jsonBody!.toJson(), isEmpty);
        if (action == 'stop' && rejectStop) {
          return PublicApiResponse.problem(
            status: 409,
            code: ErrorCode.vmOperationConflict,
            type: 'vm-operation-conflict',
            title: 'cleanup refused',
            detail: 'cleanup refused',
            retryable: false,
          );
        }
        if (action == 'start') phase = VmPhase.running;
        if (action == 'stop') phase = VmPhase.stopped;
        if (action.endsWith('-display')) {
          display = action == 'open-display'
              ? VmDisplayState.open
              : VmDisplayState.closed;
          displayTransitions.add(display);
          if (action == 'close-display' && stopOnClose) phase = VmPhase.stopped;
        }
        return _accept(
          request,
          vmId,
          ResourceType.virtualMachine,
          'vm.${action.replaceAll('-', '_')}',
        );
      });
    }
  }

  final router = PublicApiRouter();
  final bool stopOnClose;
  final bool rejectStop;
  final vmId = VmId.generate();
  final now = DateTime.now().toUtc();
  final images = <String, ImageId>{};
  final sources = <String>[];
  final operations = <OperationId, Operation>{};
  final waited = <OperationId>{};
  final displayTransitions = <VmDisplayState>[];
  late VmCreateRequest create;
  VmPhase phase = VmPhase.stopped;
  VmDisplayState display = VmDisplayState.closed;

  PublicApiResponse _accept(
    PublicApiRequest request,
    ResourceId resource,
    ResourceType type,
    String operationType,
  ) {
    expect(request.headers['idempotency-key']?.single, isNotEmpty);
    final id = OperationId.generate();
    operations[id] = Operation(
      id: id,
      type: operationType,
      resourceType: type,
      resourceId: resource,
      state: OperationState.succeeded,
      requestId: request.requestId,
      cancellable: false,
      request: request.jsonBody ?? JsonObjectValue.empty,
      createdAt: now,
      completedAt: now,
    );
    return PublicApiResponse.json(
      status: 202,
      body: {
        'operation_id': id.value,
        'resource_id': resource.value,
        'resource_type': type == ResourceType.image
            ? 'image'
            : 'virtual_machine',
        'state': 'pending',
      },
    );
  }

  VirtualMachine _vm() => VirtualMachine(
    metadata: VmMetadata(
      id: vmId,
      name: create.name,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    ),
    spec: create.spec,
    status: VmStatus(
      desiredState: phase == VmPhase.running
          ? DesiredState.running
          : DesiredState.stopped,
      phase: phase,
      specGeneration: 1,
      observedGeneration: 1,
      driverGeneration: 1,
      guestAgent: GuestAgentState.disabled,
      lastTransitionAt: now,
    ),
  );
}
