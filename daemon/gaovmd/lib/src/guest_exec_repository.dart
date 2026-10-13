import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'vm_controller_reducer.dart';

final class GuestExecAttemptSuperseded implements Exception {
  const GuestExecAttemptSuperseded();
}

/// Durable original execution binding. A reconnect must not replace it with a
/// new driver generation or turn a started attempt into a fresh exec.start.
final class GuestExecJob {
  const GuestExecJob({
    required this.operationId,
    required this.vmId,
    required this.driverGeneration,
    required this.specGeneration,
    required this.appliedIntentRevision,
    required this.createdAt,
    required this.startedAt,
    required this.attemptId,
    required this.controlEpochId,
    required this.cancellationRequested,
    required this.completedAt,
  });

  final OperationId operationId;
  final VmId vmId;
  final int driverGeneration;
  final int specGeneration;
  final int appliedIntentRevision;
  final DateTime createdAt;
  final DateTime? startedAt;
  final RequestId? attemptId;
  final RequestId? controlEpochId;
  final bool cancellationRequested;
  final DateTime? completedAt;
}

final class SqliteGuestExecRepository {
  SqliteGuestExecRepository(this._database, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final GaoVmDatabase _database;
  final DateTime Function() _now;

  /// No committed start marker means no worker was authorized to execute. This
  /// path cannot finish a started attempt or override accepted cancellation.
  Future<bool> failBeforeStart(
    OperationId id, {
    required OperationError error,
  }) async {
    if (_database.hasActiveCallerTransaction)
      throw StateError('guest pre-start failure must own its commit');
    return _database.transaction((db) async {
      final rows = db.select(
        '''
        SELECT 1 FROM guest_exec_jobs j JOIN operations o ON o.id = j.operation_id
        WHERE j.operation_id = ? AND j.started_at IS NULL AND j.completed_at IS NULL
          AND j.cancellation_requested = 0 AND o.type = 'guest.exec'
          AND o.resource_type = 'virtual_machine' AND o.resource_id = j.vm_id
          AND o.state = 'pending'
      ''',
        [id.value],
      );
      if (rows.isEmpty) return false;
      final now = _now().toUtc();
      db.execute(
        'UPDATE guest_exec_jobs SET completed_at = ? WHERE operation_id = ?',
        [formatPersistenceTimestamp(now), id.value],
      );
      final operations = SqliteOperationRepository(_database, now: () => now);
      await operations.start(id);
      await operations.fail(id, error: error);
      return true;
    });
  }

  /// Reads only durable receipts and committed host mappings. A missing sibling
  /// is incomplete, never permission to expose a guest ID or replay exec.start.
  Future<JsonObjectValue?> readTerminalResult(
    OperationId id,
    RequestId attemptId,
  ) => _database.read((db) => _readTerminalResult(db, id, attemptId));

  /// Internal evidence only: this snapshot can still contain private guest
  /// IDs and must never be returned as a public Operation result.
  Future<JsonObjectValue?> readTerminalSnapshot(
    OperationId id,
    RequestId attemptId,
  ) => _database.read((db) {
    final rows = db.select(
      "SELECT result_json FROM guest_artifact_receipts WHERE operation_id = ? AND attempt_id = ? AND source_kind = 'exec'",
      [id.value, attemptId.value],
    );
    return rows.isEmpty
        ? null
        : JsonObjectValue.fromJson(
            jsonDecode(rows.single['result_json'] as String),
          );
  });

  JsonObjectValue? _readTerminalResult(
    Database db,
    OperationId id,
    RequestId attemptId,
  ) {
    final rows = db.select(
      "SELECT id, result_json FROM guest_artifact_receipts WHERE operation_id = ? AND attempt_id = ? AND source_kind = 'exec'",
      [id.value, attemptId.value],
    );
    if (rows.isEmpty) return null;
    final json = Map<String, Object?>.from(
      jsonDecode(rows.single['result_json'] as String) as Map,
    );
    for (final output in ['stdout', 'stderr']) {
      final ref = Map<String, Object?>.from(json[output] as Map);
      if (ref['mode'] != 'artifact') continue;
      final mappings = db.select(
        'SELECT host_artifact_id FROM guest_artifact_mappings WHERE receipt_id = ? AND selector = ? AND guest_artifact_id = ?',
        [rows.single['id'], output, ref['artifact_id']],
      );
      if (mappings.isEmpty) return null;
      ref['artifact_id'] = mappings.single['host_artifact_id'];
      json[output] = ref;
    }
    return JsonObjectValue.fromJson(json);
  }

  /// Completes a known original result without live guest IO. The worker must
  /// join its owned transfer cleanup before releasing this VM's job admission.
  Future<bool> completeAttempt(
    OperationId id, {
    required RequestId attemptId,
    required RequestId controlEpochId,
  }) async {
    if (_database.hasActiveCallerTransaction)
      throw StateError('guest result completion must own its commit');
    return _database.transaction((db) async {
      final rows = db.select(
        '''
        SELECT 1 FROM guest_exec_jobs j JOIN operations o ON o.id = j.operation_id
        JOIN guest_artifact_receipts r ON r.operation_id = j.operation_id
        WHERE j.operation_id = ? AND j.attempt_id = ? AND j.control_epoch_id = ?
          AND j.started_at IS NOT NULL AND j.completed_at IS NULL
          AND r.source_kind = 'exec' AND r.attempt_id = j.attempt_id
          AND r.control_epoch_id = j.control_epoch_id AND r.vm_id = j.vm_id
          AND r.driver_generation = j.driver_generation
          AND o.type = 'guest.exec' AND o.resource_type = 'virtual_machine'
          AND o.resource_id = j.vm_id AND o.state = 'running'
      ''',
        [id.value, attemptId.value, controlEpochId.value],
      );
      if (rows.isEmpty) return false;
      final result = _readTerminalResult(db, id, attemptId);
      if (result == null) return false;
      final json = result.toJson();
      if (!const {'succeeded', 'failed', 'cancelled'}.contains(json['state']))
        return false;
      final now = _now().toUtc();
      db.execute(
        'UPDATE guest_exec_jobs SET completed_at = ? WHERE operation_id = ?',
        [formatPersistenceTimestamp(now), id.value],
      );
      final operations = SqliteOperationRepository(_database, now: () => now);
      if (json['state'] == 'succeeded') {
        await operations.succeed(id, result: result);
      } else if (json['state'] == 'cancelled') {
        await operations.cancel(id, result: result);
      } else {
        await operations.fail(
          id,
          result: result,
          error: OperationError(
            code: ErrorCode.guestExecFailed,
            message: 'Guest execution failed.',
            retryable: false,
            details: JsonObjectValue.fromJson({
              'exit_code': json['exit_code'],
              'timed_out': json['timed_out'],
              'signal': json['signal'],
            }),
          ),
        );
      }
      await _settleCancellationActions(db, operations, id);
      return true;
    });
  }

  /// A null start marker proves no worker was authorized to send exec.start.
  /// Only this pre-start path can confirm cancellation without guest cleanup.
  Future<bool> cancelBeforeStart(OperationId id) =>
      _database.transaction((connection) async {
        final rows = connection.select(
          '''
      SELECT 1 FROM guest_exec_jobs j JOIN operations o ON o.id = j.operation_id
      WHERE j.operation_id = ? AND j.cancellation_requested = 1
        AND j.started_at IS NULL AND j.completed_at IS NULL
        AND o.type = 'guest.exec' AND o.resource_type = 'virtual_machine'
        AND o.resource_id = j.vm_id AND o.state = 'pending'
    ''',
          [id.value],
        );
        if (rows.isEmpty) return false;
        final now = _now().toUtc();
        connection.execute(
          'UPDATE guest_exec_jobs SET completed_at = ? WHERE operation_id = ?',
          [formatPersistenceTimestamp(now), id.value],
        );
        final operations = SqliteOperationRepository(_database, now: () => now);
        await operations.cancel(id);
        await _settleCancellationActions(connection, operations, id);
        return true;
      });

  /// Settles only the original attempt. A late or duplicate callback cannot
  /// complete another owner, reopen a job, or alter the VM runtime checkpoint.
  Future<bool> failAttempt(
    OperationId id, {
    required RequestId attemptId,
    required OperationError error,
  }) => _database.transaction((connection) async {
    final rows = connection.select(
      '''
      SELECT 1 FROM guest_exec_jobs j JOIN operations o ON o.id = j.operation_id
      WHERE j.operation_id = ? AND j.attempt_id = ? AND j.completed_at IS NULL
        AND o.type = 'guest.exec' AND o.resource_type = 'virtual_machine'
        AND o.resource_id = j.vm_id AND o.state = 'running'
    ''',
      [id.value, attemptId.value],
    );
    if (rows.isEmpty) return false;
    final now = _now().toUtc();
    connection.execute(
      'UPDATE guest_exec_jobs SET completed_at = ? WHERE operation_id = ?',
      [formatPersistenceTimestamp(now), id.value],
    );
    final operations = SqliteOperationRepository(_database, now: () => now);
    await operations.fail(id, error: error);
    await _settleCancellationActions(connection, operations, id, error: error);
    return true;
  });

  Future<void> _settleCancellationActions(
    Database connection,
    SqliteOperationRepository operations,
    OperationId id, {
    OperationError? error,
  }) async {
    final actions = connection.select(
      'SELECT action_id FROM guest_exec_cancellations WHERE target_id = ? ORDER BY action_id',
      [id.value],
    );
    for (final row in actions) {
      final action = (await operations.get(
        OperationId(row['action_id'] as String),
      ))!;
      if (action.type != 'operation.cancel' ||
          action.resourceType != ResourceType.operation ||
          action.resourceId != id ||
          (action.state != OperationState.pending &&
              action.state != OperationState.running)) {
        throw StateError(
          'guest exec cancellation action does not match its target',
        );
      }
      if (action.state == OperationState.pending)
        await operations.start(action.id);
      if (error == null) {
        await operations.succeed(
          action.id,
          result: JsonObjectValue.fromJson({'target_operation_id': id.value}),
        );
      } else {
        await operations.fail(action.id, error: error);
      }
    }
  }

  /// Called through the existing VM controller's short write gate. The durable
  /// one-shot marker precedes all guest IO, including an uncertain first write.
  Future<GuestExecJob?> beginAttempt(
    OperationId id, {
    required RequestId attemptId,
    required VmControllerState executionState,
    required RequestId controlEpochId,
    required bool Function() stillCurrent,
    DateTime? deadlineAt,
  }) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('guest exec attempt must own its commit boundary');
    }
    return _database.transaction((connection) async {
      if (!stillCurrent()) return null;
      final state = executionState;
      if (state.phase != VmPhase.running ||
          state.desiredState != DesiredState.running ||
          state.deletionState != VmDeletionState.active ||
          state.activeDriverGeneration == null ||
          state.activeDriverGeneration != state.driverGeneration ||
          state.activeSpecGeneration == null ||
          (state.currentOperation != null &&
              !state.currentOperation!.isTerminal))
        return null;
      final rows = connection.select(
        '''
      SELECT j.operation_id FROM guest_exec_jobs j
      JOIN operations o ON o.id = j.operation_id
      JOIN vms v ON v.id = j.vm_id JOIN vm_runtime r ON r.vm_id = j.vm_id
      WHERE j.operation_id = ? AND j.vm_id = ? AND j.started_at IS NULL AND j.completed_at IS NULL
        AND j.cancellation_requested = 0
        AND j.driver_generation = ? AND j.spec_generation = ? AND j.applied_intent_revision = ?
        AND r.driver_generation = j.driver_generation AND r.observed_generation = j.spec_generation
        AND r.applied_intent_revision = j.applied_intent_revision
        AND r.phase = 'running' AND r.desired_state = 'running' AND r.guest_agent = 'ready'
        AND v.deleting_at IS NULL AND v.deleted_at IS NULL
        AND o.type = 'guest.exec' AND o.resource_type = 'virtual_machine' AND o.resource_id = j.vm_id
        AND o.state = 'pending'
        AND NOT EXISTS (
          SELECT 1 FROM test_run_step_execs e
          JOIN test_runs t ON t.id = e.test_run_id
          JOIN test_steps s ON s.test_run_id = e.test_run_id AND s.step_index = e.step_index
          JOIN operations p ON p.id = t.operation_id
          WHERE e.operation_id = j.operation_id AND (
            t.state <> 'running_steps' OR t.cancel_requested <> 0 OR t.vm_id <> j.vm_id
            OR s.state <> 'running' OR p.state <> 'running' OR p.type <> 'test.run'
            OR p.resource_type <> 'test_run' OR p.resource_id <> t.id
            OR v.intent_revision <> j.applied_intent_revision OR v.spec_generation <> j.spec_generation
            OR (p.deadline_at IS NOT NULL AND p.deadline_at <= ?)
          )
        )
    ''',
        [
          id.value,
          state.vmId.value,
          state.activeDriverGeneration,
          state.activeSpecGeneration,
          state.appliedIntentRevision,
          formatPersistenceTimestamp(_now().toUtc()),
        ],
      );
      if (rows.isEmpty) return null;
      final now = _now().toUtc();
      connection.execute(
        '''
      UPDATE guest_exec_jobs SET started_at = ?, attempt_id = ?, control_epoch_id = ? WHERE operation_id = ? AND started_at IS NULL
    ''',
        [
          formatPersistenceTimestamp(now),
          attemptId.value,
          controlEpochId.value,
          id.value,
        ],
      );
      if (deadlineAt != null)
        connection.execute(
          'UPDATE operations SET deadline_at = ? WHERE id = ?',
          [formatPersistenceTimestamp(deadlineAt), id.value],
        );
      await SqliteOperationRepository(_database, now: () => now).start(id);
      // An epoch can close while nested durable writes yield. Its started marker,
      // operation transition and event must all roll back in that case.
      if (!stillCurrent()) throw const GuestExecAttemptSuperseded();
      final job = await get(id);
      if (!stillCurrent()) throw const GuestExecAttemptSuperseded();
      return job;
    });
  }

  Future<GuestExecJob?> get(OperationId id) => _database.read((connection) {
    final rows = connection.select(
      'SELECT * FROM guest_exec_jobs WHERE operation_id = ?',
      [id.value],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return GuestExecJob(
      operationId: OperationId(row['operation_id'] as String),
      vmId: VmId(row['vm_id'] as String),
      driverGeneration: row['driver_generation'] as int,
      specGeneration: row['spec_generation'] as int,
      appliedIntentRevision: row['applied_intent_revision'] as int,
      createdAt: DateTime.parse(row['created_at'] as String),
      startedAt: row['started_at'] == null
          ? null
          : DateTime.parse(row['started_at'] as String),
      attemptId: row['attempt_id'] == null
          ? null
          : RequestId(row['attempt_id'] as String),
      controlEpochId: row['control_epoch_id'] == null
          ? null
          : RequestId(row['control_epoch_id'] as String),
      cancellationRequested: row['cancellation_requested'] == 1,
      completedAt: row['completed_at'] == null
          ? null
          : DateTime.parse(row['completed_at'] as String),
    );
  });
}
