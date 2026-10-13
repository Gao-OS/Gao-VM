import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  _wireTests();
  _transportAndUsageTests();
  group('real public log service', () {
    late Directory temporary;
    late GaoVmDatabase database;
    late OwnedImageDirectory bundles;
    late OwnedImageDirectory images;
    late PublicApiServer server;

    setUp(() async {
      temporary =
          await (Platform.isMacOS
                  ? Directory('/private/tmp')
                  : Directory.systemTemp)
              .createTemp('gvm-log-cli-');
      imageFileMode(temporary.path, 0x1c0);
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final bundleRoot = await Directory('${temporary.path}/vms').create();
      final imageRoot = await Directory('${temporary.path}/images').create();
      imageFileMode(bundleRoot.path, 0x1c0);
      imageFileMode(imageRoot.path, 0x1c0);
      bundles = await OwnedImageDirectory.open(bundleRoot);
      images = await OwnedImageDirectory.open(imageRoot);
      await File('${temporary.path}/root.raw').writeAsString('disk');
      final router = PublicApiRouter();
      VmLogApiHandlers(
        logs: VmLogApplicationService(database: database, bundles: bundles),
      ).register(router);
      server = PublicApiServer(
        socketPath: '${temporary.path}/api.sock',
        openApiDocument: const {},
        systemHealth: _Health(),
        router: router,
      );
      await server.start();
    });

    tearDown(() async {
      await server.close();
      images.close();
      bundles.close();
      database.close();
      await temporary.delete(recursive: true);
    });

    Future<VmId> createVm(String name, {bool publish = true}) async {
      final accepted =
          await SqliteVmCreateAcceptance(
            database: database,
            idempotencyRetention: const Duration(days: 30),
          ).accept(
            VmCreateCommand(
              requestId: RequestId.generate(),
              idempotencyKey: null,
              requestBody: const [],
              name: name,
              spec: VmSpec(
                cpu: 2,
                memoryBytes: 268435456,
                boot: EfiBoot(),
                disks: [
                  VmDisk(
                    id: 'root',
                    source: ExternalDiskSource('${temporary.path}/root.raw'),
                    writable: true,
                  ),
                ],
                networks: [DisconnectedNetwork(id: 'net0')],
                graphics: GraphicsConfig(enabled: false),
                serial: const SerialConfig(enabled: true, capture: true),
                guestAgent: GuestAgentConfig(
                  enabled: false,
                  requiredForReady: false,
                ),
                restartPolicy: RestartPolicy.never,
              ),
            ),
          );
      final id = accepted.resourceId as VmId;
      if (publish) {
        final job = (await SqliteVmProvisioningRepository(database).get(id))!;
        await VmBundleStore(
          database: database,
          bundles: bundles,
          images: images,
        ).withBundle(job.plan, (bundle) => bundle.publish());
      }
      return id;
    }

    String logPath(VmId id, String name) =>
        '${bundles.path}/${id.value}.gaovm/logs/$name';

    test(
      'vm logs lists only current metadata for the explicit VM over public UDS',
      () async {
        final first = await createVm('first');
        final second = await createVm('second');
        final expected = <Map<String, Object?>>[];
        for (final kind in LogKind.values) {
          final file = await File(
            logPath(first, '${kind.name}.log'),
          ).writeAsString('private ${kind.name} contents');
          await file.setLastModified(DateTime.utc(2021, 2, 3, 4, 5, 6));
          final stat = await file.stat();
          expected.add(
            LogReference(
              kind: kind,
              vmId: first,
              sizeBytes: stat.size,
              updatedAt: stat.modified,
            ).toJson(),
          );
        }
        await File(logPath(second, 'driver.log')).writeAsString('other VM');
        await File(logPath(first, 'driver.log.1')).writeAsString('rotation');
        final result = await _invoke(server.socketPath, [
          'vm',
          'logs',
          first.value,
          '--json',
        ]);
        expect(result.code, 0, reason: result.error);
        expect(result.error, isEmpty);
        expect(jsonDecode(result.output), {'items': expected});
        expect(result.output.trim().split('\n'), hasLength(1));
        expect(result.output, isNot(contains('private')));
        expect(result.output, isNot(contains(temporary.path)));
        expect(result.output, isNot(contains(second.value)));
      },
    );
    test(
      'vm logs filters existing kinds and preserves empty results',
      () async {
        final vm = await createVm('filtered');
        final serial = await File(
          logPath(vm, 'serial.log'),
        ).writeAsString('serial');
        await File(logPath(vm, 'driver.log')).writeAsString('driver');
        for (final kind in LogKind.values) {
          final result = await _invoke(server.socketPath, [
            'vm',
            'logs',
            vm.value,
            '--kind',
            kind.name,
          ]);
          expect(result.code, 0, reason: result.error);
          expect(result.error, isEmpty);
          final items = (jsonDecode(result.output)['items'] as List)
              .map(LogReference.fromJson)
              .toList();
          expect(items, hasLength(kind == LogKind.guest ? 0 : 1));
          for (final item in items) {
            expect(item.kind, kind);
            expect(item.vmId, vm);
            expect(item.artifactId, isNull);
          }
        }
        await serial.writeAsString(' more', mode: FileMode.append);
        final updated = await _invoke(server.socketPath, [
          'vm',
          'logs',
          vm.value,
          '--kind',
          'serial',
          '--json',
        ]);
        expect(updated.code, 0, reason: updated.error);
        expect(jsonDecode(updated.output)['items'].single['size_bytes'], 11);
      },
    );
    test(
      'vm logs does not create an unpublished bundle or an absent log',
      () async {
        final vm = await createVm('unpublished', publish: false);
        final result = await _invoke(server.socketPath, [
          'vm',
          'logs',
          vm.value,
          '--json',
        ]);
        expect(result.code, 0, reason: result.error);
        expect(jsonDecode(result.output), {'items': []});
        expect(
          await Directory('${bundles.path}/${vm.value}.gaovm').exists(),
          isFalse,
        );

        final published = await createVm('empty');
        final empty = await _invoke(server.socketPath, [
          'vm',
          'logs',
          published.value,
          '--json',
        ]);
        expect(empty.code, 0, reason: empty.error);
        expect(jsonDecode(empty.output), {'items': []});
        expect(await File(logPath(published, 'guest.log')).exists(), isFalse);
      },
    );
    test(
      'vm logs preserves public not-found and redacted unsafe-file Problems',
      () async {
        final missing = await _invoke(server.socketPath, [
          'vm',
          'logs',
          VmId.generate().value,
          '--json',
        ]);
        expect(missing.code, 1);
        expect(missing.output, isEmpty);
        final missingProblem = Problem.fromJson(jsonDecode(missing.error));
        expect(missingProblem.code, ErrorCode.vmNotFound);
        expect(missingProblem.status, HttpStatus.notFound);
        expect(missingProblem.retryable, isFalse);

        final vm = await createVm('unsafe');
        await Link(
          logPath(vm, 'driver.log'),
        ).create('${temporary.path}/root.raw');
        final unsafe = await _invoke(server.socketPath, [
          'vm',
          'logs',
          vm.value,
          '--json',
        ]);
        expect(unsafe.code, 1);
        expect(unsafe.output, isEmpty);
        final unsafeProblem = Problem.fromJson(jsonDecode(unsafe.error));
        expect(unsafeProblem.code, ErrorCode.internalError);
        expect(unsafeProblem.status, HttpStatus.internalServerError);
        expect(unsafe.error, isNot(contains(temporary.path)));
        expect(
          await Link(logPath(vm, 'driver.log')).target(),
          '${temporary.path}/root.raw',
        );
        expect(await File('${temporary.path}/root.raw').readAsString(), 'disk');
      },
    );
  });
}

void _wireTests() {
  test('vm logs sends only a read-only filtered public request', () async {
    final vm = VmId.generate();
    final reference = {
      'kind': 'serial',
      'vm_id': vm.value,
      'size_bytes': 0,
      'updated_at': '2021-02-03T05:05:06+01:00',
      'artifact_id': ArtifactId.generate().value,
    };
    await _withReply(
      {
        'items': [reference],
      },
      (socket) async {
        final result = await _invoke(socket, [
          'vm',
          'logs',
          vm.value,
          '--kind',
          'serial',
          '--json',
        ]);
        expect(result.code, 0, reason: result.error);
        expect(jsonDecode(result.output), {
          'items': [reference],
        });
      },
      beforeReply: (request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/v1/vms/${vm.value}/logs');
        expect(request.uri.queryParameters, {'kind': 'serial'});
        expect(request.bodyBytes, isEmpty);
        expect(request.jsonBody, isNull);
        expect(request.headers['idempotency-key'], isNull);
        expect(request.headers['if-match'], isNull);
      },
    );
  });
  test('vm logs accepts only the successful requested VM and kind', () async {
    final vm = VmId.generate();
    final valid = LogReference(
      kind: LogKind.serial,
      vmId: vm,
      sizeBytes: 3,
      updatedAt: DateTime.utc(2021, 2, 3, 4, 5, 6),
    ).toJson();
    for (final (status, reference) in [
      (HttpStatus.ok, {...valid, 'vm_id': VmId.generate().value}),
      (HttpStatus.ok, {...valid, 'kind': 'driver'}),
      (HttpStatus.created, valid),
      (HttpStatus.accepted, valid),
    ]) {
      await _withReply(
        {
          'items': [reference],
        },
        (socket) async {
          final result = await _invoke(socket, [
            'vm',
            'logs',
            vm.value,
            '--kind',
            'serial',
            '--json',
          ]);
          expect(result.code, 4, reason: '$status $reference');
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
        },
        status: status,
      );
    }
  });
  test('vm logs rejects malformed references as protocol failures', () async {
    final vm = VmId.generate();
    final valid = LogReference(
      kind: LogKind.driver,
      vmId: vm,
      sizeBytes: 3,
      updatedAt: DateTime.utc(2021, 2, 3, 4, 5, 6),
    ).toJson();
    for (final body in <Map<String, Object?>>[
      {},
      {'items': {}},
      {'items': [], 'next_cursor': null},
      {
        'items': [null],
      },
      {
        'items': [
          valid,
          {...valid, 'vm_id': 'default'},
        ],
      },
      for (final reference in [
        {...valid}..remove('artifact_id'),
        {...valid, 'path': '/private/log'},
        {...valid, 'kind': 'stdout'},
        {...valid, 'vm_id': 'default'},
        {...valid, 'size_bytes': -1},
        {...valid, 'size_bytes': 1.5},
        {...valid, 'updated_at': '2021-02-30T04:05:06Z'},
        {...valid, 'artifact_id': OperationId.generate().value},
      ])
        {
          'items': [reference],
        },
    ]) {
      await _withReply(body, (socket) async {
        final result = await _invoke(socket, [
          'vm',
          'logs',
          vm.value,
          '--json',
        ]);
        expect(result.code, 4, reason: '$body');
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
      });
    }
  });
}

void _transportAndUsageTests() {
  test('vm logs bounds a stalled public reply by the local deadline', () async {
    final release = Completer<void>();
    await _withReply({'items': []}, (socket) async {
      try {
        final result = await _invoke(socket, [
          'vm',
          'logs',
          VmId.generate().value,
          '--timeout-seconds',
          '1',
          '--json',
        ]);
        expect(result.code, 124);
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_TIMEOUT');
      } finally {
        release.complete();
      }
    }, beforeReply: (_) => release.future);
  });
  test(
    'vm logs reports an unavailable socket as a transport failure',
    () async {
      await _withReply({'items': []}, (socket) async {
        final result = await _invoke('$socket.missing', [
          'vm',
          'logs',
          VmId.generate().value,
          '--json',
        ]);
        expect(result.code, 3);
        expect(result.output, isEmpty);
        expect(jsonDecode(result.error)['code'], 'CLI_TRANSPORT');
      });
    },
  );
  test(
    'vm logs rejects invalid targets, kinds and unrelated options before I/O',
    () async {
      var requests = 0;
      await _withReply(
        {'items': []},
        (socket) async {
          for (final command in [
            ['vm', 'logs'],
            ['vm', 'logs', 'default'],
            ['vm', 'logs', OperationId.generate().value],
            ['vm', 'logs', VmId.generate().value, VmId.generate().value],
            for (final options in [
              ['--kind', 'unknown'],
              ['--kind'],
              ['--kind', 'serial', '--kind', 'driver'],
              ['--body-json', '{}'],
              ['--idempotency-key', 'not-a-mutation'],
              ['--if-match', '1'],
              ['--condition', 'runtime_running'],
              ['--service-name', 'sshd'],
              ['--output-dir', '/private/tmp'],
              ['--limit', '1'],
              ['--cursor', 'not-a-page'],
              ['--sort', 'name'],
              ['--label-selector', 'team=qa'],
              ['--after-sequence', '0'],
              ['--vm-id', VmId.generate().value],
              ['--operation-id', OperationId.generate().value],
              ['--test-run-id', TestRunId.generate().value],
              ['--resource-type', 'virtual_machine'],
              ['--resource-id', VmId.generate().value],
              ['--state', 'running'],
              ['--timeout-seconds', '0'],
              ['--timeout-seconds', '86401'],
            ])
              ['vm', 'logs', VmId.generate().value, ...options],
            ['vm', 'list', '--kind', 'driver'],
            ['capabilities', '--kind', 'driver'],
          ]) {
            final result = await _invoke(socket, [...command, '--json']);
            expect(result.code, 2, reason: command.join(' '));
            expect(result.output, isEmpty);
            expect(jsonDecode(result.error)['code'], 'CLI_USAGE');
          }
          expect(requests, 0);
        },
        beforeReply: (_) async {
          requests++;
        },
      );
    },
  );
  test('help documents vm logs and its kind filter without a daemon', () async {
    final result = await _invoke('/unavailable/gao-vm/api.sock', [
      '--help',
      '--json',
    ]);
    expect(result.code, 0, reason: result.error);
    final help = jsonDecode(result.output);
    expect(help['commands'], contains('vm logs VM_ID'));
    expect(help['options']['--kind KIND'], contains('vm logs'));
  });
  test('CLI process reads log references outside the checkout', () async {
    final vm = VmId.generate();
    await _withReply({'items': []}, (socket) async {
      final process = await Process.start(Platform.resolvedExecutable, [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        File('bin/gaovm_cli.dart').absolute.path,
        '--socket-path',
        socket,
        'vm',
        'logs',
        vm.value,
        '--kind',
        'serial',
        '--json',
        '--timeout-seconds',
        '5',
      ], workingDirectory: File(socket).parent.path);
      final output = utf8.decoder.bind(process.stdout).join();
      final error = utf8.decoder.bind(process.stderr).join();
      var exited = false;
      try {
        final code = await process.exitCode.timeout(
          const Duration(seconds: 15),
        );
        exited = true;
        expect(code, 0, reason: await error);
        expect(await error, isEmpty);
        expect(jsonDecode(await output), {'items': []});
      } finally {
        if (!exited) {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(const Duration(seconds: 5));
        }
        await output;
        await error;
      }
    });
  });
}

Future<void> _withReply(
  Map<String, Object?> body,
  Future<void> Function(String socket) action, {
  Future<void> Function(PublicApiRequest)? beforeReply,
  int status = HttpStatus.ok,
}) async {
  final directory =
      await (Platform.isMacOS
              ? Directory('/private/tmp')
              : Directory.systemTemp)
          .createTemp('gvm-log-reply-');
  imageFileMode(directory.path, 0x1c0);
  final router = PublicApiRouter()
    ..add('GET', '/v1/vms/{vm_id}/logs', (request) async {
      await beforeReply?.call(request);
      return PublicApiResponse.json(status: status, body: body);
    });
  final server = PublicApiServer(
    socketPath: '${directory.path}/api.sock',
    openApiDocument: const {},
    systemHealth: _Health(),
    router: router,
  );
  try {
    await server.start();
    await action(server.socketPath);
  } finally {
    await server.close();
    await directory.delete(recursive: true);
  }
}

Future<({int code, String output, String error})> _invoke(
  String socket,
  List<String> arguments,
) async {
  final output = StringBuffer(), error = StringBuffer();
  final code = await runCli(
    ['--socket-path', socket, ...arguments],
    output: output.writeln,
    error: error.writeln,
  );
  return (code: code, output: output.toString(), error: error.toString());
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
