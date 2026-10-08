import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';

const imageWorkOutboxTopic = 'images.work';

final class ImageWorkLeaseLost implements Exception {}

final class ImageOperationCancellationRequested implements Exception {}

/// A fenced image worker delivery, not an arbitrary transaction callback.
/// The store verifies it before publication and completes it in the same
/// transaction as the catalog mutation. The filesystem lock spans that commit.
final class ImageOperationCommit {
  ImageOperationCommit({
    required this.database,
    required this.operationId,
    required this.imageId,
    required this.outboxId,
    required this.token,
    required this.now,
  });
  final GaoVmDatabase database;
  final OperationId operationId;
  final ImageId imageId;
  final int outboxId;
  final String token;
  final DateTime Function() now;

  Future<bool> cancellationRequested() => database.read(
    (db) => db.select(
      "SELECT 1 FROM operations WHERE type = 'operation.cancel' AND resource_type = 'operation' AND resource_id = ? AND state IN ('pending', 'running') LIMIT 1",
      [operationId.value],
    ).isNotEmpty,
  );

  Future<void> verify({bool allowCancellation = false}) async {
    final current = await database.read(
      (db) => db
          .select(
            '''SELECT 1 FROM outbox WHERE id = ? AND topic = ? AND key = ?
        AND published_at IS NULL AND claimed_by = ? AND claim_expires_at > ?''',
            [
              outboxId,
              imageWorkOutboxTopic,
              operationId.value,
              token,
              formatPersistenceTimestamp(now()),
            ],
          )
          .isNotEmpty,
    );
    if (!current) throw ImageWorkLeaseLost();
    if (!allowCancellation && await cancellationRequested())
      throw ImageOperationCancellationRequested();
  }

  Future<void> complete(Image image) => database.transaction((db) async {
    await verify();
    final operations = SqliteOperationRepository(database, now: now);
    final operation = await operations.get(operationId);
    if (operation == null ||
        operation.state != OperationState.running ||
        operation.resourceType != ResourceType.image ||
        !const {'image.import', 'image.delete'}.contains(operation.type)) {
      throw StateError('image work disagrees with its operation');
    }
    // Content deduplication can resolve a reserved import ID to an existing
    // immutable resource. The saved acceptance remains an exact replay snapshot.
    db.execute('UPDATE operations SET resource_id = ? WHERE id = ?', [
      image.id.value,
      operationId.value,
    ]);
    await operations.succeed(
      operationId,
      result: JsonObjectValue.fromJson({
        'image_id': image.id.value,
        'digest': image.digest,
      }),
    );
    _acknowledge(db);
  });

  Future<void> fail(OperationError error) => database.transaction((db) async {
    await verify();
    await SqliteOperationRepository(
      database,
      now: now,
    ).fail(operationId, error: error);
    _acknowledge(db);
  });

  /// Called only after the store has unwound and removed this attempt's stage.
  Future<void> cancel() => database.transaction((db) async {
    await verify(allowCancellation: true);
    if (!await cancellationRequested())
      throw StateError('image cancellation was not requested');
    final operations = SqliteOperationRepository(database, now: now);
    await operations.cancel(operationId);
    final actions = db.select(
      "SELECT id FROM operations WHERE type = 'operation.cancel' AND resource_type = 'operation' AND resource_id = ? AND state IN ('pending', 'running') ORDER BY id",
      [operationId.value],
    );
    for (final row in actions) {
      final id = OperationId(row['id'] as String);
      if ((await operations.get(id))!.state == OperationState.pending)
        await operations.start(id);
      await operations.succeed(
        id,
        result: JsonObjectValue.fromJson({
          'operation_id': operationId.value,
          'state': 'cancelled',
        }),
      );
    }
    _acknowledge(db);
  });

  void _acknowledge(Database db) {
    db.execute(
      'UPDATE outbox SET published_at = ?, claimed_by = NULL, claim_expires_at = NULL WHERE id = ? AND topic = ? AND claimed_by = ?',
      [
        formatPersistenceTimestamp(now()),
        outboxId,
        imageWorkOutboxTopic,
        token,
      ],
    );
    if (db.updatedRows != 1) throw ImageWorkLeaseLost();
  }
}
