import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:test/test.dart';

void main() {
  test(
    'CLI entrypoint reads healthy and failed reports from the composed doctor service',
    () async {
      final temporary = await Directory.systemTemp.createTemp('gvm-dc-');
      imageFileMode(temporary.path, 0x1c0);
      final state = await OwnedImageDirectory.open(temporary);
      final roots = <OwnedImageDirectory>[];
      for (final name in ['run', 'images']) {
        final directory = await Directory('${state.path}/$name').create();
        imageFileMode(directory.path, 0x1c0);
        roots.add(await OwnedImageDirectory.open(directory));
      }
      final database = await GaoVmDatabase.open('${state.path}/catalog.db');
      final manager = DriverProcessManager(
        layout: DriverRuntimeLayout(roots.first.path),
        resolveExecutable: (_) => DriverExecutable(path: '/usr/bin/false'),
        resolveBundlePath: (id) => '${state.path}/vms/${id.value}.gaovm',
      );
      final router = PublicApiRouter();
      final server = PublicApiServer(
        socketPath: '${roots.first.path}/api.sock',
        openApiDocument: const {},
        systemHealth: _Health(),
        router: router,
      );
      // Only the OS observations are substituted, not services, SQLite, or UDS.
      final host = _Host();
      final doctor = SystemDoctorService(
        database: database,
        stateDirectory: state,
        runtimeDirectory: roots.first,
        imageStore: ImageStore(database, Directory(roots.last.path)),
        imageDirectory: roots.last,
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
      );
      SystemApiHandlers(doctor: doctor).register(router);
      try {
        await server.start();
        for (final appleSilicon in [true, false]) {
          host.appleSilicon = appleSilicon;
          final result = await Process.run(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/bin/gaovm_cli.dart',
            '--socket-path',
            server.socketPath,
            'doctor',
            '--json',
            '--timeout-seconds',
            '5',
          ]).timeout(const Duration(seconds: 15));
          expect(
            result.exitCode,
            appleSilicon ? 0 : 1,
            reason: '${result.stderr}',
          );
          expect(result.stderr, isEmpty);
          expect((result.stdout as String).trim().split('\n'), hasLength(1));
          final report = DoctorResult.fromJson(
            jsonDecode(result.stdout as String),
          );
          expect(report.healthy, appleSilicon);
          expect(report.checks, hasLength(9));
          expect(
            report.checks
                .singleWhere((check) => check.name == 'host_platform')
                .status,
            appleSilicon ? DoctorCheckStatus.ok : DoctorCheckStatus.error,
          );
          expect(await SqliteHostLeaseRepository(database).list(), isEmpty);
        }
      } finally {
        await server.close();
        await doctor.close();
        await manager.close();
        database.close();
        for (final root in roots) {
          root.close();
        }
        state.close();
        await temporary.delete(recursive: true);
      }
    },
  );
}

final class _Host implements DoctorHost {
  bool appleSilicon = true;
  @override
  Future<DoctorPlatformObservation> inspectPlatform() async =>
      (macOS: true, appleSilicon: appleSilicon, majorVersion: 14);
  @override
  Future<DoctorDriverObservation> inspectDriver() async => (
    executable: true,
    arm64: true,
    validSignature: true,
    virtualizationEntitlement: true,
    signatureMessage: 'Verified fixture.',
  );
  @override
  Future<HostMetrics> sampleResources() async => const HostMetrics(
    logicalCpuCount: 8,
    totalMemoryBytes: 16 * 1024 * 1024 * 1024,
    availableMemoryBytes: 10 * 1024 * 1024 * 1024,
    freeDiskBytes: 100 * 1024 * 1024 * 1024,
    unmanagedDriverProcesses: 0,
  );
  @override
  Future<DriverInventorySnapshot> inventory() async =>
      DriverInventorySnapshot(processes: [], unresolvedProcessIds: []);
}

final class _Health implements SystemHealthService {
  @override
  Future<SystemHealthStatus> liveness() async =>
      SystemHealthStatus(healthy: true, checks: const {});
  @override
  Future<SystemHealthStatus> readiness() => liveness();
}
