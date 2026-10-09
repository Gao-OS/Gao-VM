import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  test(
    'installed daemon completes a pre-cancelled TestRun without client polling',
    () async {
      final state = await Directory('/private/tmp').createTemp('gvm-collect-');
      addTearDown(() => state.delete(recursive: true));
      final database = await GaoVmDatabase.open('${state.path}/gaovm.db');
      addTearDown(database.close);
      final source =
          await ImageStore(
            database,
            Directory('${state.path}/images'),
          ).importFile(
            await File('${state.path}/input-kernel').writeAsString('kernel'),
            type: ImageType.linuxKernel,
          );
      final spec = TestRunSpec(
        source: ImageTestRunSource(source.id),
        wait: VmWaitSpec(
          condition: WaitCondition.runtimeRunning,
          timeoutSeconds: 30,
        ),
        steps: [
          TestStepRequest(argv: ['true'], timeoutSeconds: 30),
        ],
        cleanup: CleanupPolicy.retain,
        retainOnFailure: true,
      );
      final service = TestRunApplicationService(database: database);
      final acceptance = await service.create(
        TestRunCreateCommand(
          spec: spec,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: utf8.encode(jsonEncode(spec.toJson())),
        ),
      );
      final id = acceptance.resourceId as TestRunId;
      await service.cancelRun(
        TestRunCancelCommand(
          testRunId: id,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
        ),
      );
      final completed = Completer<void>();
      final subscription = SqliteDurableEventFeed(database)
          .watch(testRunId: id)
          .listen((event) {
            if (event.type == 'test_run.completed' && !completed.isCompleted) {
              completed.complete();
            }
          }, onError: completed.completeError);
      _Daemon? daemon;
      try {
        daemon = await _Daemon.start(state, '/bin/cat');
        await completed.future.timeout(const Duration(seconds: 5));
        final status = await daemon.get('/v1/test-runs/${id.value}');
        expect(status.$1, HttpStatus.ok);
        expect(status.$2['state'], 'cancelled');
        expect(status.$2['cleanup_decision'], 'not_required');
        final operation = await daemon.get(
          '/v1/operations/${acceptance.operationId.value}',
        );
        expect(operation.$1, HttpStatus.ok);
        expect(operation.$2['state'], 'cancelled');
        final response = await daemon.get(
          '/v1/test-runs/${id.value}/artifacts',
        );
        expect(response.$1, HttpStatus.ok);
        final artifact = ((response.$2['items'] as List).single as Map);
        expect(artifact['kind'], 'result');
        expect(artifact['test_run_id'], id.value);
        expect(artifact['operation_id'], acceptance.operationId.value);
        final result = await daemon.get(artifact['download_url'] as String);
        expect(result.$1, HttpStatus.ok);
        expect(result.$2['execution_outcome'], 'cancelled');
        expect(result.$2['vm_id'], isNull);
        expect(await SqliteVmRepository(database).list(), isEmpty);
      } finally {
        await subscription.cancel();
        await daemon?.close();
        if (daemon != null) expect(await daemon.process.exitCode, 0);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'installed daemon serves the VM catalog over HTTP UDS',
    () async {
      final state = await Directory('/private/tmp').createTemp('gvm-app-');
      addTearDown(() => state.delete(recursive: true));
      final daemon = await _Daemon.start(state, '/bin/cat');
      final missingVmId = VmId.generate();
      try {
        final response = await daemon.get('/v1/vms');
        expect(response.$1, HttpStatus.ok);
        expect(response.$2['items'], isEmpty);
        final images = await daemon.get('/v1/images');
        expect(images.$1, HttpStatus.ok);
        expect(images.$2['items'], isEmpty);
        final logs = await daemon.get('/v1/vms/${missingVmId.value}/logs');
        expect(logs.$1, HttpStatus.notFound);
        expect(logs.$2['code'], 'VM_NOT_FOUND');
        final health = await daemon.get('/v1/system/live');
        expect(health.$1, HttpStatus.ok);
      } finally {
        await daemon.close();
      }
      final records =
          (await File('${state.path}/logs/gaovmd.log').readAsLines())
              .map((line) => jsonDecode(line) as Map<String, dynamic>)
              .toList();
      expect(records, hasLength(4));
      expect(
        records.map((record) => record['component']),
        everyElement('gaovmd.api'),
      );
      expect(
        records.map((record) => record['event_type']),
        everyElement('api.request.completed'),
      );
      expect(records.map((record) => record['message']), [
        'public API response 200',
        'public API response 200',
        'public API response 404',
        'public API response 200',
      ]);
      expect(records[2]['vm_id'], missingVmId.value);
      expect(
        records.map((record) => record['driver_generation']),
        everyElement(isNull),
      );
      expect(
        records.map((record) => record['operation_id']),
        everyElement(isNull),
      );
      final requestIds = records
          .map((record) => RequestId(record['request_id'] as String))
          .toSet();
      expect(requestIds, hasLength(4));
    },
    skip: !Platform.isMacOS,
  );

  test(
    'a second daemon cannot mutate an owned state directory',
    () async {
      final temporary = await Directory(
        '/private/tmp',
      ).createTemp('gvm-owner-');
      final state = await OwnedImageDirectory.open(temporary);
      final owner = (await DaemonOwnership.tryAcquire(state))!;
      try {
        await expectLater(
          DaemonApplication.start(
            stateDirectory: temporary,
            driverBinary: '/bin/cat',
            openApiDocument: const {},
          ),
          throwsStateError,
        );
        expect(await File('${state.path}/gaovm.db').exists(), isFalse);
        expect(await Directory('${state.path}/run').exists(), isFalse);
        await owner.verify();
      } finally {
        owner.close();
        state.close();
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'linked catalogs are rejected without touching their target',
    () async {
      final temporary = await Directory('/private/tmp').createTemp('gvm-link-');
      final outside = await File(
        '${temporary.path}/outside',
      ).writeAsString('preserve');
      await Link('${temporary.path}/gaovm.db').create(outside.path);
      try {
        await expectLater(
          DaemonApplication.start(
            stateDirectory: temporary,
            driverBinary: '/bin/cat',
            openApiDocument: const {},
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await outside.readAsString(), 'preserve');
        final state = await OwnedImageDirectory.open(temporary);
        final owner = (await DaemonOwnership.tryAcquire(state))!;
        owner.close();
        state.close();
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );

  test(
    'linked artifact stores are rejected without touching their target',
    () async {
      final temporary = await Directory(
        '/private/tmp',
      ).createTemp('gvm-art-link-');
      final state = await Directory('${temporary.path}/state').create();
      imageFileMode(state.path, 0x1c0);
      final outside = await Directory('${temporary.path}/outside').create();
      final proof = await File(
        '${outside.path}/proof',
      ).writeAsString('preserve');
      await Link('${state.path}/artifacts').create(outside.path);
      DaemonApplication? daemon;
      try {
        await expectLater(() async {
          daemon = await DaemonApplication.start(
            stateDirectory: state,
            driverBinary: '/bin/cat',
            openApiDocument: const {},
          );
        }(), throwsA(isA<FileSystemException>()));
        expect(await proof.readAsString(), 'preserve');
        final held = await OwnedImageDirectory.open(state);
        final owner = (await DaemonOwnership.tryAcquire(held))!;
        owner.close();
        held.close();
      } finally {
        await daemon?.close();
        await temporary.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
  );
}

final class _Daemon {
  _Daemon(this.process, this.client, this.output, this.errors) {
    process.exitCode.then((_) => _exited = true);
  }
  final Process process;
  final HttpClient client;
  final StreamSubscription<String> output;
  final Future<void> errors;
  bool _exited = false;
  Future<void>? _closing;

  static Future<_Daemon> start(Directory state, String driver) async {
    final socket = '${state.path}/run/api.sock';
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      '${Directory.current.path}/bin/gaovmd.dart',
      '--state-dir',
      state.path,
      '--socket-path',
      socket,
      '--driver-bin',
      driver,
    ]);
    final ready = Completer<void>();
    final diagnostics = StringBuffer();
    final errors = process.stderr.transform(utf8.decoder).forEach((chunk) {
      if (diagnostics.length < 8192) diagnostics.write(chunk);
    });
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.startsWith('gaovmd listening on unix:') &&
                !ready.isCompleted) {
              ready.complete();
            }
          },
          onDone: () {
            errors.then((_) {
              if (!ready.isCompleted)
                ready.completeError(
                  StateError('daemon exited before listening: $diagnostics'),
                );
            });
          },
        );
    final client = HttpClient()
      ..connectionFactory = (_, _, _) => Socket.startConnect(
        InternetAddress(socket, type: InternetAddressType.unix),
        0,
      );
    final daemon = _Daemon(process, client, output, errors);
    try {
      await ready.future.timeout(const Duration(seconds: 10));
      return daemon;
    } catch (_) {
      await daemon.close();
      rethrow;
    }
  }

  Future<(int, Map<String, Object?>)> get(String path) async {
    final request = await client.getUrl(Uri.parse('http://localhost$path'));
    final response = await request.close().timeout(const Duration(seconds: 3));
    final decoded = jsonDecode(await response.transform(utf8.decoder).join());
    return (response.statusCode, Map<String, Object?>.from(decoded as Map));
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    client.close(force: true);
    if (!_exited) process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      if (!_exited) process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await output.cancel();
    await errors;
  }
}
