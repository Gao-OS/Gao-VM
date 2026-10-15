import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'artifact_api_handlers.dart';
import 'artifact_application_service.dart';
import 'artifact_repository.dart';
import 'cold_state_lease.dart';
import 'driver_process_manager.dart';
import 'driver_runtime_layout.dart';
import 'driver_runtime_discovery.dart';
import 'host_scheduler_models.dart';
import 'image_filesystem.dart';
import 'image_api_handlers.dart';
import 'image_application_service.dart';
import 'image_store.dart';
import 'legacy_vm_migration.dart';
import 'macos_driver_inventory.dart';
import 'macos_host_metrics.dart';
import 'macos_system_doctor_host.dart';
import 'maintenance_tree.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'public_api_server.dart';
import 'resource_api_handlers.dart';
import 'sqlite_database.dart';
import 'system_api_handlers.dart';
import 'system_doctor_host.dart';
import 'system_doctor_service.dart';
import 'test_run_api_handlers.dart';
import 'test_run_application_service.dart';
import 'vm_application_service.dart';
import 'vm_log_api_handlers.dart';
import 'vm_log_application_service.dart';
import 'vm_repository.dart';

extension ColdCandidateValidation on ColdStateLease {
  /// Borrows this actual kernel owner through controlled migration, a native
  /// READONLY API session and complete probe drain. No worker/controller or
  /// driver session is constructed, recovered or started by this composition.
  Future<Map<String, Object?>> validateCandidate({
    required Map<String, Object?> openApiDocument,
    required Future<void> Function() verifyBeforeMigration,
    DoctorHost? doctorHost,
  }) => withCandidateState((_root, _ownership) async {
    await verifyBeforeMigration();
    final roots = <OwnedImageDirectory>[];
    GaoVmDatabase? database;
    PublicApiServer? server;
    SystemDoctorService? doctor;
    DriverProcessManager? manager;
    MaintenanceTree? stateTree;
    Map<String, Object?>? readOnlyManifest;
    Map<String, Object?>? result;
    Future<Map<String, Object?>> captureState() => stateTree!.captureStateData(
      verifyBoundary: () async {
        await _ownership.verify();
        return {'source_state': path};
      },
    );
    final api = _ValidationApi();
    try {
      final run = await _validationChild(_root, 'run');
      roots.add(run);
      final bundles = await _validationChild(_root, 'vms');
      roots.add(bundles);
      final images = await _validationChild(_root, 'images');
      roots.add(images);
      final artifacts = await _validationChild(_root, 'artifacts');
      roots.add(artifacts);
      final existing = _root.fileOrNull('gaovm.db');
      if (existing == null) {
        final created = _root.createFile('gaovm.db');
        try {
          final writer = await created.openWrite();
          try {
            await writer.flush();
          } finally {
            await writer.close();
          }
        } finally {
          created.close();
        }
        await _root.sync();
      } else {
        existing.close();
      }
      database = await GaoVmDatabase.open('$path/gaovm.db');
      await LegacyVmMigration(
        database: database,
        state: _root,
        bundles: bundles,
        images: images,
        ownership: _ownership,
      ).migrate();
      await _ownership.verify();
      database.close();
      database = await GaoVmDatabase.openReadOnly('$path/gaovm.db');
      stateTree = await MaintenanceTree.open(Directory(path));
      readOnlyManifest = await captureState();
      final catalog = SqliteVmRepository(database);
      final operations = SqliteOperationRepository(database);
      final imageStore = ImageStore(database, Directory(images.path));
      final artifactService = ArtifactApplicationService(
        database: database,
        directory: artifacts,
      );
      final router = PublicApiRouter();
      server = PublicApiServer(
        socketPath: '${run.path}/api.sock',
        openApiDocument: openApiDocument,
        systemHealth: const _ValidationHealth(),
        router: router,
        access: PublicApiAccess.maintenanceValidation,
      );
      final driverPath = '$installationPath/Contents/Helpers/gaovm-driver-vz';
      final nativeInventory = MacOsDriverInventory(executablePath: driverPath);
      final metrics = MacOsHostMetricsSource(
        storage: _root,
        countUnmanagedDrivers: () async =>
            (await nativeInventory.snapshotForMaintenance()).countUnmanaged({}),
      );
      manager = DriverProcessManager(
        layout: DriverRuntimeLayout(run.path),
        resolveExecutable: (_) => DriverExecutable(path: driverPath),
        resolveBundlePath: (id) => '${bundles.path}/${id.value}.gaovm',
      );
      final observedHost =
          doctorHost ??
          _ValidationDoctorNative(
            MacOsDoctorHost(
              driverBinary: driverPath,
              metrics: metrics,
              processes: nativeInventory,
            ),
          );
      final capacity = await observedHost.sampleResources();
      final limits = HostSchedulerLimits(
        maxRunningVms: 8,
        maxConcurrentBoots: 2,
        maxDriverProcesses: 8,
        maxCpuCount: capacity.logicalCpuCount,
        maxMemoryBytes: capacity.totalMemoryBytes * 3 ~/ 4,
        minFreeDiskBytes: 1024 * 1024 * 1024,
      );
      final ownedDatabase = database;
      doctor = SystemDoctorService(
        database: database,
        stateDirectory: _root,
        runtimeDirectory: run,
        imageStore: imageStore,
        imageDirectory: images,
        publicServer: server,
        processManager: manager,
        resolveBinding: (id) async {
          final vm = await catalog.get(id, includeDeleted: true);
          return vm == null
              ? null
              : DriverRecoveryBinding(
                  driverGeneration: vm.status.driverGeneration,
                  executable: driverPath,
                  bundlePath: '${bundles.path}/${id.value}.gaovm',
                );
        },
        host: observedHost,
        limits: limits,
      );
      ResourceApiHandlers(
        vms: VmApplicationService.readOnly(repository: catalog),
        operations: OperationApplicationService.readOnly(
          repository: operations,
        ),
      ).register(router);
      ImageApiHandlers(
        images: ImageApplicationService(database: database, store: imageStore),
      ).register(router);
      ArtifactApiHandlers(artifacts: artifactService).register(router);
      VmLogApiHandlers(
        logs: VmLogApplicationService(database: database, bundles: bundles),
      ).register(router);
      TestRunApiHandlers(
        runs: TestRunApplicationService(database: database),
      ).register(router);
      SystemApiHandlers(doctor: doctor).register(router);
      await server.start();
      api.connect(server.socketPath);
      await api.json('/v1/system/live');
      final readiness = await api.json('/v1/system/ready', expectedStatus: 503);
      if (readiness['ready'] != false)
        throw StateError('ordinary readiness was not fenced');
      final capabilities = await api.json('/v1/system/capabilities');
      PublicCapabilities.fromJson(capabilities);
      final report = await api.json('/v1/system/doctor');
      if (!DoctorResult.fromJson(report).healthy) {
        throw StateError('candidate public doctor has unverified/error checks');
      }
      final ids = await ownedDatabase.read(
        (db) => <String, Object?>{
          'vm_ids': db
              .select('SELECT id FROM vms ORDER BY id')
              .map((r) => r['id'] as String)
              .toList(),
          'image_ids': db
              .select('SELECT id FROM images ORDER BY id')
              .map((r) => r['id'] as String)
              .toList(),
          'operation_ids': db
              .select('SELECT id FROM operations ORDER BY id')
              .map((r) => r['id'] as String)
              .toList(),
          'test_run_ids': db
              .select('SELECT id FROM test_runs ORDER BY id')
              .map((r) => r['id'] as String)
              .toList(),
          'artifact_ids': db
              .select('SELECT id FROM artifacts ORDER BY id')
              .map((r) => r['id'] as String)
              .toList(),
          'event_cursor': db
              .select('SELECT COALESCE(MAX(sequence), 0) AS cursor FROM events')
              .single['cursor'],
          'idempotency_count': db
              .select('SELECT COUNT(*) AS count FROM idempotency_keys')
              .single['count'],
        },
      );
      await api.verifyList(
        '/v1/vms',
        (await catalog.list()).map((vm) => vm.toJson()).toList(),
        vm: true,
      );
      await api.verifyList(
        '/v1/images',
        (await imageStore.list()).map((image) => image.toJson()).toList(),
      );
      await api.verifyList(
        '/v1/operations',
        (await operations.list())
            .map((operation) => operation.toJson())
            .toList(),
      );
      for (final id in (ids['vm_ids'] as List<String>)) {
        final vm = await catalog.get(VmId(id));
        if (vm != null) {
          final value = await api.json('/v1/vms/$id');
          if (jsonEncode(value) != jsonEncode(vm.toJson()))
            throw StateError('VM identity mismatch');
          await api.json('/v1/vms/$id/logs');
          await api.json('/v1/vms/$id/artifacts');
        }
      }
      for (final id in (ids['operation_ids'] as List<String>)) {
        final operation = await operations.get(OperationId(id));
        final value = await api.json('/v1/operations/$id');
        if (jsonEncode(value) != jsonEncode(operation!.toJson()))
          throw StateError('operation identity mismatch');
      }
      for (final id in (ids['test_run_ids'] as List<String>)) {
        await api.json('/v1/test-runs/$id');
        await api.json('/v1/test-runs/$id/artifacts');
      }
      for (final id in (ids['artifact_ids'] as List<String>)) {
        await api.artifact(
          (await ArtifactRepository(ownedDatabase).get(ArtifactId(id)))!,
        );
      }
      final refused = await api.json(
        '/v1/vms',
        method: 'POST',
        expectedStatus: 403,
      );
      if (refused['code'] != 'INVALID_REQUEST')
        throw StateError('write restriction was not enforced');
      result = {
        'applied_catalog_schema': ownedDatabase.schemaVersion,
        'catalog_identity': ids,
        'public_capabilities': capabilities,
        'public_doctor': report,
        'ordinary_ready': false,
        'background_workers_started': false,
        'driver_sessions_started': false,
        'read_only_state_digest':
            'sha256:${sha256.convert(utf8.encode(jsonEncode(readOnlyManifest)))}',
      };
    } finally {
      api.close();
      try {
        await server?.close();
      } finally {
        // A listener cleanup error must not abandon an original native probe.
        try {
          await doctor?.drain();
        } finally {
          await manager?.close();
          try {
            await _ownership.verify();
            if (server?.fatalError != null) {
              throw StateError('validation listener terminated unexpectedly');
            }
            if (readOnlyManifest != null &&
                jsonEncode(await captureState()) !=
                    jsonEncode(readOnlyManifest)) {
              throw const FormatException(
                'persistent state changed during read-only validation',
              );
            }
          } finally {
            database?.close();
            try {
              if (result != null) {
                result['closed_session_state_digest'] =
                    'sha256:${sha256.convert(utf8.encode(jsonEncode(await captureState())))}';
              }
            } finally {
              stateTree?.close();
              for (final root in roots.reversed) root.close();
            }
          }
        }
      }
    }
    return result;
  });
}

Future<OwnedImageDirectory> _validationChild(
  OwnedImageDirectory parent,
  String name,
) async {
  OwnedImageDirectory child;
  try {
    child = parent.directory(name);
  } on FileSystemException catch (error) {
    if (error.osError?.errorCode != 2) rethrow;
    child = parent.createDirectory(name);
  }
  try {
    await parent.sync();
    await child.verifyPathBinding();
    if (child.mode & 0xfff != 0x1c0 ||
        (await child.maintenanceMetadata())['has_acl'] != false) {
      throw const FormatException('private validation directory required');
    }
    return child;
  } catch (_) {
    child.close();
    rethrow;
  }
}

final class _ValidationHealth implements SystemHealthService {
  const _ValidationHealth();
  @override
  Future<SystemHealthStatus> liveness() async => SystemHealthStatus(
    healthy: true,
    checks: const {'maintenance_validation': 'live'},
  );
  @override
  Future<SystemHealthStatus> readiness() async => SystemHealthStatus(
    healthy: false,
    checks: const {'maintenance_validation': 'read_only'},
  );
}

final class _ValidationDoctorNative implements DoctorHost {
  _ValidationDoctorNative(this.delegate);
  final MacOsDoctorHost delegate;
  @override
  Future<DoctorPlatformObservation> inspectPlatform() =>
      delegate.inspectPlatform();
  @override
  Future<DoctorDriverObservation> inspectDriver() => delegate.inspectDriver();
  @override
  Future<HostMetrics> sampleResources() =>
      (delegate.metrics as MacOsHostMetricsSource).sampleForMaintenance();
  @override
  Future<DriverInventorySnapshot> inventory() =>
      delegate.processes.snapshotForMaintenance();
}

final class _ValidationApi {
  HttpClient? _client;
  void connect(String path) {
    _client = HttpClient()
      ..autoUncompress = false
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (_, _, _) => Socket.startConnect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
  }

  void close() => _client?.close(force: true);
  Future<Map<String, Object?>> json(
    String path, {
    String method = 'GET',
    int expectedStatus = 200,
  }) async {
    final request = await _client!.openUrl(
      method,
      Uri.parse('http://localhost$path'),
    );
    final response = await request.close();
    final value = jsonDecode(await utf8.decoder.bind(response).join());
    if (response.statusCode != expectedStatus ||
        value is! Map<String, Object?>) {
      throw StateError('candidate public API did not verify $path');
    }
    return value;
  }

  Future<void> verifyList(
    String path,
    List<Map<String, Object?>> expected, {
    bool vm = false,
  }) async {
    final seen = <String, Map<String, Object?>>{};
    final cursors = <String>{};
    String? cursor;
    do {
      final query = Uri(
        queryParameters: {'limit': '200', if (cursor != null) 'cursor': cursor},
      ).query;
      final page = await json('$path?$query');
      final items = page['items'];
      if (items is! List) throw StateError('invalid candidate API page');
      for (final item in items.cast<Map<String, Object?>>()) {
        final id =
            (vm ? (item['metadata'] as Map)['id'] : item['id']) as String;
        if (seen.containsKey(id))
          throw StateError('duplicate candidate API identity');
        seen[id] = item;
      }
      cursor = page['next_cursor'] as String?;
      if (cursor != null && !cursors.add(cursor))
        throw StateError('candidate API cursor repeated');
    } while (cursor != null);
    if (seen.length != expected.length)
      throw StateError('candidate API catalog count mismatch');
    for (final item in expected) {
      final id = (vm ? (item['metadata'] as Map)['id'] : item['id']) as String;
      if (jsonEncode(seen[id]) != jsonEncode(item))
        throw StateError('candidate API catalog value mismatch');
    }
  }

  Future<void> artifact(Artifact artifact) async {
    final request = await _client!.getUrl(
      Uri.parse('http://localhost${artifact.downloadUrl}'),
    );
    final response = await request.close();
    var size = 0;
    final digest = await sha256
        .bind(
          response.map((bytes) {
            size += bytes.length;
            return bytes;
          }),
        )
        .first;
    if (response.statusCode != 200 ||
        response.contentLength != artifact.sizeBytes ||
        size != artifact.sizeBytes ||
        artifact.digest != 'sha256:$digest' ||
        response.headers.value('digest') !=
            'sha-256=${base64.encode(digest.bytes)}') {
      throw StateError('candidate API artifact bytes or digest mismatch');
    }
  }
}
