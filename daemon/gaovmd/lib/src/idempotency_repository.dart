import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'persistence_timestamp.dart';
import 'sqlite_database.dart';

/// The durable response envelope. Callers may include status, headers, resource,
/// and operation IDs in [response]; transport request IDs should be regenerated.
final class IdempotencyResponse {
  const IdempotencyResponse(this.response);

  final JsonObjectValue response;
}

final class IdempotencyResult {
  const IdempotencyResult({required this.response, required this.replayed});

  final JsonObjectValue response;
  final bool replayed;
}

final class IdempotencyConflictException implements Exception {
  const IdempotencyConflictException(this.scope, this.key);

  final String scope;
  final String key;
  String get code => 'IDEMPOTENCY_CONFLICT';

  @override
  String toString() => '$code: key already belongs to a different request';
}

/// An unfinished durable reservation must never execute its action again.
/// Application recovery must reconcile it before allowing a retry.
final class IdempotencyInProgressException implements Exception {
  const IdempotencyInProgressException(this.scope, this.key);

  final String scope;
  final String key;

  @override
  String toString() => 'idempotent request is still in progress';
}

final class SqliteIdempotencyRepository {
  SqliteIdempotencyRepository(
    this._database, {
    required this.retention,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (retention <= Duration.zero) {
      throw ArgumentError.value(retention, 'retention', 'must be positive');
    }
  }

  final GaoVmDatabase _database;
  final Duration retention;
  final DateTime Function() _now;

  /// Hashes the exact request bytes, without lossy JSON normalization.
  static String requestHash(List<int> requestBody) {
    if (requestBody.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError.value(requestBody, 'requestBody', 'must be bytes');
    }
    return sha256.convert(requestBody).toString();
  }

  /// [scope] must identify the method and target resource, not merely its route
  /// template. The caller supplies the same exact body bytes on retries.
  ///
  /// [action] must perform only transactional database work on this database.
  /// Publish external work through the transactional outbox after commit. Nested
  /// repository transactions join this transaction using savepoints, including
  /// when execute itself is called inside a caller-owned transaction.
  Future<IdempotencyResult> execute({
    required String scope,
    required String key,
    required List<int> requestBody,
    required Future<IdempotencyResponse> Function() action,
  }) {
    if (scope.isEmpty) throw ArgumentError.value(scope, 'scope');
    if (key.isEmpty || key.length > 255) {
      throw ArgumentError.value(key, 'key', 'must contain 1 to 255 characters');
    }
    final hash = requestHash(requestBody);
    return _database.transaction((connection) async {
      final now = _now().toUtc();
      final rows = connection.select(
        'SELECT * FROM idempotency_keys WHERE scope = ? AND key = ?',
        [scope, key],
      );
      if (rows.isNotEmpty) {
        final row = rows.single;
        final response = row['response_json'] as String?;
        final expired = !DateTime.parse(
          row['expires_at'] as String,
        ).isAfter(now);
        // An unfinished action does not become safe to repeat with age.
        if (response == null || !expired) {
          if (row['request_hash'] != hash) {
            throw IdempotencyConflictException(scope, key);
          }
          if (response == null) {
            throw IdempotencyInProgressException(scope, key);
          }
          return IdempotencyResult(
            response: JsonObjectValue.fromJson(
              jsonDecode(response) as Map<String, dynamic>,
            ),
            replayed: true,
          );
        }
        connection.execute(
          'DELETE FROM idempotency_keys WHERE scope = ? AND key = ?',
          [scope, key],
        );
      }
      connection.execute(
        '''INSERT INTO idempotency_keys(
          scope, key, request_hash, created_at, expires_at
        ) VALUES (?, ?, ?, ?, ?)''',
        [
          scope,
          key,
          hash,
          formatPersistenceTimestamp(now),
          formatPersistenceTimestamp(now.add(retention)),
        ],
      );
      final result = await action();
      connection.execute(
        '''UPDATE idempotency_keys SET response_json = ?, expires_at = ?
           WHERE scope = ? AND key = ?''',
        [
          jsonEncode(result.response.toJson()),
          formatPersistenceTimestamp(_now().toUtc().add(retention)),
          scope,
          key,
        ],
      );
      return IdempotencyResult(response: result.response, replayed: false);
    });
  }

  /// Expiry ends the replay guarantee. Never removes unresolved reservations.
  Future<int> cleanupExpired() => _database.transaction((connection) {
    connection.execute(
      '''DELETE FROM idempotency_keys
         WHERE response_json IS NOT NULL AND expires_at <= ?''',
      [formatPersistenceTimestamp(_now().toUtc())],
    );
    return connection.updatedRows;
  });
}
