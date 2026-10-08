import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_cli/gaovm_cli.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:test/test.dart';

void main() {
  test('malformed event data and EOF have stable JSON failure exits', () async {
    for (final (payload, expectedCode, kind) in [
      ('id: 1\ndata: {"invalid":true}\n\n', 4, 'CLI_PROTOCOL'),
      (': connected\n\n', 3, 'CLI_TRANSPORT'),
    ]) {
      final router = PublicApiRouter()
        ..add(
          'GET',
          '/v1/events',
          (_) async => PublicApiResponse.stream(
            body: Stream.value(utf8.encode(payload)),
            contentType: ContentType('text', 'event-stream'),
          ),
        );
      await _withServer(router, (server) async {
        final output = StringBuffer(), error = StringBuffer();
        final code = await runCli(
          [
            '--socket-path',
            server.socketPath,
            'events',
            '--timeout-seconds',
            '2',
            '--json',
          ],
          output: output.writeln,
          error: error.writeln,
        );
        expect(code, expectedCode, reason: error.toString());
        expect(output.toString(), isEmpty);
        expect(jsonDecode(error.toString())['code'], kind);
      });
    }
  });

  test(
    'invalid event cursors and filters are JSON usage errors before connecting',
    () async {
      var calls = 0;
      final router = PublicApiRouter()
        ..add('GET', '/v1/events', (_) async {
          calls++;
          return PublicApiResponse.json(status: 200, body: const {});
        });
      await _withServer(router, (server) async {
        for (final args in [
          for (final value in ['', '-1', '+1', '1.5', 'invalid', '9' * 100])
            ['events', '--after-sequence', value],
          ['events', '--after-sequence', '1', '--after-sequence', '2'],
          ['events', '--vm-id', 'default'],
          ['events', '--operation-id', VmId.generate().value],
          ['events', '--test-run-id', OperationId.generate().value],
          [
            'events',
            '--vm-id',
            VmId.generate().value,
            '--vm-id',
            VmId.generate().value,
          ],
          ['events', '--limit', '1'],
          ['events', '--idempotency-key', 'not-a-mutation'],
          ['events', '--body-json', '{}'],
          ['events', 'extra'],
          ['vm', 'list', '--after-sequence', '1'],
          ['operation', 'list', '--operation-id', OperationId.generate().value],
        ]) {
          final output = StringBuffer(), error = StringBuffer();
          final code = await runCli(
            ['--socket-path', server.socketPath, ...args, '--json'],
            output: output.writeln,
            error: error.writeln,
          );
          expect(code, 2, reason: '${args.join(' ')}: $error');
          expect(output.toString(), isEmpty);
          expect(jsonDecode(error.toString())['code'], 'CLI_USAGE');
        }
        expect(calls, 0);
      });
    },
  );
  test(
    'events follows committed Operation events and resumes without replaying them',
    () async {
      await _withCatalog((database, server, databasePath) async {
        final vm = (await SqliteVmRepository(
          database,
        ).create(name: 'live', spec: _spec())).metadata.id;
        final operations = SqliteOperationRepository(database);
        Future<Operation> operation() => operations.create(
          type: 'vm.start',
          resourceType: ResourceType.virtualMachine,
          resourceId: vm,
          requestId: RequestId.generate(),
          cancellable: false,
          request: JsonObjectValue.empty,
        );
        final selected = await operation(), excluded = await operation();
        Future<Event> append(
          SqliteEventRepository events,
          OperationId id,
          String message,
        ) => events.append(
          type: 'vm.changed',
          resourceType: ResourceType.virtualMachine,
          resourceId: vm,
          vmId: vm,
          operationId: id,
          payload: JsonObjectValue.fromJson({'message': message}),
        );
        final events = SqliteEventRepository(database);
        final previous = await append(events, selected.id, 'previous');
        await append(events, excluded.id, 'excluded');
        final replay = await append(events, selected.id, 'replay');
        final replayed = Completer<void>(), liveReceived = Completer<void>();
        final received = <Event>[];
        final error = StringBuffer();
        final args = [
          '--socket-path',
          server.socketPath,
          'events',
          '--vm-id',
          vm.value,
          '--operation-id',
          selected.id.value,
        ];
        final running = runCli(
          [
            ...args,
            '--after-sequence',
            '${previous.sequence}',
            '--timeout-seconds',
            '5',
          ],
          output: (line) {
            received.add(Event.fromJson(jsonDecode(line)));
            if (received.length == 1) replayed.complete();
            if (received.length == 2) liveReceived.complete();
          },
          error: error.writeln,
        );
        GaoVmDatabase? writer;
        try {
          await replayed.future.timeout(const Duration(seconds: 3));
          writer = await GaoVmDatabase.open(databasePath);
          final live = await append(
            SqliteEventRepository(writer),
            selected.id,
            'live',
          );
          await liveReceived.future.timeout(const Duration(seconds: 2));
          expect(await running, 124, reason: error.toString());
          expect(received, [replay, live]);
          expect(jsonDecode(error.toString())['code'], 'CLI_TIMEOUT');

          final next = await append(events, selected.id, 'after reconnect');
          final output = StringBuffer(), reconnectError = StringBuffer();
          final code = await runCli(
            [
              ...args,
              '--after-sequence',
              '${live.sequence}',
              '--timeout-seconds',
              '2',
              '--json',
            ],
            output: output.writeln,
            error: reconnectError.writeln,
          );
          expect(code, 124, reason: reconnectError.toString());
          expect(
            const LineSplitter()
                .convert(output.toString())
                .map((line) => Event.fromJson(jsonDecode(line))),
            [next],
          );
        } finally {
          writer?.close();
        }
      });
    },
  );

  test(
    'the CLI handles SIGINT and SIGTERM and releases an idle SQLite feed',
    () async {
      var cancelled = Completer<void>();
      await _withCatalog((database, server, _) async {
        final event = await SqliteEventRepository(database).append(
          type: 'system.changed',
          resourceType: ResourceType.system,
          payload: JsonObjectValue.empty,
        );
        for (final (signal, expectedCode) in [
          (ProcessSignal.sigint, 130),
          (ProcessSignal.sigterm, 143),
        ]) {
          cancelled = Completer<void>();
          final process = await Process.start(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/bin/gaovm_cli.dart',
            '--socket-path',
            server.socketPath,
            'events',
            '--timeout-seconds',
            '30',
            '--json',
          ]);
          final exited = process.exitCode;
          var exitConfirmed = false;
          final ready = Completer<void>();
          final received = <Event>[];
          final errors = utf8.decoder.bind(process.stderr).join();
          final output = utf8.decoder
              .bind(process.stdout)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  try {
                    received.add(Event.fromJson(jsonDecode(line)));
                    if (!ready.isCompleted) ready.complete();
                  } catch (error, stack) {
                    if (!ready.isCompleted) ready.completeError(error, stack);
                  }
                },
                onError: (Object error, StackTrace stack) {
                  if (!ready.isCompleted) ready.completeError(error, stack);
                },
                onDone: () {
                  if (!ready.isCompleted)
                    ready.completeError(
                      StateError('CLI exited without an event'),
                    );
                },
              );
          try {
            await ready.future.timeout(const Duration(seconds: 15));
            expect(process.kill(signal), isTrue);
            final code = await exited.timeout(const Duration(seconds: 5));
            exitConfirmed = true;
            final diagnostic = await errors;
            expect(code, expectedCode, reason: diagnostic);
            expect(received, [event]);
            expect(jsonDecode(diagnostic)['code'], 'CLI_INTERRUPTED');
            expect(jsonDecode(diagnostic)['detail'], contains('$signal'));
            await cancelled.future.timeout(const Duration(seconds: 2));
          } finally {
            if (!exitConfirmed) {
              process.kill(ProcessSignal.sigkill);
              await exited.timeout(const Duration(seconds: 5));
            }
            await output.cancel();
            await errors;
          }
        }
      }, onCancel: () => cancelled.complete());
    },
  );

  test(
    'event filters use the public query and preserve an API Problem',
    () async {
      final vm = VmId.generate(),
          operation = OperationId.generate(),
          run = TestRunId.generate();
      Uri? uri;
      List<String>? accept;
      final router = PublicApiRouter()
        ..add('GET', '/v1/events', (request) async {
          uri = request.uri;
          accept = request.headers['accept'];
          return PublicApiResponse.problem(
            status: 400,
            code: ErrorCode.invalidRequest,
            type: 'invalid-request',
            title: 'Invalid request',
            detail: 'Rejected event query.',
            retryable: false,
            details: JsonObjectValue.fromJson({'field': 'fixture'}),
          );
        });
      await _withServer(router, (server) async {
        final output = StringBuffer(), error = StringBuffer();
        final code = await runCli(
          [
            '--socket-path',
            server.socketPath,
            'events',
            '--after-sequence',
            '4',
            '--vm-id',
            vm.value,
            '--operation-id',
            operation.value,
            '--test-run-id',
            run.value,
            '--timeout-seconds',
            '2',
            '--json',
          ],
          output: output.writeln,
          error: error.writeln,
        );
        expect(code, 1, reason: error.toString());
        expect(output.toString(), isEmpty);
        final problem = Problem.fromJson(jsonDecode(error.toString()));
        expect(problem.code, ErrorCode.invalidRequest);
        expect(problem.status, 400);
        expect(problem.requestId.value, startsWith('req_'));
        expect(problem.detail, 'Rejected event query.');
        expect(problem.details.toJson(), {'field': 'fixture'});
        expect(uri!.path, '/v1/events');
        expect(uri!.queryParameters, {
          'after_sequence': '4',
          'vm_id': vm.value,
          'operation_id': operation.value,
          'test_run_id': run.value,
        });
        expect(accept, ['text/event-stream']);
      });
    },
  );

  test('events resumes a SQLite VM stream as newline-delimited JSON', () async {
    await _withCatalog((database, server, _) async {
      final vms = SqliteVmRepository(database);
      final events = SqliteEventRepository(database);
      final vm = (await vms.create(
        name: 'selected',
        spec: _spec(),
      )).metadata.id;
      final otherVm = (await vms.create(
        name: 'other',
        spec: _spec(),
      )).metadata.id;
      Future<Event> append(VmId target) => events.append(
        type: 'vm.changed',
        resourceType: ResourceType.virtualMachine,
        resourceId: target,
        vmId: target,
        payload: JsonObjectValue.fromJson({'message': '日本語\nnext line'}),
      );
      final previous = await append(vm);
      await append(otherVm);
      final next = await append(vm);
      final output = StringBuffer(), error = StringBuffer();
      final code = await runCli(
        [
          '--socket-path',
          server.socketPath,
          'events',
          '--after-sequence',
          '${previous.sequence}',
          '--vm-id',
          vm.value,
          '--timeout-seconds',
          '2',
          '--json',
        ],
        output: output.writeln,
        error: error.writeln,
      );
      expect(code, 124, reason: error.toString());
      final received = const LineSplitter()
          .convert(output.toString())
          .map((line) => Event.fromJson(jsonDecode(line)))
          .toList();
      expect(received, [next]);
      expect(jsonDecode(error.toString())['code'], 'CLI_TIMEOUT');
    });
  });
}

Future<void> _withCatalog(
  Future<void> Function(GaoVmDatabase, PublicApiServer, String) check, {
  void Function()? onCancel,
}) async {
  final directory = await Directory.systemTemp.createTemp('gaovm-cli-events-');
  final databasePath = '${directory.path}/catalog.db';
  final database = await GaoVmDatabase.open(databasePath);
  final router = PublicApiRouter();
  final feed = SqliteDurableEventFeed(database);
  EventApiHandlers(
    feed: onCancel == null ? feed : _ObservedFeed(feed, onCancel),
  ).register(router);
  try {
    await _withServer(
      router,
      (server) => check(database, server, databasePath),
    );
  } finally {
    database.close();
    await directory.delete(recursive: true);
  }
}

// Observe subscription teardown while retaining the real SQLite feed behavior.
final class _ObservedFeed implements DurableEventFeed {
  _ObservedFeed(this.delegate, this.onCancel);
  final DurableEventFeed delegate;
  final void Function() onCancel;
  @override
  Future<int> latestSequence() => delegate.latestSequence();
  @override
  Stream<Event> watch({
    int after = 0,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
  }) async* {
    try {
      yield* delegate.watch(
        after: after,
        vmId: vmId,
        operationId: operationId,
        testRunId: testRunId,
      );
    } finally {
      onCancel();
    }
  }
}

Future<void> _withServer(
  PublicApiRouter router,
  Future<void> Function(PublicApiServer) check,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'gaovm-cli-events-wire-',
  );
  final server = PublicApiServer(
    socketPath: '${directory.path}/api.sock',
    openApiDocument: const {},
    systemHealth: _Health(),
    router: router,
  );
  try {
    await server.start();
    await check(server);
  } finally {
    await server.close();
    await directory.delete(recursive: true);
  }
}

VmSpec _spec() => VmSpec(
  cpu: 2,
  memoryBytes: 268435456,
  boot: LinuxKernelBoot(kernelImageId: ImageId.generate()),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/fixture/disk.raw'),
      writable: true,
    ),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
