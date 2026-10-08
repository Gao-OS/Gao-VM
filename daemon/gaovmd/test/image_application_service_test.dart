import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:crypto/crypto.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:gaovmd/src/image_application_service.dart';
import 'package:gaovmd/src/image_manifest.dart';
import 'package:gaovmd/src/image_store.dart';
import 'package:gaovmd/src/operation_application_service.dart';
import 'package:gaovmd/src/operation_repository.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late GaoVmDatabase database;
  late ImageStore store;
  late ImageApplicationService images;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gvm-image-app-');
    database = await GaoVmDatabase.open('${directory.path}/catalog.db');
    store = ImageStore(database, Directory('${directory.path}/images'));
    images = ImageApplicationService(database: database, store: store);
  });
  tearDown(() async {
    database.close();
    await directory.delete(recursive: true);
  });

  test(
    'deduplication resolves the operation without changing acceptance or labels',
    () async {
      final source = await File(
        '${directory.path}/source',
      ).writeAsString('disk');
      final original = await store.importFile(
        source,
        type: ImageType.rawDisk,
        labels: {'owner': 'original'},
      );
      final body = {
        'source_path': source.path,
        'type': 'raw-disk',
        'architecture': 'arm64',
        'labels': {'owner': 'duplicate'},
      };
      ImageImportCommand command() => ImageImportCommand.fromJson(
        body,
        requestId: RequestId.generate(),
        idempotencyKey: 'duplicate',
        requestBody: utf8.encode(jsonEncode(body)),
      );
      final accepted = await images.importImage(command());
      expect(accepted.resourceId, isNot(original.id));
      await images.dispatchOnce();
      final operation = (await SqliteOperationRepository(
        database,
      ).get(accepted.operationId))!;
      expect(operation.state, OperationState.succeeded);
      expect(operation.resourceId, original.id);
      expect(operation.result!.toJson()['image_id'], original.id.value);
      expect(await store.list(), [original]);
      expect((await images.importImage(command())).toJson(), accepted.toJson());
      expect(
        (await SqliteEventRepository(database).list(
          operationId: accepted.operationId,
        )).where((event) => event.type == 'image.imported'),
        isEmpty,
      );
    },
  );

  test(
    'replacement cancellation waits for the previous filesystem owner',
    () async {
      var now = DateTime.utc(2026, 10, 8);
      final entered = Completer<void>();
      final resume = Completer<void>();
      store = ImageStore(
        database,
        store.directory,
        availableBytes: (_) async {
          if (!entered.isCompleted) entered.complete();
          await resume.future;
          return 100 * 1024 * 1024;
        },
      );
      images = ImageApplicationService(
        database: database,
        store: store,
        now: () => now,
      );
      final source = await File(
        '${directory.path}/source',
      ).writeAsString('disk');
      final body = {
        'source_path': source.path,
        'type': 'raw-disk',
        'architecture': 'arm64',
      };
      final accepted = await images.importImage(
        ImageImportCommand.fromJson(
          body,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: utf8.encode(jsonEncode(body)),
        ),
      );
      final oldWorker = images.dispatchOnce();
      await entered.future;
      now = now.add(const Duration(seconds: 31));
      final cancel = await images.cancel(
        OperationCancelCommand(
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: const [],
          operationId: accepted.operationId,
        ),
      );
      final replacement = ImageApplicationService(
        database: database,
        store: store,
        now: () => now,
      );
      final newWorker = replacement.dispatchOnce();
      addTearDown(() async {
        if (!resume.isCompleted) resume.complete();
        await Future.wait([oldWorker, newWorker]);
      });
      expect(
        await database.read(
          (db) => db.select(
            'SELECT attempts FROM outbox WHERE topic = ? AND key = ?',
            ['images.work', accepted.operationId.value],
          ).single['attempts'],
        ),
        2,
      );
      await expectLater(
        newWorker.timeout(const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.running,
      );
      expect(
        (await operations.get(cancel.operationId))!.state,
        OperationState.pending,
      );
      resume.complete();
      await Future.wait([oldWorker, newWorker]);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.cancelled,
      );
      expect(
        await store.directory
            .list()
            .where((entry) => entry is Directory)
            .toList(),
        isEmpty,
      );
    },
  );

  test(
    'an expired delivery cannot publish after another worker claims it',
    () async {
      var now = DateTime.utc(2026, 10, 8);
      final entered = Completer<void>();
      final resume = Completer<void>();
      store = ImageStore(
        database,
        store.directory,
        availableBytes: (_) async {
          if (!entered.isCompleted) entered.complete();
          await resume.future;
          return 100 * 1024 * 1024;
        },
      );
      images = ImageApplicationService(
        database: database,
        store: store,
        now: () => now,
      );
      final source = await File(
        '${directory.path}/source',
      ).writeAsString('disk');
      final body = {
        'source_path': source.path,
        'type': 'raw-disk',
        'architecture': 'arm64',
      };
      final accepted = await images.importImage(
        ImageImportCommand.fromJson(
          body,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: utf8.encode(jsonEncode(body)),
        ),
      );
      final oldWorker = images.dispatchOnce();
      await entered.future;
      now = now.add(const Duration(seconds: 31));
      final replacement = ImageApplicationService(
        database: database,
        store: store,
        now: () => now,
      );
      final newWorker = replacement.dispatchOnce();
      // Wait for an authoritative claim, not an arbitrary delay.
      final running = SqliteOperationRepository(database);
      final originalRead = database.read(
        (db) => db.select(
          'SELECT attempts FROM outbox WHERE topic = ? AND key = ?',
          ['images.work', accepted.operationId.value],
        ).single['attempts'],
      );
      addTearDown(() async {
        if (!resume.isCompleted) resume.complete();
        await Future.wait([oldWorker, newWorker]);
      });
      // The claim transaction was enqueued before this read on the catalog gate.
      expect(await originalRead, 2);
      resume.complete();
      await Future.wait([oldWorker, newWorker]);
      expect(
        (await running.get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
      expect(await store.list(), hasLength(1));
      expect(
        (await SqliteEventRepository(
          database,
        ).list(operationId: accepted.operationId)).map((event) => event.type),
        [
          'operation.created',
          'operation.started',
          'image.imported',
          'operation.completed',
        ],
      );
    },
  );

  test(
    'cancellation completes only after import staging has been removed',
    () async {
      final copying = Completer<void>();
      final resume = Completer<void>();
      store = ImageStore(
        database,
        store.directory,
        availableBytes: (_) async {
          copying.complete();
          await resume.future;
          return 100 * 1024 * 1024;
        },
      );
      images = ImageApplicationService(database: database, store: store);
      final source = await File(
        '${directory.path}/source',
      ).writeAsString('raw-disk');
      final body = {
        'source_path': source.path,
        'type': 'raw-disk',
        'architecture': 'arm64',
      };
      final accepted = await images.importImage(
        ImageImportCommand.fromJson(
          body,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: utf8.encode(jsonEncode(body)),
        ),
      );
      final work = images.dispatchOnce();
      addTearDown(() async {
        if (!resume.isCompleted) resume.complete();
        await work;
      });
      await copying.future;
      final action = await images.cancel(
        OperationCancelCommand(
          requestId: RequestId.generate(),
          idempotencyKey: 'cancel-import',
          requestBody: const [],
          operationId: accepted.operationId,
        ),
      );
      final operations = SqliteOperationRepository(database);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.running,
      );
      expect(
        (await operations.get(action.operationId))!.state,
        OperationState.pending,
      );
      resume.complete();
      await work;
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.cancelled,
      );
      expect(
        (await operations.get(action.operationId))!.state,
        OperationState.succeeded,
      );
      expect(await store.list(), isEmpty);
      expect(
        await store.directory
            .list()
            .where((entry) => entry is Directory)
            .toList(),
        isEmpty,
      );
    },
  );

  for (final requestedVersion in ['1.0', 'mismatch'])
    test(
      'imports GaoOS bundle only when requested metadata matches: $requestedVersion',
      () async {
        final bundle = await Directory('${directory.path}/bundle').create();
        final objects = await Directory('${bundle.path}/objects').create();
        final manifest = ImageManifest.create(
          type: ImageType.gaoosBundle,
          guestProfile: 'gaoos',
          version: '1.0',
          buildId: 'build-1',
          channel: 'nightly',
          objects: {
            for (final name in ['kernel', 'initrd', 'root'])
              name: {
                'digest': 'sha256:${sha256.convert(utf8.encode(name))}',
                'size_bytes': utf8.encode(name).length,
              },
          },
          gaoos: {
            'kernel': 'kernel',
            'initrd': 'initrd',
            'root_disk': 'root',
            'default_command_line': 'console=hvc0',
            'guest_agent_expected': true,
          },
        );
        for (final name in ['kernel', 'initrd', 'root']) {
          await File('${objects.path}/$name').writeAsString(name);
        }
        await File(
          '${bundle.path}/manifest.json',
        ).writeAsString(jsonEncode(manifest.toJson()));
        final body = {
          'source_path': bundle.path,
          'type': 'gaoos-bundle',
          'architecture': 'arm64',
          'version': requestedVersion,
        };
        final accepted = await images.importImage(
          ImageImportCommand.fromJson(
            body,
            requestId: RequestId.generate(),
            idempotencyKey: null,
            requestBody: utf8.encode(jsonEncode(body)),
          ),
        );
        await images.dispatchOnce();
        final operation = (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!;
        if (requestedVersion == 'mismatch') {
          expect(operation.state, OperationState.failed);
          expect(operation.error!.code, ErrorCode.invalidRequest);
          expect(await store.list(), isEmpty);
          return;
        }
        expect(operation.state, OperationState.succeeded);
        final image = (await store.list()).single;
        expect(
          [image.guestProfile, image.version, image.buildId, image.channel],
          ['gaoos', '1.0', 'build-1', 'nightly'],
        );
        expect(image.manifest.toJson(), manifest.toJson());
      },
    );

  for (final failure in ['statement', 'commit'])
    test('$failure failure rolls back the image and permits recovery', () async {
      final source = await File(
        '${directory.path}/source',
      ).writeAsString('raw-disk');
      final body = {
        'source_path': source.path,
        'type': 'raw-disk',
        'architecture': 'arm64',
      };
      final accepted = await images.importImage(
        ImageImportCommand.fromJson(
          body,
          requestId: RequestId.generate(),
          idempotencyKey: null,
          requestBody: utf8.encode(jsonEncode(body)),
        ),
      );
      await database.transaction((db) {
        if (failure == 'commit')
          db.execute(
            'CREATE TABLE commit_fault(image_id TEXT REFERENCES images(id) DEFERRABLE INITIALLY DEFERRED)',
          );
        db.execute(
          '''CREATE TRIGGER reject_completion BEFORE INSERT ON events
          WHEN NEW.type = 'operation.completed' BEGIN
          ${failure == 'commit' ? "INSERT INTO commit_fault(image_id) VALUES ('missing');" : "SELECT RAISE(ABORT, 'injected completion failure');"} END''',
        );
      });
      await expectLater(images.dispatchOnce(), throwsA(isA<Exception>()));
      expect(await store.list(), isEmpty);
      expect(
        await store.directory
            .list()
            .where((entry) => entry is Directory)
            .toList(),
        isEmpty,
      );
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.running,
      );
      expect(
        (await SqliteEventRepository(
          database,
        ).list(operationId: accepted.operationId)).map((event) => event.type),
        ['operation.created', 'operation.started'],
      );
      await database.transaction(
        (db) => db.execute('DROP TRIGGER reject_completion'),
      );
      await images.dispatchOnce();
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
      expect(await store.list(), hasLength(1));
    });

  test('a missing source becomes a durable failed operation', () async {
    final body = {
      'source_path': '${directory.path}/missing',
      'type': 'raw-disk',
      'architecture': 'arm64',
    };
    final accepted = await images.importImage(
      ImageImportCommand.fromJson(
        body,
        requestId: RequestId.generate(),
        idempotencyKey: null,
        requestBody: utf8.encode(jsonEncode(body)),
      ),
    );
    await images.dispatchOnce();
    final failed = (await SqliteOperationRepository(
      database,
    ).get(accepted.operationId))!;
    expect(failed.state, OperationState.failed);
    expect(failed.error!.code, ErrorCode.invalidRequest);
    expect(failed.error!.retryable, isFalse);
    expect(await store.list(), isEmpty);
    await images.dispatchOnce();
    expect(
      (await SqliteEventRepository(database).list(
        operationId: accepted.operationId,
      )).where((event) => event.type == 'operation.completed'),
      hasLength(1),
    );
  });

  test(
    'accepts import before copying and durably completes the image',
    () async {
      final source = await File(
        '${directory.path}/kernel',
      ).writeAsString('kernel');
      final body = {
        'source_path': source.path,
        'type': 'linux-kernel',
        'architecture': 'arm64',
        'labels': {'suite': 'smoke'},
      };
      final accepted = await images.importImage(
        ImageImportCommand.fromJson(
          body,
          requestId: RequestId.generate(),
          idempotencyKey: 'import-kernel',
          requestBody: utf8.encode(jsonEncode(body)),
        ),
      );
      final operations = SqliteOperationRepository(database);
      expect(accepted.state, OperationState.pending);
      expect(accepted.resourceType, ResourceType.image);
      expect(
        (await operations.get(accepted.operationId))!.state,
        OperationState.pending,
      );
      expect(await store.list(), isEmpty);
      expect(await store.directory.exists(), isFalse);

      await images.dispatchOnce();

      final imported = (await store.list()).single;
      final completed = (await operations.get(accepted.operationId))!;
      expect(imported.id, accepted.resourceId);
      expect(imported.labels, {'suite': 'smoke'});
      expect(completed.state, OperationState.succeeded);
      expect(completed.result!.toJson()['image_id'], imported.id.value);
      expect(
        await (await store.objectFile(imported.id, 'payload')).readAsString(),
        'kernel',
      );
      final events = await SqliteEventRepository(
        database,
      ).list(operationId: accepted.operationId);
      expect(events.map((event) => event.type), [
        'operation.created',
        'operation.started',
        'image.imported',
        'operation.completed',
      ]);

      database.close();
      database = await GaoVmDatabase.open('${directory.path}/catalog.db');
      final reopened = ImageApplicationService(
        database: database,
        store: ImageStore(database, store.directory),
      );
      await reopened.dispatchOnce();
      expect(
        (await SqliteOperationRepository(
          database,
        ).get(accepted.operationId))!.state,
        OperationState.succeeded,
      );
      expect(await reopened.store.list(), [imported]);
    },
  );
}
