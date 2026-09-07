import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'persistence_timestamp.dart';
import 'sqlite_database.dart';

const vmCommandOutboxTopic = 'vm.commands';

enum VmCommandAction { create, patch, start, stop, restart, kill, delete }

final class VmCommandRecord {
  const VmCommandRecord._({
    required this.id,
    required this.action,
    required this.vmId,
    required this.operationId,
    required this.payload,
    required this.createdAt,
  });
  final int id;
  final VmCommandAction action;
  final VmId vmId;
  final OperationId operationId;
  final JsonObjectValue payload;
  final DateTime createdAt;
}

/// A claim is a single delivery attempt, not merely a reusable worker name.
final class VmCommandClaim {
  const VmCommandClaim._({
    required this.record,
    required this.owner,
    required this.attempt,
    required this.leaseExpiresAt,
    required String token,
  }) : _token = token;
  final VmCommandRecord record;
  final String owner;
  final int attempt;
  final DateTime leaseExpiresAt;
  final String _token;
}

/// Durable acceptance queue. Enqueue joins the caller's SQLite transaction.
/// Dispatch is at-least-once: a dispatcher must guard effects using the durable
/// Operation and controller correlation before acknowledging. No driver effects
/// or automatic external retries are performed by this repository.
final class SqliteVmCommandRepository {
  SqliteVmCommandRepository(this._database, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final GaoVmDatabase _database;
  final DateTime Function() _now;

  Future<VmCommandRecord> enqueue({
    required VmCommandAction action,
    required VmId vmId,
    required OperationId operationId,
    required JsonObjectValue payload,
  }) => _database.transaction((db) {
    final envelope = {
      'version': 1,
      'action': action.name,
      'vm_id': vmId.value,
      'operation_id': operationId.value,
      'payload': payload.toJson(),
    };
    final createdAt = _now().toUtc();
    db.execute(
      '''INSERT INTO outbox(topic,key,payload_json,created_at) VALUES(?,?,?,?)''',
      [
        vmCommandOutboxTopic,
        vmId.value,
        jsonEncode(envelope),
        formatPersistenceTimestamp(createdAt),
      ],
    );
    return _decode(
      db.select('SELECT * FROM outbox WHERE id = ?', [
        db.lastInsertRowId,
      ]).single,
    );
  });

  Future<List<VmCommandClaim>> claim({
    required String owner,
    required Duration lease,
    int limit = 100,
  }) => _database.transaction((db) {
    _validateOwner(owner);
    if (lease <= Duration.zero)
      throw ArgumentError.value(lease, 'lease', 'must be positive');
    if (limit < 1 || limit > 1000)
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 1000');
    final now = _now().toUtc();
    final expiry = now.add(lease);
    final rows = db.select(
      '''SELECT candidate.* FROM outbox candidate
      WHERE candidate.topic = ? AND candidate.published_at IS NULL
        AND (candidate.claimed_by IS NULL OR candidate.claim_expires_at <= ?)
        AND NOT EXISTS (
          SELECT 1 FROM outbox earlier
          WHERE earlier.topic = candidate.topic AND earlier.key = candidate.key
            AND earlier.published_at IS NULL AND earlier.id < candidate.id
        )
      ORDER BY candidate.id LIMIT ?''',
      [vmCommandOutboxTopic, formatPersistenceTimestamp(now), limit],
    );
    final claims = <VmCommandClaim>[];
    for (final row in rows) {
      final record = _decode(row);
      final token = '$owner/${RequestId.generate().value}';
      db.execute(
        '''UPDATE outbox SET claimed_by = ?, claim_expires_at = ?, attempts = attempts + 1 WHERE topic = ? AND id = ?''',
        [
          token,
          formatPersistenceTimestamp(expiry),
          vmCommandOutboxTopic,
          record.id,
        ],
      );
      claims.add(
        VmCommandClaim._(
          record: record,
          owner: owner,
          attempt: (row['attempts'] as int) + 1,
          leaseExpiresAt: expiry,
          token: token,
        ),
      );
    }
    return List.unmodifiable(claims);
  });

  Future<bool> acknowledge(VmCommandClaim claim) => _database.transaction((db) {
    final now = formatPersistenceTimestamp(_now().toUtc());
    db.execute(
      '''UPDATE outbox SET published_at = ?, claimed_by = NULL, claim_expires_at = NULL
      WHERE topic = ? AND id = ? AND published_at IS NULL AND claimed_by = ? AND attempts = ? AND claim_expires_at = ? AND claim_expires_at > ?''',
      [
        now,
        vmCommandOutboxTopic,
        claim.record.id,
        claim._token,
        claim.attempt,
        formatPersistenceTimestamp(claim.leaseExpiresAt),
        now,
      ],
    );
    return db.updatedRows == 1;
  });

  Future<bool> release(VmCommandClaim claim) => _database.transaction((db) {
    final now = formatPersistenceTimestamp(_now().toUtc());
    db.execute(
      '''UPDATE outbox SET claimed_by = NULL, claim_expires_at = NULL
      WHERE topic = ? AND id = ? AND published_at IS NULL AND claimed_by = ? AND attempts = ? AND claim_expires_at = ? AND claim_expires_at > ?''',
      [
        vmCommandOutboxTopic,
        claim.record.id,
        claim._token,
        claim.attempt,
        formatPersistenceTimestamp(claim.leaseExpiresAt),
        now,
      ],
    );
    return db.updatedRows == 1;
  });
}

VmCommandRecord _decode(Row row) {
  final json = jsonDecode(row['payload_json'] as String);
  const keys = {'version', 'action', 'vm_id', 'operation_id', 'payload'};
  if (row['topic'] != vmCommandOutboxTopic ||
      json is! Map<String, dynamic> ||
      json.length != keys.length ||
      json.keys.any((key) => !keys.contains(key)) ||
      json['version'] is! int ||
      json['version'] != 1)
    throw FormatException('invalid VM command envelope');
  final action = VmCommandAction.values
      .where((action) => action.name == json['action'])
      .firstOrNull;
  if (action == null ||
      json['vm_id'] is! String ||
      json['operation_id'] is! String ||
      row['key'] != json['vm_id'])
    throw FormatException('invalid VM command action or correlation');
  return VmCommandRecord._(
    id: row['id'] as int,
    action: action,
    vmId: VmId(json['vm_id'] as String),
    operationId: OperationId(json['operation_id'] as String),
    payload: JsonObjectValue.fromJson(json['payload']),
    createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
  );
}

void _validateOwner(String owner) {
  if (owner.isEmpty || owner.length > 255)
    throw ArgumentError.value(
      owner,
      'owner',
      'must contain 1 to 255 characters',
    );
}
