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
  _usageAndTransportTests();
  group('real artifact service', () {
    late Directory temporary;
    late GaoVmDatabase database;
    late OwnedImageDirectory root;
    late ArtifactApplicationService artifacts;
    late PublicApiServer server;

    setUp(() async {
      temporary =
          await (Platform.isMacOS
                  ? Directory('/private/tmp')
                  : Directory.systemTemp)
              .createTemp('gvm-vmart-cli-');
      imageFileMode(temporary.path, 0x1c0);
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      final directory = await Directory('${temporary.path}/artifacts').create();
      imageFileMode(directory.path, 0x1c0);
      root = await OwnedImageDirectory.open(directory);
      artifacts = ArtifactApplicationService(
        database: database,
        directory: root,
        now: () => DateTime.utc(2026, 10, 10),
      );
      final router = PublicApiRouter();
      ArtifactApiHandlers(artifacts: artifacts).register(router);
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
      root.close();
      database.close();
      await temporary.delete(recursive: true);
    });

    Future<VmId> createVm(String name) async =>
        (await SqliteVmRepository(database).create(
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
            serial: const SerialConfig(enabled: false, capture: false),
            guestAgent: GuestAgentConfig(
              enabled: false,
              requiredForReady: false,
            ),
            restartPolicy: RestartPolicy.never,
          ),
        )).metadata.id;

    Future<Artifact> publish(VmId owner, String content) => artifacts.publish(
      bytes: Stream.value(utf8.encode(content)),
      kind: ArtifactKind.serial,
      contentType: 'text/plain',
      maxBytes: 1024,
      vmId: owner,
    );

    test(
      'vm artifacts pages real committed metadata for only the explicit VM',
      () async {
        final vm = await createVm('first');
        final other = await createVm('other');
        final expected = [
          await publish(vm, 'first'),
          await publish(vm, 'second'),
        ]..sort((a, b) => a.id.value.compareTo(b.id.value));
        await publish(other, 'excluded');
        final args = ['vm', 'artifacts', vm.value, '--limit', '1', '--json'];
        final first = await _invoke(server.socketPath, args);
        expect(first.code, 0, reason: first.error);
        expect(first.error, isEmpty);
        final page = jsonDecode(first.output);
        expect(page['items'], [expected.first.toJson()]);
        expect(page['next_cursor'], isA<String>());
        final next = await _invoke(server.socketPath, [
          ...args,
          '--cursor',
          page['next_cursor'] as String,
        ]);
        expect(next.code, 0, reason: next.error);
        expect(jsonDecode(next.output), {
          'items': [expected.last.toJson()],
          'next_cursor': null,
        });
        expect(first.output, isNot(contains(temporary.path)));
        expect(next.output, isNot(contains(other.value)));
      },
    );
    test(
      'vm download streams only the selected VM-owned artifact into private output',
      () async {
        final vm = await createVm('download');
        final other = await createVm('other');
        final selected = await publish(vm, 'VM diagnostic bytes\n');
        await publish(other, 'excluded');
        final output = await Directory('${temporary.path}/output').create();
        final existing = await File(
          '${output.path}/${selected.id.value}',
        ).writeAsString('preserve');
        final result = await _invoke(server.socketPath, [
          'vm',
          'download',
          vm.value,
          selected.id.value,
          '--output-dir',
          output.path,
          '--timeout-seconds',
          '5',
          '--json',
        ]);
        expect(result.code, 0, reason: result.error);
        expect(result.error, isEmpty);
        final receipt = jsonDecode(result.output);
        expect(receipt['verified'], isTrue);
        expect(receipt['artifact'], selected.toJson());
        expect(
          () => RequestId(receipt['request_id'] as String),
          returnsNormally,
        );
        final downloaded = File(receipt['output_path'] as String);
        expect(await downloaded.readAsString(), 'VM diagnostic bytes\n');
        expect(
          downloaded.parent.parent.path,
          await output.resolveSymbolicLinks(),
        );
        expect(downloaded.uri.pathSegments.last, selected.id.value);
        expect(await existing.readAsString(), 'preserve');
      },
    );
    test(
      'vm artifacts and download preserve retained diagnostics after tombstoning',
      () async {
        final vm = await createVm('retained');
        final selected = await publish(vm, 'retained diagnostic');
        final vms = SqliteVmRepository(database);
        final current = (await vms.get(vm))!;
        final deleting = await vms.markDeleting(
          vm,
          expectedRevision: current.metadata.revision,
        );
        await vms.tombstone(vm, expectedRevision: deleting.metadata.revision);
        expect(await vms.get(vm), isNull);
        final page = await _invoke(server.socketPath, [
          'vm',
          'artifacts',
          vm.value,
          '--json',
        ]);
        expect(page.code, 0, reason: page.error);
        expect(jsonDecode(page.output), {
          'items': [selected.toJson()],
          'next_cursor': null,
        });
        final output = await Directory('${temporary.path}/output').create();
        final downloaded = await _invoke(server.socketPath, [
          'vm',
          'download',
          vm.value,
          selected.id.value,
          '--output-dir',
          output.path,
          '--json',
        ]);
        expect(downloaded.code, 0, reason: downloaded.error);
        expect(
          await File(
            jsonDecode(downloaded.output)['output_path'] as String,
          ).readAsString(),
          'retained diagnostic',
        );
      },
    );
    test(
      'vm artifact reads preserve empty results, not-found and cursor Problems',
      () async {
        final vm = await createVm('empty');
        final other = await createVm('other');
        final empty = await _invoke(server.socketPath, [
          'vm',
          'artifacts',
          vm.value,
        ]);
        expect(empty.code, 0, reason: empty.error);
        expect(jsonDecode(empty.output), {'items': [], 'next_cursor': null});
        final missing = await _invoke(server.socketPath, [
          'vm',
          'artifacts',
          VmId.generate().value,
          '--json',
        ]);
        expect(missing.code, 1);
        expect(missing.output, isEmpty);
        final problem = Problem.fromJson(jsonDecode(missing.error));
        expect(problem.status, HttpStatus.notFound);
        expect(problem.code, ErrorCode.vmNotFound);
        await publish(vm, 'first');
        await publish(vm, 'second');
        final page = await _invoke(server.socketPath, [
          'vm',
          'artifacts',
          vm.value,
          '--limit',
          '1',
          '--json',
        ]);
        final cursor = jsonDecode(page.output)['next_cursor'] as String;
        final foreign = await _invoke(server.socketPath, [
          'vm',
          'artifacts',
          other.value,
          '--cursor',
          cursor,
          '--json',
        ]);
        expect(foreign.code, 1);
        expect(foreign.output, isEmpty);
        expect(
          Problem.fromJson(jsonDecode(foreign.error)).code,
          ErrorCode.invalidRequest,
        );
      },
    );
    test(
      'vm download rejects a foreign or missing ID without creating local files',
      () async {
        final vm = await createVm('requested');
        final other = await createVm('other');
        final foreign = await publish(other, 'foreign bytes');
        final output = await Directory('${temporary.path}/output').create();
        for (final id in [foreign.id, ArtifactId.generate()]) {
          final result = await _invoke(server.socketPath, [
            'vm',
            'download',
            vm.value,
            id.value,
            '--output-dir',
            output.path,
            '--json',
          ]);
          expect(result.code, 1);
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'ARTIFACT_NOT_FOUND');
          expect(await output.list().toList(), isEmpty);
        }
        final stored = await artifacts.download(foreign.id);
        expect(
          utf8.decode(await stored.bytes.expand((chunk) => chunk).toList()),
          'foreign bytes',
        );
      },
    );
    test(
      'vm artifact reads include artifacts associated with that VM and a TestRun',
      () async {
        final vm = await createVm('test-owned');
        final runs = SqliteTestRunRepository(database);
        final run = await runs.create(
          requestId: RequestId.generate(),
          spec: TestRunSpec(
            source: ImageTestRunSource(ImageId.generate()),
            wait: VmWaitSpec(
              condition: WaitCondition.guestAgentReady,
              timeoutSeconds: 30,
            ),
            steps: [
              TestStepRequest(argv: ['true'], timeoutSeconds: 30),
            ],
            cleanup: CleanupPolicy.retain,
            retainOnFailure: true,
          ),
        );
        await runs.transition(
          run.id,
          expectedState: TestRunState.pending,
          nextState: TestRunState.provisioning,
        );
        await runs.transition(
          run.id,
          expectedState: TestRunState.provisioning,
          nextState: TestRunState.startingVm,
          vmId: vm,
        );
        final artifact = await artifacts.publish(
          bytes: Stream.value(utf8.encode('test output')),
          kind: ArtifactKind.stdout,
          contentType: 'text/plain',
          maxBytes: 1024,
          vmId: vm,
          testRunId: run.id,
          operationId: run.operationId,
        );
        for (final command in [
          ['vm', 'artifacts', vm.value, '--json'],
          ['test', 'artifacts', run.id.value, '--json'],
        ]) {
          final page = await _invoke(server.socketPath, command);
          expect(page.code, 0, reason: page.error);
          expect(jsonDecode(page.output), {
            'items': [artifact.toJson()],
            'next_cursor': null,
          });
        }
        final output = await Directory('${temporary.path}/output').create();
        final downloaded = await _invoke(server.socketPath, [
          'vm',
          'download',
          vm.value,
          artifact.id.value,
          '--output-dir',
          output.path,
          '--json',
        ]);
        expect(downloaded.code, 0, reason: downloaded.error);
        expect(
          jsonDecode(downloaded.output)['artifact']['test_run_id'],
          run.id.value,
        );
      },
    );
  });
}

void _wireTests() {
  test('vm artifacts sends only the read-only public page query', () async {
    final vm = VmId.generate();
    final artifact = _metadata(vm);
    final page = {
      'items': [artifact.toJson()],
      'next_cursor': 'next opaque',
    };
    await _withReply(
      page,
      (socket) async {
        for (final compact in [true, false]) {
          final result = await _invoke(socket, [
            'vm',
            'artifacts',
            vm.value,
            '--limit',
            '1',
            '--cursor',
            'opaque & cursor',
            if (compact) '--json',
          ]);
          expect(result.code, 0, reason: result.error);
          expect(result.error, isEmpty);
          expect(jsonDecode(result.output), page);
          if (compact) expect(result.output.trim().split('\n'), hasLength(1));
        }
      },
      beforeReply: (request) async {
        expect(request.method, 'GET');
        expect(request.pathParameters['vm_id'], vm.value);
        expect(request.uri.queryParameters, {
          'limit': '1',
          'cursor': 'opaque & cursor',
        });
        expect(request.bodyBytes, isEmpty);
        expect(request.jsonBody, isNull);
        expect(request.headers['idempotency-key'], isNull);
        expect(request.headers['if-match'], isNull);
      },
    );
  });
  test(
    'artifact listings enforce successful status and the requested page bound',
    () async {
      final vm = VmId.generate();
      for (final (status, items) in [
        (HttpStatus.created, <Map<String, Object?>>[]),
        (HttpStatus.accepted, <Map<String, Object?>>[]),
        (HttpStatus.ok, [_metadata(vm).toJson(), _metadata(vm).toJson()]),
      ]) {
        await _withReply({'items': items, 'next_cursor': null}, (socket) async {
          final result = await _invoke(socket, [
            'vm',
            'artifacts',
            vm.value,
            '--limit',
            '1',
            '--json',
          ]);
          expect(result.code, 4);
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
        }, status: status);
      }
    },
  );
  test(
    'TestRun listings use the same strict owner and DTO validation',
    () async {
      final vm = VmId.generate();
      final run = TestRunId.generate();
      for (final owner in [run, TestRunId.generate(), null]) {
        final record = {..._metadata(vm).toJson(), 'test_run_id': owner?.value};
        await _withReply(
          {
            'items': [record],
            'next_cursor': null,
          },
          (socket) async {
            final result = await _invoke(socket, [
              'test',
              'artifacts',
              run.value,
              '--json',
            ]);
            expect(result.code, owner == run ? 0 : 4);
            if (owner == run) {
              expect(jsonDecode(result.output)['items'], [record]);
            } else {
              expect(result.output, isEmpty);
              expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
            }
          },
        );
      }
    },
  );
  test(
    'artifact listings reject malformed, foreign or URL-mismatched records',
    () async {
      final vm = VmId.generate();
      final valid = _metadata(vm).toJson();
      for (final body in <Map<String, Object?>>[
        {},
        {'items': []},
        {'items': {}, 'next_cursor': null},
        {'items': [], 'next_cursor': ''},
        {'items': [], 'next_cursor': 1},
        {'items': [], 'next_cursor': null, 'path': '/private/artifact'},
        {
          'items': [null],
          'next_cursor': null,
        },
        {
          'items': [valid, valid],
          'next_cursor': null,
        },
        for (final item in [
          {...valid}..remove('retention_until'),
          {...valid, 'vm_id': VmId.generate().value},
          {...valid, 'vm_id': null},
          {...valid, 'size_bytes': -1},
          {...valid, 'digest': 'not-a-digest'},
          {
            ...valid,
            'download_url': '/v1/artifacts/${ArtifactId.generate().value}',
          },
        ])
          {
            'items': [item],
            'next_cursor': null,
          },
      ]) {
        await _withReply(body, (socket) async {
          final result = await _invoke(socket, [
            'vm',
            'artifacts',
            vm.value,
            '--json',
          ]);
          expect(result.code, 4, reason: '$body');
          expect(result.output, isEmpty);
          expect(jsonDecode(result.error)['code'], 'CLI_PROTOCOL');
        });
      }
    },
  );
}

Artifact _metadata(VmId owner, {ArtifactId? id}) {
  final artifactId = id ?? ArtifactId.generate();
  return Artifact(
    id: artifactId,
    vmId: owner,
    kind: ArtifactKind.serial,
    contentType: 'text/plain',
    sizeBytes: 0,
    digest:
        'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    downloadUrl: '/v1/artifacts/${artifactId.value}',
    createdAt: DateTime.utc(2026, 10, 10),
  );
}

void _usageAndTransportTests() {
  test(
    'vm artifact listing bounds stalled HTTP with the explicit deadline',
    () async {
      final release = Completer<void>();
      await _withReply({'items': [], 'next_cursor': null}, (socket) async {
        try {
          final result = await _invoke(socket, [
            'vm',
            'artifacts',
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
    },
  );
  test(
    'vm artifact listing preserves transport failure without fallback',
    () async {
      await _withReply({'items': [], 'next_cursor': null}, (socket) async {
        final result = await _invoke('$socket.missing', [
          'vm',
          'artifacts',
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
    'VM artifact commands reject inapplicable options and invalid IDs before I/O',
    () async {
      var requests = 0;
      await _withReply(
        {'items': [], 'next_cursor': null},
        (socket) async {
          final vm = VmId.generate().value;
          final artifact = ArtifactId.generate().value;
          for (final command in [
            ['vm', 'artifacts'],
            ['vm', 'artifacts', 'default'],
            ['vm', 'artifacts', TestRunId.generate().value],
            ['vm', 'artifacts', vm, '--limit', '0'],
            ['vm', 'artifacts', vm, '--limit', '201'],
            ['vm', 'artifacts', vm, '--cursor', ''],
            ['vm', 'artifacts', vm, '--output-dir', File(socket).parent.path],
            ['vm', 'artifacts', vm, '--kind', 'serial'],
            ['vm', 'artifacts', vm, '--sort', 'name'],
            ['vm', 'artifacts', vm, '--body-json', '{}'],
            ['vm', 'artifacts', vm, '--idempotency-key', 'not-a-mutation'],
            ['vm', 'artifacts', vm, '--condition', 'runtime_running'],
            ['vm', 'artifacts', vm, '--label-selector', 'team=qa'],
            ['vm', 'download', vm, artifact],
            [
              'vm',
              'download',
              'default',
              artifact,
              '--output-dir',
              File(socket).parent.path,
            ],
            [
              'vm',
              'download',
              vm,
              OperationId.generate().value,
              '--output-dir',
              File(socket).parent.path,
            ],
            for (final option in [
              ['--limit', '1'],
              ['--cursor', 'opaque'],
              ['--kind', 'serial'],
              ['--body-json', '{}'],
              ['--idempotency-key', 'not-a-mutation'],
              ['--if-match', '1'],
              ['--condition', 'runtime_running'],
              ['--timeout-seconds', '0'],
            ])
              [
                'vm',
                'download',
                vm,
                artifact,
                '--output-dir',
                File(socket).parent.path,
                ...option,
              ],
          ]) {
            final result = await _invoke(socket, [...command, '--json']);
            expect(result.code, 2, reason: command.join(' '));
            expect(result.output, isEmpty);
            expect(jsonDecode(result.error)['code'], 'CLI_USAGE');
          }
          final missingOutput = await _invoke(socket, [
            'vm',
            'download',
            vm,
            artifact,
            '--output-dir',
            '$socket.missing-directory',
            '--json',
          ]);
          expect(missingOutput.code, 1);
          expect(missingOutput.output, isEmpty);
          expect(jsonDecode(missingOutput.error)['code'], 'CLI_LOCAL_IO');
          expect(requests, 0);
        },
        beforeReply: (_) async {
          requests++;
        },
      );
    },
  );
  test(
    'help includes explicit VM artifact IDs and local output requirements',
    () async {
      final result = await _invoke('/unavailable/gao-vm/api.sock', [
        '--help',
        '--json',
      ]);
      expect(result.code, 0, reason: result.error);
      final commands = jsonDecode(result.output)['commands'];
      expect(commands, contains('vm artifacts VM_ID'));
      expect(
        commands,
        contains('vm download VM_ID ART_ID --output-dir DIRECTORY'),
      );
    },
  );
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
          .createTemp('gvm-vmart-reply-');
  imageFileMode(directory.path, 0x1c0);
  final router = PublicApiRouter();
  Future<PublicApiResponse> reply(PublicApiRequest request) async {
    await beforeReply?.call(request);
    return PublicApiResponse.json(status: status, body: body);
  }

  router
    ..add('GET', '/v1/vms/{vm_id}/artifacts', reply)
    ..add('GET', '/v1/test-runs/{test_run_id}/artifacts', reply);
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
