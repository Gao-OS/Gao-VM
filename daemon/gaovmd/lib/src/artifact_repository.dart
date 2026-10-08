import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'event_repository.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';

final class ArtifactPublicationConflict implements Exception {
  const ArtifactPublicationConflict(this.id, this.message);
  final ArtifactId id;
  final String message;
  @override
  String toString() => 'Artifact $id: $message';
}

final class ArtifactCatalogCorruption implements Exception {
  const ArtifactCatalogCorruption();

  @override
  String toString() => 'Artifact catalog metadata is invalid';
}

final class ArtifactListQuery {
  ArtifactListQuery({required this.owner, this.cursor, this.limit = 50}) {
    if (owner is! VmId && owner is! TestRunId)
      throw ArgumentError.value(owner, 'owner');
    if (limit < 1 ||
        limit > 200 ||
        cursor != null && (cursor!.isEmpty || cursor!.length > 512)) {
      throw const FormatException('invalid artifact pagination');
    }
  }
  final ResourceId owner;
  final String? cursor;
  final int limit;
}

final class ArtifactPage {
  const ArtifactPage(this.items, this.nextCursor);
  final List<Artifact> items;
  final String? nextCursor;
}

final class ArtifactRepository {
  ArtifactRepository(this.database);
  final GaoVmDatabase database;

  /// managedPayload is an attestation by the managed store after sealed bytes
  /// have been published. Metadata-only/legacy imports must leave it false.
  Future<Artifact> publish(
    Artifact artifact, {
    bool managedPayload = false,
  }) => database.transaction((db) async {
    final existing = await get(artifact.id);
    if (existing != null) {
      if (existing != artifact ||
          managedPayload && !await hasManagedPayload(artifact.id)) {
        throw ArtifactPublicationConflict(
          artifact.id,
          'published metadata is immutable',
        );
      }
      return existing;
    }
    if (artifact.testRunId case final id?) {
      final run = await SqliteTestRunRepository(database).get(id);
      if (run == null) throw TestRunNotFoundException(id);
      if (artifact.vmId != null && artifact.vmId != run.vmId) {
        throw ArtifactPublicationConflict(
          artifact.id,
          'VM does not own this TestRun',
        );
      }
      if (const {
        TestRunState.cleaningUp,
        TestRunState.succeeded,
        TestRunState.failed,
        TestRunState.cancelled,
      }.contains(run.state)) {
        throw TestRunConflictException(id, 'artifact collection is closed');
      }
      if (artifact.operationId case final operationId?) {
        final operation = await SqliteOperationRepository(
          database,
        ).get(operationId);
        if (operation == null) throw OperationNotFoundException(operationId);
        if (!(operation.resourceType == ResourceType.testRun &&
                operation.resourceId == id) &&
            !(operation.resourceType == ResourceType.virtualMachine &&
                operation.resourceId == run.vmId)) {
          throw ArtifactPublicationConflict(
            artifact.id,
            'operation belongs to another resource',
          );
        }
      }
    }
    final json = artifact.toJson();
    db.execute(
      '''
      INSERT INTO artifacts(
        id, vm_id, operation_id, test_run_id, kind, content_type, size_bytes,
        digest, download_url, retention_until, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        artifact.id.value,
        artifact.vmId?.value,
        artifact.operationId?.value,
        artifact.testRunId?.value,
        json['kind'],
        artifact.contentType,
        artifact.sizeBytes,
        artifact.digest,
        artifact.downloadUrl,
        artifact.retentionUntil == null
            ? null
            : formatPersistenceTimestamp(artifact.retentionUntil!),
        formatPersistenceTimestamp(artifact.createdAt),
      ],
    );
    if (managedPayload) {
      db.execute(
        'INSERT INTO artifact_payloads(artifact_id, storage_version) VALUES (?, 1)',
        [artifact.id.value],
      );
    }
    if (artifact.testRunId case final id?) {
      final row = db.select(
        'SELECT artifact_ids_json FROM test_runs WHERE id = ?',
        [id.value],
      ).single;
      final ids = jsonDecode(row['artifact_ids_json'] as String) as List;
      ids.add(artifact.id.value);
      db.execute('UPDATE test_runs SET artifact_ids_json = ? WHERE id = ?', [
        jsonEncode(ids),
        id.value,
      ]);
    }
    await SqliteEventRepository(database).append(
      type: 'artifact.created',
      resourceType: ResourceType.artifact,
      resourceId: artifact.id,
      vmId: artifact.vmId,
      operationId: artifact.operationId,
      testRunId: artifact.testRunId,
      payload: JsonObjectValue.fromJson(json),
      occurredAt: artifact.createdAt,
    );
    return artifact;
  });

  Future<Artifact?> get(ArtifactId id) => database.read((db) {
    final rows = db.select('SELECT * FROM artifacts WHERE id = ?', [id.value]);
    return rows.isEmpty ? null : _decode(rows.single);
  });

  Future<ArtifactPage> list(ArtifactListQuery query) {
    String? afterTime;
    ArtifactId? afterId;
    if (query.cursor case final cursor?) {
      try {
        final anchor = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(cursor))),
        );
        if (anchor is! Map ||
            anchor.length != 4 ||
            anchor['version'] != 1 ||
            anchor['owner'] != query.owner.value ||
            anchor['created_at'] is! String) {
          throw const FormatException('invalid artifact cursor');
        }
        afterTime = anchor['created_at'] as String;
        if (afterTime.length > 64 || DateTime.tryParse(afterTime) == null) {
          throw const FormatException('invalid artifact cursor timestamp');
        }
        afterId = ArtifactId(anchor['id'] as String);
      } catch (_) {
        throw const FormatException('invalid artifact cursor');
      }
    }
    final column = query.owner is VmId ? 'vm_id' : 'test_run_id';
    return database.read((db) {
      final rows = db.select(
        '''
        SELECT * FROM artifacts WHERE $column = ?
          ${afterId == null ? '' : 'AND (created_at, id) > (?, ?)'}
        ORDER BY created_at, id LIMIT ?
      ''',
        [
          query.owner.value,
          if (afterId != null) ...[afterTime, afterId.value],
          query.limit + 1,
        ],
      );
      final items = List<Artifact>.unmodifiable(
        rows.take(query.limit).map(_decode),
      );
      final next = rows.length > query.limit
          ? base64Url
                .encode(
                  utf8.encode(
                    jsonEncode({
                      'version': 1,
                      'owner': query.owner.value,
                      'id': items.last.id.value,
                      'created_at': rows[query.limit - 1]['created_at'],
                    }),
                  ),
                )
                .replaceAll('=', '')
          : null;
      return ArtifactPage(items, next);
    });
  }

  Future<bool> hasManagedPayload(ArtifactId id) => database.read(
    (db) => db.select(
      'SELECT 1 FROM artifact_payloads WHERE artifact_id = ? AND storage_version = 1',
      [id.value],
    ).isNotEmpty,
  );

  Future<List<Artifact>> listManaged({ArtifactId? afterId, int limit = 100}) {
    if (limit < 1 || limit > 200) throw ArgumentError.value(limit, 'limit');
    return database.read(
      (db) => List<Artifact>.unmodifiable(
        db
            .select(
              '''
      SELECT a.* FROM artifacts a JOIN artifact_payloads p ON p.artifact_id = a.id
      WHERE p.storage_version = 1 AND a.id > ? ORDER BY a.id LIMIT ?
    ''',
              [afterId?.value ?? '', limit],
            )
            .map(_decode),
      ),
    );
  }
}

Artifact _decode(Row row) {
  try {
    return Artifact.fromJson({
      for (final key in const [
        'id',
        'vm_id',
        'operation_id',
        'test_run_id',
        'kind',
        'content_type',
        'size_bytes',
        'digest',
        'download_url',
        'retention_until',
        'created_at',
      ])
        key: row[key],
    });
  } on FormatException {
    throw const ArtifactCatalogCorruption();
  } on ArgumentError {
    throw const ArtifactCatalogCorruption();
  } on TypeError {
    throw const ArtifactCatalogCorruption();
  }
}
