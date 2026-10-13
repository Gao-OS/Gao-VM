import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_models/gaovm_models.dart';

Future<void> main(List<String> args) async {
  if (args.length == 1 && args.single == '--help') {
    stdout.writeln(
      'GaoVM public-API VM smoke test (macOS 14+, Apple Silicon)\n'
      'Required: KERNEL_PATH and DISK_PATH point to existing ARM64 guest images.\n'
      'Optional: INITRD_PATH, DRIVER_BIN, STATE_DIR (must not exist),\n'
      'SOCK_PATH (inside STATE_DIR/run), TIMEOUT_SECONDS (default 120).\n'
      'DART_BIN selects the Dart 3.9 executable in the shell entrypoint.\n'
      'Inputs are imported; the VM receives a managed writable disk.\n'
      'Run files are retained. This is not installed-service or GaoOS acceptance.',
    );
    return;
  }
  OwnedE2eDaemon? daemon;
  ProcessSignal? interrupted;
  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    if (args.isNotEmpty)
      throw const FormatException(
        'use --help or environment inputs, not positional arguments',
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
    Directory state;
    if (env['STATE_DIR'] case final requested?) {
      if (!Directory(requested).isAbsolute ||
          await FileSystemEntity.type(requested, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw const FormatException(
          'STATE_DIR must be an absolute, new directory; existing state is never reused',
        );
      }
      state = await Directory(requested).create();
    } else {
      state = await Directory.systemTemp.createTemp('gaovm-native-e2e-');
    }
    state = Directory(await state.resolveSymbolicLinks());
    await _tool('/bin/chmod', ['700', state.path]);
    stdout.writeln(jsonEncode({'state_dir': state.path, 'retained': true}));
    final socket = env['SOCK_PATH'] ?? '${state.path}/run/api.sock';
    if (!File(socket).isAbsolute ||
        File(socket).parent.path != '${state.path}/run')
      throw const FormatException(
        'SOCK_PATH must be inside the canonical STATE_DIR/run',
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
    );
    await owned.stop();
    if (interrupted != null) throw StateError('native run interrupted');
    stdout.writeln(
      jsonEncode({
        'vm_id': id.value,
        'state_dir': state.path,
        'public_vm_display_flow': 'passed',
        'daemon_exit_confirmed': true,
        'not_verified': [
          'framebuffer',
          'input',
          'guest_exec',
          'multi_vm',
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
    if (interrupted != null)
      exitCode = interrupted == ProcessSignal.sigint ? 130 : 143;
  }
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
}) async {
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

  Future<Operation> mutate(
    List<String> command,
    ResourceType type,
    String operationType, {
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
    final operation = Operation.fromJson(
      await cli(['operation', 'wait', operationId.value]),
    );
    if (operation.id != operationId ||
        operation.resourceId != resource ||
        operation.resourceType != type ||
        operation.type != operationType ||
        operation.state != OperationState.succeeded) {
      throw StateError('Operation completion does not match its acceptance');
    }
    return operation;
  }

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
      graphics: GraphicsConfig(enabled: true, width: 1280, height: 800),
      serial: const SerialConfig(enabled: true, capture: true),
      guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
      restartPolicy: RestartPolicy.never,
    ),
  );
  final created = await mutate(
    ['vm', 'create', '--body-json', jsonEncode(request.toJson())],
    ResourceType.virtualMachine,
    'vm.create',
  );
  final id = created.resourceId as VmId;

  Future<Operation> action(String action) => mutate(
    ['vm', action, id.value],
    ResourceType.virtualMachine,
    'vm.${action.replaceAll('-', '_')}',
    target: id,
  );
  Future<VirtualMachine> vm() async {
    final result = VirtualMachine.fromJson(await cli(['vm', 'get', id.value]));
    if (result.metadata.id != id)
      throw StateError('VM status belongs to another VM');
    return result;
  }

  Object? primaryFailure;
  try {
    await action('start');
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
    final running = await vm();
    if (running.status.phase != VmPhase.running ||
        running.status.desiredState != DesiredState.running ||
        running.status.driverGeneration < 1) {
      throw StateError('VM did not reach a running generation');
    }
    for (final open in [true, false, true, false]) {
      await action(open ? 'open-display' : 'close-display');
      final display = VmDisplayStatus.fromJson(
        await cli(['vm', 'display', id.value]),
      );
      final current = await vm();
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
    try {
      await action('stop');
      final stopped = await vm();
      if (stopped.status.phase != VmPhase.stopped ||
          stopped.status.desiredState != DesiredState.stopped) {
        throw StateError('owned VM stop did not complete');
      }
    } catch (error) {
      if (primaryFailure != null)
        throw StateError('$primaryFailure; owned VM cleanup failed: $error');
      rethrow;
    }
  }
}
