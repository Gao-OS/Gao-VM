import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:gaovmd/src/artifact_retention_loop.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'helpers/owned_test_process.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OwnedImageDirectory root;
  late TestRun run;
  final children = <OwnedTestProcess>[];
  var fixtureClosed = false;
  ArtifactApplicationService service() =>
      ArtifactApplicationService(database: database, directory: root);

  Future<ProcessResult> crashArtifact(String checkpoint) async {
    final child = OwnedTestProcess(
      await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        'test/helpers/artifact_crash_child.dart',
        root.path,
        '${temporary.path}/catalog.db',
        run.id.value,
        run.operationId.value,
        checkpoint,
      ]),
    );
    children.add(child);
    return child.result(timeout: const Duration(seconds: 30));
  }

  Future<void> closeFixture() async {
    if (fixtureClosed) return;
    final unconfirmed = <int>[];
    for (final child in children) {
      if (!await child.terminate()) unconfirmed.add(child.pid);
    }
    if (unconfirmed.isNotEmpty) {
      throw StateError(
        'artifact fixture retained at ${temporary.path}; '
        'child exit unconfirmed: ${unconfirmed.join(', ')}',
      );
    }
    root.close();
    database.close();
    await temporary.delete(recursive: true);
    fixtureClosed = true;
  }

  test('artifact fixture confirms child exit before deleting state', () async {
    final child = OwnedTestProcess(await Process.start('/bin/sleep', ['60']));
    children.add(child);
    try {
      await closeFixture();
      expect(child.exitConfirmed, isTrue);
      expect(await temporary.exists(), isFalse);
    } finally {
      await child.terminate();
    }
  });

  test('artifact fixture retains state without a child exit receipt', () async {
    final exit = Completer<int>();
    final child = OwnedTestProcess(_UnconfirmedProcess(exit.future));
    children.add(child);
    try {
      await expectLater(
        closeFixture(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'retention diagnostic',
            contains('retained'),
          ),
        ),
      );
      expect(child.exitConfirmed, isFalse);
      expect(await temporary.exists(), isTrue);
      expect(await SqliteTestRunRepository(database).get(run.id), run);
    } finally {
      exit.complete(0);
      await child.terminate();
    }
  });

  test(
    'retention collection removes only expired unreferenced managed bytes',
    () async {
      final expired = await service().publish(
        bytes: Stream.value([1, 2, 3]),
        kind: ArtifactKind.file,
        contentType: 'application/octet-stream',
        maxBytes: 3,
        retentionUntil: DateTime.utc(2000),
      );
      final pinned = await service().publish(
        bytes: Stream.value([4, 5, 6]),
        kind: ArtifactKind.stdout,
        contentType: 'application/octet-stream',
        maxBytes: 3,
        testRunId: run.id,
        operationId: run.operationId,
        retentionUntil: DateTime.utc(2000),
      );
      final future = await service().publish(
        bytes: Stream.value([7]),
        kind: ArtifactKind.file,
        contentType: 'application/octet-stream',
        maxBytes: 1,
        retentionUntil: DateTime.utc(2100),
      );
      // Startup reconciliation is also the first retention pass. It must make a
      // durable catalog decision before deleting its proven private payload.
      final recovery = await service().reconcile();
      expect(recovery.removedNames, contains(expired.id.value));
      await expectLater(
        service().download(expired.id),
        throwsA(isA<ArtifactNotFoundException>()),
      );
      expect(
        await Directory('${root.path}/${expired.id.value}').exists(),
        isFalse,
      );
      expect(
        await (await service().download(
          pinned.id,
        )).bytes.expand((bytes) => bytes).toList(),
        [4, 5, 6],
      );
      expect(
        await (await service().download(
          future.id,
        )).bytes.expand((bytes) => bytes).toList(),
        [7],
      );
      expect(
        (await SqliteTestRunRepository(database).get(run.id))!.artifactIds,
        contains(pinned.id),
      );
      expect(
        (await SqliteEventRepository(
          database,
        ).list(resourceId: expired.id)).map((event) => event.type),
        contains('artifact.deleted'),
      );
      expect((await service().reconcile()).removedNames, isEmpty);
    },
  );

  setUp(() async {
    children.clear();
    fixtureClosed = false;
    temporary = await Directory.systemTemp.createTemp('gvm-art-store-');
    final directory = await Directory('${temporary.path}/artifacts').create();
    imageFileMode(directory.path, 0x1c0);
    root = await OwnedImageDirectory.open(directory);
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    run = await SqliteTestRunRepository(database).create(
      requestId: RequestId.generate(),
      spec: TestRunSpec(
        source: ImageTestRunSource(ImageId.generate()),
        wait: VmWaitSpec(
          condition: WaitCondition.guestAgentReady,
          timeoutSeconds: 30,
        ),
        steps: [
          TestStepRequest(argv: ['true'], timeoutSeconds: 60),
        ],
        cleanup: CleanupPolicy.deleteOnSuccess,
        retainOnFailure: true,
      ),
    );
  });

  test(
    'retention pins terminal operation results and preserves unknown content',
    () async {
      final referenced = await service().publish(
        bytes: Stream.value([1]),
        kind: ArtifactKind.file,
        contentType: 'application/octet-stream',
        maxBytes: 1,
        retentionUntil: DateTime.utc(2000),
      );
      final operations = SqliteOperationRepository(database);
      final reference = await operations.createAndStart(
        type: 'artifact.audit',
        resourceType: ResourceType.testRun,
        resourceId: run.id,
        requestId: RequestId.generate(),
        cancellable: false,
        request: JsonObjectValue.empty,
      );
      await operations.succeed(
        reference.id,
        result: JsonObjectValue.fromJson({'artifact_id': referenced.id.value}),
      );
      final unknown = await service().publish(
        bytes: Stream.value([2]),
        kind: ArtifactKind.file,
        contentType: 'application/octet-stream',
        maxBytes: 1,
        retentionUntil: DateTime.utc(2000),
      );
      final evidence = await File(
        '${root.path}/${unknown.id.value}/operator-evidence',
      ).writeAsString('preserve');
      expect(await service().collectExpired(), isEmpty);
      expect(await service().repository.get(referenced.id), referenced);
      expect(await service().repository.get(unknown.id), unknown);
      expect(await evidence.readAsString(), 'preserve');
      expect(
        (await SqliteEventRepository(
          database,
        ).list()).where((event) => event.type == 'artifact.deleted'),
        isEmpty,
      );
    },
  );

  test(
    'a committed retention deletion is recoverable before byte cleanup',
    () async {
      final artifact = await service().publish(
        bytes: Stream.value([1]),
        kind: ArtifactKind.file,
        contentType: 'application/octet-stream',
        maxBytes: 1,
        retentionUntil: DateTime.utc(2000),
      );
      expect(
        await service().repository.expireUnreferenced(
          artifact.id,
          DateTime.now(),
        ),
        isTrue,
      );
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      expect((await service().reconcile()).removedNames, [artifact.id.value]);
      expect(
        await Directory('${root.path}/${artifact.id.value}').exists(),
        isFalse,
      );
      expect(
        (await SqliteEventRepository(database).list(
          resourceId: artifact.id,
        )).where((event) => event.type == 'artifact.deleted'),
        hasLength(1),
      );
    },
  );

  test('retention loop drains its owned pass before shutdown', () async {
    final artifact = await service().publish(
      bytes: Stream.value([1]),
      kind: ArtifactKind.file,
      contentType: 'application/octet-stream',
      maxBytes: 1,
      retentionUntil: DateTime.utc(2000),
    );
    final errors = <Object>[];
    final loop = ArtifactRetentionLoop(
      artifacts: service(),
      onError: (error, _) => errors.add(error),
    );
    loop.start();
    loop.start();
    await loop.close();
    expect(errors, isEmpty);
    expect(await service().repository.get(artifact.id), isNull);
    expect(() => loop.start(), throwsStateError);
  });

  tearDown(closeFixture);

  test('a server-reserved publication replays after catalog reopen', () async {
    final id = ArtifactId.generate();
    final retention = DateTime.utc(2026, 11, 7);
    final first = await service().publish(
      artifactId: id,
      bytes: Stream.value([1, 2, 3]),
      kind: ArtifactKind.result,
      contentType: 'application/json',
      maxBytes: 16,
      testRunId: run.id,
      operationId: run.operationId,
      retentionUntil: retention,
    );
    expect(first.id, id);
    database.close();
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    var consumed = false;
    Stream<List<int>> retryInput() async* {
      consumed = true;
      yield [4, 5, 6];
    }

    final retry = await service().publish(
      artifactId: id,
      bytes: retryInput(),
      kind: ArtifactKind.result,
      contentType: 'application/json',
      maxBytes: 16,
      testRunId: run.id,
      operationId: run.operationId,
      retentionUntil: retention,
    );
    expect(retry, first);
    expect(consumed, isFalse);
    expect((await SqliteTestRunRepository(database).get(run.id))!.artifactIds, [
      id,
    ]);
    final content = await service().download(id);
    expect(await content.bytes.expand((chunk) => chunk).toList(), [1, 2, 3]);
  });

  for (final revisedRetention in [
    DateTime.utc(2026, 11, 14),
    null,
    DateTime.utc(2000),
  ]) {
    test(
      'SQLite retention $revisedRetention keeps referenced bytes after reopen',
      () async {
        final bytes = [0, 255, 10, 13, 128, 1];
        final artifact = await service().publish(
          bytes: Stream.value(bytes),
          kind: ArtifactKind.stdout,
          contentType: 'application/octet-stream',
          maxBytes: 16,
          testRunId: run.id,
          operationId: run.operationId,
          retentionUntil: DateTime.utc(2026, 11, 7),
        );
        final manifest = File(
          '${root.path}/${artifact.id.value}/manifest.json',
        );
        final sealedManifest = await manifest.readAsBytes();
        // Simulate a retention policy write at the real SQLite boundary. This
        // does not choose default deadlines or implement a policy/GC worker.
        await database.transaction(
          (db) => db.execute(
            'UPDATE artifacts SET retention_until = ? WHERE id = ?',
            [revisedRetention?.toIso8601String(), artifact.id.value],
          ),
        );
        database.close();
        database = await GaoVmDatabase.open('${temporary.path}/catalog.db');

        final download = await service().download(artifact.id);
        expect(download.artifact.retentionUntil, revisedRetention);
        expect(download.artifact.digest, artifact.digest);
        expect(download.artifact.sizeBytes, bytes.length);
        expect(await download.bytes.expand((chunk) => chunk).toList(), bytes);
        final recovery = await service().reconcile();
        expect(recovery.damagedArtifactIds, isEmpty);
        expect(recovery.removedNames, isEmpty);
        expect(recovery.retainedNames, isEmpty);
        expect((await service().listForTestRun(run.id)).items, [
          download.artifact,
        ]);
        expect(await manifest.readAsBytes(), sealedManifest);
      },
    );
  }

  for (final originalRetention in [DateTime.utc(2026, 11, 7), null]) {
    test(
      'reserved replay with original retention $originalRetention preserves revised retention without consuming input',
      () async {
        final id = ArtifactId.generate();
        final revisedRetention = DateTime.utc(2026, 11, 14);
        final first = await service().publish(
          artifactId: id,
          bytes: Stream.value([1, 2, 3]),
          kind: ArtifactKind.result,
          contentType: 'application/json',
          maxBytes: 16,
          testRunId: run.id,
          operationId: run.operationId,
          retentionUntil: originalRetention,
        );
        await database.transaction(
          (db) => db.execute(
            'UPDATE artifacts SET retention_until = ? WHERE id = ?',
            [revisedRetention.toIso8601String(), id.value],
          ),
        );
        database.close();
        database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
        final events = SqliteEventRepository(database);
        final before = await events.list();
        var consumed = false;
        Stream<List<int>> retryInput() async* {
          consumed = true;
          yield [4, 5, 6];
        }

        final retry = await service().publish(
          artifactId: id,
          bytes: retryInput(),
          kind: ArtifactKind.result,
          contentType: 'application/json',
          maxBytes: 16,
          testRunId: run.id,
          operationId: run.operationId,
          retentionUntil: originalRetention,
        );
        expect(consumed, isFalse);
        expect(
          retry,
          Artifact.fromJson({
            ...first.toJson(),
            'retention_until': revisedRetention.toIso8601String(),
          }),
        );
        expect(await ArtifactRepository(database).get(id), retry);
        expect(
          (await SqliteTestRunRepository(database).get(run.id))!.artifactIds,
          [id],
        );
        expect(await events.list(), before);
        final content = await service().download(id);
        expect(content.artifact, retry);
        expect(await content.bytes.expand((chunk) => chunk).toList(), [
          1,
          2,
          3,
        ]);
      },
    );
  }

  test(
    'a reserved retry cannot adopt revised retention as publication input',
    () async {
      final id = ArtifactId.generate();
      final originalRetention = DateTime.utc(2026, 11, 7);
      final revisedRetention = DateTime.utc(2026, 11, 14);
      final artifact = await service().publish(
        artifactId: id,
        bytes: Stream.value([1, 2, 3]),
        kind: ArtifactKind.result,
        contentType: 'application/json',
        maxBytes: 16,
        retentionUntil: originalRetention,
      );
      await database.transaction(
        (db) => db.execute(
          'UPDATE artifacts SET retention_until = ? WHERE id = ?',
          [revisedRetention.toIso8601String(), id.value],
        ),
      );
      final before = await SqliteEventRepository(database).list();
      var consumed = false;
      Stream<List<int>> retryInput() async* {
        consumed = true;
        yield [4, 5, 6];
      }

      for (final retention in [revisedRetention, null]) {
        await expectLater(
          service().publish(
            artifactId: id,
            bytes: retryInput(),
            kind: ArtifactKind.result,
            contentType: 'application/json',
            maxBytes: 16,
            retentionUntil: retention,
          ),
          throwsA(isA<ArtifactPublicationConflict>()),
        );
      }
      expect(consumed, isFalse);
      expect(await SqliteEventRepository(database).list(), before);
      final download = await service().download(id);
      expect(download.artifact.retentionUntil, revisedRetention);
      expect(download.artifact.digest, artifact.digest);
      expect(await download.bytes.expand((chunk) => chunk).toList(), [1, 2, 3]);
    },
  );

  for (final entry in <String, Object?>{
    'id': ArtifactId.generate().value,
    'vm_id': VmId.generate().value,
    'operation_id': OperationId.generate().value,
    'test_run_id': TestRunId.generate().value,
    'kind': 'stderr',
    'content_type': 'text/plain',
    'size_bytes': 4,
    'digest': contentDigest('different'),
    'download_url': '/v1/artifacts/${ArtifactId.generate().value}',
    'created_at': DateTime.utc(2000).toIso8601String(),
  }.entries) {
    test(
      'retention updates do not bypass sealed ${entry.key} integrity',
      () async {
        final artifact = await service().publish(
          bytes: Stream.value([1, 2, 3]),
          kind: ArtifactKind.stdout,
          contentType: 'application/octet-stream',
          maxBytes: 16,
          testRunId: run.id,
          operationId: run.operationId,
          retentionUntil: DateTime.utc(2026, 11, 7),
        );
        await database.transaction(
          (db) => db.execute(
            'UPDATE artifacts SET retention_until = ? WHERE id = ?',
            [DateTime.utc(2026, 11, 14).toIso8601String(), artifact.id.value],
          ),
        );
        // Fault injection changes one otherwise well-formed immutable field
        // in this test's owned manifest, not the catalog or payload bytes.
        final manifest = File(
          '${root.path}/${artifact.id.value}/manifest.json',
        );
        final json = jsonDecode(await manifest.readAsString()) as Map;
        (json['artifact'] as Map)[entry.key] = entry.value;
        imageFileMode(manifest.path, 0x180);
        await manifest.writeAsString(jsonEncode(json));
        imageFileMode(manifest.path, 0x100);

        await expectLater(
          service().download(artifact.id),
          throwsA(isA<ArtifactContentUnavailable>()),
        );
        final recovery = await service().reconcile();
        expect(recovery.damagedArtifactIds, [artifact.id]);
        expect(recovery.removedNames, isEmpty);
        expect(
          await File('${root.path}/${artifact.id.value}/payload').readAsBytes(),
          [1, 2, 3],
        );
      },
    );
  }

  test('sealed binary payload and catalog references survive reopen', () async {
    final bytes = [0, 255, 10, 13, 128, 1];
    final artifact = await service().publish(
      bytes: Stream.fromIterable([bytes.sublist(0, 2), bytes.sublist(2)]),
      kind: ArtifactKind.stdout,
      contentType: 'application/octet-stream',
      maxBytes: 16,
      testRunId: run.id,
      operationId: run.operationId,
      retentionUntil: DateTime.utc(2026, 11, 7),
    );
    expect(artifact.id.value, startsWith('art_'));
    expect(artifact.sizeBytes, bytes.length);
    expect(artifact.digest, 'sha256:${sha256.convert(bytes)}');
    expect(artifact.retentionUntil, DateTime.utc(2026, 11, 7));
    expect(
      (await File('${root.path}/${artifact.id.value}/payload').stat()).mode &
          0x1ff,
      0x100,
    );
    database.close();
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    final download = await service().download(artifact.id);
    expect(download.artifact, artifact);
    expect(await download.bytes.expand((chunk) => chunk).toList(), bytes);
    expect(await ArtifactRepository(database).get(artifact.id), artifact);
    expect(
      await ArtifactRepository(database).hasManagedPayload(artifact.id),
      isTrue,
    );
    expect((await SqliteTestRunRepository(database).get(run.id))!.artifactIds, [
      artifact.id,
    ]);
  });

  test(
    'output budget stops consumption and removes only its unpublished files',
    () async {
      var chunks = 0;
      var cancelled = false;
      Stream<List<int>> source() async* {
        try {
          for (var index = 0; index < 100; index++) {
            chunks++;
            yield List<int>.filled(65536, index);
          }
        } finally {
          cancelled = true;
        }
      }

      final before = await SqliteEventRepository(database).list();
      await expectLater(
        service().publish(
          bytes: source(),
          kind: ArtifactKind.stdout,
          contentType: 'text/plain',
          maxBytes: 2 * 65536,
          testRunId: run.id,
          operationId: run.operationId,
        ),
        throwsA(isA<ArtifactSizeLimitExceeded>()),
      );
      expect(chunks, 3);
      expect(cancelled, isTrue);
      expect(
        (await SqliteTestRunRepository(database).get(run.id))!.artifactIds,
        isEmpty,
      );
      expect(await SqliteEventRepository(database).list(), before);
      expect(
        await Directory(root.path)
            .list(followLinks: false)
            .where((entry) => entry is Directory)
            .toList(),
        isEmpty,
      );
    },
  );

  test('advertised size and digest mismatches never become visible', () async {
    for (final mismatchSize in [true, false]) {
      final before = await SqliteEventRepository(database).list();
      await expectLater(
        service().publish(
          bytes: Stream.value([1, 2, 3]),
          kind: ArtifactKind.stdout,
          contentType: 'application/octet-stream',
          maxBytes: 16,
          expectedSizeBytes: mismatchSize ? 4 : 3,
          expectedDigest: mismatchSize
              ? 'sha256:${sha256.convert([1, 2, 3])}'
              : contentDigest('wrong'),
          testRunId: run.id,
          operationId: run.operationId,
        ),
        throwsA(isA<ArtifactContentMismatch>()),
      );
      expect(
        (await SqliteTestRunRepository(database).get(run.id))!.artifactIds,
        isEmpty,
      );
      expect(await SqliteEventRepository(database).list(), before);
      expect(
        await Directory(root.path)
            .list(followLinks: false)
            .where((entry) => entry is Directory)
            .toList(),
        isEmpty,
      );
    }
  });

  test(
    'same-length corruption and symlink payloads are never downloaded',
    () async {
      final artifact = await service().publish(
        bytes: Stream.value([1, 2, 3]),
        kind: ArtifactKind.stdout,
        contentType: 'application/octet-stream',
        maxBytes: 16,
      );
      final payload = File('${root.path}/${artifact.id.value}/payload');
      imageFileMode(payload.path, 0x180);
      await payload.writeAsBytes([4, 5, 6]);
      imageFileMode(payload.path, 0x100);
      await expectLater(
        service().download(artifact.id),
        throwsA(isA<ArtifactContentUnavailable>()),
      );
      final outside = await File(
        '${temporary.path}/outside',
      ).writeAsString('secret');
      await payload.delete();
      await Link(payload.path).create(outside.path);
      await expectLater(
        service().download(artifact.id),
        throwsA(isA<FileSystemException>()),
      );
      expect(await outside.readAsString(), 'secret');
    },
  );

  test(
    'publication refuses a caller-owned transaction before consuming input',
    () async {
      var consumed = false;
      Stream<List<int>> source() async* {
        consumed = true;
        yield [1];
      }

      await database.transaction((_) async {
        await expectLater(
          service().publish(
            bytes: source(),
            kind: ArtifactKind.result,
            contentType: 'application/json',
            maxBytes: 16,
          ),
          throwsStateError,
        );
      });
      expect(consumed, isFalse);
      expect(
        await Directory(root.path).list(followLinks: false).toList(),
        isEmpty,
      );
    },
  );

  test(
    'process exit after staging leaves no accepted artifact and is recoverable',
    () async {
      final child = await crashArtifact('staged');
      expect(child.exitCode, 73, reason: '${child.stdout}\n${child.stderr}');
      final proof =
          jsonDecode(
                await File(
                  '${temporary.path}/crash-staged.json',
                ).readAsString(),
              )
              as Map;
      final id = ArtifactId(proof['artifact_id'] as String);
      expect(await ArtifactRepository(database).get(id), isNull);
      expect(
        await Directory('${root.path}/.stage-${id.value}').exists(),
        isTrue,
      );
      final result = await service().reconcile();
      expect(result.removedNames, ['.stage-${id.value}']);
      expect(result.damagedArtifactIds, isEmpty);
      expect(result.retainedNames, isEmpty);
      expect(
        await Directory('${root.path}/.stage-${id.value}').exists(),
        isFalse,
      );
      expect(
        (await SqliteTestRunRepository(database).get(run.id))!.artifactIds,
        isEmpty,
      );
      expect(
        (await SqliteEventRepository(
          database,
        ).list()).any((event) => event.type == 'artifact.store_cleaned'),
        isTrue,
      );
    },
  );

  for (final checkpoint in ['receiving', 'published', 'committed']) {
    test(
      'process exit at $checkpoint respects the catalog commit boundary',
      () async {
        final child = await crashArtifact(checkpoint);
        expect(child.exitCode, 73, reason: '${child.stdout}\n${child.stderr}');
        final proof =
            jsonDecode(
                  await File(
                    '${temporary.path}/crash-$checkpoint.json',
                  ).readAsString(),
                )
                as Map;
        final id = ArtifactId(proof['artifact_id'] as String);
        final committed = checkpoint == 'committed';
        expect(
          await ArtifactRepository(database).get(id),
          committed ? isNotNull : isNull,
        );
        final result = await service().reconcile();
        expect(result.damagedArtifactIds, isEmpty);
        expect(result.retainedNames, isEmpty);
        expect(
          result.removedNames,
          committed
              ? isEmpty
              : [checkpoint == 'receiving' ? '.stage-${id.value}' : id.value],
        );
        expect(
          (await SqliteTestRunRepository(database).get(run.id))!.artifactIds,
          committed ? [id] : isEmpty,
        );
        if (committed) {
          expect(
            await (await service().download(
              id,
            )).bytes.expand((chunk) => chunk).toList(),
            [1, 2, 3],
          );
          expect(
            (await SqliteEventRepository(
              database,
            ).list()).where((event) => event.type == 'artifact.created'),
            hasLength(1),
          );
        }
        expect((await service().reconcile()).removedNames, isEmpty);
      },
    );
  }

  test(
    'recovery skips a live writer without blocking another publication',
    () async {
      final started = Completer<void>();
      final resume = Completer<void>();
      Stream<List<int>> input() async* {
        yield [1];
        await resume.future;
        yield [2];
      }

      final writing =
          ArtifactApplicationService(
            database: database,
            directory: root,
            onCheckpoint: (checkpoint, _) {
              if (checkpoint == ArtifactPublicationCheckpoint.receiving &&
                  !started.isCompleted)
                started.complete();
            },
          ).publish(
            bytes: input(),
            kind: ArtifactKind.stdout,
            contentType: 'text/plain',
            maxBytes: 16,
          );
      await started.future.timeout(const Duration(seconds: 5));
      try {
        final result = await service().reconcile().timeout(
          const Duration(seconds: 5),
        );
        expect(result.removedNames, isEmpty);
        expect(result.retainedNames, isEmpty);
        final other = await service().publish(
          bytes: Stream.value([3]),
          kind: ArtifactKind.stderr,
          contentType: 'text/plain',
          maxBytes: 16,
        );
        expect(
          await (await service().download(
            other.id,
          )).bytes.expand((chunk) => chunk).toList(),
          [3],
        );
      } finally {
        resume.complete();
      }
      final artifact = await writing;
      expect(
        await (await service().download(
          artifact.id,
        )).bytes.expand((chunk) => chunk).toList(),
        [1, 2],
      );
    },
  );

  test(
    'deferred commit failure compensates payload, links, events and outbox',
    () async {
      await database.transaction(
        (db) => db.execute('''
      CREATE TABLE artifact_commit_fault(id TEXT REFERENCES vms(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER inject_artifact_commit_failure AFTER INSERT ON artifacts
      BEGIN INSERT INTO artifact_commit_fault VALUES('missing'); END;
    '''),
      );
      final events = SqliteEventRepository(database);
      final before = await events.list();
      final outbox = (await events.readUnpublishedOutbox())
          .map((row) => row.id)
          .toList();
      await expectLater(
        service().publish(
          bytes: Stream.value([1, 2, 3]),
          kind: ArtifactKind.stdout,
          contentType: 'text/plain',
          maxBytes: 16,
          testRunId: run.id,
          operationId: run.operationId,
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(await ArtifactRepository(database).listManaged(), isEmpty);
      expect(
        (await SqliteTestRunRepository(database).get(run.id))!.artifactIds,
        isEmpty,
      );
      expect(await events.list(), before);
      expect(
        (await events.readUnpublishedOutbox()).map((row) => row.id),
        outbox,
      );
      expect(
        await Directory(root.path)
            .list(followLinks: false)
            .where((entry) => entry is Directory)
            .toList(),
        isEmpty,
      );
    },
  );

  test(
    'rollback and recovery preserve unknown content and the primary failure',
    () async {
      late ArtifactId id;
      final cause = StateError('injected publication interruption');
      await expectLater(
        ArtifactApplicationService(
          database: database,
          directory: root,
          onCheckpoint: (checkpoint, artifactId) {
            if (checkpoint != ArtifactPublicationCheckpoint.staged) return;
            id = artifactId;
            File(
              '${root.path}/.stage-${id.value}/keep.txt',
            ).writeAsStringSync('unknown evidence');
            throw cause;
          },
        ).publish(
          bytes: Stream.value([1, 2, 3]),
          kind: ArtifactKind.stdout,
          contentType: 'text/plain',
          maxBytes: 16,
        ),
        throwsA(
          isA<ArtifactPublicationFailure>().having(
            (failure) => failure.cause,
            'primary cause',
            same(cause),
          ),
        ),
      );
      final result = await service().reconcile();
      expect(result.removedNames, isEmpty);
      expect(result.retainedNames, ['.stage-${id.value}']);
      expect(
        await File('${root.path}/.stage-${id.value}/keep.txt').readAsString(),
        'unknown evidence',
      );
      expect(
        await File('${root.path}/.stage-${id.value}/payload').readAsBytes(),
        [1, 2, 3],
      );
      expect(await ArtifactRepository(database).get(id), isNull);
    },
  );

  test(
    'recovery resumes after the last ownership marker was already removed',
    () async {
      final names = <String>[];
      for (final prefix in ['.stage-', '']) {
        final name = '$prefix${ArtifactId.generate().value}';
        root.createDirectory(name).close();
        names.add(name);
      }
      await root.sync();
      final result = await service().reconcile();
      expect(result.removedNames, unorderedEquals(names));
      expect(result.retainedNames, isEmpty);
      for (final name in names)
        expect(await Directory('${root.path}/$name').exists(), isFalse);
    },
  );

  for (final removeManifest in [false, true]) {
    test('recovery resumes unpublished cleanup after payload removal '
        '(manifest ${removeManifest ? 'removed' : 'present'})', () async {
      final child = await crashArtifact('published');
      expect(child.exitCode, 73, reason: '${child.stdout}\n${child.stderr}');
      final proof =
          jsonDecode(
                await File(
                  '${temporary.path}/crash-published.json',
                ).readAsString(),
              )
              as Map;
      final id = ArtifactId(proof['artifact_id'] as String);
      final directory = root.directory(id.value);
      try {
        directory.removeFile('payload');
        if (removeManifest) directory.removeFile('manifest.json');
        await directory.sync();
      } finally {
        directory.close();
      }
      final result = await service().reconcile();
      expect(result.removedNames, [id.value]);
      expect(result.retainedNames, isEmpty);
      expect(await ArtifactRepository(database).get(id), isNull);
      expect(await Directory('${root.path}/${id.value}').exists(), isFalse);
    });
  }

  test(
    'malformed unpublished manifests are retained without aborting recovery',
    () async {
      final child = await crashArtifact('published');
      expect(child.exitCode, 73, reason: '${child.stdout}\n${child.stderr}');
      final proof =
          jsonDecode(
                await File(
                  '${temporary.path}/crash-published.json',
                ).readAsString(),
              )
              as Map;
      final id = ArtifactId(proof['artifact_id'] as String);
      final manifest = File('${root.path}/${id.value}/manifest.json');
      imageFileMode(manifest.path, 0x180);
      await manifest.writeAsString('[]');
      imageFileMode(manifest.path, 0x100);
      final result = await service().reconcile();
      expect(result.removedNames, isEmpty);
      expect(result.retainedNames, [id.value]);
      expect(result.damagedArtifactIds, isEmpty);
      expect(await File('${root.path}/${id.value}/payload').readAsBytes(), [
        1,
        2,
        3,
      ]);
      expect(await ArtifactRepository(database).get(id), isNull);
    },
  );
}

final class _UnconfirmedProcess implements Process {
  _UnconfirmedProcess(this.exitCode);

  @override
  final Future<int> exitCode;

  @override
  int get pid => 2147483647;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused process member: ${invocation.memberName}');
}
