import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'persistence_timestamp.dart';
import 'event_repository.dart';
import 'sqlite_database.dart';

abstract interface class OperationRepository {
  Future<Operation> create({
    required String type,
    required ResourceType resourceType,
    required ResourceId resourceId,
    required RequestId requestId,
    String? idempotencyKey,
    required bool cancellable,
    required JsonObjectValue request,
    DateTime? deadlineAt,
  });

  Future<Operation?> get(OperationId id);

  Future<List<Operation>> list({
    ResourceType? resourceType,
    ResourceId? resourceId,
    OperationState? state,
  });

  Future<Operation> start(OperationId id, {OperationProgress? progress});

  Future<Operation> succeed(OperationId id, {JsonObjectValue? result});

  Future<Operation> fail(OperationId id, {required OperationError error});

  Future<Operation> setCancellable(OperationId id, {required bool cancellable});

  Future<Operation> cancel(OperationId id);
}

final class OperationNotFoundException implements Exception {
  const OperationNotFoundException(this.id);

  final OperationId id;

  @override
  String toString() => 'operation not found: $id';
}

final class InvalidOperationTransitionException implements Exception {
  const InvalidOperationTransitionException({
    required this.id,
    required this.from,
    required this.to,
  });

  final OperationId id;
  final OperationState from;
  final OperationState to;

  @override
  String toString() => 'invalid operation transition for $id: $from -> $to';
}

final class OperationNotCancellableException implements Exception {
  const OperationNotCancellableException(this.id);

  final OperationId id;

  @override
  String toString() => 'operation is not cancellable: $id';
}

final class SqliteOperationRepository implements OperationRepository {
  SqliteOperationRepository(
    this._database, {
    OperationId Function()? newOperationId,
    EventId Function()? newEventId,
    DateTime Function()? now,
  }) : _newOperationId = newOperationId ?? OperationId.generate,
       _newEventId = newEventId ?? EventId.generate,
       _now = now ?? DateTime.now;

  final GaoVmDatabase _database;
  final OperationId Function() _newOperationId;
  final EventId Function() _newEventId;
  final DateTime Function() _now;

  @override
  Future<Operation> create({
    required String type,
    required ResourceType resourceType,
    required ResourceId resourceId,
    required RequestId requestId,
    String? idempotencyKey,
    required bool cancellable,
    required JsonObjectValue request,
    DateTime? deadlineAt,
  }) {
    final operation = Operation(
      id: _newOperationId(),
      type: type,
      resourceType: resourceType,
      resourceId: resourceId,
      state: OperationState.pending,
      requestId: requestId,
      idempotencyKey: idempotencyKey,
      cancellable: cancellable,
      request: request,
      createdAt: _now().toUtc(),
      deadlineAt: deadlineAt,
    );
    return _database.transaction((connection) async {
      connection.execute(
        '''
          INSERT INTO operations(
            id, type, resource_type, resource_id, state, request_id,
            idempotency_key, cancellable, progress_json, request_json,
            result_json, error_json, created_at, started_at, completed_at,
            deadline_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          operation.id.value,
          operation.type,
          _resourceTypeName(operation.resourceType),
          operation.resourceId.value,
          operation.state.name,
          operation.requestId.value,
          operation.idempotencyKey,
          operation.cancellable ? 1 : 0,
          jsonEncode(operation.progress.toJson()),
          jsonEncode(operation.request.toJson()),
          null,
          null,
          formatPersistenceTimestamp(operation.createdAt),
          null,
          null,
          operation.deadlineAt == null
              ? null
              : formatPersistenceTimestamp(operation.deadlineAt!),
        ],
      );
      final stored = _require(connection, operation.id);
      _appendLifecycleEvent(
        connection,
        stored,
        lifecycle: _OperationLifecycle.created,
        occurredAt: stored.createdAt,
      );
      return stored;
    });
  }

  @override
  Future<Operation?> get(OperationId id) => _database.read((connection) {
    final rows = connection.select('SELECT * FROM operations WHERE id = ?', [
      id.value,
    ]);
    return rows.isEmpty ? null : _decodeOperation(rows.single);
  });

  @override
  Future<List<Operation>> list({
    ResourceType? resourceType,
    ResourceId? resourceId,
    OperationState? state,
  }) => _database.read((connection) {
    if (resourceId != null &&
        resourceType != null &&
        !resourceId.matchesResourceType(resourceType)) {
      throw ArgumentError('resourceType does not match resourceId');
    }
    final predicates = <String>[];
    final parameters = <Object?>[];
    if (resourceType != null) {
      predicates.add('resource_type = ?');
      parameters.add(_resourceTypeName(resourceType));
    }
    if (resourceId != null) {
      predicates.add('resource_id = ?');
      parameters.add(resourceId.value);
    }
    if (state != null) {
      predicates.add('state = ?');
      parameters.add(state.name);
    }
    final where = predicates.isEmpty ? '' : 'WHERE ${predicates.join(' AND ')}';
    return List<Operation>.unmodifiable(
      connection
          .select('''
              SELECT * FROM operations
              $where
              ORDER BY created_at, id
            ''', parameters)
          .map(_decodeOperation),
    );
  });

  @override
  Future<Operation> start(OperationId id, {OperationProgress? progress}) =>
      _database.transaction((connection) async {
        final current = _require(connection, id);
        _requireTransition(current, OperationState.running);
        final startedAt = _now().toUtc();
        connection.execute(
          '''
        UPDATE operations
        SET state = 'running', progress_json = ?, started_at = ?
        WHERE id = ?
      ''',
          [
            jsonEncode((progress ?? current.progress).toJson()),
            formatPersistenceTimestamp(startedAt),
            id.value,
          ],
        );
        final running = _require(connection, id);
        _appendLifecycleEvent(
          connection,
          running,
          lifecycle: _OperationLifecycle.started,
          occurredAt: startedAt,
        );
        return running;
      });

  @override
  Future<Operation> succeed(OperationId id, {JsonObjectValue? result}) =>
      _database.transaction((connection) async {
        final current = _require(connection, id);
        _requireTransition(current, OperationState.succeeded);
        final completedAt = _now().toUtc();
        connection.execute(
          '''
        UPDATE operations
        SET state = 'succeeded', cancellable = 0,
            result_json = ?, error_json = NULL,
            completed_at = ?
        WHERE id = ?
      ''',
          [
            result == null ? null : jsonEncode(result.toJson()),
            formatPersistenceTimestamp(completedAt),
            id.value,
          ],
        );
        final completed = _require(connection, id);
        _appendLifecycleEvent(
          connection,
          completed,
          lifecycle: _OperationLifecycle.completed,
          occurredAt: completedAt,
        );
        return completed;
      });

  @override
  Future<Operation> fail(OperationId id, {required OperationError error}) =>
      _database.transaction((connection) async {
        final current = _require(connection, id);
        _requireTransition(current, OperationState.failed);
        final completedAt = _now().toUtc();
        connection.execute(
          '''
        UPDATE operations
        SET state = 'failed', cancellable = 0,
            result_json = NULL, error_json = ?,
            completed_at = ?
        WHERE id = ?
      ''',
          [
            jsonEncode(error.toJson()),
            formatPersistenceTimestamp(completedAt),
            id.value,
          ],
        );
        final completed = _require(connection, id);
        _appendLifecycleEvent(
          connection,
          completed,
          lifecycle: _OperationLifecycle.completed,
          occurredAt: completedAt,
        );
        return completed;
      });

  @override
  Future<Operation> setCancellable(
    OperationId id, {
    required bool cancellable,
  }) => _database.transaction((connection) async {
    final current = _require(connection, id);
    if (_isTerminal(current.state)) {
      throw InvalidOperationTransitionException(
        id: id,
        from: current.state,
        to: current.state,
      );
    }
    connection.execute('UPDATE operations SET cancellable = ? WHERE id = ?', [
      cancellable ? 1 : 0,
      id.value,
    ]);
    final updated = _require(connection, id);
    final occurredAt = _now().toUtc();
    _appendLifecycleEvent(
      connection,
      updated,
      lifecycle: _OperationLifecycle.updated,
      occurredAt: occurredAt,
    );
    return updated;
  });

  @override
  Future<Operation> cancel(OperationId id) =>
      _database.transaction((connection) async {
        final current = _require(connection, id);
        _requireTransition(current, OperationState.cancelled);
        if (!current.cancellable) throw OperationNotCancellableException(id);
        final completedAt = _now().toUtc();
        connection.execute(
          '''
        UPDATE operations
        SET state = 'cancelled', cancellable = 0,
            result_json = NULL, error_json = NULL,
            completed_at = ?
        WHERE id = ?
      ''',
          [formatPersistenceTimestamp(completedAt), id.value],
        );
        final completed = _require(connection, id);
        _appendLifecycleEvent(
          connection,
          completed,
          lifecycle: _OperationLifecycle.completed,
          occurredAt: completedAt,
        );
        return completed;
      });

  void _appendLifecycleEvent(
    Database connection,
    Operation operation, {
    required _OperationLifecycle lifecycle,
    required DateTime occurredAt,
  }) {
    final vmId =
        operation.resourceType == ResourceType.virtualMachine &&
            _rowExists(connection, 'vms', operation.resourceId.value)
        ? operation.resourceId as VmId
        : null;
    final testRunId =
        operation.resourceType == ResourceType.testRun &&
            _rowExists(connection, 'test_runs', operation.resourceId.value)
        ? operation.resourceId as TestRunId
        : null;
    final payload = JsonObjectValue.fromJson({
      'state': operation.state.name,
      'cancellable': operation.cancellable,
      'progress': operation.progress.toJson(),
      'result': operation.result?.toJson(),
      'error': operation.error?.toJson(),
    });
    final eventId = _newEventId();
    final type = 'operation.${lifecycle.name}';
    connection.execute(
      '''
        INSERT INTO events(
          id, type, resource_type, resource_id, vm_id, operation_id,
          test_run_id, payload_json, occurred_at
        ) VALUES (?, ?, 'operation', ?, ?, ?, ?, ?, ?)
      ''',
      [
        eventId.value,
        type,
        operation.id.value,
        vmId?.value,
        operation.id.value,
        testRunId?.value,
        jsonEncode(payload.toJson()),
        formatPersistenceTimestamp(occurredAt),
      ],
    );
    final event = Event(
      sequence: connection.lastInsertRowId,
      eventId: eventId,
      type: type,
      resourceType: ResourceType.operation,
      resourceId: operation.id,
      vmId: vmId,
      operationId: operation.id,
      testRunId: testRunId,
      payload: payload,
      occurredAt: occurredAt,
    );
    connection.execute(
      '''
        INSERT INTO outbox(topic, key, payload_json, created_at)
        VALUES (?, ?, ?, ?)
      ''',
      [
        durableEventOutboxTopic,
        event.eventId.value,
        jsonEncode(event.toJson()),
        formatPersistenceTimestamp(occurredAt),
      ],
    );
  }

  Operation _require(Database connection, OperationId id) {
    final rows = connection.select('SELECT * FROM operations WHERE id = ?', [
      id.value,
    ]);
    if (rows.isEmpty) throw OperationNotFoundException(id);
    return _decodeOperation(rows.single);
  }

  void _requireTransition(Operation operation, OperationState target) {
    final valid = switch ((operation.state, target)) {
      (OperationState.pending, OperationState.running) => true,
      (OperationState.pending, OperationState.cancelled) => true,
      (OperationState.running, OperationState.succeeded) => true,
      (OperationState.running, OperationState.failed) => true,
      (OperationState.running, OperationState.cancelled) => true,
      _ => false,
    };
    if (!valid) {
      throw InvalidOperationTransitionException(
        id: operation.id,
        from: operation.state,
        to: target,
      );
    }
  }
}

bool _isTerminal(OperationState state) => switch (state) {
  OperationState.pending || OperationState.running => false,
  OperationState.succeeded ||
  OperationState.failed ||
  OperationState.cancelled => true,
};

bool _rowExists(Database connection, String table, String id) => connection
    .select('SELECT 1 FROM $table WHERE id = ? LIMIT 1', [id])
    .isNotEmpty;

enum _OperationLifecycle { created, started, updated, completed }

Operation _decodeOperation(Row row) => Operation.fromJson({
  'id': row['id'],
  'type': row['type'],
  'resource_type': row['resource_type'],
  'resource_id': row['resource_id'],
  'state': row['state'],
  'request_id': row['request_id'],
  'idempotency_key': row['idempotency_key'],
  'cancellable': row['cancellable'] == 1,
  'progress': jsonDecode(row['progress_json'] as String),
  'request': jsonDecode(row['request_json'] as String),
  'result': row['result_json'] == null
      ? null
      : jsonDecode(row['result_json'] as String),
  'error': row['error_json'] == null
      ? null
      : jsonDecode(row['error_json'] as String),
  'created_at': row['created_at'],
  'started_at': row['started_at'],
  'completed_at': row['completed_at'],
  'deadline_at': row['deadline_at'],
});

String _resourceTypeName(ResourceType value) => switch (value) {
  ResourceType.virtualMachine => 'virtual_machine',
  ResourceType.image => 'image',
  ResourceType.operation => 'operation',
  ResourceType.testRun => 'test_run',
  ResourceType.artifact => 'artifact',
  ResourceType.system => 'system',
};
