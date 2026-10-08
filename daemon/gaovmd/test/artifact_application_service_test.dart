import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/gaovmd.dart';
import 'package:gaovmd/src/artifact_application_service.dart';
import 'package:gaovmd/src/artifact_repository.dart';
import 'package:gaovmd/src/image_filesystem.dart' show imageFileMode;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late OwnedImageDirectory root;
  late TestRun run;
  ArtifactApplicationService service() =>
      ArtifactApplicationService(database: database, directory: root);

  setUp(() async {
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

  tearDown(() async {
    root.close();
    database.close();
    await temporary.delete(recursive: true);
  });

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
      final child = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/helpers/artifact_crash_child.dart',
        root.path,
        '${temporary.path}/catalog.db',
        run.id.value,
        run.operationId.value,
        'staged',
      ]);
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
        final child = await Process.run(Platform.resolvedExecutable, [
          'run',
          'test/helpers/artifact_crash_child.dart',
          root.path,
          '${temporary.path}/catalog.db',
          run.id.value,
          run.operationId.value,
          checkpoint,
        ]);
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

  test('recovery resumes unpublished cleanup after payload removal', () async {
    for (final removeManifest in [false, true]) {
      final child = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/helpers/artifact_crash_child.dart',
        root.path,
        '${temporary.path}/catalog.db',
        run.id.value,
        run.operationId.value,
        'published',
      ]);
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
    }
  });
}
