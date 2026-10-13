import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'artifact_application_service.dart';
import 'event_repository.dart';
import 'guest_bridge_client.dart';
import 'host_guest_artifacts.dart';
import 'host_guest_session.dart';
import 'image_filesystem.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';
import 'test_run_step_artifact_collector.dart';
import 'vm_bundle_manifest.dart';
import 'vm_provisioning_repository.dart';
import 'vm_repository.dart';

const _maxLogBytes = 64 * 1024 * 1024;

final class TestRunCollectionOutcome {
  const TestRunCollectionOutcome({
    required this.testRunId,
    required this.operationId,
    required this.requestId,
    required this.vmId,
    required this.collected,
    this.driverGeneration,
    this.error,
  });
  final TestRunId testRunId;
  final OperationId operationId;
  final RequestId requestId;
  final VmId? vmId;
  final bool collected;
  final int? driverGeneration;
  final Object? error;
}

/// Collection never controls a driver or removes a VM. Its durable completion
/// attests managed artifact publication, not execution or cleanup completion.
final class TestRunCollectionWorker {
  TestRunCollectionWorker({
    required this.database,
    required this.bundles,
    required this.artifacts,
    this.guestBudget,
    this.resolveGuestConnection,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (!identical(database, artifacts.database))
      throw ArgumentError('collection catalog differs');
    if (resolveGuestConnection != null && guestBudget == null)
      throw ArgumentError('guest collection requires the shared budget');
  }
  final GaoVmDatabase database;
  final OwnedImageDirectory bundles;
  final ArtifactApplicationService artifacts;
  final GuestArtifactBudget? guestBudget;
  final GuestControlConnection? Function(VmId, int)? resolveGuestConnection;
  final DateTime Function() _now;
  TestRunId? _cursor;
  final Set<HostGuestArtifactService> _guestOwners = {};
  Future<List<TestRunCollectionOutcome>>? _dispatchFuture;
  bool _closed = false;
  Future<void>? _closeFuture;
  Future<void>? _recovery;
  bool _recovered = false;
  bool _hasRun = false;

  Future<List<TestRunCollectionOutcome>> dispatchOnce({int limit = 100}) {
    if (limit < 1 || limit > 200)
      throw RangeError.range(limit, 1, 200, 'limit');
    if (database.hasActiveCallerTransaction)
      throw StateError('TestRun collection must own its commit boundary');
    if (_closed) return Future.value(const []);
    return _dispatchFuture ??= _dispatch(
      limit,
    ).whenComplete(() => _dispatchFuture = null);
  }

  Future<List<TestRunCollectionOutcome>> _dispatch(int limit) async {
    if (_recovery != null && !_recovered)
      throw StateError('TestRun diagnostic recovery has not succeeded');
    _hasRun = true;
    final items = await database.read((db) {
      const query = '''
        SELECT t.id, t.operation_id, t.vm_id, o.request_id, r.driver_generation
        FROM test_runs t JOIN operations o ON o.id = t.operation_id
        LEFT JOIN test_run_collection c ON c.test_run_id = t.id
        LEFT JOIN vm_runtime r ON r.vm_id = t.vm_id
        WHERE t.state = 'collecting' AND c.completed_at IS NULL AND t.id > ?
        ORDER BY t.id LIMIT ?
      ''';
      var rows = db.select(query, [_cursor?.value ?? '', limit]);
      if (rows.isEmpty && _cursor != null) rows = db.select(query, ['', limit]);
      return [
        for (final row in rows)
          (
            id: TestRunId(row['id'] as String),
            operation: OperationId(row['operation_id'] as String),
            request: RequestId(row['request_id'] as String),
            vm: row['vm_id'] == null ? null : VmId(row['vm_id'] as String),
            generation: row['driver_generation'] as int? ?? 0,
          ),
      ];
    });
    _cursor = items.lastOrNull?.id;
    return List.unmodifiable(
      await Future.wait(
        items.map((item) async {
          Object? failure;
          var collected = false;
          try {
            await bundles.verifyPathBinding();
            if (bundles.mode & 0x3f != 0)
              throw StateError('VM root must be private');
            final lock = await bundles.acquireLock(
              '.lock-' + (item.vm?.value ?? item.id.value),
            );
            try {
              if (_closed)
                return TestRunCollectionOutcome(
                  testRunId: item.id,
                  operationId: item.operation,
                  requestId: item.request,
                  vmId: item.vm,
                  collected: false,
                  driverGeneration: item.generation > 0
                      ? item.generation
                      : null,
                );
              collected = await _collect(item.id);
            } finally {
              lock.close();
            }
          } catch (error) {
            failure = error;
          }
          return TestRunCollectionOutcome(
            testRunId: item.id,
            operationId: item.operation,
            requestId: item.request,
            vmId: item.vm,
            driverGeneration: item.generation > 0 ? item.generation : null,
            collected: collected,
            error: failure,
          );
        }),
      ),
    );
  }

  Future<_CollectionPlan?> _reserve(TestRunId id) => database.transaction((
    db,
  ) async {
    final run = await SqliteTestRunRepository(database).get(id);
    if (run == null || run.state != TestRunState.collecting) return null;
    final parent = await SqliteOperationRepository(
      database,
    ).get(run.operationId);
    if (parent == null ||
        parent.state != OperationState.running ||
        parent.type != 'test.run' ||
        parent.resourceId != id)
      throw StateError('TestRun collection operation is not active');
    var rows = db.select(
      'SELECT * FROM test_run_collection WHERE test_run_id = ?',
      [id.value],
    );
    if (rows.isEmpty) {
      final outcome = db.select(
        'SELECT planned_outcome FROM test_runs WHERE id = ?',
        [id.value],
      ).single['planned_outcome'];
      if (outcome == null) throw StateError('TestRun has no execution outcome');
      final vm = run.vmId == null
          ? null
          : await SqliteVmRepository(
              database,
            ).get(run.vmId!, includeDeleted: true);
      final originalStart = db.select(
        'SELECT driver_generation FROM test_run_vm_start WHERE test_run_id = ?',
        [id.value],
      ).singleOrNull;
      // The report describes original execution, not a replacement generation
      // observed later during collection/recovery. Log records keep their tags.
      final generation =
          originalStart?['driver_generation'] as int? ??
          vm?.status.driverGeneration ??
          0;
      final snapshot = JsonObjectValue.fromJson({
        'format': 'gaovm.test-result.v1',
        'test_run_id': id.value,
        'vm_id': run.vmId?.value,
        'operation_id': run.operationId.value,
        'request_id': parent.requestId.value,
        'driver_generation': generation > 0 ? generation : null,
        'execution_outcome': outcome,
        'execution': run.toJson(),
      });
      // Cleanup may still fail. Do not expire diagnostics on the shorter
      // successful-run schedule before its final outcome is known.
      final retention = _now().toUtc().add(const Duration(days: 30));
      db.execute(
        '''
        INSERT INTO test_run_collection(test_run_id, snapshot_json, retention_until)
        VALUES (?, ?, ?)
      ''',
        [
          id.value,
          jsonEncode(snapshot.toJson()),
          formatPersistenceTimestamp(retention),
        ],
      );
      for (final kind in [
        ArtifactKind.driver,
        ArtifactKind.serial,
        ArtifactKind.result,
      ]) {
        db.execute(
          '''
          INSERT INTO test_run_collection_items(test_run_id, kind, artifact_id)
          VALUES (?, ?, ?)
        ''',
          [id.value, kind.name, ArtifactId.generate().value],
        );
      }
      await SqliteEventRepository(database, now: _now).append(
        type: 'test_run.collection_planned',
        resourceType: ResourceType.testRun,
        resourceId: id,
        testRunId: id,
        vmId: run.vmId,
        operationId: run.operationId,
        payload: JsonObjectValue.empty,
      );
      rows = db.select(
        'SELECT * FROM test_run_collection WHERE test_run_id = ?',
        [id.value],
      );
    }
    if (rows.single['completed_at'] != null) return null;
    return _CollectionPlan(
      run,
      JsonObjectValue.fromJson(
        jsonDecode(rows.single['snapshot_json'] as String),
      ),
      DateTime.parse(rows.single['retention_until'] as String).toUtc(),
    );
  });

  Future<bool> _collect(TestRunId id) async {
    final plan = await _reserve(id);
    if (plan == null) return false;
    final systemInfo = await _systemInfo(plan);
    final stepCollector = TestRunStepArtifactCollector(
      database: database,
      artifacts: artifacts,
    );
    final stepArtifacts = await stepCollector.collect(
      run: plan.run,
      snapshot: plan.snapshot,
      retentionUntil: plan.retention,
      isActive: () => !_closed,
    );
    for (final slot in await _slots(id)) {
      if (_closed) return false;
      if (slot.state != 'pending') continue;
      if (slot.kind != ArtifactKind.result) {
        await _collectLog(plan, slot);
        continue;
      }
      final report = {
        ...plan.snapshot.toJson(),
        ...stepArtifacts.toJson(),
        'system_info': systemInfo.toJson(),
        'collection': [
          for (final item in await _slots(id))
            if (item.kind != ArtifactKind.result)
              {
                'kind': item.kind.name,
                'state': item.state,
                'artifact_id': item.state == 'published' ? item.id.value : null,
                if (item.error != null) 'error': item.error!.toJson(),
              },
        ],
      };
      await artifacts.publish(
        artifactId: slot.id,
        bytes: Stream.value(utf8.encode(jsonEncode(report))),
        kind: ArtifactKind.result,
        contentType: 'application/json',
        maxBytes: 16 * 1024 * 1024,
        vmId: plan.run.vmId,
        operationId: plan.run.operationId,
        testRunId: id,
        retentionUntil: plan.retention,
      );
      await _finishSlot(plan.run, slot, 'published');
    }
    for (final slot in await _slots(id)) {
      if (slot.state != 'published') continue;
      final verified = (await artifacts.download(slot.id)).artifact;
      if (verified.testRunId != id ||
          verified.operationId != plan.run.operationId ||
          verified.vmId != plan.run.vmId ||
          verified.kind != slot.kind)
        throw StateError('TestRun artifact ownership differs');
    }
    await stepCollector.verify(plan.run, isActive: () => !_closed);
    await database.transaction((db) async {
      final run = await SqliteTestRunRepository(database).get(id);
      if (run == null || run.state != TestRunState.collecting)
        throw StateError('TestRun left collection');
      if (db
          .select(
            '''
        SELECT 1 FROM test_run_collection_items
        WHERE test_run_id = ? AND state = 'pending'
      ''',
            [id.value],
          )
          .isNotEmpty)
        throw StateError('TestRun collection is unfinished');
      db.execute(
        '''
        UPDATE test_run_collection SET completed_at = ? WHERE test_run_id = ?
      ''',
        [formatPersistenceTimestamp(_now().toUtc()), id.value],
      );
      await SqliteEventRepository(database, now: _now).append(
        type: 'test_run.artifacts_collected',
        resourceType: ResourceType.testRun,
        resourceId: id,
        testRunId: id,
        vmId: run.vmId,
        operationId: run.operationId,
        payload: JsonObjectValue.fromJson({
          'artifact_ids': run.artifactIds.map((id) => id.value).toList(),
        }),
      );
    });
    return true;
  }

  Future<JsonObjectValue> _systemInfo(
    _CollectionPlan plan, {
    bool allowGuestIO = true,
  }) async {
    final stored = await database.read(
      (db) => db.select(
        'SELECT system_info_json FROM test_run_collection WHERE test_run_id = ?',
        [plan.run.id.value],
      ).single['system_info_json'],
    );
    if (stored != null)
      return JsonObjectValue.fromJson(jsonDecode(stored as String));
    final previous = await database.read(
      (db) => db.select(
        "SELECT * FROM guest_diagnostic_attempts WHERE operation_id = ? AND method = 'system.info'",
        [plan.run.operationId.value],
      ).singleOrNull,
    );
    JsonObjectValue outcome;
    if (previous != null) {
      if (previous['completed_at'] == null)
        throw StateError('original system info owner has not retired');
      outcome = previous['result_json'] == null
          ? _unavailableSystemInfo('original_attempt_unavailable')
          : JsonObjectValue.fromJson({
              'state': 'collected',
              'vm_id': previous['vm_id'],
              'driver_generation': previous['driver_generation'],
              'result': jsonDecode(previous['result_json'] as String),
            });
    } else if (!allowGuestIO) {
      outcome = _unavailableSystemInfo('daemon_restarted_before_diagnostics');
    } else {
      final start = await database.read(
        (db) => db.select(
          'SELECT vm_id, driver_generation FROM test_run_vm_start WHERE test_run_id = ?',
          [plan.run.id.value],
        ).singleOrNull,
      );
      HostGuestArtifactService? owner;
      try {
        if (_closed) throw StateError('collection is closed');
        final vm = plan.run.vmId;
        final generation = start?['driver_generation'] as int?;
        final connection = vm == null || generation == null || generation < 1
            ? null
            : resolveGuestConnection?.call(vm, generation);
        if (connection == null) {
          outcome = _unavailableSystemInfo('original_guest_unavailable');
        } else {
          owner = HostGuestArtifactService(
            database: database,
            artifacts: artifacts,
            budget: guestBudget!,
          );
          _guestOwners.add(owner);
          final info = await owner.captureSystemInfo(
            connection: connection,
            operationId: plan.run.operationId,
            deadline: GuestBridgeDeadline.after(const Duration(seconds: 5)),
          );
          outcome = JsonObjectValue.fromJson({
            'state': 'collected',
            'vm_id': vm!.value,
            'driver_generation': generation,
            'result': info.toJson(),
          });
        }
      } catch (error) {
        outcome = _unavailableSystemInfo('${error.runtimeType}');
      } finally {
        if (owner != null) {
          await owner.close();
          _guestOwners.remove(owner);
        }
      }
    }
    if (_closed) throw StateError('collection is closed');
    return database.transaction((db) {
      final rows = db.select(
        '''
        SELECT c.system_info_json FROM test_run_collection c JOIN test_runs t ON t.id = c.test_run_id
        WHERE c.test_run_id = ? AND t.state = 'collecting' AND c.completed_at IS NULL
      ''',
        [plan.run.id.value],
      );
      if (rows.isEmpty) throw StateError('TestRun left system info collection');
      if (rows.single['system_info_json'] != null)
        return JsonObjectValue.fromJson(
          jsonDecode(rows.single['system_info_json'] as String),
        );
      // Another owner may win the claim after the initial lookup. The final
      // checkpoint must prove its retirement atomically, not turn that failed
      // local claim into permission for cleanup while foreign RPC is live.
      final latest = db.select(
        "SELECT * FROM guest_diagnostic_attempts WHERE operation_id = ? AND method = 'system.info'",
        [plan.run.operationId.value],
      ).singleOrNull;
      if (latest != null) {
        if (latest['completed_at'] == null)
          throw StateError('original system info owner has not retired');
        outcome = latest['result_json'] == null
            ? _unavailableSystemInfo('original_attempt_unavailable')
            : JsonObjectValue.fromJson({
                'state': 'collected',
                'vm_id': latest['vm_id'],
                'driver_generation': latest['driver_generation'],
                'result': jsonDecode(latest['result_json'] as String),
              });
      }
      db.execute(
        'UPDATE test_run_collection SET system_info_json = ? WHERE test_run_id = ?',
        [jsonEncode(outcome.toJson()), plan.run.id.value],
      );
      return outcome;
    });
  }

  JsonObjectValue _unavailableSystemInfo(String reason) =>
      JsonObjectValue.fromJson({'state': 'unavailable', 'reason': reason});

  /// Startup-only: all old guest/driver owners must actually retire before a
  /// missing reply can be declared unknown. No resolver or fresh RPC is used.
  Future<void> recoverInterrupted({
    required Future<void> Function() retireOriginalOwners,
  }) {
    if (_closed || _hasRun)
      throw StateError(
        'diagnostic recovery must precede collection activation',
      );
    return _recovery ??= _recoverInterrupted(
      retireOriginalOwners,
    ).then((_) => _recovered = true);
  }

  Future<void> _recoverInterrupted(
    Future<void> Function() retireOriginalOwners,
  ) async {
    await retireOriginalOwners();
    if (_closed) throw StateError('diagnostic recovery is closed');
    await database.transaction((db) {
      db.execute(
        '''
        UPDATE guest_diagnostic_attempts SET error_json = ?, completed_at = ? WHERE completed_at IS NULL
      ''',
        [
          jsonEncode({
            'outcome': 'unknown',
            'reason': 'daemon_restarted_after_authorization',
          }),
          formatPersistenceTimestamp(_now().toUtc()),
        ],
      );
    });
    var cursor = '';
    while (!_closed) {
      final ids = await database.read(
        (db) => [
          for (final row in db.select(
            '''
        SELECT t.id FROM test_runs t LEFT JOIN test_run_collection c ON c.test_run_id = t.id
        WHERE t.state = 'collecting' AND c.completed_at IS NULL AND t.id > ? ORDER BY t.id LIMIT 100
      ''',
            [cursor],
          ))
            TestRunId(row['id'] as String),
        ],
      );
      if (ids.isEmpty) return;
      for (final id in ids) {
        if (_closed) throw StateError('diagnostic recovery is closed');
        cursor = id.value;
        final plan = await _reserve(id);
        if (plan != null) await _systemInfo(plan, allowGuestIO: false);
      }
    }
    throw StateError('diagnostic recovery is closed');
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closed = true;
    try {
      await Future.wait(_guestOwners.toList().map((owner) => owner.close()));
    } finally {
      // The recovery caller observes its failure. Shutdown still joins it.
      await _recovery?.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      );
      await _dispatchFuture;
    }
  }

  Future<void> _collectLog(_CollectionPlan plan, _CollectionSlot slot) async {
    // Publication may have committed before the worker checkpoint. Replay its
    // reserved identity before inspecting a possibly rotated/deleted source.
    if (await artifacts.repository.get(slot.id) != null) {
      await _publishLog(plan, slot, const Stream.empty());
      await _finishSlot(plan.run, slot, 'published');
      return;
    }
    final List<OwnedImageFile> files;
    try {
      files = await _openLogs(plan.run, slot.kind);
    } catch (error) {
      if (error is! FileSystemException &&
          error is! FormatException &&
          error is! StateError)
        rethrow;
      await _sourceFailed(plan.run, slot, error);
      return;
    }
    try {
      if (files.isEmpty) {
        await _finishSlot(plan.run, slot, 'absent');
        return;
      }
      final size = files.fold<int>(0, (size, file) => size + file.size);
      if (size > _maxLogBytes) {
        await _sourceFailed(
          plan.run,
          slot,
          ArtifactSizeLimitExceeded(_maxLogBytes),
        );
        return;
      }
      try {
        await _publishLog(
          plan,
          slot,
          _snapshotBytes(files),
          expectedSize: size,
        );
      } on _LogSourceFailure catch (error) {
        await _sourceFailed(plan.run, slot, error.cause);
        return;
      }
      await _finishSlot(plan.run, slot, 'published');
    } finally {
      for (final file in files) file.close();
    }
  }

  Future<void> _sourceFailed(TestRun run, _CollectionSlot slot, Object cause) =>
      _finishSlot(
        run,
        slot,
        'failed',
        error: OperationError(
          code: ErrorCode.internalError,
          message: 'Unable to collect a TestRun log source.',
          retryable: false,
          details: JsonObjectValue.fromJson({
            'phase': 'collecting',
            'source': slot.kind.name,
            'vm_id': run.vmId?.value,
            'cause_type': '${cause.runtimeType}',
          }),
        ),
      );

  Future<Artifact> _publishLog(
    _CollectionPlan plan,
    _CollectionSlot slot,
    Stream<List<int>> bytes, {
    int? expectedSize,
  }) => artifacts.publish(
    artifactId: slot.id,
    bytes: bytes,
    kind: slot.kind,
    contentType: 'application/octet-stream',
    maxBytes: _maxLogBytes,
    expectedSizeBytes: expectedSize,
    vmId: plan.run.vmId,
    operationId: plan.run.operationId,
    testRunId: plan.run.id,
    retentionUntil: plan.retention,
  );

  Future<List<OwnedImageFile>> _openLogs(TestRun run, ArtifactKind kind) async {
    final vmId = run.vmId;
    if (vmId == null) return const [];
    final owned = await database.read(
      (db) => db
          .select(
            '''
      SELECT 1 FROM test_run_vm_provisioning WHERE test_run_id = ? AND vm_id = ?
    ''',
            [run.id.value, vmId.value],
          )
          .isNotEmpty,
    );
    if (!owned) throw StateError('TestRun has no VM provisioning ownership');
    final job = await SqliteVmProvisioningRepository(database).get(vmId);
    if (job == null)
      throw StateError('TestRun VM provisioning plan is missing');
    final root = bundles.directoryOrNull(vmId.value + '.gaovm');
    if (root == null) {
      final vm = await SqliteVmRepository(
        database,
      ).get(vmId, includeDeleted: true);
      if (job.completion?.kind == VmProvisioningCompletionKind.succeeded &&
          vm?.status.phase != VmPhase.deleted)
        throw StateError('Published TestRun VM bundle is missing');
      return const [];
    }
    final files = <OwnedImageFile>[];
    try {
      await root.verifyPathBinding();
      final manifestFile = root.file('manifest.json');
      try {
        final manifest = VmBundleManifest.fromJson(
          jsonDecode(utf8.decode(await manifestFile.readBounded(1024 * 1024))),
        );
        if (manifest.digest != VmBundleManifest.create(job.plan).digest)
          throw StateError('TestRun VM bundle origin differs');
      } finally {
        manifestFile.close();
      }
      final logs = root.directory('logs');
      try {
        await logs.verifyPathBinding();
        final name = kind == ArtifactKind.driver ? 'driver.log' : 'serial.log';
        for (final leaf in [name + '.3', name + '.2', name + '.1', name]) {
          final file = logs.fileOrNull(leaf);
          if (file != null) files.add(file);
        }
        return files;
      } finally {
        logs.close();
      }
    } catch (_) {
      for (final file in files) file.close();
      rethrow;
    } finally {
      root.close();
    }
  }

  Future<List<_CollectionSlot>> _slots(TestRunId id) => database.read(
    (db) => [
      for (final row in db.select(
        '''
      SELECT * FROM test_run_collection_items WHERE test_run_id = ?
      ORDER BY CASE kind WHEN 'driver' THEN 0 WHEN 'serial' THEN 1 ELSE 2 END
    ''',
        [id.value],
      ))
        _CollectionSlot(
          ArtifactKind.values.byName(row['kind'] as String),
          ArtifactId(row['artifact_id'] as String),
          row['state'] as String,
          row['error_json'] == null
              ? null
              : OperationError.fromJson(
                  jsonDecode(row['error_json'] as String),
                ),
        ),
    ],
  );

  Future<void> _finishSlot(
    TestRun run,
    _CollectionSlot slot,
    String state, {
    OperationError? error,
  }) => database.transaction((db) async {
    final current = await SqliteTestRunRepository(database).get(run.id);
    if (current == null || current.state != TestRunState.collecting)
      throw StateError('TestRun left collection');
    final stored = db.select(
      'SELECT state FROM test_run_collection_items WHERE test_run_id = ? AND kind = ?',
      [run.id.value, slot.kind.name],
    ).single['state'];
    if (stored == state) return;
    if (stored != 'pending')
      throw StateError('TestRun collection slot changed');
    if (error != null)
      await SqliteTestRunRepository(
        database,
        now: _now,
      ).recordFailure(run.id, error: error);
    db.execute(
      '''
      UPDATE test_run_collection_items SET state = ?, error_json = ?
      WHERE test_run_id = ? AND kind = ? AND state = 'pending'
    ''',
      [
        state,
        error == null ? null : jsonEncode(error.toJson()),
        run.id.value,
        slot.kind.name,
      ],
    );
    await SqliteEventRepository(database, now: _now).append(
      type: state == 'published'
          ? 'test_run.artifact_collected'
          : 'test_run.artifact_unavailable',
      resourceType: ResourceType.testRun,
      resourceId: run.id,
      testRunId: run.id,
      vmId: run.vmId,
      operationId: run.operationId,
      payload: JsonObjectValue.fromJson({
        'kind': slot.kind.name,
        'state': state,
        if (state == 'published') 'artifact_id': slot.id.value,
        if (error != null) 'error': error.toJson(),
      }),
    );
  });
}

final class _CollectionPlan {
  const _CollectionPlan(this.run, this.snapshot, this.retention);
  final TestRun run;
  final JsonObjectValue snapshot;
  final DateTime retention;
}

final class _CollectionSlot {
  const _CollectionSlot(this.kind, this.id, this.state, this.error);
  final ArtifactKind kind;
  final ArtifactId id;
  final String state;
  final OperationError? error;
}

final class _LogSourceFailure implements Exception {
  const _LogSourceFailure(this.cause);
  final Object cause;
}

/// Bound each held inode to the length observed when collection opened it.
/// Appending to a running VM log cannot extend this snapshot indefinitely.
Stream<List<int>> _snapshotBytes(List<OwnedImageFile> files) async* {
  try {
    for (final file in files) {
      var remaining = file.size;
      if (remaining == 0) continue;
      await for (final chunk in file.openRead()) {
        final length = chunk.length < remaining ? chunk.length : remaining;
        yield length == chunk.length ? chunk : chunk.sublist(0, length);
        remaining -= length;
        if (remaining == 0) break;
      }
      if (remaining != 0)
        throw StateError('VM log was truncated during collection');
    }
  } on FileSystemException catch (error) {
    throw _LogSourceFailure(error);
  } on StateError catch (error) {
    throw _LogSourceFailure(error);
  }
}
