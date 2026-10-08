import 'dart:async';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'driver_process_manager.dart';
import 'driver_runtime_discovery.dart';
import 'host_lease_repository.dart';
import 'host_scheduler_models.dart';
import 'image_filesystem.dart';
import 'image_store.dart';
import 'public_api_server.dart';
import 'sqlite_database.dart';
import 'system_doctor_host.dart';

/// A bounded observation, not admission, startup recovery, or a repair operation.
final class SystemDoctorService {
  SystemDoctorService({
    required this.database,
    required this.stateDirectory,
    required this.runtimeDirectory,
    required this.imageStore,
    required this.imageDirectory,
    required this.publicServer,
    required this.processManager,
    required this.resolveBinding,
    required this.host,
    required this.limits,
    this.timeout = const Duration(seconds: 8),
  }) {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    if (imageStore.directory.absolute.path != imageDirectory.path) {
      throw ArgumentError(
        'doctor image root must match the canonical image store',
      );
    }
  }

  final GaoVmDatabase database;
  final OwnedImageDirectory stateDirectory;
  final OwnedImageDirectory runtimeDirectory;
  final ImageStore imageStore;
  final OwnedImageDirectory imageDirectory;
  final PublicApiServer publicServer;
  final DriverProcessManager processManager;
  final Future<DriverRecoveryBinding?> Function(VmId) resolveBinding;
  final DoctorHost host;
  final HostSchedulerLimits limits;
  final Duration timeout;
  _DoctorScan? _scan;
  bool _closed = false;

  Future<DoctorResult> check() {
    if (_closed) throw StateError('doctor is closed');
    final scan = _scan ?? _begin();
    final remaining = timeout - scan.elapsed.elapsed;
    if (remaining <= Duration.zero) return Future.value(scan.snapshot());
    return scan.done.timeout(remaining, onTimeout: scan.snapshot);
  }

  Future<void> close() async {
    _closed = true;
    final scan = _scan;
    if (scan != null) {
      await scan.done.timeout(timeout, onTimeout: scan.snapshot);
    }
  }

  _DoctorScan _begin() {
    final elapsed = Stopwatch()..start();
    final driver = Future.sync(host.inspectDriver);
    final probes = <String, Future<DoctorCheck> Function()>{
      'host_platform': () async {
        final platform = await host.inspectPlatform();
        return _check(
          'host_platform',
          platform.macOS &&
              platform.appleSilicon &&
              platform.majorVersion >= 14,
          'macOS ${platform.majorVersion}; Apple Silicon=${platform.appleSilicon}.',
          'macOS 14+ on Apple Silicon is required.',
        );
      },
      'driver_binary': () async {
        final binary = await driver;
        return _check(
          'driver_binary',
          binary.executable && binary.arm64,
          'Executable Mach-O with an ARM64 slice is present.',
          'Driver must be an executable Mach-O with an ARM64 slice.',
        );
      },
      'entitlement': () async {
        final binary = await driver;
        return _check(
          'entitlement',
          binary.validSignature && binary.virtualizationEntitlement,
          'Static code signature and com.apple.security.virtualization=true verified; not a VM boot test.',
          binary.signatureMessage,
        );
      },
      'database': _database,
      'state_directory': _state,
      'image_store': () => _images(elapsed),
      'host_resources': _resources,
      'runtime': _runtime,
      'guest_profile': () async => const DoctorCheck(
        name: 'guest_profile',
        status: DoctorCheckStatus.warning,
        message:
            'GaoOS image profile provisioning is supported. Authenticated guest session, exec, and service readiness are not verified by this daemon.',
      ),
    };
    final scan = _DoctorScan(probes, elapsed);
    _scan = scan;
    unawaited(
      scan.done.then((_) {
        if (identical(_scan, scan)) _scan = null;
      }),
    );
    return scan;
  }

  Future<DoctorCheck> _database() async {
    await database.read((db) => db.select('SELECT 1'));
    final missing = coreTableNames.difference(database.tableNames);
    return _check(
      'database',
      missing.isEmpty &&
          database.journalMode == 'wal' &&
          database.foreignKeysEnabled,
      'SQLite catalog is readable; schema=${database.schemaVersion}, WAL and foreign keys enabled. Not a full integrity audit.',
      'Catalog tables, WAL mode, or foreign-key enforcement could not be verified.',
    );
  }

  Future<DoctorCheck> _state() async {
    await stateDirectory.verifyPathBinding();
    await runtimeDirectory.verifyPathBinding();
    return _check(
      'state_directory',
      stateDirectory.mode & 0x1ff == 0x1c0 &&
          runtimeDirectory.mode & 0x1ff == 0x1c0,
      'Owned state and runtime directories remain bound and mode 0700.',
      'State and runtime directories must remain owned, bound, and mode 0700.',
    );
  }

  Future<DoctorCheck> _images(Stopwatch elapsed) async {
    final root = imageDirectory;
    await root.verifyPathBinding();
    var count = 0;
    var unverified = 0;
    const contentByteBudget = 64 * 1024 * 1024;
    var remainingBytes = contentByteBudget;
    String? cursor;
    try {
      if (root.mode & 0x1ff != 0x1c0)
        throw const FormatException('image store must be private');
      while (true) {
        if (elapsed.elapsed >= timeout)
          throw TimeoutException('image scan deadline');
        final ids = await database.read(
          (db) => db
              .select(
                'SELECT id FROM images WHERE deleted_at IS NULL AND (? IS NULL OR id > ?) ORDER BY id LIMIT 64',
                [cursor, cursor],
              )
              .map((row) => ImageId(row['id'] as String))
              .toList(),
        );
        if (ids.isEmpty) break;
        for (final id in ids) {
          if (elapsed.elapsed >= timeout)
            throw TimeoutException('image scan deadline');
          try {
            final verified = await imageStore.verifyImage(
              id,
              contentByteBudget: remainingBytes,
              isCancelled: () => _closed || elapsed.elapsed >= timeout,
            );
            remainingBytes -= verified.bytesHashed;
            if (!verified.digestsVerified) unverified++;
          } catch (error) {
            if (elapsed.elapsed >= timeout)
              throw TimeoutException('image scan deadline');
            return DoctorCheck(
              name: 'image_store',
              status: DoctorCheckStatus.error,
              message:
                  'Image ${id.value} failed read-only integrity verification (${error.runtimeType}). Published and staging files were left untouched.',
            );
          }
          count++;
        }
        cursor = ids.last.value;
      }
      await root.verifyPathBinding();
      return DoctorCheck(
        name: 'image_store',
        status: unverified == 0
            ? DoctorCheckStatus.ok
            : DoctorCheckStatus.warning,
        message:
            '$count catalog image manifests and object sizes verified; content_digests_unverified=$unverified; hash_budget_bytes=$contentByteBudget. Unregistered files are left untouched; a warning is not full content-integrity proof.',
      );
    } finally {
      await root.verifyPathBinding();
    }
  }

  Future<DoctorCheck> _resources() async {
    final metrics = await host.sampleResources();
    final leases = await SqliteHostLeaseRepository(
      database,
    ).list(activeAt: DateTime.now());
    final cpuReserved = leases.fold(
      0,
      (sum, lease) => sum + lease.request.cpuCount,
    );
    final memoryReserved = leases.fold(
      0,
      (sum, lease) => sum + lease.request.memoryBytes,
    );
    final cpu = (limits.maxCpuCount - cpuReserved).clamp(
      0,
      metrics.logicalCpuCount,
    );
    final memory = (limits.maxMemoryBytes - memoryReserved).clamp(
      0,
      metrics.availableMemoryBytes,
    );
    final status = metrics.freeDiskBytes < limits.minFreeDiskBytes
        ? DoctorCheckStatus.error
        : cpu == 0 || memory == 0
        ? DoctorCheckStatus.warning
        : DoctorCheckStatus.ok;
    return DoctorCheck(
      name: 'host_resources',
      status: status,
      message:
          'cpu_budget_available=$cpu; memory_budget_available_bytes=$memory; free_disk_bytes=${metrics.freeDiskBytes}; disk_floor_bytes=${limits.minFreeDiskBytes}. Snapshot estimates, not a reservation.',
    );
  }

  Future<DoctorCheck> _runtime() async {
    final sockets = await publicServer.inspectOwnedSocketPaths();
    final inventory = await host.inventory();
    if (inventory.unresolvedProcessIds.isNotEmpty) {
      return DoctorCheck(
        name: 'runtime',
        status: DoctorCheckStatus.error,
        message:
            'Process census has ${inventory.unresolvedProcessIds.length} unresolved executables; absence or spare driver capacity cannot be proven. No process was signalled.',
      );
    }
    final managed = processManager.managedProcessIdentities;
    final unmanaged = inventory.countUnmanaged(managed);
    final discovery = await DriverRuntimeDiscovery(
      root: runtimeDirectory,
      resolveBinding: resolveBinding,
      reservedNames: sockets.map((path) => path.split('/').last).toSet(),
    ).scan();
    var stale = 0;
    for (final record in discovery.records) {
      if (record.processIdentity == null ||
          !managed.contains(record.processIdentity) ||
          await FileSystemEntity.type(record.socketPath, followLinks: false) !=
              FileSystemEntityType.unixDomainSock)
        stale++;
    }
    return DoctorCheck(
      name: 'runtime',
      status:
          unmanaged == 0 &&
              stale == 0 &&
              discovery.issues.isEmpty &&
              processManager.pendingSpawnCount == 0
          ? DoctorCheckStatus.ok
          : DoctorCheckStatus.warning,
      message:
          'Current API socket links verified; unmanaged_drivers=$unmanaged; stale_runtime_records=$stale; namespace_issues=${discovery.issues.length}; pending_spawns=${processManager.pendingSpawnCount}. Read-only snapshot; no process signals or socket cleanup.',
    );
  }
}

DoctorCheck _check(String name, bool ok, String success, String failure) =>
    DoctorCheck(
      name: name,
      status: ok ? DoctorCheckStatus.ok : DoctorCheckStatus.error,
      message: ok ? success : failure,
    );

final class _DoctorScan {
  _DoctorScan(Map<String, Future<DoctorCheck> Function()> probes, this.elapsed)
    : names = List.unmodifiable(probes.keys) {
    done = Future.wait(
      probes.entries.map((entry) async {
        final DoctorCheck check;
        try {
          check = await entry.value();
        } catch (error) {
          settled[entry.key] = DoctorCheck(
            name: entry.key,
            status: DoctorCheckStatus.error,
            message:
                'Read-only ${entry.key} check could not be verified (${error.runtimeType}).',
          );
          return settled[entry.key]!;
        }
        settled[entry.key] = check;
        return check;
      }),
    ).then(DoctorResult.fromChecks);
  }
  final Stopwatch elapsed;
  final List<String> names;
  final Map<String, DoctorCheck> settled = {};
  late final Future<DoctorResult> done;

  DoctorResult snapshot() => DoctorResult.fromChecks(
    names.map(
      (name) =>
          settled[name] ??
          DoctorCheck(
            name: name,
            status: DoctorCheckStatus.error,
            message:
                'Read-only check exceeded the doctor deadline; no repair was attempted.',
          ),
    ),
  );
}
