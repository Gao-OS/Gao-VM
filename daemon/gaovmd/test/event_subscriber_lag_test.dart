import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_api_client/gaovm_api_client.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

// Real SQLite, controllers, admission, dispatch, and public UDS transport.
// Only host metrics and the runtime boundary are fixtures; no native VM boots.
void main() {
  test(
    'concurrent public VM lifecycles finish without an SSE subscriber',
    () async {
      final fixture = await _Fixture.open();
      try {
        await fixture
            .actAll('start', 'baseline-start')
            .timeout(const Duration(seconds: 2));
        await fixture
            .actAll('stop', 'baseline-stop')
            .timeout(const Duration(seconds: 2));
      } finally {
        await fixture.close();
      }
      expect(fixture.errors, isEmpty);
    },
    skip: Platform.isWindows ? 'HTTP-over-UDS fixture requires POSIX' : false,
  );

  test(
    'a stalled SQLite SSE subscriber cannot hold up concurrent VM lifecycles',
    () async {
      final fixture = await _Fixture.open();
      try {
        final laggingVm = fixture.vmIds.first;
        final cursor = await fixture.feed.latestSequence();
        await fixture.pauseEvents(laggingVm, cursor);
        await fixture.flood(laggingVm);

        // The subscriber never consumes its backlog. Both controllers must
        // finish before the independent five-second stream-write deadline.
        await fixture
            .actAll('start', 'concurrent-start')
            .timeout(const Duration(seconds: 2));
        for (final id in fixture.vmIds) {
          final vm = await fixture.request('GET', '/v1/vms/$id');
          expect(vm.json['status']['phase'], 'running');
          expect(vm.json['status']['desired_state'], 'running');
        }
        await fixture
            .actAll('stop', 'concurrent-stop')
            .timeout(const Duration(seconds: 2));
        for (final id in fixture.vmIds) {
          final vm = await fixture.request('GET', '/v1/vms/$id');
          expect(vm.json['status']['phase'], 'stopped');
          expect(vm.json['status']['desired_state'], 'stopped');
        }
      } finally {
        await fixture.close();
      }
      expect(fixture.errors, isEmpty);
    },
    skip: Platform.isWindows ? 'HTTP-over-UDS fixture requires POSIX' : false,
  );

  test(
    'a write-expired SQLite SSE cursor replays every remaining event while another subscriber progresses',
    () async {
      final fixture = await _Fixture.open(
        streamWriteDeadline: const Duration(seconds: 1),
      );
      try {
        final vm = fixture.vmIds.first;
        final otherVm = fixture.vmIds.last;
        final before = await fixture.feed.latestSequence();
        final anchor = await fixture.marker(vm);
        final lagging = await fixture.pauseEvents(
          vm,
          before,
          readThrough: anchor.sequence,
        );
        final backlog = await fixture.flood(vm);

        final fast = fixture
            .events(otherVm, before)
            .first
            .timeout(const Duration(seconds: 2));
        final marker = await fixture.marker(otherVm);
        expect(_digest(await fast), _digest(marker));

        // Elapsed time alone is not closure evidence: draining must observe
        // actual EOF and an incomplete prefix, without destroying the client
        // or closing the server to manufacture that result.
        await Future<void>.delayed(const Duration(seconds: 2));
        final delivered = await lagging.drainAfterRemoteClose().timeout(
          const Duration(seconds: 3),
        );
        expect(delivered.first.eventId, anchor.eventId);
        expect(delivered.length, lessThan(backlog.length + 1));
        final prefix = [anchor, ...backlog.take(delivered.length - 1)];
        expect(delivered.map(_digest), prefix.map(_digest));
        final last = delivered.last.sequence;
        final remaining = backlog
            .where((event) => event.sequence > last)
            .toList();
        expect(remaining, isNotEmpty);

        // Header precedence must use the last complete event, never a partial
        // SSE frame's ID, despite the deliberately older query cursor.
        final replayed = await fixture
            .events(vm, before, lastEventId: last)
            .take(remaining.length)
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(replayed.map(_digest), remaining.map(_digest));
        expect(
          [...delivered.skip(1), ...replayed].map((event) => event.sequence),
          backlog.map((event) => event.sequence),
        );
        expect(replayed.every((event) => event.vmId == vm), isTrue);
        final health = await fixture.request('GET', '/v1/system/live');
        expect(health.status, HttpStatus.ok);
        expect(health.json['live'], isTrue);
      } finally {
        await fixture.close();
      }
      expect(fixture.errors, isEmpty);
    },
    skip: Platform.isWindows ? 'HTTP-over-UDS fixture requires POSIX' : false,
  );
}

final class _Fixture {
  _Fixture(this.directory, this.streamWriteDeadline);

  final Directory directory;
  final Duration streamWriteDeadline;
  final errors = <Object>[];
  final vmIds = <VmId>[];
  final _paused = <_PausedEvents>[];
  GaoVmDatabase? _database;
  HostScheduler? _host;
  RuntimeDriverEffectAdapter? _drivers;
  VmRegistry? _registry;
  VmCommandDispatchLoop? _commands;
  Timer? _runtimeClock;
  PublicApiServer? _server;
  HttpClient? _client;
  late SqliteDurableEventFeed feed;
  bool _closed = false;

  static Future<_Fixture> open({
    Duration streamWriteDeadline = const Duration(seconds: 5),
  }) async {
    final directory =
        await (Platform.isMacOS
                ? Directory('/private/tmp')
                : Directory.systemTemp)
            .createTemp('gv-sse-lag-');
    final fixture = _Fixture(directory, streamWriteDeadline);
    try {
      imageFileMode(directory.path, 0x1c0);
      await fixture._open();
      return fixture;
    } catch (_) {
      await fixture.close();
      rethrow;
    }
  }

  String get socketPath => '${directory.path}/api.sock';
  GaoVmDatabase get database => _database!;

  Future<void> _open() async {
    _database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    final catalog = SqliteVmRepository(database);
    final operations = SqliteOperationRepository(database);
    final persistence = SqliteVmStateEffectAdapter(database);
    for (var index = 0; index < 2; index++) {
      final disk = File('${directory.path}/disk-$index.raw');
      await disk.writeAsBytes(List<int>.filled(4096, 0));
      final vm = await catalog.create(
        name: 'lag-test-$index',
        spec: _spec(disk.path),
      );
      vmIds.add(vm.metadata.id);
      final stopped = VmControllerState.initial(
        vmId: vm.metadata.id,
        specGeneration: 1,
        restartPolicy: RestartPolicy.never,
      ).copyWith(phase: VmPhase.stopped);
      await persistence.persistVm(stopped);
      await persistence.persistRuntime(stopped);
    }
    feed = SqliteDurableEventFeed(
      database,
      pageSize: 2,
      pollInterval: const Duration(milliseconds: 5),
    );
    final runtimeClock = ManualRuntimeScheduler();
    _drivers = RuntimeDriverEffectAdapter(
      factory: FakeRuntimeDriverFactory(scheduler: runtimeClock),
      resolveConfiguration: (state) async {
        final vm = (await catalog.get(state.vmId))!;
        // These valid DTO paths are owned by this fixture. The fake runtime
        // does not interpret a disk or variable store as a bootable image.
        return RuntimeDriverConfiguration(
          architecture: vm.spec.architecture,
          cpu: vm.spec.cpu,
          memoryBytes: vm.spec.memoryBytes,
          boot: RuntimeEfiBootConfiguration(
            variableStorePath: '${directory.path}/${state.vmId}.nvram',
          ),
          disks: [
            RuntimeDiskConfiguration(
              id: 'root',
              path: (vm.spec.disks.single.source as ExternalDiskSource).path,
              writable: true,
            ),
          ],
          networks: [
            RuntimeNetworkConfiguration(
              id: 'net0',
              mode: RuntimeNetworkMode.none,
            ),
          ],
          graphics: RuntimeGraphicsConfiguration(enabled: false),
          serial: RuntimeSerialConfiguration(
            enabled: false,
            capture: false,
            logPath: '${directory.path}/${state.vmId}.serial.log',
          ),
          guestAgent: RuntimeGuestAgentConfiguration(
            enabled: false,
            vsockPort: 1024,
          ),
          bundlePath: '${directory.path}/${state.vmId}.gaovm',
          driverLogPath: '${directory.path}/${state.vmId}.driver.log',
        );
      },
      dispatch: (id, command) async {
        final controller = await _registry!.get(id);
        if (controller == null) throw StateError('fixture VM disappeared');
        await controller.submit(command);
      },
    );
    _host = HostScheduler(
      leases: SqliteHostLeaseRepository(database),
      catalog: SqliteHostCapacityCatalog(database, diskBytes: (_) => 0),
      metrics: const _Metrics(),
      limits: HostSchedulerLimits(
        maxRunningVms: 2,
        maxConcurrentBoots: 2,
        maxDriverProcesses: 2,
        maxCpuCount: 4,
        maxMemoryBytes: 2 * 1024 * 1024 * 1024,
        minFreeDiskBytes: 0,
      ),
      ownerId: RequestId.generate().value,
      onLeaseLost: (vm, spec, operation, generation, error) => _registry!
          .handleHostLeaseLost(vm, spec, operation, generation, error),
    );
    final runner = RepositoryVmEffectRunner(
      database: database,
      operations: operations,
      events: SqliteEventRepository(database),
      persistence: persistence,
      leases: _host!,
      drivers: _drivers!,
      managedFiles: const _NoDeletion(),
    );
    _registry = VmRegistry(
      repository: catalog,
      operations: operations,
      effectRunner: runner,
      recovery: SqliteVmIntentRecoveryRepository(database),
    );
    _commands = VmCommandDispatchLoop(
      dispatcher: VmCommandDispatcher(
        commands: SqliteVmCommandRepository(database),
        target: SqliteVmCommandTarget(
          database: database,
          registry: _registry!,
          effectRunner: runner,
        ),
        owner: RequestId.generate().value,
      ),
      interval: const Duration(milliseconds: 5),
      onDispatch: (outcomes) {
        for (final outcome in outcomes) {
          if (outcome.error case final error?) errors.add(error);
        }
      },
      onError: (error, _) => errors.add(error),
    );
    final router = PublicApiRouter();
    const retention = Duration(days: 1);
    ResourceApiHandlers(
      vms: VmApplicationService.composed(
        repository: catalog,
        creates: SqliteVmCreateAcceptance(
          database: database,
          idempotencyRetention: retention,
        ),
        patches: SqliteVmPatchAcceptor(
          database: database,
          registry: _registry!,
          idempotencyRetention: retention,
        ),
        lifecycle: SqliteVmLifecycleAcceptor(
          database: database,
          registry: _registry!,
          idempotencyRetention: retention,
        ),
        waiter: SqliteVmConditionWaiter(repository: catalog, events: feed),
        display: SqliteVmDisplayRepository(database),
      ),
      operations: OperationApplicationService(
        repository: operations,
        mutations: const _NoCancellation(),
        waiter: SqliteOperationWaiter(operations: operations, events: feed),
      ),
    ).register(router);
    EventApiHandlers(feed: feed).register(router);
    _server = PublicApiServer(
      socketPath: socketPath,
      openApiDocument: const {},
      systemHealth: const _Health(),
      router: router,
      streamWriteDeadline: streamWriteDeadline,
    );
    _client = HttpClient()
      ..connectionFactory = (_, _, _) => Socket.startConnect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
    // FakeRuntimeDriver schedules even zero-delay completion on its explicit
    // clock. Drive that boundary instead of lengthening public wait deadlines.
    _runtimeClock = Timer.periodic(const Duration(milliseconds: 5), (_) {
      runtimeClock.advanceBy(const Duration(milliseconds: 5));
    });
    _commands!.start();
    await _server!.start();
  }

  Future<_PausedEvents> pauseEvents(
    VmId vmId,
    int cursor, {
    int? readThrough,
  }) async {
    final stream = await _PausedEvents.open(
      socketPath,
      vmId,
      cursor,
      readThrough: readThrough,
    );
    _paused.add(stream);
    return stream;
  }

  Future<Event> marker(VmId vmId) => SqliteEventRepository(database).append(
    type: 'vm.marker',
    resourceType: ResourceType.virtualMachine,
    resourceId: vmId,
    vmId: vmId,
    payload: JsonObjectValue.empty,
  );

  Stream<Event> events(VmId vm, int after, {int? lastEventId}) =>
      GaoVmApiClient(socketPath: socketPath).watchEvents(
        afterSequence: after,
        lastEventId: lastEventId?.toString(),
        vmId: vm,
        timeout: const Duration(seconds: 5),
      );

  Future<List<Event>> flood(VmId vmId) async {
    final payload = JsonObjectValue.fromJson({'output': 'x' * (512 * 1024)});
    final repository = SqliteEventRepository(database);
    return database.transaction(
      (_) async => [
        for (var index = 0; index < 16; index++)
          await repository.append(
            type: 'vm.lag_fixture',
            resourceType: ResourceType.virtualMachine,
            resourceId: vmId,
            vmId: vmId,
            payload: payload,
          ),
      ],
    );
  }

  Future<void> actAll(String action, String key) => Future.wait([
    for (final id in vmIds)
      () async {
        final accepted = await request(
          'POST',
          '/v1/vms/$id/actions/$action',
          body: const {},
          key: key,
        );
        expect(accepted.status, HttpStatus.accepted);
        final operation = await request(
          'POST',
          '/v1/operations/${accepted.json['operation_id']}/wait',
          body: const {'timeout_seconds': 2},
        );
        expect(operation.status, HttpStatus.ok);
        expect(operation.json['state'], 'succeeded');
        expect(operation.json['resource_id'], id.value);
        expect(operation.json['type'], 'vm.$action');
      }(),
  ]).then((_) {});

  Future<({int status, Map<String, dynamic> json})> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? key,
  }) async {
    final outgoing = await _client!.openUrl(
      method,
      Uri.parse('http://localhost$path'),
    );
    if (key != null) outgoing.headers.set('Idempotency-Key', key);
    if (body != null) {
      outgoing.headers.contentType = ContentType.json;
      outgoing.add(utf8.encode(jsonEncode(body)));
    }
    final response = await outgoing.close();
    return (
      status: response.statusCode,
      json:
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _runtimeClock?.cancel();
    _client?.close(force: true);
    for (final connection in _paused) {
      await connection.close();
    }
    await _server?.close();
    final commands = _commands?.close();
    await _registry?.shutdown();
    await commands;
    await _drivers?.close();
    await _host?.shutdown();
    _database?.close();
    await directory.delete(recursive: true);
  }
}

final class _PausedEvents {
  _PausedEvents(this.socket, this.iterator, this.initialWire);
  final Socket socket;
  final StreamIterator<List<int>> iterator;
  final String initialWire;

  static Future<_PausedEvents> open(
    String socketPath,
    VmId vm,
    int cursor, {
    int? readThrough,
  }) async {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final iterator = StreamIterator<List<int>>(socket);
    try {
      socket.write(
        'GET /v1/events?vm_id=$vm&after_sequence=$cursor HTTP/1.1\r\n'
        'Host: localhost\r\nConnection: close\r\n\r\n',
      );
      await socket.flush();
      var received = '';
      while (!received.contains(': connected\n\n') ||
          (readThrough != null &&
              !_completeEvents(
                received,
              ).any((event) => event.sequence == readThrough))) {
        expect(
          await iterator.moveNext().timeout(const Duration(seconds: 2)),
          isTrue,
        );
        received += utf8.decode(iterator.current);
      }
      expect(received, startsWith('HTTP/1.1 200'));
      // StreamIterator pauses between moveNext calls, so no backlog is read.
      return _PausedEvents(socket, iterator, received);
    } catch (_) {
      socket.destroy();
      await iterator.cancel();
      rethrow;
    }
  }

  Future<List<Event>> drainAfterRemoteClose() async {
    final wire = StringBuffer(initialWire);
    while (await iterator.moveNext()) {
      wire.write(utf8.decode(iterator.current));
    }
    return _completeEvents(wire.toString());
  }

  Future<void> close() async {
    socket.destroy();
    await iterator.cancel();
  }
}

List<Event> _completeEvents(String wire) {
  final headerEnd = wire.indexOf('\r\n\r\n');
  if (headerEnd < 0) return const [];
  final blocks = wire.substring(headerEnd + 4).split('\n\n');
  final events = <Event>[];
  for (final block in blocks.take(blocks.length - 1)) {
    if (block.startsWith(':')) continue;
    final lines = block.split('\n');
    expect(lines, hasLength(2));
    expect(lines.first, startsWith('id: '));
    expect(lines.last, startsWith('data: '));
    final event = Event.fromJson(jsonDecode(lines.last.substring(6)));
    expect(int.parse(lines.first.substring(4)), event.sequence);
    events.add(event);
  }
  return events;
}

String _digest(Event event) =>
    sha256.convert(utf8.encode(jsonEncode(event.toJson()))).toString();

final class _Metrics implements HostMetricsSource {
  const _Metrics();
  @override
  Future<HostMetrics> sample() async => const HostMetrics(
    logicalCpuCount: 4,
    totalMemoryBytes: 4 * 1024 * 1024 * 1024,
    availableMemoryBytes: 4 * 1024 * 1024 * 1024,
    freeDiskBytes: 1024 * 1024 * 1024,
    unmanagedDriverProcesses: 0,
  );
}

final class _NoDeletion implements VmManagedFileEffectAdapter {
  const _NoDeletion();
  @override
  Future<void> remove(VmControllerState state, OperationId operationId) =>
      throw StateError('fixture never deletes VMs');
}

final class _NoCancellation implements OperationMutationAcceptor {
  const _NoCancellation();
  @override
  Future<OperationAcceptance> cancel(OperationCancelCommand command) =>
      throw StateError('fixture never cancels operations');
}

final class _Health implements SystemHealthService {
  const _Health();
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {'fixture': true});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}

VmSpec _spec(String diskPath) => VmSpec(
  cpu: 1,
  memoryBytes: 268435456,
  boot: EfiBoot(),
  disks: [
    VmDisk(id: 'root', source: ExternalDiskSource(diskPath), writable: true),
  ],
  networks: [DisconnectedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: false, capture: false),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.never,
);
