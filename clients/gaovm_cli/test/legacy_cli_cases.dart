part of 'public_api_cli_test.dart';

void _legacyCliTests() {
  test(
    'legacy executable resolves its environment binding through public HTTP',
    () async {
      final vm = _legacyVm();
      final router = PublicApiRouter()
        ..add('GET', '/v1/vms/{vm_id}', (request) async {
          expect(request.pathParameters['vm_id'], vm.metadata.id.value);
          return PublicApiResponse.json(
            status: 200,
            body: vm.toJson(),
            headers: {'ETag': '"7"'},
          );
        });
      await _withServer(router, (server) async {
        final result = await Process.run(
          Platform.resolvedExecutable,
          [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/bin/gaovm_cli.dart',
            '--socket-path',
            server.socketPath,
            '--json',
          ],
          environment: {'GAOVM_LEGACY_VM_ID': vm.metadata.id.value},
        ).timeout(const Duration(seconds: 15));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          VirtualMachine.fromJson(jsonDecode(result.stdout as String)),
          vm,
        );
      });
    },
  );

  test(
    'legacy config preserves a revision conflict without retrying',
    () async {
      var calls = 0;
      final router = PublicApiRouter()
        ..add('PATCH', '/v1/vms/{vm_id}', (_) async {
          calls++;
          return PublicApiResponse.problem(
            status: 409,
            code: ErrorCode.revisionConflict,
            type: 'revision-conflict',
            title: 'Revision conflict',
            detail: 'Changed by another client.',
            retryable: false,
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, [
          'config-patch',
          '--vm-id',
          VmId.generate().value,
          '--json',
          '{"cpu":4}',
          '--if-match',
          '7',
          '--idempotency-key',
          'retry-exact',
        ]);
        expect(result.code, 1);
        final problem = Problem.fromJson(jsonDecode(result.error));
        expect(problem.code, ErrorCode.revisionConflict);
        expect(problem.status, 409);
        expect(problem.requestId.value, startsWith('req_'));
        expect(calls, 1);
      });
    },
  );

  test(
    'legacy ambiguity and unsupported inputs fail before public IO',
    () async {
      var calls = 0;
      final vm = VmId.generate().value;
      final router = PublicApiRouter()
        ..add('GET', '/v1/vms', (_) async {
          calls++;
          return PublicApiResponse.json(status: 200, body: {});
        })
        ..add('GET', '/v1/vms/{vm_id}', (_) async {
          calls++;
          return PublicApiResponse.json(status: 200, body: {});
        })
        ..add('PATCH', '/v1/vms/{vm_id}', (_) async {
          calls++;
          return PublicApiResponse.json(status: 200, body: {});
        });
      await _withServer(router, (server) async {
        for (final args in [
          ['start'],
          ['stop', '--vm-id', 'default'],
          ['status'],
          ['config-get', '--vm-id', OperationId.generate().value],
          ['driver-exec', '--method', 'vm.start'],
          ['vm', 'start', 'default'],
          ['vm', 'list', '--verbose'],
          ['vm', 'patch', vm, '--json', '{}', '--if-match', '7'],
          ['config-patch', '--vm-id', vm, '--json', '{"cpu":4}'],
          [
            'config-patch',
            '--vm-id',
            vm,
            '--json',
            '{"cpu":null}',
            '--if-match',
            '7',
          ],
          [
            'config-patch',
            '--vm-id',
            vm,
            '--json',
            '{"boot":{"kernelPath":"/kernel"}}',
            '--if-match',
            '7',
          ],
          [
            'config-patch',
            '--vm-id',
            vm,
            '--json',
            '{"disk":{"sizeMiB":64}}',
            '--if-match',
            '7',
          ],
          [
            'config-patch',
            '--vm-id',
            vm,
            '--json',
            '{"cpu":4,"extra":true}',
            '--if-match',
            '7',
          ],
          [
            'config-patch',
            '--vm-id',
            vm,
            '--json',
            '{"graphics":{"extra":true}}',
            '--if-match',
            '7',
          ],
          [
            'config-set',
            '--vm-id',
            vm,
            '--json',
            '{"cpu":4}',
            '--if-match',
            '7',
          ],
          [
            'config-patch',
            '--vm-id',
            vm,
            '--json',
            '{}',
            '--json',
            '{}',
            '--if-match',
            '7',
          ],
        ]) {
          final result = await _invoke(server, args);
          expect(result.code, 2, reason: '${args.join(' ')}: ${result.error}');
          expect(jsonDecode(result.error)['code'], 'CLI_USAGE');
        }
        final invalidBinding = await _invoke(
          server,
          ['status'],
          environment: {'GAOVM_LEGACY_VM_ID': 'default'},
        );
        expect(invalidBinding.code, 2);
        expect(calls, 0);
      });
    },
  );

  test(
    'legacy nested config read and write share one local deadline',
    () async {
      final vm = _legacyVm();
      final router = PublicApiRouter()
        ..add('GET', '/v1/vms/{vm_id}', (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 650));
          return PublicApiResponse.json(
            status: 200,
            body: vm.toJson(),
            headers: {'ETag': '"7"'},
          );
        })
        ..add('PATCH', '/v1/vms/{vm_id}', (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 650));
          return PublicApiResponse.json(
            status: 202,
            body: {
              'operation_id': OperationId.generate().value,
              'resource_id': vm.metadata.id.value,
              'resource_type': 'virtual_machine',
              'state': 'pending',
            },
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, [
          'config-patch',
          '--vm-id',
          vm.metadata.id.value,
          '--json',
          '{"graphics":{"enabled":false}}',
          '--if-match',
          '7',
          '--timeout-seconds',
          '1',
        ]);
        expect(result.code, 124);
        expect(jsonDecode(result.error)['code'], 'CLI_TIMEOUT');
      });
    },
  );

  test(
    'legacy status rejects a response belonging to a different VM',
    () async {
      final wrong = _legacyVm();
      final router = PublicApiRouter()
        ..add(
          'GET',
          '/v1/vms/{vm_id}',
          (_) async => PublicApiResponse.json(
            status: 200,
            body: wrong.toJson(),
            headers: {'ETag': '"7"'},
          ),
        );
      await _withServer(router, (server) async {
        final result = await _invoke(server, [
          'status',
          '--vm-id',
          VmId.generate().value,
        ]);
        expect(result.code, 4);
        expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
      });
    },
  );

  test('legacy ping and verbose spellings use public health', () async {
    await _withServer(PublicApiRouter(), (server) async {
      for (final args in [
        ['ping'],
        ['ping', '--verbose'],
        ['ping', '-v'],
      ]) {
        final result = await _invoke(server, args);
        expect(result.code, 0, reason: result.error);
        expect(
          SystemHealth.fromJson(
            jsonDecode(result.output),
            probe: SystemHealthProbe.live,
          ).healthy,
          isTrue,
        );
      }
    });
  });

  test(
    'legacy lifecycle aliases use only explicitly bound real VM IDs',
    () async {
      final vm = VmId.generate();
      final operation = OperationId.generate();
      final actions = <String>[];
      final router = PublicApiRouter();
      for (final action in ['start', 'stop', 'open-display', 'close-display']) {
        router.add('POST', '/v1/vms/{vm_id}/actions/$action', (request) async {
          expect(request.pathParameters['vm_id'], vm.value);
          actions.add(action);
          return PublicApiResponse.json(
            status: 202,
            body: {
              'operation_id': operation.value,
              'resource_id': vm.value,
              'resource_type': 'virtual_machine',
              'state': 'pending',
            },
          );
        });
      }
      await _withServer(router, (server) async {
        for (final action in [
          'start',
          'stop',
          'open-display',
          'close-display',
        ]) {
          final result = await _invoke(
            server,
            [action, '--vm-id', 'default'],
            environment: {'GAOVM_LEGACY_VM_ID': vm.value},
          );
          expect(result.code, 0, reason: result.error);
          expect(jsonDecode(result.output)['resource_id'], vm.value);
        }
        expect(actions, ['start', 'stop', 'open-display', 'close-display']);
      });
    },
  );

  test(
    'legacy config-patch translates scalar fields with explicit OCC and idempotency',
    () async {
      final vm = VmId.generate();
      var calls = 0;
      final router = PublicApiRouter()
        ..add('PATCH', '/v1/vms/{vm_id}', (request) async {
          calls++;
          expect(request.pathParameters['vm_id'], vm.value);
          expect(request.headers['if-match'], ['"7"']);
          expect(request.headers['idempotency-key'], ['config-once']);
          expect(jsonDecode(utf8.decode(request.bodyBytes)), {
            'spec': {'cpu': 4, 'memory_bytes': 536870912},
          });
          return PublicApiResponse.json(
            status: 202,
            body: {
              'operation_id': OperationId.generate().value,
              'resource_id': vm.value,
              'resource_type': 'virtual_machine',
              'state': 'pending',
            },
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, [
          'config-patch',
          '--vm-id',
          vm.value,
          '--json',
          '{"cpu":4,"memory":536870912}',
          '--if-match',
          '7',
          '--idempotency-key',
          'config-once',
        ]);
        expect(result.code, 0, reason: result.error);
        expect(calls, 1);
        expect(jsonDecode(result.output)['state'], 'pending');
      });
    },
  );

  test(
    'legacy config-set translates its complete shape without dropping new spec fields',
    () async {
      final vm = _legacyVm();
      final boot = vm.spec.boot as LinuxKernelBoot;
      var calls = 0;
      final router = PublicApiRouter()
        ..add(
          'GET',
          '/v1/vms/{vm_id}',
          (_) async => PublicApiResponse.json(
            status: 200,
            body: vm.toJson(),
            headers: {'ETag': '"7"'},
          ),
        )
        ..add('PATCH', '/v1/vms/{vm_id}', (request) async {
          calls++;
          expect(request.headers['if-match'], ['"7"']);
          final patch =
              jsonDecode(utf8.decode(request.bodyBytes))['spec'] as Map;
          expect(patch['boot'], {
            ...boot.toJson(),
            'command_line': 'console=hvc0',
          });
          expect(patch['disks'], [
            {
              'id': 'root',
              'source': {'type': 'external', 'path': '/operator/new.raw'},
              'writable': true,
            },
          ]);
          expect(patch['networks'], [
            {'id': 'net0', 'mode': 'shared'},
          ]);
          expect(patch['graphics'], {
            ...vm.spec.graphics.toJson(),
            'enabled': true,
            'width': 1280,
            'height': 720,
          });
          expect(
            patch.keys,
            unorderedEquals([
              'cpu',
              'memory_bytes',
              'boot',
              'disks',
              'networks',
              'graphics',
            ]),
          );
          return PublicApiResponse.json(
            status: 202,
            body: {
              'operation_id': OperationId.generate().value,
              'resource_id': vm.metadata.id.value,
              'resource_type': 'virtual_machine',
              'state': 'pending',
            },
          );
        });
      await _withServer(router, (server) async {
        final result = await _invoke(server, [
          'config-set',
          '--vm-id',
          vm.metadata.id.value,
          '--if-match',
          '7',
          '--json',
          jsonEncode({
            'cpu': 4,
            'memory': 536870912,
            'boot': {
              'loader': 'linux',
              'kernelPath': boot.kernelImageId.value,
              'initrdPath': null,
              'commandLine': 'console=hvc0',
            },
            'disk': {'path': '/operator/new.raw', 'sizeMiB': null},
            'network': {'mode': 'shared'},
            'graphics': {'enabled': true, 'width': 1280, 'height': 720},
          }),
        ]);
        expect(result.code, 0, reason: result.error);
        expect(calls, 1);
      });
    },
  );
}

VirtualMachine _legacyVm() => VirtualMachine(
  metadata: VmMetadata(
    id: VmId.generate(),
    name: 'legacy',
    revision: 7,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
  spec: VmSpec(
    cpu: 2,
    memoryBytes: 268435456,
    boot: LinuxKernelBoot(kernelImageId: ImageId.generate()),
    disks: [
      VmDisk(
        id: 'root',
        source: ExternalDiskSource('/operator/old.raw'),
        writable: true,
      ),
    ],
    networks: [DisconnectedNetwork(id: 'net0')],
    graphics: GraphicsConfig(enabled: false),
    serial: const SerialConfig(enabled: true, capture: true),
    guestAgent: GuestAgentConfig(enabled: true, requiredForReady: true),
    restartPolicy: RestartPolicy.onFailure,
  ),
  status: VmStatus(
    desiredState: DesiredState.stopped,
    phase: VmPhase.stopped,
    specGeneration: 1,
    observedGeneration: 0,
    driverGeneration: 0,
    guestAgent: GuestAgentState.disabled,
    lastTransitionAt: DateTime.utc(2026),
  ),
);
