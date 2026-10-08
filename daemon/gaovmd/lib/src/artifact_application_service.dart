import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'artifact_repository.dart';
import 'event_repository.dart';
import 'image_filesystem.dart';
import 'sqlite_database.dart';
import 'test_run_repository.dart';
import 'vm_repository.dart';

const maxManagedArtifactBytes = 256 * 1024 * 1024;
const _artifactFormat = 'gaovm.artifact.v1';

enum ArtifactPublicationCheckpoint { receiving, staged, published, committed }

final class ArtifactReconciliation {
  const ArtifactReconciliation({
    required this.removedNames,
    required this.damagedArtifactIds,
    required this.retainedNames,
  });
  final List<String> removedNames;
  final List<ArtifactId> damagedArtifactIds;
  final List<String> retainedNames;
}

final class ArtifactNotFoundException implements Exception {
  const ArtifactNotFoundException(this.id);
  final ArtifactId id;
}

final class ArtifactContentUnavailable implements Exception {
  const ArtifactContentUnavailable(this.id);
  final ArtifactId id;
}

final class ArtifactSizeLimitExceeded implements Exception {
  const ArtifactSizeLimitExceeded(this.limit);
  final int limit;
}

final class ArtifactContentMismatch implements Exception {
  const ArtifactContentMismatch();
}

final class ArtifactPublicationFailure implements Exception {
  const ArtifactPublicationFailure(this.cause, this.cleanupCause);
  final Object cause;
  final Object cleanupCause;
}

final class ArtifactDownload {
  const ArtifactDownload({required this.artifact, required this.bytes});
  final Artifact artifact;
  final Stream<List<int>> bytes;
}

final class ArtifactApplicationService {
  ArtifactApplicationService({
    required this.database,
    required this.directory,
    DateTime Function()? now,
    void Function(ArtifactPublicationCheckpoint, ArtifactId)? onCheckpoint,
  }) : repository = ArtifactRepository(database),
       _now = now ?? DateTime.now,
       _onCheckpoint = onCheckpoint;
  final GaoVmDatabase database;
  final OwnedImageDirectory directory;
  final ArtifactRepository repository;
  final DateTime Function() _now;
  final void Function(ArtifactPublicationCheckpoint, ArtifactId)? _onCheckpoint;

  Future<ArtifactPage> listForVm(
    VmId id, {
    String? cursor,
    int limit = 50,
  }) async {
    final query = ArtifactListQuery(owner: id, cursor: cursor, limit: limit);
    // Artifacts outlive ephemeral VMs; their retained catalog tombstone remains
    // a valid owner even though ordinary VM GET hides deleted resources.
    if (await SqliteVmRepository(database).get(id, includeDeleted: true) ==
        null) {
      throw VmNotFoundException(id);
    }
    return repository.list(query);
  }

  Future<ArtifactPage> listForTestRun(
    TestRunId id, {
    String? cursor,
    int limit = 50,
  }) async {
    final query = ArtifactListQuery(owner: id, cursor: cursor, limit: limit);
    if (await SqliteTestRunRepository(database).get(id) == null)
      throw TestRunNotFoundException(id);
    return repository.list(query);
  }

  Future<Artifact> publish({
    required Stream<List<int>> bytes,
    required ArtifactKind kind,
    required String contentType,
    required int maxBytes,
    int? expectedSizeBytes,
    String? expectedDigest,
    VmId? vmId,
    OperationId? operationId,
    TestRunId? testRunId,
    DateTime? retentionUntil,
  }) async {
    if (database.hasActiveCallerTransaction) {
      throw StateError('artifact publication must own its commit boundary');
    }
    if (maxBytes < 0 || maxBytes > maxManagedArtifactBytes) {
      throw ArgumentError.value(maxBytes, 'maxBytes');
    }
    if (expectedSizeBytes != null &&
        (expectedSizeBytes < 0 || expectedSizeBytes > maxBytes)) {
      throw ArgumentError.value(expectedSizeBytes, 'expectedSizeBytes');
    }
    if (expectedDigest != null &&
        !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(expectedDigest)) {
      throw const FormatException('invalid advertised artifact digest');
    }
    if (contentType.isEmpty || contentType.length > 256) {
      throw const FormatException('invalid artifact content type');
    }
    ContentType.parse(contentType);
    await _verifyRoot();
    final id = ArtifactId.generate();
    final stageName = '.stage-${id.value}';
    final lock = await directory.acquireLock('.lock-${id.value}');
    OwnedImageDirectory? stage;
    var published = false;
    try {
      stage = directory.createDirectory(stageName);
      await _write(
        stage,
        'owner.json',
        utf8.encode(
          jsonEncode({'format': _artifactFormat, 'artifact_id': id.value}),
        ),
      );
      await stage.sync();
      await directory.sync();
      final output = stage.createFile('payload');
      final hashResult = _DigestSink();
      final hash = sha256.startChunkedConversion(hashResult);
      var size = 0;
      try {
        final writer = await output.openWrite();
        try {
          await for (final chunk in bytes) {
            if (size + chunk.length > maxBytes)
              throw ArtifactSizeLimitExceeded(maxBytes);
            if (expectedSizeBytes != null &&
                size + chunk.length > expectedSizeBytes) {
              throw const ArtifactContentMismatch();
            }
            size += chunk.length;
            hash.add(chunk);
            await writer.writeFrom(chunk);
            _onCheckpoint?.call(ArtifactPublicationCheckpoint.receiving, id);
          }
          hash.close();
          await writer.flush();
        } finally {
          await writer.close();
        }
        await output.seal();
      } finally {
        output.close();
      }
      final digest = 'sha256:${hashResult.value!}';
      if (expectedSizeBytes != null && size != expectedSizeBytes ||
          expectedDigest != null && digest != expectedDigest) {
        throw const ArtifactContentMismatch();
      }
      final artifact = Artifact(
        id: id,
        vmId: vmId,
        operationId: operationId,
        testRunId: testRunId,
        kind: kind,
        contentType: contentType,
        sizeBytes: size,
        digest: digest,
        downloadUrl: '/v1/artifacts/${id.value}',
        retentionUntil: retentionUntil,
        createdAt: _now().toUtc(),
      );
      await _write(
        stage,
        'manifest.json',
        utf8.encode(
          jsonEncode({
            'format': _artifactFormat,
            'artifact': artifact.toJson(),
          }),
        ),
      );
      await stage.sync();
      _onCheckpoint?.call(ArtifactPublicationCheckpoint.staged, id);
      final publication = await directory.acquireLock('.gaovmd-artifacts.lock');
      try {
        await _verifyRoot();
        await stage.verifyPathBinding();
        await database.transaction((_) async {
          await directory.renameDirectoryNoReplace(stageName, id.value);
          published = true;
          _onCheckpoint?.call(ArtifactPublicationCheckpoint.published, id);
          await repository.publish(artifact, managedPayload: true);
        });
      } finally {
        publication.close();
      }
      // A diagnostic observer cannot turn a committed resource into failure.
      try {
        _onCheckpoint?.call(ArtifactPublicationCheckpoint.committed, id);
      } catch (_) {}
      return artifact;
    } catch (error, stack) {
      if (stage != null && await repository.get(id) == null) {
        try {
          await _removeOwned(published ? id.value : stageName, id);
        } catch (cleanup) {
          throw ArtifactPublicationFailure(error, cleanup);
        }
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      stage?.close();
      lock.close();
    }
  }

  Future<ArtifactReconciliation> reconcile() async {
    if (database.hasActiveCallerTransaction) {
      throw StateError('artifact reconciliation must own its commit boundary');
    }
    await _verifyRoot();
    final publication = await directory.acquireLock('.gaovmd-artifacts.lock');
    final removed = <String>[];
    final retained = <String>[];
    final damaged = <ArtifactId>[];
    try {
      await _verifyRoot();
      await for (final entry in Directory(
        directory.path,
      ).list(followLinks: false)) {
        final name = entry.path.split('/').last;
        if (entry is File &&
            (name == '.gaovmd-artifacts.lock' ||
                name.startsWith('.lock-') &&
                    _artifactId(name.substring(6)) != null)) {
          continue;
        }
        final isStage = name.startsWith('.stage-');
        final id = _artifactId(isStage ? name.substring(7) : name);
        if (id == null || entry is! Directory) {
          retained.add(name);
          continue;
        }
        final lock = await directory.tryAcquireLock('.lock-${id.value}');
        if (lock == null) continue; // A live writer owns this namespace.
        try {
          final registered = await repository.get(id);
          if (registered != null) {
            if (isStage || !await repository.hasManagedPayload(id))
              retained.add(name);
            continue;
          }
          try {
            if (!isStage) {
              final child = directory.directory(name);
              Artifact? manifest;
              try {
                // Interrupted cleanup may already have removed the payload.
                // Remaining nonempty content still requires matching ownership
                // proof and a complete allowlist check in _removeOwned.
                final payload = child.fileOrNull('payload');
                if (payload != null) {
                  payload.close();
                  final file = child.file('manifest.json');
                  try {
                    final json = jsonDecode(
                      utf8.decode(await file.readBounded(64 * 1024)),
                    );
                    if (json is! Map || json['format'] != _artifactFormat)
                      throw const FormatException('unknown artifact format');
                    manifest = Artifact.fromJson(json['artifact']);
                    if (manifest.id != id)
                      throw const FormatException(
                        'artifact directory identity mismatch',
                      );
                  } finally {
                    file.close();
                  }
                }
              } finally {
                child.close();
              }
              if (manifest != null) (await _verifiedPayload(manifest)).close();
            }
            await SqliteEventRepository(database).append(
              type: 'artifact.store_cleanup_started',
              resourceType: ResourceType.system,
              payload: JsonObjectValue.fromJson({
                'entry': name,
                'artifact_id': id.value,
              }),
              occurredAt: _now(),
            );
            await _removeOwned(name, id);
            removed.add(name);
          } on FileSystemException {
            retained.add(name);
          } on FormatException {
            retained.add(name);
          } on StateError {
            retained.add(name);
          } on ArtifactContentUnavailable {
            retained.add(name);
          }
        } finally {
          lock.close();
        }
      }
      ArtifactId? after;
      while (true) {
        final page = await repository.listManaged(afterId: after);
        if (page.isEmpty) break;
        for (final artifact in page) {
          try {
            (await _verifiedPayload(artifact)).close();
          } catch (_) {
            damaged.add(artifact.id);
          }
        }
        after = page.last.id;
      }
      if (removed.isNotEmpty) {
        await SqliteEventRepository(database).append(
          type: 'artifact.store_cleaned',
          resourceType: ResourceType.system,
          payload: JsonObjectValue.fromJson({'removed_entries': removed}),
          occurredAt: _now(),
        );
      }
      return ArtifactReconciliation(
        removedNames: List.unmodifiable(removed),
        damagedArtifactIds: List.unmodifiable(damaged),
        retainedNames: List.unmodifiable(retained),
      );
    } finally {
      publication.close();
    }
  }

  Future<ArtifactDownload> download(ArtifactId id) async {
    final artifact = await repository.get(id);
    if (artifact == null) throw ArtifactNotFoundException(id);
    if (!await repository.hasManagedPayload(id))
      throw ArtifactContentUnavailable(id);
    final verified = await _verifiedPayload(artifact);
    verified.close();
    // No file descriptor survives in an unconsumed response. The stream opens
    // and revalidates its own held inode only when the transport subscribes.
    return ArtifactDownload(artifact: artifact, bytes: _read(artifact));
  }

  Stream<List<int>> _read(Artifact artifact) async* {
    final file = await _verifiedPayload(artifact);
    try {
      var size = 0;
      final result = _DigestSink();
      final hash = sha256.startChunkedConversion(result);
      await for (final chunk in file.openRead()) {
        size += chunk.length;
        if (size > artifact.sizeBytes)
          throw ArtifactContentUnavailable(artifact.id);
        hash.add(chunk);
        yield chunk;
      }
      hash.close();
      if (size != artifact.sizeBytes ||
          'sha256:${result.value!}' != artifact.digest) {
        throw ArtifactContentUnavailable(artifact.id);
      }
    } finally {
      file.close();
    }
  }

  Future<OwnedImageFile> _verifiedPayload(Artifact artifact) async {
    await _verifyRoot();
    final child = directory.directory(artifact.id.value);
    OwnedImageFile? payload;
    try {
      if (child.mode & 0x3f != 0) throw ArtifactContentUnavailable(artifact.id);
      final manifest = child.file('manifest.json');
      try {
        final json = jsonDecode(
          utf8.decode(await manifest.readBounded(64 * 1024)),
        );
        if (json is! Map ||
            json['format'] != _artifactFormat ||
            Artifact.fromJson(json['artifact']) != artifact) {
          throw ArtifactContentUnavailable(artifact.id);
        }
      } finally {
        manifest.close();
      }
      payload = child.file('payload');
      if (payload.size != artifact.sizeBytes || payload.mode & 0x1ff != 0x100) {
        throw ArtifactContentUnavailable(artifact.id);
      }
      var size = 0;
      final digest = await sha256
          .bind(
            payload.openRead().map((chunk) {
              size += chunk.length;
              if (size > artifact.sizeBytes)
                throw ArtifactContentUnavailable(artifact.id);
              return chunk;
            }),
          )
          .first;
      if (size != artifact.sizeBytes || 'sha256:$digest' != artifact.digest) {
        throw ArtifactContentUnavailable(artifact.id);
      }
      return payload;
    } catch (_) {
      payload?.close();
      rethrow;
    } finally {
      child.close();
    }
  }

  Future<void> _verifyRoot() async {
    await directory.verifyPathBinding();
    if (directory.mode & 0x3f != 0)
      throw StateError('artifact root must be private');
  }

  Future<void> _removeOwned(String name, ArtifactId id) async {
    await _verifyRoot();
    final child = directory.directoryOrNull(name);
    if (child == null) return;
    try {
      final names = <String>[];
      await for (final entry in Directory(
        child.path,
      ).list(followLinks: false)) {
        final leaf = entry.path.split('/').last;
        if (!const {'owner.json', 'payload', 'manifest.json'}.contains(leaf)) {
          throw StateError('artifact directory contains unknown content');
        }
        child.file(leaf).close();
        names.add(leaf);
      }
      // Empty namespaces contain no bytes to claim: cleanup may have exited
      // after removing the last marker but before removing the directory.
      if (names.isNotEmpty) {
        final marker = child.file('owner.json');
        try {
          final json = jsonDecode(utf8.decode(await marker.readBounded(4096)));
          if (json is! Map ||
              json['format'] != _artifactFormat ||
              json['artifact_id'] != id.value) {
            throw StateError(
              'artifact directory has no matching ownership proof',
            );
          }
        } finally {
          marker.close();
        }
      }
      await child.verifyPathBinding();
      // Ownership proof is removed last, so interrupted cleanup remains proven.
      for (final leaf in ['payload', 'manifest.json', 'owner.json']) {
        if (names.contains(leaf)) child.removeFile(leaf);
      }
      await child.sync();
    } finally {
      child.close();
    }
    directory.removeDirectory(name);
    await directory.sync();
  }
}

Future<void> _write(
  OwnedImageDirectory directory,
  String name,
  List<int> bytes,
) async {
  final output = directory.createFile(name);
  try {
    final writer = await output.openWrite();
    try {
      await writer.writeFrom(bytes);
      await writer.flush();
    } finally {
      await writer.close();
    }
    await output.seal();
  } finally {
    output.close();
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

ArtifactId? _artifactId(String value) {
  try {
    return ArtifactId(value);
  } on ArgumentError {
    return null;
  } on FormatException {
    return null;
  }
}
