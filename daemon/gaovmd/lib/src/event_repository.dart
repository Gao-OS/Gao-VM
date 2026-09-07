import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'persistence_timestamp.dart';
import 'sqlite_database.dart';

const durableEventOutboxTopic = 'events';

final class OutboxRecord {
  const OutboxRecord({
    required this.id,
    required this.topic,
    required this.key,
    required this.payload,
    required this.createdAt,
    required this.publishedAt,
    required this.attempts,
    required this.claimedBy,
    required this.claimExpiresAt,
  });

  final int id;
  final String topic;
  final String key;
  final JsonObjectValue payload;
  final DateTime createdAt;
  final DateTime? publishedAt;
  final int attempts;
  final String? claimedBy;
  final DateTime? claimExpiresAt;
}

abstract interface class EventRepository {
  Future<Event> append({
    required String type,
    required ResourceType resourceType,
    ResourceId? resourceId,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
    required JsonObjectValue payload,
    DateTime? occurredAt,
  });

  Future<Event?> get(EventId id);

  Future<List<Event>> list({
    int after = 0,
    ResourceType? resourceType,
    ResourceId? resourceId,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
  });

  Future<List<OutboxRecord>> readUnpublishedOutbox({
    int afterId = 0,
    int limit = 100,
  });

  Future<List<OutboxRecord>> claimOutbox({
    required String owner,
    required Duration lease,
    int limit = 100,
  });

  Future<bool> markOutboxPublished(int id, {required String owner});

  Future<bool> releaseOutbox(int id, {required String owner});
}

final class SqliteEventRepository implements EventRepository {
  SqliteEventRepository(
    this._database, {
    EventId Function()? newEventId,
    DateTime Function()? now,
  }) : _newEventId = newEventId ?? EventId.generate,
       _now = now ?? DateTime.now;

  final GaoVmDatabase _database;
  final EventId Function() _newEventId;
  final DateTime Function() _now;

  @override
  Future<Event> append({
    required String type,
    required ResourceType resourceType,
    ResourceId? resourceId,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
    required JsonObjectValue payload,
    DateTime? occurredAt,
  }) {
    if (_operationLifecycleTypes.contains(type)) {
      throw ArgumentError(
        'operation lifecycle events are emitted only by OperationRepository',
      );
    }
    _validateCorrelation(
      resourceType: resourceType,
      resourceId: resourceId,
      vmId: vmId,
      operationId: operationId,
      testRunId: testRunId,
    );
    final eventId = _newEventId();
    final timestamp = (occurredAt ?? _now()).toUtc();
    return _database.transaction((connection) {
      return _insertEvent(
        connection,
        eventId: eventId,
        type: type,
        resourceType: resourceType,
        resourceId: resourceId,
        vmId: vmId,
        operationId: operationId,
        testRunId: testRunId,
        payload: payload,
        occurredAt: timestamp,
      );
    });
  }

  Event _insertEvent(
    Database connection, {
    required EventId eventId,
    required String type,
    required ResourceType resourceType,
    required ResourceId? resourceId,
    required VmId? vmId,
    required OperationId? operationId,
    required TestRunId? testRunId,
    required JsonObjectValue payload,
    required DateTime occurredAt,
  }) {
    connection.execute(
      '''
        INSERT INTO events(
          id, type, resource_type, resource_id, vm_id, operation_id,
          test_run_id, payload_json, occurred_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        eventId.value,
        type,
        _resourceTypeName(resourceType),
        resourceId?.value,
        vmId?.value,
        operationId?.value,
        testRunId?.value,
        jsonEncode(payload.toJson()),
        formatPersistenceTimestamp(occurredAt),
      ],
    );
    final event = Event(
      sequence: connection.lastInsertRowId,
      eventId: eventId,
      type: type,
      resourceType: resourceType,
      resourceId: resourceId,
      vmId: vmId,
      operationId: operationId,
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
    return event;
  }

  @override
  Future<Event?> get(EventId id) => _database.read((connection) {
    final rows = connection.select('SELECT * FROM events WHERE id = ?', [
      id.value,
    ]);
    return rows.isEmpty ? null : _decodeEvent(rows.single);
  });

  @override
  Future<List<Event>> list({
    int after = 0,
    ResourceType? resourceType,
    ResourceId? resourceId,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
  }) => _database.read((connection) {
    if (after < 0) {
      throw ArgumentError.value(after, 'after', 'must not be negative');
    }
    if (resourceId != null &&
        resourceType != null &&
        !resourceId.matchesResourceType(resourceType)) {
      throw ArgumentError('resourceType does not match resourceId');
    }
    final predicates = <String>['sequence > ?'];
    final parameters = <Object?>[after];
    if (resourceType != null) {
      predicates.add('resource_type = ?');
      parameters.add(_resourceTypeName(resourceType));
    }
    if (resourceId != null) {
      predicates.add('resource_id = ?');
      parameters.add(resourceId.value);
    }
    if (vmId != null) {
      predicates.add('vm_id = ?');
      parameters.add(vmId.value);
    }
    if (operationId != null) {
      predicates.add('operation_id = ?');
      parameters.add(operationId.value);
    }
    if (testRunId != null) {
      predicates.add('test_run_id = ?');
      parameters.add(testRunId.value);
    }
    return List<Event>.unmodifiable(
      connection
          .select('''
              SELECT * FROM events
              WHERE ${predicates.join(' AND ')}
              ORDER BY sequence
            ''', parameters)
          .map(_decodeEvent),
    );
  });

  @override
  Future<List<OutboxRecord>> readUnpublishedOutbox({
    int afterId = 0,
    int limit = 100,
  }) => _database.read((connection) {
    if (afterId < 0) {
      throw ArgumentError.value(afterId, 'afterId', 'must not be negative');
    }
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 1000');
    }
    return List<OutboxRecord>.unmodifiable(
      connection
          .select(
            '''
              SELECT * FROM outbox
              WHERE topic = 'events' AND published_at IS NULL AND id > ?
              ORDER BY id
              LIMIT ?
            ''',
            [afterId, limit],
          )
          .map(_decodeOutboxRecord),
    );
  });

  @override
  Future<List<OutboxRecord>> claimOutbox({
    required String owner,
    required Duration lease,
    int limit = 100,
  }) => _database.transaction((connection) {
    _validateOwner(owner);
    if (lease <= Duration.zero) {
      throw ArgumentError.value(lease, 'lease', 'must be positive');
    }
    _validateOutboxLimit(limit);
    final claimedAt = _now().toUtc();
    final expiresAt = claimedAt.add(lease);
    final rows = connection.select(
      '''
        SELECT id FROM outbox
        WHERE topic = 'events' AND published_at IS NULL
          AND (claimed_by IS NULL OR claim_expires_at <= ?)
        ORDER BY id
        LIMIT ?
      ''',
      [formatPersistenceTimestamp(claimedAt), limit],
    );
    final ids = [for (final row in rows) row['id'] as int];
    if (ids.isEmpty) return const <OutboxRecord>[];
    final placeholders = List.filled(ids.length, '?').join(', ');
    connection.execute(
      '''
        UPDATE outbox
        SET attempts = attempts + CASE WHEN claimed_by IS NULL THEN 0 ELSE 1 END,
            claimed_by = ?, claim_expires_at = ?
        WHERE id IN ($placeholders)
          AND published_at IS NULL
          AND (claimed_by IS NULL OR claim_expires_at <= ?)
      ''',
      [
        owner,
        formatPersistenceTimestamp(expiresAt),
        ...ids,
        formatPersistenceTimestamp(claimedAt),
      ],
    );
    return List<OutboxRecord>.unmodifiable(
      connection
          .select(
            '''
              SELECT * FROM outbox
              WHERE id IN ($placeholders) AND claimed_by = ?
              ORDER BY id
            ''',
            [...ids, owner],
          )
          .map(_decodeOutboxRecord),
    );
  });

  @override
  Future<bool> markOutboxPublished(int id, {required String owner}) =>
      _database.transaction((connection) {
        _validateOutboxId(id);
        _validateOwner(owner);
        final publishedAt = _now().toUtc();
        connection.execute(
          '''
            UPDATE outbox
            SET published_at = ?, claimed_by = NULL, claim_expires_at = NULL
            WHERE topic = 'events' AND id = ? AND published_at IS NULL AND claimed_by = ?
              AND claim_expires_at > ?
          ''',
          [
            formatPersistenceTimestamp(publishedAt),
            id,
            owner,
            formatPersistenceTimestamp(publishedAt),
          ],
        );
        return connection.updatedRows == 1;
      });

  @override
  Future<bool> releaseOutbox(int id, {required String owner}) =>
      _database.transaction((connection) {
        _validateOutboxId(id);
        _validateOwner(owner);
        connection.execute(
          '''
            UPDATE outbox
            SET claimed_by = NULL, claim_expires_at = NULL,
                attempts = attempts + 1
            WHERE topic = 'events' AND id = ? AND published_at IS NULL AND claimed_by = ?
          ''',
          [id, owner],
        );
        return connection.updatedRows == 1;
      });
}

Event _decodeEvent(Row row) => Event.fromJson({
  'sequence': row['sequence'],
  'event_id': row['id'],
  'type': row['type'],
  'resource_type': row['resource_type'],
  'resource_id': row['resource_id'],
  'vm_id': row['vm_id'],
  'operation_id': row['operation_id'],
  'test_run_id': row['test_run_id'],
  'payload': jsonDecode(row['payload_json'] as String),
  'occurred_at': row['occurred_at'],
});

OutboxRecord _decodeOutboxRecord(Row row) => OutboxRecord(
  id: row['id'] as int,
  topic: row['topic'] as String,
  key: row['key'] as String,
  payload: JsonObjectValue.fromJson(jsonDecode(row['payload_json'] as String)),
  createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
  publishedAt: row['published_at'] == null
      ? null
      : DateTime.parse(row['published_at'] as String).toUtc(),
  attempts: row['attempts'] as int,
  claimedBy: row['claimed_by'] as String?,
  claimExpiresAt: row['claim_expires_at'] == null
      ? null
      : DateTime.parse(row['claim_expires_at'] as String).toUtc(),
);

String _resourceTypeName(ResourceType value) => switch (value) {
  ResourceType.virtualMachine => 'virtual_machine',
  ResourceType.image => 'image',
  ResourceType.operation => 'operation',
  ResourceType.testRun => 'test_run',
  ResourceType.artifact => 'artifact',
  ResourceType.system => 'system',
};

const _operationLifecycleTypes = {
  'operation.created',
  'operation.started',
  'operation.updated',
  'operation.completed',
};

void _validateOutboxId(int id) {
  if (id < 1) {
    throw ArgumentError.value(id, 'id', 'must be at least 1');
  }
}

void _validateOwner(String owner) {
  if (owner.isEmpty) {
    throw ArgumentError.value(owner, 'owner', 'must not be empty');
  }
}

void _validateOutboxLimit(int limit) {
  if (limit < 1 || limit > 1000) {
    throw ArgumentError.value(limit, 'limit', 'must be between 1 and 1000');
  }
}

void _validateCorrelation({
  required ResourceType resourceType,
  required ResourceId? resourceId,
  required VmId? vmId,
  required OperationId? operationId,
  required TestRunId? testRunId,
}) {
  switch (resourceType) {
    case ResourceType.virtualMachine:
      if (resourceId is! VmId || resourceId != vmId) {
        throw ArgumentError(
          'virtual_machine events require resource_id to match vm_id',
        );
      }
      return;
    case ResourceType.operation:
      if (resourceId is! OperationId || resourceId != operationId) {
        throw ArgumentError(
          'operation events require resource_id to match operation_id',
        );
      }
      return;
    case ResourceType.testRun:
      if (resourceId is! TestRunId || resourceId != testRunId) {
        throw ArgumentError(
          'test_run events require resource_id to match test_run_id',
        );
      }
      return;
    case ResourceType.image:
    case ResourceType.artifact:
    case ResourceType.system:
      return;
  }
}
