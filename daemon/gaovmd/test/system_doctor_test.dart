import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  test(
    'public doctor reports all required checks without repairing the host',
    () async {
      await _withDoctor((fixture) async {
        final response = await fixture.request();
        expect(response.status, HttpStatus.ok);
        final report = DoctorResult.fromJson(response.body);
        expect(report.healthy, isTrue);
        expect(report.checks.map((check) => check.name).toSet(), {
          'host_platform',
          'driver_binary',
          'entitlement',
          'database',
          'state_directory',
          'image_store',
          'host_resources',
          'runtime',
          'guest_profile',
        });
        expect(
          report.checks.where(
            (check) => check.status == DoctorCheckStatus.error,
          ),
          isEmpty,
        );
        final guest = report.checks.singleWhere(
          (check) => check.name == 'guest_profile',
        );
        expect(guest.status, DoctorCheckStatus.warning);
        expect(guest.message, contains('not verified'));
        expect(await fixture.store.list(), isEmpty);
        expect(
          await SqliteHostLeaseRepository(fixture.database).list(),
          isEmpty,
        );
      });
    },
  );
  test(
    'unresolved census is an error and doctor leaves unknown runtime files untouched',
    () async {
      await _withDoctor((fixture) async {
        fixture.host.processes = DriverInventorySnapshot(
          processes: [],
          unresolvedProcessIds: [123],
        );
        final orphan = await File(
          '${fixture.temporary.path}/run/operator-evidence',
        ).writeAsString('preserve');
        final report = DoctorResult.fromJson((await fixture.request()).body);
        expect(report.healthy, isFalse);
        final runtime = report.checks.singleWhere(
          (check) => check.name == 'runtime',
        );
        expect(runtime.status, DoctorCheckStatus.error);
        expect(runtime.message, contains('unresolved executables'));
        expect(await orphan.readAsString(), 'preserve');
        expect(
          report.checks.singleWhere((check) => check.name == 'database').status,
          DoctorCheckStatus.ok,
        );
      });
    },
  );
  test('doctor rejects replacement of the daemon-held image root', () async {
    await _withDoctor((fixture) async {
      final original = Directory(fixture.store.directory.path);
      await original.rename('${fixture.temporary.path}/retired-images');
      await original.create();
      imageFileMode(original.path, 0x1c0);
      final report = DoctorResult.fromJson((await fixture.request()).body);
      expect(report.healthy, isFalse);
      expect(
        report.checks
            .singleWhere((check) => check.name == 'image_store')
            .status,
        DoctorCheckStatus.error,
      );
    });
  });
  test(
    'doctor detects same-size image corruption without repairing or removing files',
    () async {
      await _withDoctor((fixture) async {
        final source = await File(
          '${fixture.temporary.path}/disk',
        ).writeAsString('disk');
        final image = await fixture.store.importFile(
          source,
          type: ImageType.rawDisk,
        );
        final payload = File(
          '${fixture.store.directory.path}/sha256-${image.digest.substring(7)}/objects/payload',
        );
        imageFileMode(payload.path, 0x180);
        await payload.writeAsString('evil');
        imageFileMode(payload.path, 0x124);
        final staging = await Directory(
          '${fixture.store.directory.path}/.staging-evidence',
        ).create();
        final evidence = await File(
          '${staging.path}/evidence',
        ).writeAsString('preserve');
        final report = DoctorResult.fromJson((await fixture.request()).body);
        expect(report.healthy, isFalse);
        expect(
          report.checks
              .singleWhere((check) => check.name == 'image_store')
              .status,
          DoctorCheckStatus.error,
        );
        expect(await payload.readAsString(), 'evil');
        expect(
          report.checks
              .singleWhere((check) => check.name == 'image_store')
              .message,
          contains(image.id.value),
        );
        expect(await evidence.readAsString(), 'preserve');
        expect((await fixture.store.list()).single.id, image.id);
      });
    },
  );
  test('public doctor rejects request bodies and query parameters', () async {
    await _withDoctor((fixture) async {
      for (final response in [
        await fixture.request(query: '?repair=true'),
        await fixture.request(body: const {}),
      ]) {
        expect(response.status, HttpStatus.badRequest);
        final problem = Problem.fromJson(response.body);
        expect(problem.code, ErrorCode.invalidRequest);
        expect(problem.requestId.value, startsWith('req_'));
      }
    });
  });
  test(
    'doctor bounds its response and coalesces an unfinished native observation',
    () async {
      await _withDoctor((fixture) async {
        final release = Completer<HostMetrics>();
        fixture.host.pendingMetrics = release;
        try {
          for (var request = 0; request < 2; request++) {
            final response = await fixture.request();
            expect(response.status, HttpStatus.ok);
            final report = DoctorResult.fromJson(response.body);
            expect(report.healthy, isFalse);
            expect(
              report.checks
                  .singleWhere((check) => check.name == 'host_resources')
                  .status,
              DoctorCheckStatus.error,
            );
          }
          expect(fixture.host.resourceSamples, 1);
        } finally {
          release.complete(fixture.host.metrics);
        }
      }, timeout: const Duration(milliseconds: 100));
    },
  );
  test(
    'resource reporting retains expired runtime reservations without renewing them',
    () async {
      await _withDoctor((fixture) async {
        final leases = SqliteHostLeaseRepository(fixture.database);
        final decision = await leases.acquire(
          request: HostCapacityRequest(
            vmId: VmId.generate(),
            cpuCount: 8,
            memoryBytes: 8 * 1024 * 1024 * 1024,
            diskBytes: 0,
            phase: HostLeasePhase.running,
            specGeneration: 1,
            driverGeneration: 1,
            operationId: null,
          ),
          limits: fixture.doctor.limits,
          metrics: fixture.host.metrics,
          ownerId: RequestId.generate().value,
          now: DateTime.now().toUtc().subtract(const Duration(days: 1)),
          ttl: const Duration(seconds: 1),
        );
        expect(decision.lease, isNotNull);
        final before = await leases.list();
        final report = DoctorResult.fromJson((await fixture.request()).body);
        final resources = report.checks.singleWhere(
          (check) => check.name == 'host_resources',
        );
        expect(resources.status, DoctorCheckStatus.warning);
        expect(resources.message, contains('cpu_budget_available=0'));
        expect(resources.message, contains('memory_budget_available_bytes=0'));
        expect(await leases.list(), before);
      });
    },
  );
  test(
    'live diagnostics reserve only exact API links and preserve a foreign socket',
    () async {
      await _withDoctor((fixture) async {
        final path = '${fixture.temporary.path}/run/.o.foreign';
        final foreign = await ServerSocket.bind(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        try {
          final report = DoctorResult.fromJson((await fixture.request()).body);
          final runtime = report.checks.singleWhere(
            (check) => check.name == 'runtime',
          );
          expect(runtime.status, DoctorCheckStatus.warning);
          expect(runtime.message, contains('namespace_issues=1'));
          expect(
            await FileSystemEntity.type(path, followLinks: false),
            FileSystemEntityType.unixDomainSock,
          );
          final connected = await Socket.connect(
            InternetAddress(path, type: InternetAddressType.unix),
            0,
          );
          connected.destroy();
        } finally {
          await foreign.close();
        }
      });
    },
  );
  test(
    'an unreadable catalog is reported as an unhealthy check, not an API crash',
    () async {
      await _withDoctor((fixture) async {
        fixture.database.close();
        final response = await fixture.request();
        expect(response.status, HttpStatus.ok);
        final report = DoctorResult.fromJson(response.body);
        expect(report.healthy, isFalse);
        expect(
          report.checks.singleWhere((check) => check.name == 'database').status,
          DoctorCheckStatus.error,
        );
        expect(
          report.checks
              .singleWhere((check) => check.name == 'host_platform')
              .status,
          DoctorCheckStatus.ok,
        );
      });
    },
  );
  test(
    'large images report unverified content digests instead of an unbounded rehash',
    () async {
      await _withDoctor((fixture) async {
        final source = File('${fixture.temporary.path}/large-disk');
        final file = await source.open(mode: FileMode.write);
        try {
          await file.truncate(64 * 1024 * 1024 + 1);
        } finally {
          await file.close();
        }
        await fixture.store.importFile(source, type: ImageType.rawDisk);
        final response = await fixture.request();
        expect(response.status, HttpStatus.ok);
        final report = DoctorResult.fromJson(response.body);
        expect(report.healthy, isTrue);
        final images = report.checks.singleWhere(
          (check) => check.name == 'image_store',
        );
        expect(images.status, DoctorCheckStatus.warning);
        expect(images.message, contains('content_digests_unverified=1'));
        expect(images.message, contains('manifests and object sizes verified'));
      });
    },
  );
  test(
    'doctor preserves independent required failures in one report',
    () async {
      await _withDoctor((fixture) async {
        fixture.host.platform = (
          macOS: true,
          appleSilicon: false,
          majorVersion: 14,
        );
        fixture.host.driver = (
          executable: false,
          arm64: false,
          validSignature: false,
          virtualizationEntitlement: false,
          signatureMessage: 'No signing proof.',
        );
        fixture.host.metrics = fixture.host.metrics.copyWith(freeDiskBytes: 0);
        imageFileMode(fixture.temporary.path, 0x1ed);
        try {
          final report = DoctorResult.fromJson((await fixture.request()).body);
          expect(report.healthy, isFalse);
          expect(
            report.checks
                .where((check) => check.status == DoctorCheckStatus.error)
                .map((check) => check.name)
                .toSet(),
            {
              'host_platform',
              'driver_binary',
              'entitlement',
              'state_directory',
              'host_resources',
            },
          );
          expect(
            report.checks
                .singleWhere((check) => check.name == 'host_resources')
                .message,
            contains('free_disk_bytes=0'),
          );
          expect((await fixture.temporary.stat()).mode & 0x1ff, 0x1ed);
        } finally {
          imageFileMode(fixture.temporary.path, 0x1c0);
        }
      });
    },
  );
  test(
    'a replaced public socket link is reported without deleting its replacement',
    () async {
      await _withDoctor((fixture) async {
        final published = File(fixture.server.socketPath);
        final moved = await published.rename(
          '${fixture.temporary.path}/run/held-api.sock',
        );
        final foreign = await ServerSocket.bind(
          InternetAddress(published.path, type: InternetAddressType.unix),
          0,
        );
        try {
          final report = await fixture.doctor.check();
          expect(report.healthy, isFalse);
          expect(
            report.checks
                .singleWhere((check) => check.name == 'runtime')
                .status,
            DoctorCheckStatus.error,
          );
          expect(
            await FileSystemEntity.type(published.path, followLinks: false),
            FileSystemEntityType.unixDomainSock,
          );
          final connected = await Socket.connect(
            InternetAddress(published.path, type: InternetAddressType.unix),
            0,
          );
          connected.destroy();
        } finally {
          await foreign.close();
          await moved.rename(published.path);
        }
      });
    },
  );
}

Future<void> _withDoctor(
  Future<void> Function(_Fixture) action, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final temporary = await Directory.systemTemp.createTemp('gvm-doctor-');
  imageFileMode(temporary.path, 0x1c0);
  final state = await OwnedImageDirectory.open(temporary);
  final runPath = await Directory('${temporary.path}/run').create();
  imageFileMode(runPath.path, 0x1c0);
  final run = await OwnedImageDirectory.open(runPath);
  final images = await Directory('${temporary.path}/images').create();
  imageFileMode(images.path, 0x1c0);
  final imageRoot = await OwnedImageDirectory.open(images);
  final database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
  final store = ImageStore(database, Directory(imageRoot.path));
  final manager = DriverProcessManager(
    layout: DriverRuntimeLayout(run.path),
    resolveExecutable: (_) => DriverExecutable(path: '/usr/bin/false'),
    resolveBundlePath: (id) => '${temporary.path}/vms/${id.value}.gaovm',
  );
  final router = PublicApiRouter();
  final server = PublicApiServer(
    socketPath: '${run.path}/api.sock',
    openApiDocument: const {},
    systemHealth: _Health(),
    router: router,
  );
  final host = _Host();
  final doctor = SystemDoctorService(
    database: database,
    stateDirectory: state,
    runtimeDirectory: run,
    imageStore: store,
    imageDirectory: imageRoot,
    publicServer: server,
    processManager: manager,
    resolveBinding: (_) async => null,
    host: host,
    limits: HostSchedulerLimits(
      maxRunningVms: 8,
      maxConcurrentBoots: 2,
      maxDriverProcesses: 8,
      maxCpuCount: 8,
      maxMemoryBytes: 8 * 1024 * 1024 * 1024,
      minFreeDiskBytes: 1024 * 1024 * 1024,
    ),
    timeout: timeout,
  );
  SystemApiHandlers(doctor: doctor).register(router);
  final fixture = _Fixture(database, store, host, server, temporary, doctor);
  try {
    await server.start();
    await action(fixture);
  } finally {
    await server.close();
    await doctor.close();
    await manager.close();
    database.close();
    imageRoot.close();
    run.close();
    state.close();
    await temporary.delete(recursive: true);
  }
}

final class _Fixture {
  const _Fixture(
    this.database,
    this.store,
    this.host,
    this.server,
    this.temporary,
    this.doctor,
  );
  final GaoVmDatabase database;
  final ImageStore store;
  final _Host host;
  final PublicApiServer server;
  final Directory temporary;
  final SystemDoctorService doctor;

  Future<({int status, Object? body})> request({
    String query = '',
    Map<String, Object?>? body,
  }) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (_, _, _) => Socket.startConnect(
        InternetAddress(server.socketPath, type: InternetAddressType.unix),
        0,
      );
    try {
      final request = await client.openUrl(
        'GET',
        Uri.parse('http://localhost/v1/system/doctor$query'),
      );
      if (body != null) {
        request.headers.contentType = ContentType.json;
        final bytes = utf8.encode(jsonEncode(body));
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close();
      return (
        status: response.statusCode,
        body: jsonDecode(await utf8.decoder.bind(response).join()),
      );
    } finally {
      client.close(force: true);
    }
  }
}

final class _Host implements DoctorHost {
  DoctorPlatformObservation platform = (
    macOS: true,
    appleSilicon: true,
    majorVersion: 14,
  );
  DoctorDriverObservation driver = (
    executable: true,
    arm64: true,
    validSignature: true,
    virtualizationEntitlement: true,
    signatureMessage: 'Signature verified.',
  );
  DriverInventorySnapshot processes = DriverInventorySnapshot(
    processes: [],
    unresolvedProcessIds: [],
  );
  Completer<HostMetrics>? pendingMetrics;
  int resourceSamples = 0;
  HostMetrics metrics = const HostMetrics(
    logicalCpuCount: 8,
    totalMemoryBytes: 16 * 1024 * 1024 * 1024,
    availableMemoryBytes: 10 * 1024 * 1024 * 1024,
    freeDiskBytes: 100 * 1024 * 1024 * 1024,
    unmanagedDriverProcesses: 0,
  );
  @override
  Future<DoctorPlatformObservation> inspectPlatform() async => platform;
  @override
  Future<DoctorDriverObservation> inspectDriver() async => driver;
  @override
  Future<HostMetrics> sampleResources() async {
    resourceSamples++;
    return pendingMetrics == null ? metrics : pendingMetrics!.future;
  }

  @override
  Future<DriverInventorySnapshot> inventory() async => processes;
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
