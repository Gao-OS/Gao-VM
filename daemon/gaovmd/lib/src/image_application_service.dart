import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:crypto/crypto.dart';

import 'idempotency_repository.dart';
import 'image_operation_commit.dart';
import 'image_repository.dart';
import 'image_store.dart';
import 'operation_application_service.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'vm_repository.dart' show LabelSelector;

final class ImageListQuery {
  ImageListQuery({this.cursor, this.limit = 50, this.selector}) {
    if (limit < 1 ||
        limit > 200 ||
        cursor != null && (cursor!.isEmpty || cursor!.length > 512)) {
      throw const FormatException('invalid image pagination');
    }
  }
  final String? cursor;
  final int limit;
  final LabelSelector? selector;
}

final class ImagePage {
  const ImagePage(this.items, this.nextCursor);
  final List<Image> items;
  final String? nextCursor;
}

final class ImageDeleteCommand {
  ImageDeleteCommand({
    required this.imageId,
    required this.requestId,
    required this.idempotencyKey,
    required List<int> requestBody,
  }) : requestBody = List.unmodifiable(requestBody) {
    if (idempotencyKey != null &&
        (idempotencyKey!.isEmpty || idempotencyKey!.length > 255))
      throw const FormatException('invalid Idempotency-Key');
  }
  final ImageId imageId;
  final RequestId requestId;
  final String? idempotencyKey;
  final List<int> requestBody;
}

final class ImageImportCommand {
  ImageImportCommand.fromJson(
    Map<String, Object?> json, {
    required this.requestId,
    required this.idempotencyKey,
    required List<int> requestBody,
  }) : requestBody = List.unmodifiable(requestBody),
       sourcePath = json['source_path'] is String
           ? json['source_path'] as String
           : '',
       type = switch (json['type']) {
         'linux-kernel' => ImageType.linuxKernel,
         'initrd' => ImageType.initrd,
         'raw-disk' => ImageType.rawDisk,
         'gaoos-bundle' => ImageType.gaoosBundle,
         _ => throw const FormatException('unsupported image type'),
       },
       guestProfile = _metadata(json['guest_profile']),
       version = _metadata(json['version']),
       buildId = _metadata(json['build_id']),
       channel = _metadata(json['channel']),
       labels = _labels(json['labels'], json.containsKey('labels')) {
    if (sourcePath.isEmpty ||
        json['architecture'] != 'arm64' ||
        json.keys.any(
          (key) => !const {
            'source_path',
            'type',
            'architecture',
            'guest_profile',
            'version',
            'build_id',
            'channel',
            'labels',
          }.contains(key),
        )) {
      throw const FormatException('invalid image import request');
    }
    if (idempotencyKey != null &&
        (idempotencyKey!.isEmpty || idempotencyKey!.length > 255)) {
      throw const FormatException('invalid Idempotency-Key');
    }
  }
  final RequestId requestId;
  final String? idempotencyKey;
  final List<int> requestBody;
  final String sourcePath;
  final ImageType type;
  final String? guestProfile;
  final String? version;
  final String? buildId;
  final String? channel;
  final Map<String, String> labels;

  Map<String, Object?> toJson() => {
    'source_path': sourcePath,
    'type': switch (type) {
      ImageType.linuxKernel => 'linux-kernel',
      ImageType.initrd => 'initrd',
      ImageType.rawDisk => 'raw-disk',
      ImageType.gaoosBundle => 'gaoos-bundle',
    },
    'architecture': 'arm64',
    if (guestProfile != null) 'guest_profile': guestProfile,
    if (version != null) 'version': version,
    if (buildId != null) 'build_id': buildId,
    if (channel != null) 'channel': channel,
    'labels': labels,
  };
}

/// Database-only command acceptance and recoverable post-commit image work.
/// No API request waits for file copying, hashing, or publication.
final class ImageApplicationService implements OperationMutationAcceptor {
  ImageApplicationService({
    required this.database,
    required this.store,
    Duration idempotencyRetention = const Duration(days: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _idempotency = SqliteIdempotencyRepository(
         database,
         retention: idempotencyRetention,
         now: now,
       ) {
    if (!identical(database, store.database))
      throw ArgumentError('image store must use the application catalog');
  }
  final GaoVmDatabase database;
  final ImageStore store;
  final DateTime Function() _now;
  final SqliteIdempotencyRepository _idempotency;
  Future<void>? _dispatching;

  Future<ImagePage> list([ImageListQuery? query]) async {
    final effective = query ?? ImageListQuery();
    final values = (await store.list())
        .where((image) => effective.selector?.matches(image.labels) ?? true)
        .toList();
    final selector = sha256
        .convert(utf8.encode(effective.selector?.toString() ?? ''))
        .toString();
    var start = 0;
    if (effective.cursor case final cursor?) {
      try {
        final anchor = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(cursor))),
        );
        if (anchor is! Map ||
            anchor.length != 4 ||
            anchor['version'] != 1 ||
            anchor['selector'] != selector)
          throw const FormatException('invalid image cursor');
        final createdAt = DateTime.parse(anchor['created_at'] as String);
        final id = ImageId(anchor['id'] as String);
        start = values.indexWhere((image) {
          final comparison = image.createdAt.compareTo(createdAt);
          return comparison > 0 ||
              comparison == 0 && image.id.value.compareTo(id.value) > 0;
        });
        if (start < 0) start = values.length;
      } catch (_) {
        throw const FormatException('invalid image cursor');
      }
    }
    final end = (start + effective.limit).clamp(0, values.length);
    final items = List<Image>.unmodifiable(values.sublist(start, end));
    final next = end < values.length
        ? base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'version': 1,
                    'id': items.last.id.value,
                    'created_at': items.last.createdAt
                        .toUtc()
                        .toIso8601String(),
                    'selector': selector,
                  }),
                ),
              )
              .replaceAll('=', '')
        : null;
    return ImagePage(items, next);
  }

  @override
  Future<OperationAcceptance> cancel(OperationCancelCommand command) async {
    if (database.hasActiveCallerTransaction)
      throw StateError('image cancellation must own its commit boundary');
    return database.transaction((_) async {
      Future<IdempotencyResponse> accept() async {
        final operations = SqliteOperationRepository(database, now: _now);
        final target = await operations.get(command.operationId);
        if (target == null)
          throw OperationNotFoundException(command.operationId);
        if (target.type != 'image.import' ||
            target.resourceType != ResourceType.image ||
            !target.cancellable ||
            !const {
              OperationState.pending,
              OperationState.running,
            }.contains(target.state)) {
          throw OperationNotCancellableException(target.id);
        }
        final action = await operations.create(
          type: 'operation.cancel',
          resourceType: ResourceType.operation,
          resourceId: target.id,
          requestId: command.requestId,
          idempotencyKey: command.idempotencyKey,
          cancellable: false,
          request: JsonObjectValue.fromJson({
            'image_id': target.resourceId.value,
          }),
        );
        return IdempotencyResponse(
          JsonObjectValue.fromJson(
            OperationAcceptance.fromOperation(action).toJson(),
          ),
        );
      }

      final key = command.idempotencyKey;
      final response = key == null
          ? (await accept()).response
          : (await _idempotency.execute(
              scope: 'POST /v1/operations/${command.operationId.value}/cancel',
              key: key,
              requestBody: command.requestBody,
              action: accept,
            )).response;
      return OperationAcceptance.fromJson(response.toJson());
    });
  }

  Future<OperationAcceptance> importImage(ImageImportCommand command) async {
    if (database.hasActiveCallerTransaction)
      throw StateError('image acceptance must own its commit boundary');
    return database.transaction((db) async {
      Future<IdempotencyResponse> accept() async {
        final operation = await SqliteOperationRepository(database, now: _now)
            .create(
              type: 'image.import',
              resourceType: ResourceType.image,
              resourceId: ImageId.generate(),
              requestId: command.requestId,
              idempotencyKey: command.idempotencyKey,
              cancellable: true,
              request: JsonObjectValue.fromJson(command.toJson()),
            );
        db.execute(
          'INSERT INTO outbox(topic, key, payload_json, created_at) VALUES (?, ?, ?, ?)',
          [
            imageWorkOutboxTopic,
            operation.id.value,
            jsonEncode({'operation_id': operation.id.value}),
            formatPersistenceTimestamp(_now()),
          ],
        );
        return IdempotencyResponse(
          JsonObjectValue.fromJson(
            OperationAcceptance.fromOperation(operation).toJson(),
          ),
        );
      }

      final key = command.idempotencyKey;
      final response = key == null
          ? (await accept()).response
          : (await _idempotency.execute(
              scope: 'POST /v1/images/import',
              key: key,
              requestBody: command.requestBody,
              action: accept,
            )).response;
      return OperationAcceptance.fromJson(response.toJson());
    });
  }

  Future<OperationAcceptance> deleteImage(ImageDeleteCommand command) async {
    if (database.hasActiveCallerTransaction)
      throw StateError('image acceptance must own its commit boundary');
    return database.transaction((db) async {
      Future<IdempotencyResponse> accept() async {
        if (await store.repository.get(command.imageId) == null)
          throw ImageNotFound(command.imageId);
        final users = await store.repository.references(command.imageId);
        if (users.isNotEmpty) throw ImageInUse(command.imageId, users);
        final operation = await SqliteOperationRepository(database, now: _now)
            .create(
              type: 'image.delete',
              resourceType: ResourceType.image,
              resourceId: command.imageId,
              requestId: command.requestId,
              idempotencyKey: command.idempotencyKey,
              cancellable: false,
              request: JsonObjectValue.fromJson({
                'image_id': command.imageId.value,
              }),
            );
        db.execute(
          'INSERT INTO outbox(topic, key, payload_json, created_at) VALUES (?, ?, ?, ?)',
          [
            imageWorkOutboxTopic,
            operation.id.value,
            jsonEncode({'operation_id': operation.id.value}),
            formatPersistenceTimestamp(_now()),
          ],
        );
        return IdempotencyResponse(
          JsonObjectValue.fromJson(
            OperationAcceptance.fromOperation(operation).toJson(),
          ),
        );
      }

      final key = command.idempotencyKey;
      final response = key == null
          ? (await accept()).response
          : (await _idempotency.execute(
              scope: 'DELETE /v1/images/${command.imageId.value}',
              key: key,
              requestBody: command.requestBody,
              action: accept,
            )).response;
      return OperationAcceptance.fromJson(response.toJson());
    });
  }

  Future<void> dispatchOnce() =>
      _dispatching ??= _dispatch().whenComplete(() => _dispatching = null);

  Future<void> _dispatch() async {
    if (database.hasActiveCallerTransaction)
      throw StateError('image dispatch must own its commit boundary');
    const lease = Duration(seconds: 30);
    final commit = await database.transaction((db) async {
      final rows = db.select(
        '''SELECT * FROM outbox WHERE topic = ? AND published_at IS NULL
        AND (claimed_by IS NULL OR claim_expires_at <= ?) ORDER BY id LIMIT 1''',
        [imageWorkOutboxTopic, formatPersistenceTimestamp(_now())],
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final id = OperationId(row['key'] as String);
      final operations = SqliteOperationRepository(database, now: _now);
      final operation = await operations.get(id);
      if (operation == null ||
          !const {'image.import', 'image.delete'}.contains(operation.type) ||
          operation.resourceType != ResourceType.image ||
          !const {
            OperationState.pending,
            OperationState.running,
          }.contains(operation.state)) {
        throw StateError('invalid durable image work');
      }
      final token = RequestId.generate().value;
      db.execute(
        'UPDATE outbox SET claimed_by = ?, claim_expires_at = ?, attempts = attempts + 1 WHERE id = ?',
        [token, formatPersistenceTimestamp(_now().add(lease)), row['id']],
      );
      if (operation.state == OperationState.pending) await operations.start(id);
      return ImageOperationCommit(
        database: database,
        operationId: id,
        imageId: operation.resourceId as ImageId,
        outboxId: row['id'] as int,
        token: token,
        now: _now,
      );
    });
    if (commit == null) return;
    var lost = false;
    var cancelled = false;
    Future<void>? renewing;
    Future<void> refreshClaim() async {
      try {
        await database.transaction((db) {
          db.execute(
            '''UPDATE outbox SET claim_expires_at = ? WHERE id = ? AND topic = ?
          AND published_at IS NULL AND claimed_by = ? AND claim_expires_at > ?''',
            [
              formatPersistenceTimestamp(_now().add(lease)),
              commit.outboxId,
              imageWorkOutboxTopic,
              commit.token,
              formatPersistenceTimestamp(_now()),
            ],
          );
          if (db.updatedRows != 1) lost = true;
        });
        cancelled = await commit.cancellationRequested();
      } catch (_) {
        lost = true;
      }
    }

    Future<void> renew() =>
        renewing ??= refreshClaim().whenComplete(() => renewing = null);

    final timer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(renew());
    });
    try {
      await commit.verify();
      final operation = (await SqliteOperationRepository(
        database,
      ).get(commit.operationId))!;
      if (operation.type == 'image.delete') {
        await store.delete(commit.imageId, operation: commit);
        return;
      }
      final command = ImageImportCommand.fromJson(
        operation.request.toJson(),
        requestId: operation.requestId,
        idempotencyKey: operation.idempotencyKey,
        requestBody: const [],
      );
      if (command.type == ImageType.gaoosBundle) {
        await store.importBundle(
          Directory(command.sourcePath),
          guestProfile: command.guestProfile,
          version: command.version,
          buildId: command.buildId,
          channel: command.channel,
          labels: command.labels,
          isCancelled: () => lost || cancelled,
          operation: commit,
        );
      } else {
        await store.importFile(
          File(command.sourcePath),
          type: command.type,
          guestProfile: command.guestProfile,
          version: command.version,
          buildId: command.buildId,
          channel: command.channel,
          labels: command.labels,
          isCancelled: () => lost || cancelled,
          operation: commit,
        );
      }
    } on ImageWorkLeaseLost {
      // A new delivery owns the terminal transaction; this attempt is fenced.
    } catch (error) {
      final current = await SqliteOperationRepository(
        database,
      ).get(commit.operationId);
      if (current?.state == OperationState.succeeded)
        rethrow; // Post-commit orphan cleanup; reconcile owns recovery.
      final noSpace =
          error is ImageInsufficientSpace ||
          error is FileSystemException && error.osError?.errorCode == 28;
      final invalid =
          error is FormatException ||
          error is ArgumentError ||
          error is FileSystemException &&
              const {2, 13}.contains(error.osError?.errorCode);
      try {
        await store.finishUnpublished(
          commit,
          error: OperationError(
            code: error is ImageInUse
                ? ErrorCode.imageInUse
                : error is ImageNotFound
                ? ErrorCode.imageNotFound
                : noSpace
                ? ErrorCode.hostResourceExhausted
                : invalid
                ? ErrorCode.invalidRequest
                : ErrorCode.internalError,
            message: 'Image operation failed.',
            retryable: noSpace,
            details: JsonObjectValue.fromJson({
              'reason': noSpace
                  ? 'insufficient_space'
                  : invalid
                  ? 'invalid_source'
                  : 'storage_failure',
            }),
          ),
        );
      } on ImageWorkLeaseLost {
        // Recovery will retry this unacknowledged delivery.
      }
    } finally {
      timer.cancel();
      await renewing;
      await database.transaction((db) {
        db.execute(
          'UPDATE outbox SET claimed_by = NULL, claim_expires_at = NULL WHERE id = ? AND topic = ? AND claimed_by = ? AND published_at IS NULL',
          [commit.outboxId, imageWorkOutboxTopic, commit.token],
        );
      });
    }
  }
}

String? _metadata(Object? value) {
  if (value == null) return null;
  if (value is! String || value.isEmpty || value.length > 1024)
    throw const FormatException('invalid image metadata');
  return value;
}

Map<String, String> _labels(Object? value, bool present) {
  if (!present) return const {};
  if (value is! Map ||
      value.length > 64 ||
      value.entries.any(
        (entry) =>
            entry.key is! String ||
            (entry.key as String).length > 253 ||
            !RegExp(
              r'^[A-Za-z0-9](?:[A-Za-z0-9._/-]*[A-Za-z0-9])?$',
            ).hasMatch(entry.key as String) ||
            entry.value is! String ||
            (entry.value as String).length > 253,
      ))
    throw const FormatException('invalid image labels');
  return Map<String, String>.unmodifiable(Map<String, String>.from(value));
}
