import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'e2e_runtime_inspection.dart';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--help') {
    stdout.writeln(
      'GaoVM public-API VM smoke test (macOS 14+, Apple Silicon)\n'
      'Required: KERNEL_PATH and DISK_PATH point to existing ARM64 guest images.\n'
      'Optional: INITRD_PATH, DRIVER_BIN, STATE_DIR (must not exist),\n'
      'SOCK_PATH (inside STATE_DIR/run), TIMEOUT_SECONDS (default 120).\n'
      'DART_BIN selects the Dart 3.9 executable in the shell entrypoint.\n'
      '--multi-vm selects the three-VM independence check instead of display.\n'
      'Inputs are imported; the VM receives a managed writable disk.\n'
      'Run files are retained. This is not installed-service or GaoOS acceptance.',
    );
    return;
  }
  OwnedE2eDaemon? daemon;
  NativeVmRuntimeInspection? inspection;
  ProcessSignal? interrupted;
  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    final multiVm = args.length == 1 && args.single == '--multi-vm';
    if (args.isNotEmpty && !multiVm)
      throw const FormatException(
        'use --help, --multi-vm or environment inputs, not positional arguments',
      );
    if (!Platform.isMacOS ||
        (await Process.run('/usr/bin/uname', [
              '-m',
            ])).stdout.toString().trim() !=
            'arm64' ||
        int.parse(
              (await Process.run('/usr/bin/sw_vers', [
                '-productVersion',
              ])).stdout.toString().split('.').first,
            ) <
            14) {
      throw const FormatException(
        'requires Apple Silicon macOS 14+; no run was started',
      );
    }
    final env = Platform.environment;
    final kernel = await _existingFile(env['KERNEL_PATH'], 'KERNEL_PATH');
    final disk = await _existingFile(env['DISK_PATH'], 'DISK_PATH');
    final initrd = env['INITRD_PATH'] == null || env['INITRD_PATH']!.isEmpty
        ? null
        : await _existingFile(env['INITRD_PATH'], 'INITRD_PATH');
    final timeout = int.tryParse(env['TIMEOUT_SECONDS'] ?? '120');
    if (timeout == null || timeout < 1 || timeout > 86400)
      throw const FormatException('TIMEOUT_SECONDS must be 1-86400');
    final root = Directory.fromUri(Platform.script.resolve('../../../'));
    final packageConfig =
        '${root.path}/daemon/gaovmd/.dart_tool/package_config.json';
    await _existingFile(
      packageConfig,
      'daemon package config (run dart pub get --enforce-lockfile)',
    );
    final customDriver = env['DRIVER_BIN'] == null
        ? null
        : await _existingFile(env['DRIVER_BIN'], 'DRIVER_BIN');
    final state = await createSmokeState(requested: env['STATE_DIR']);
    stdout.writeln(jsonEncode({'state_dir': state.path, 'retained': true}));
    final socket = env['SOCK_PATH'] ?? '${state.path}/run/api.sock';
    if (!File(socket).isAbsolute ||
        File(socket).parent.path != '${state.path}/run' ||
        utf8.encode(socket).length >= 104)
      throw const FormatException(
        'SOCK_PATH must fit the Unix socket limit inside canonical STATE_DIR/run',
      );
    final driverProject = '${root.path}/drivers/vz_macos';
    String sourceDriver;
    if (customDriver == null) {
      await _tool('swift', ['build'], workingDirectory: driverProject);
      final bin = await _tool('swift', [
        'build',
        '--show-bin-path',
      ], workingDirectory: driverProject);
      sourceDriver = await _existingFile(
        '${bin.trim()}/gaovm-driver-vz',
        'built driver',
      );
    } else {
      sourceDriver = customDriver;
    }
    final tools = await Directory('${state.path}/bin').create();
    await _tool('/bin/chmod', ['700', tools.path]);
    final driver = await File(
      sourceDriver,
    ).copy('${tools.path}/gaovm-driver-vz');
    await _tool('/bin/chmod', ['700', driver.path]);
    await _tool('/usr/bin/codesign', [
      '--force',
      '--sign',
      '-',
      '--options',
      'runtime',
      '--timestamp=none',
      '--entitlements',
      '$driverProject/Resources/entitlements.plist',
      driver.path,
    ]);
    if (multiVm)
      inspection = await NativeVmRuntimeInspection.open(
        stateDirectory: state,
        executable: driver.path,
      );
    final vmIds = <VmId>[];
    final runtimeBindings = <Map<String, Object?>>[];
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=$packageConfig',
        '${root.path}/daemon/gaovmd/bin/gaovmd.dart',
        '--state-dir',
        state.path,
        '--socket-path',
        socket,
        '--driver-bin',
        driver.path,
        '--openapi-path',
        '${root.path}/schemas/openapi/gaovm-v1.yaml',
      ],
      workingDirectory: root.path,
      runInShell: false,
    );
    final owned = daemon = OwnedE2eDaemon(process, socket);
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      signals.add(
        signal.watch().listen((received) {
          interrupted ??= received;
          unawaited(
            owned.stop().catchError((Object error) {
              stderr.writeln(error);
            }),
          );
        }),
      );
    }
    await owned.waitUntilListening();
    final id = await runVmHappyPath(
      socketPath: socket,
      kernelPath: kernel,
      initrdPath: initrd,
      diskPath: disk,
      timeoutSeconds: timeout,
      multiVm: multiVm,
      inspectRuntimes: inspection == null
          ? null
          : (vms) async {
              final records = await inspection!.check(vms);
              if (vmIds.isEmpty) {
                vmIds.addAll(vms.map((vm) => vm.metadata.id));
                runtimeBindings.addAll(
                  records.map(
                    (record) => {
                      'vm_id': record.correlation.vmId.value,
                      'driver_generation': record.correlation.driverGeneration,
                      'pid': record.pid,
                      'socket_path': record.socketPath,
                    },
                  ),
                );
              }
            },
    );
    await owned.stop();
    if (interrupted != null) throw StateError('native run interrupted');
    stdout.writeln(
      jsonEncode({
        'vm_id': id.value,
        'state_dir': state.path,
        if (multiVm) ...{
          'vm_ids': vmIds.map((id) => id.value).toList(),
          'public_multi_vm_isolation': 'passed',
          'runtime_bindings': runtimeBindings,
        } else
          'public_vm_display_flow': 'passed',
        'daemon_exit_confirmed': true,
        'not_verified': [
          'framebuffer',
          'input',
          'guest_exec',
          if (multiVm) 'display' else 'multi_vm',
          'test_run',
          'daemon_restart_recovery',
          'crash_recovery',
          'installed_service',
          'release',
        ],
      }),
    );
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 2;
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    try {
      await daemon?.stop();
    } catch (error) {
      stderr.writeln(error);
      exitCode = 1;
    }
    for (final signal in signals) await signal.cancel();
    inspection?.close();
    if (interrupted != null)
      exitCode = interrupted == ProcessSignal.sigint ? 130 : 143;
  }
}

Future<Directory> createSmokeState({String? requested}) async {
  Directory state;
  if (requested != null) {
    if (!Directory(requested).isAbsolute ||
        await FileSystemEntity.type(requested, followLinks: false) !=
            FileSystemEntityType.notFound)
      throw const FormatException(
        'STATE_DIR must be an absolute, new directory; existing state is never reused',
      );
    state = await Directory(requested).create();
  } else {
    state =
        await (Platform.isMacOS
                ? Directory('/private/tmp')
                : Directory.systemTemp)
            .createTemp('gvm-e2e-');
  }
  state = Directory(await state.resolveSymbolicLinks());
  await _tool('/bin/chmod', ['700', state.path]);
  // Shape-only probe for the frozen 26-character VM ID, not a created resource.
  final driverSocket =
      '${state.path}/run/vm_00000000000000000000000000/1/driver.sock';
  if (utf8.encode(driverSocket).length >= 104)
    throw FormatException(
      'STATE_DIR leaves no room for the driver socket; choose a shorter path. New private state retained at ${state.path}',
    );
  return state;
}

Future<String> _existingFile(String? path, String name) async {
  if (path == null ||
      path.isEmpty ||
      !File(path).isAbsolute ||
      await FileSystemEntity.type(path) != FileSystemEntityType.file ||
      await File(path).length() == 0) {
    throw FormatException(
      '$name must name an existing, nonempty absolute file',
    );
  }
  return File(path).resolveSymbolicLinks();
}

Future<String> _tool(
  String executable,
  List<String> args, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    args,
    workingDirectory: workingDirectory,
    runInShell: false,
  );
  if (result.exitCode != 0)
    throw StateError(
      '$executable failed (${result.exitCode}): ${result.stderr}',
    );
  return result.stdout.toString();
}

final class OwnedE2eDaemon {
  OwnedE2eDaemon(this.process, this.socketPath) {
    _exit = process.exitCode.then((code) {
      _exited = true;
      return code;
    });
    _stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line == 'gaovmd listening on unix:$socketPath' &&
              !_ready.isCompleted)
            _ready.complete();
        });
    _stderr = process.stderr.transform(utf8.decoder).listen((chunk) {
      final remaining = 32768 - _diagnostics.length;
      if (remaining > 0)
        _diagnostics.write(
          chunk.substring(
            0,
            chunk.length < remaining ? chunk.length : remaining,
          ),
        );
    }, onDone: _stderrDone.complete);
  }
  final Process process;
  final String socketPath;
  final _ready = Completer<void>();
  final _stderrDone = Completer<void>();
  final _diagnostics = StringBuffer();
  late final Future<int> _exit;
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<String> _stderr;
  bool _exited = false;
  Future<void>? _stopping;

  Future<void> waitUntilListening() => Future.any<void>([
    _ready.future,
    _exit.then((code) async {
      await _stderrDone.future;
      throw StateError('daemon exited before listening ($code): $_diagnostics');
    }),
  ]).timeout(const Duration(seconds: 30));

  Future<void> stop() => _stopping ??= _stop();
  Future<void> _stop() async {
    try {
      for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigkill]) {
        if (_exited) break;
        process.kill(signal);
        try {
          await _exit.timeout(
            Duration(seconds: signal == ProcessSignal.sigterm ? 10 : 5),
          );
        } on TimeoutException {
          // Delivery and elapsed time do not establish process retirement.
        }
      }
      if (!_exited)
        throw StateError(
          'owned daemon PID ${process.pid} exit unconfirmed; retain all run files',
        );
      await _stderrDone.future.timeout(const Duration(seconds: 2));
      final code = await _exit;
      if (_ready.isCompleted && code != 0) {
        throw StateError(
          'owned daemon had a nonzero exit ($code): $_diagnostics',
        );
      }
    } finally {
      await _stdout.cancel();
      await _stderr.cancel();
    }
  }
}

Future<VmId> runVmHappyPath({
  required String socketPath,
  required String kernelPath,
  required String diskPath,
  String? initrdPath,
  int timeoutSeconds = 120,
  bool multiVm = false,
  Future<void> Function(List<VirtualMachine>)? inspectRuntimes,
}) async {
  if (multiVm && inspectRuntimes == null)
    throw ArgumentError(
      'multi-VM acceptance requires native runtime inspection',
    );
  final keyPrefix = RequestId.generate().value;
  var keySequence = 0;
  Future<Object?> cli(List<String> command) async {
    final output = StringBuffer(), error = StringBuffer();
    final code = await runCli(
      [
        '--socket-path',
        socketPath,
        ...command,
        '--timeout-seconds',
        '$timeoutSeconds',
        '--json',
      ],
      output: output.writeln,
      error: error.writeln,
    );
    if (code != 0) {
      throw StateError(
        '${command.take(2).join(' ')} failed ($code): '
        '${error.isEmpty ? output : error}',
      );
    }
    return jsonDecode(output.toString());
  }

  Future<({OperationId operationId, ResourceId resourceId})> accept(
    List<String> command,
    ResourceType type, {
    ResourceId? target,
  }) async {
    final body = await cli([
      ...command,
      '--idempotency-key',
      '$keyPrefix-${keySequence++}',
    ]);
    final resourceType = type == ResourceType.image
        ? 'image'
        : 'virtual_machine';
    if (body is! Map ||
        body.length != 4 ||
        body['resource_type'] != resourceType ||
        !const ['pending', 'running', 'succeeded'].contains(body['state'])) {
      throw const FormatException('invalid Operation acceptance');
    }
    final operationId = OperationId(body['operation_id'] as String);
    final resource = type == ResourceType.image
        ? ImageId(body['resource_id'] as String)
        : VmId(body['resource_id'] as String);
    if (target != null && target != resource)
      throw StateError('acceptance belongs to another resource');
    return (operationId: operationId, resourceId: resource);
  }

  Future<Operation> completion(
    ({OperationId operationId, ResourceId resourceId}) accepted,
    ResourceType type,
    String operationType,
  ) async {
    final operation = Operation.fromJson(
      await cli(['operation', 'wait', accepted.operationId.value]),
    );
    if (operation.id != accepted.operationId ||
        operation.resourceId != accepted.resourceId ||
        operation.resourceType != type ||
        operation.type != operationType ||
        operation.state != OperationState.succeeded) {
      throw StateError('Operation completion does not match its acceptance');
    }
    return operation;
  }

  Future<Operation> mutate(
    List<String> command,
    ResourceType type,
    String operationType, {
    ResourceId? target,
  }) async => completion(
    await accept(command, type, target: target),
    type,
    operationType,
  );

  Future<ImageId> importImage(String path, String type) async =>
      (await mutate(
            [
              'image',
              'import',
              '--body-json',
              jsonEncode({
                'source_path': path,
                'type': type,
                'architecture': 'arm64',
              }),
            ],
            ResourceType.image,
            'image.import',
          )).resourceId
          as ImageId;

  final kernel = await importImage(kernelPath, 'linux-kernel');
  final initrd = initrdPath == null
      ? null
      : await importImage(initrdPath, 'initrd');
  final disk = await importImage(diskPath, 'raw-disk');
  final request = VmCreateRequest(
    name: 'native-e2e-$keyPrefix',
    spec: VmSpec(
      cpu: 2,
      memoryBytes: 2147483648,
      boot: LinuxKernelBoot(
        kernelImageId: kernel,
        initrdImageId: initrd,
        commandLine: 'console=hvc0 root=/dev/vda rw',
      ),
      disks: [
        VmDisk(
          id: 'root',
          source: ManagedImageDiskSource(disk),
          writable: true,
        ),
      ],
      networks: [SharedNetwork(id: 'net0')],
      graphics: multiVm
          ? GraphicsConfig(enabled: false)
          : GraphicsConfig(enabled: true, width: 1280, height: 800),
      serial: const SerialConfig(enabled: true, capture: true),
      guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
      restartPolicy: RestartPolicy.never,
    ),
  );
  Future<Operation> action(String action, VmId id) => mutate(
    ['vm', action, id.value],
    ResourceType.virtualMachine,
    'vm.${action.replaceAll('-', '_')}',
    target: id,
  );
  Future<VirtualMachine> vm(VmId id) async {
    final result = VirtualMachine.fromJson(await cli(['vm', 'get', id.value]));
    if (result.metadata.id != id)
      throw StateError('VM status belongs to another VM');
    return result;
  }

  Future<void> waitRunning(VmId id) async {
    final wait = await cli([
      'vm',
      'wait',
      id.value,
      '--condition',
      'runtime_running',
    ]);
    if (wait is! Map ||
        wait.length != 4 ||
        wait['vm_id'] != id.value ||
        wait['condition'] != 'runtime_running' ||
        wait['reached'] != true ||
        wait['observed_at'] is! String ||
        DateTime.tryParse(wait['observed_at'] as String) == null) {
      throw const FormatException('invalid runtime wait result');
    }
  }

  void requireRunning(VirtualMachine running) {
    if (running.status.phase != VmPhase.running ||
        running.status.desiredState != DesiredState.running ||
        running.status.driverGeneration < 1) {
      throw StateError('VM did not reach a running generation');
    }
  }

  final owned = <VmId>[];
  Object? primaryFailure;
  try {
    for (var index = 0; index < (multiVm ? 3 : 1); index++) {
      final created = await accept([
        'vm',
        'create',
        '--body-json',
        jsonEncode(
          VmCreateRequest(
            name: '${request.name}-$index',
            spec: request.spec,
          ).toJson(),
        ),
      ], ResourceType.virtualMachine);
      final id = created.resourceId as VmId;
      if (owned.contains(id))
        throw StateError('VM creation reused another VM identity');
      // Keep accepted resources owned even if their create completion fails.
      owned.add(id);
      await completion(created, ResourceType.virtualMachine, 'vm.create');
    }
    final id = owned.first;
    if (multiVm) {
      final starts = await Future.wait([
        for (final target in owned.take(2))
          accept(
            ['vm', 'start', target.value],
            ResourceType.virtualMachine,
            target: target,
          ),
      ]);
      if (starts.map((start) => start.operationId).toSet().length != 2)
        throw StateError('independent starts share an Operation');
      await Future.wait([
        for (final start in starts)
          completion(start, ResourceType.virtualMachine, 'vm.start'),
      ]);
      await Future.wait(owned.take(2).map(waitRunning));
      final running = await Future.wait(owned.map(vm));
      requireRunning(running[0]);
      requireRunning(running[1]);
      void requireNeverStarted(VirtualMachine stopped) {
        if (stopped.status.phase != VmPhase.stopped ||
            stopped.status.desiredState != DesiredState.stopped ||
            stopped.status.driverGeneration != 0)
          throw StateError('the third VM started a runtime');
      }

      requireNeverStarted(running[2]);
      await inspectRuntimes!(running);
      await action('stop', id);
      final isolated = await Future.wait(owned.map(vm));
      if (isolated[0].status.phase != VmPhase.stopped ||
          isolated[0].status.desiredState != DesiredState.stopped)
        throw StateError('owned VM stop did not complete');
      requireRunning(isolated[1]);
      if (isolated[1].status.driverGeneration !=
              running[1].status.driverGeneration ||
          isolated[1].spec != running[1].spec ||
          isolated[1].status.observedGeneration !=
              running[1].status.observedGeneration)
        throw StateError('stopping VM-A changed VM-B lifetime');
      requireNeverStarted(isolated[2]);
      await inspectRuntimes(isolated);
      return id;
    }
    await action('start', id);
    await waitRunning(id);
    final running = await vm(id);
    requireRunning(running);
    for (final open in [true, false, true, false]) {
      await action(open ? 'open-display' : 'close-display', id);
      final display = VmDisplayStatus.fromJson(
        await cli(['vm', 'display', id.value]),
      );
      final current = await vm(id);
      if (display.vmId != id ||
          display.driverGeneration != running.status.driverGeneration ||
          display.state !=
              (open ? VmDisplayState.open : VmDisplayState.closed) ||
          display.observedAt == null ||
          current.status.phase != VmPhase.running ||
          current.status.desiredState != DesiredState.running ||
          current.status.driverGeneration != running.status.driverGeneration) {
        throw StateError(
          'display action changed VM lifetime or lacked a confirmed snapshot',
        );
      }
    }
    return id;
  } catch (error) {
    primaryFailure = error;
    rethrow;
  } finally {
    final cleanupErrors = <Object>[];
    for (final id in owned) {
      try {
        await action('stop', id);
        final stopped = await vm(id);
        if (stopped.status.phase != VmPhase.stopped ||
            stopped.status.desiredState != DesiredState.stopped) {
          throw StateError('owned VM stop did not complete');
        }
      } catch (error) {
        cleanupErrors.add('$id: $error');
      }
    }
    if (multiVm && owned.length == 3 && cleanupErrors.isEmpty) {
      try {
        await inspectRuntimes!(await Future.wait(owned.map(vm)));
      } catch (error) {
        cleanupErrors.add('native runtime cleanup unconfirmed: $error');
      }
    }
    if (cleanupErrors.isNotEmpty)
      throw StateError(
        '${primaryFailure == null ? '' : '$primaryFailure; '}owned VM cleanup failed: ${cleanupErrors.join('; ')}',
      );
  }
}
