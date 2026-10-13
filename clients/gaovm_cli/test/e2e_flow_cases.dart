part of 'public_api_cli_test.dart';

void _e2eFlowTests() {
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
  test(
    'native entrypoint rejects unsupported hosts before creating state',
    () async {
      if (Platform.isMacOS &&
          (await Process.run('/usr/bin/uname', [
                '-m',
              ])).stdout.toString().trim() ==
              'arm64') {
        markTestSkipped(
          'unsupported-host guard applies only outside Apple Silicon macOS',
        );
        return;
      }
      final directory = await Directory.systemTemp.createTemp(
        'e2e-host-guard-',
      );
      try {
        final state = '${directory.path}/must-not-exist';
        final result = await Process.run(
          '/bin/bash',
          ['../../scripts/e2e_macos14_happy_path.sh'],
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
