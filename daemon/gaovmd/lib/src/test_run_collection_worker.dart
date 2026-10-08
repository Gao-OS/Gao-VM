import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'artifact_application_service.dart';
import 'event_repository.dart';
import 'image_filesystem.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';
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
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final GaoVmDatabase database;
  final OwnedImageDirectory bundles;
  final ArtifactApplicationService artifacts;
  final DateTime Function() _now;
  TestRunId? _cursor;

  Future<List<TestRunCollectionOutcome>> dispatchOnce({int limit = 100}) async {
    if (limit < 1 || limit > 200)
      throw RangeError.range(limit, 1, 200, 'limit');
    if (database.hasActiveCallerTransaction)
      throw StateError('TestRun collection must own its commit boundary');
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
      final generation = vm?.status.driverGeneration ?? 0;
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
    for (final slot in await _slots(id)) {
      if (slot.state != 'pending') continue;
      if (slot.kind != ArtifactKind.result) {
        await _collectLog(plan, slot);
        continue;
      }
      final report = {
        ...plan.snapshot.toJson(),
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
