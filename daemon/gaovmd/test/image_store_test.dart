import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/image_manifest.dart';
import 'package:gaovmd/src/image_repository.dart';
import 'package:gaovmd/src/vm_repository.dart';
import 'package:gaovmd/src/event_repository.dart';
import 'package:gaovmd/src/image_store.dart';
import 'package:gaovmd/src/image_filesystem.dart';
import 'package:gaovmd/src/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late GaoVmDatabase database;
  late ImageStore store;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('gaovm-image-test-');
    database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
    store = ImageStore(database, Directory('${temporary.path}/images'));
  });
  tearDown(() async {
    database.close();
    await temporary.delete(recursive: true);
  });

  test(
    'rejects filesystem mutations inside caller transactions before effects',
    () async {
      final source = await File(
        '${temporary.path}/source',
      ).writeAsString('original');
      await database.transaction((_) async {
        expect(database.hasActiveCallerTransaction, isTrue);
        await expectLater(
          store.importFile(source, type: ImageType.rawDisk),
          throwsStateError,
        );
        await expectLater(store.importBundle(temporary), throwsStateError);
        await expectLater(store.reconcile(), throwsStateError);
      });
      expect(database.hasActiveCallerTransaction, isFalse);
      expect(await store.directory.exists(), isFalse);
      final image = await store.importFile(source, type: ImageType.rawDisk);
      final other = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      try {
        await database.transaction((_) async {
          expect(other.hasActiveCallerTransaction, isTrue);
          await expectLater(
            ImageStore(other, store.directory).delete(image.id),
            throwsStateError,
          );
          await expectLater(store.delete(image.id), throwsStateError);
        });
      } finally {
        other.close();
      }
      expect(await store.get(image.id), image);
      expect(
        await (await store.objectFile(image.id, 'payload')).readAsString(),
        'original',
      );
      expect(
        (await SqliteEventRepository(
          database,
        ).list(resourceType: ResourceType.image)).map((event) => event.type),
        ['image.imported'],
      );
    },
  );

  test(
    'copies the validated descriptor when source pathname is replaced',
    () async {
      final source = await File(
        '${temporary.path}/source',
      ).writeAsString('original');
      final replacement = await File(
        '${temporary.path}/replacement',
      ).writeAsString('replaced');
      final replacingStore = ImageStore(
        database,
        store.directory,
        availableBytes: (_) async {
          await source.rename('${source.path}.old');
          await Link(source.path).create(replacement.path);
          return 100 * 1024 * 1024;
        },
      );
      final image = await replacingStore.importFile(
        source,
        type: ImageType.rawDisk,
      );
      expect(
        await (await store.objectFile(image.id, 'payload')).readAsString(),
        'original',
      );
      expect(await replacement.readAsString(), 'replaced');
    },
  );

  test(
    'descriptor manifest reading bounds growth after initial stat',
    () async {
      final source = await File(
        '${temporary.path}/manifest.json',
      ).writeAsString('{}');
      final input = await OwnedImageFile.open(source);
      try {
        expect(input.size, 2);
        await source.writeAsBytes(List.filled(1024 * 1024 + 1, 32));
        await expectLater(
          input.readBounded(1024 * 1024),
          throwsFormatException,
        );
      } finally {
        input.close();
      }
    },
  );

  test(
    'anchored bundle descriptors reject object symlinks and traversal',
    () async {
      final source = await Directory('${temporary.path}/bundle').create();
      final file = await File(
        '${temporary.path}/outside',
      ).writeAsString('outside');
      await Link('${source.path}/payload').create(file.path);
      final bundle = await OwnedImageDirectory.open(source);
      try {
        expect(
          () => bundle.file('payload'),
          throwsA(isA<FileSystemException>()),
        );
        expect(() => bundle.file('../outside'), throwsArgumentError);
        expect(
          () => bundle.directory('payload'),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        bundle.close();
      }
    },
  );

  test('simultaneous child processes deduplicate under the store lock', () async {
    final source = await File(
      '${temporary.path}/source',
    ).writeAsString('shared');
    final children = await Future.wait(
      List.generate(
        2,
        (_) => Process.start(Platform.resolvedExecutable, [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          'test/fixtures/parallel_image_import.dart',
          '${temporary.path}/catalog.db',
          store.directory.path,
          source.path,
        ]),
      ),
    );
    addTearDown(() {
      for (final child in children) {
        child.kill();
      }
    });
    final outputs = <List<String>>[];
    final ready = <Future<void>>[];
    final done = <Future<void>>[];
    final errors = <Future<String>>[];
    for (final child in children) {
      final lines = <String>[];
      final started = Completer<void>();
      final ended = Completer<void>();
      outputs.add(lines);
      child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              lines.add(line);
              if (line == 'ready') started.complete();
            },
            onDone: ended.complete,
            onError: ended.completeError,
          );
      ready.add(started.future);
      done.add(ended.future);
      errors.add(child.stderr.transform(utf8.decoder).join());
    }
    await Future.wait(ready).timeout(const Duration(seconds: 15));
    for (final child in children) {
      child.stdin.writeln('go');
      await child.stdin.close();
    }
    final exits = await Future.wait(children.map((child) => child.exitCode));
    await Future.wait(done);
    final stderr = await Future.wait(errors);
    expect(exits, [0, 0], reason: stderr.join('\n'));
    expect(outputs[0].last, outputs[1].last);
    expect(await store.list(), hasLength(1));
    expect(
      await SqliteEventRepository(
        database,
      ).list(resourceType: ResourceType.image),
      hasLength(1),
    );
    expect((await store.reconcile()).damagedImageIds, isEmpty);
  });

  test(
    'imports a file into immutable managed storage and survives reopen',
    () async {
      final source = File('${temporary.path}/kernel');
      await source.writeAsString('kernel bytes');
      final imported = await store.importFile(
        source,
        type: ImageType.linuxKernel,
      );
      expect(imported.id, isA<ImageId>());
      expect(imported.digest, startsWith('sha256:'));
      expect(
        await (await store.objectFile(imported.id, 'payload')).readAsString(),
        'kernel bytes',
      );
      await source.writeAsString('changed');
      expect(
        await (await store.objectFile(imported.id, 'payload')).readAsString(),
        'kernel bytes',
      );
      expect(await store.list(), [imported]);
      database.close();
      database = await GaoVmDatabase.open('${temporary.path}/catalog.db');
      store = ImageStore(database, Directory('${temporary.path}/images'));
      expect(await store.get(imported.id), imported);
    },
  );

  test(
    'validates and imports a GaoOS bundle with immutable role metadata',
    () async {
      final bundle = await Directory(
        '${temporary.path}/bundle/objects',
      ).create(recursive: true);
      final objects = <String, Map<String, Object?>>{};
      for (final name in ['kernel', 'initrd', 'root']) {
        final data = utf8.encode('$name bytes');
        await File('${bundle.path}/$name').writeAsBytes(data);
        objects[name] = {
          'digest': 'sha256:${sha256.convert(data)}',
          'size_bytes': data.length,
        };
      }
      final manifest = ImageManifest.create(
        type: ImageType.gaoosBundle,
        objects: objects,
        guestProfile: 'gaoos',
        version: '1',
        buildId: 'nightly-42',
        channel: 'nightly',
        gaoos: {
          'kernel': 'kernel',
          'initrd': 'initrd',
          'root_disk': 'root',
          'default_command_line': 'console=hvc0',
          'guest_agent_expected': true,
        },
      );
      await File(
        '${bundle.parent.path}/manifest.json',
      ).writeAsString(jsonEncode(manifest.toJson()));
      final imported = await store.importBundle(bundle.parent);
      expect(imported.buildId, 'nightly-42');
      expect(
        await (await store.objectFile(imported.id, 'root')).readAsString(),
        'root bytes',
      );
      await File('${bundle.path}/root').writeAsString('corrupt');
      await expectLater(
        store.importBundle(bundle.parent),
        throwsA(isA<FormatException>()),
      );
      expect(await store.list(), [imported]);
    },
  );

  test(
    'deduplicates concurrent imports and recovers unregistered publications',
    () async {
      final source = File('${temporary.path}/disk');
      await source.writeAsBytes(List.filled(10000, 42));
      final results = await Future.wait(
        List.generate(
          4,
          (_) => store.importFile(source, type: ImageType.rawDisk),
        ),
      );
      expect(results.map((image) => image.id).toSet(), hasLength(1));
      final abandoned = await Directory(
        '${store.directory.path}/.staging-abandoned',
      ).create();
      await File('${abandoned.path}/partial').writeAsString('partial');
      final orphan = await Directory(
        '${store.directory.path}/sha256-${'a' * 64}',
      ).create();
      await File('${orphan.path}/manifest.json').writeAsString('{}');
      final report = await store.reconcile();
      expect(report.removedPaths, containsAll([abandoned.path, orphan.path]));
      expect(report.damagedImageIds, isEmpty);
      expect(await store.get(results.first.id), results.first);
      expect(await store.delete(results.first.id), isTrue);
      expect(await store.list(), isEmpty);
      expect(await source.exists(), isTrue);
    },
  );

  test(
    'cancellation and low capacity leave no visible image or staging data',
    () async {
      final source = File('${temporary.path}/disk');
      await source.writeAsBytes(List.filled(200000, 9));
      var cancelled = false;
      await expectLater(
        store.importFile(
          source,
          type: ImageType.rawDisk,
          isCancelled: () => cancelled,
          onProgress: (_) {
            cancelled = true;
          },
        ),
        throwsA(isA<ImageImportCancelled>()),
      );
      expect(await store.list(), isEmpty);
      expect(
        await store.directory
            .list()
            .where((entry) => entry.path.contains('.staging-'))
            .isEmpty,
        isTrue,
      );
      final constrained = ImageStore(
        database,
        store.directory,
        availableBytes: (_) async => 1,
      );
      await expectLater(
        constrained.importFile(source, type: ImageType.rawDisk),
        throwsA(isA<ImageInsufficientSpace>()),
      );
      expect(await store.list(), isEmpty);
    },
  );

  test(
    'pending and applied VM specs protect images until VM deletion',
    () async {
      final source = await File(
        '${temporary.path}/disk',
      ).writeAsString('disk bytes');
      final first = await store.importFile(source, type: ImageType.rawDisk);
      await source.writeAsString('next disk bytes');
      final second = await store.importFile(source, type: ImageType.rawDisk);
      final vms = SqliteVmRepository(database);
      final vm = await vms.create(name: 'uses-image', spec: _spec(first.id));
      final patched = await vms.updateSpec(
        vm.metadata.id,
        expectedRevision: vm.metadata.revision,
        spec: _spec(second.id),
      );
      await expectLater(store.delete(first.id), throwsA(isA<ImageInUse>()));
      await expectLater(store.delete(second.id), throwsA(isA<ImageInUse>()));
      final deleting = await vms.markDeleting(
        vm.metadata.id,
        expectedRevision: patched.metadata.revision,
      );
      await vms.tombstone(
        vm.metadata.id,
        expectedRevision: deleting.metadata.revision,
      );
      expect(await store.delete(first.id), isTrue);
      expect(await store.delete(second.id), isTrue);
      final events = await SqliteEventRepository(
        database,
      ).list(resourceType: ResourceType.image);
      expect(events.map((event) => event.type), [
        'image.imported',
        'image.imported',
        'image.deleted',
        'image.deleted',
      ]);
    },
  );

  test(
    'rolls back published files and imported event when catalog insertion fails',
    () async {
      final source = await File(
        '${temporary.path}/disk',
      ).writeAsString('disk bytes');
      await database.transaction(
        (db) => db.execute(
          "CREATE TRIGGER reject_image BEFORE INSERT ON images BEGIN SELECT RAISE(ABORT, 'injected database failure'); END",
        ),
      );
      await expectLater(
        store.importFile(source, type: ImageType.rawDisk),
        throwsException,
      );
      expect(await store.list(), isEmpty);
      expect(
        await SqliteEventRepository(
          database,
        ).list(resourceType: ResourceType.image),
        isEmpty,
      );
      expect(
        await store.directory
            .list()
            .where((entry) => entry is Directory)
            .isEmpty,
        isTrue,
      );
    },
  );

  test(
    'rejects symlink store and object traversal; doctor retains damaged catalog images',
    () async {
      final outside = await Directory('${temporary.path}/outside').create();
      final alias = Link('${temporary.path}/alias');
      await alias.create(outside.path);
      final source = await File(
        '${temporary.path}/disk',
      ).writeAsString('disk bytes');
      await expectLater(
        ImageStore(
          database,
          Directory(alias.path),
        ).importFile(source, type: ImageType.rawDisk),
        throwsA(isA<FileSystemException>()),
      );
      final imported = await store.importFile(source, type: ImageType.rawDisk);
      await expectLater(
        store.objectFile(imported.id, '../manifest.json'),
        throwsStateError,
      );
      final object = await store.objectFile(imported.id, 'payload');
      await object.delete();
      final report = await store.reconcile();
      expect(report.damagedImageIds, [imported.id]);
      expect(await store.get(imported.id), imported);
    },
  );

  for (final point in ['staged', 'published', 'committed']) {
    test('recovers actual process exit after $point checkpoint', () async {
      final source = await File(
        '${temporary.path}/disk',
      ).writeAsString('crash-safe disk bytes');
      final child = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/fixtures/crash_image_import.dart',
        '${temporary.path}/catalog.db',
        store.directory.path,
        source.path,
        point,
      ]);
      expect(child.exitCode, 91, reason: '${child.stdout}\n${child.stderr}');
      final report = await store.reconcile();
      expect(report.damagedImageIds, isEmpty);
      final images = await store.list();
      if (point == 'committed') {
        expect(images, hasLength(1));
        expect(
          await (await store.objectFile(
            images.single.id,
            'payload',
          )).readAsString(),
          'crash-safe disk bytes',
        );
      } else {
        expect(images, isEmpty);
        expect(report.removedPaths, hasLength(1));
      }
      final reimported = await store.importFile(
        source,
        type: ImageType.rawDisk,
      );
      expect(await store.list(), [reimported]);
    });
  }

  test(
    'never resolves a managed object through a replaced directory symlink',
    () async {
      final source = await File(
        '${temporary.path}/disk',
      ).writeAsString('disk bytes');
      final image = await store.importFile(source, type: ImageType.rawDisk);
      final object = await store.objectFile(image.id, 'payload');
      final outside = await Directory('${temporary.path}/outside').create();
      await File('${outside.path}/payload').writeAsString('outside bytes');
      await object.parent.delete(recursive: true);
      await Link(object.parent.path).create(outside.path);
      await expectLater(
        store.objectFile(image.id, 'payload'),
        throwsA(isA<FileSystemException>()),
      );
      final report = await store.reconcile();
      expect(report.damagedImageIds, [image.id]);
      expect(
        await File('${outside.path}/payload').readAsString(),
        'outside bytes',
      );
    },
  );

  test(
    'imports initrd metadata and checks an expected source digest',
    () async {
      final bytes = utf8.encode('initrd bytes');
      final source = await File('${temporary.path}/initrd').writeAsBytes(bytes);
      await expectLater(
        store.importFile(
          source,
          type: ImageType.initrd,
          expectedObjectDigest: 'sha256:${'0' * 64}',
        ),
        throwsFormatException,
      );
      expect(await store.list(), isEmpty);
      final image = await store.importFile(
        source,
        type: ImageType.initrd,
        guestProfile: 'gaoos',
        version: '2',
        buildId: 'build-2',
        channel: 'stable',
        labels: {'team': 'os'},
        expectedObjectDigest: 'sha256:${sha256.convert(bytes)}',
      );
      expect(image.type, ImageType.initrd);
      expect(image.labels, {'team': 'os'});
      expect(image.version, '2');
      final object = await store.objectFile(image.id, 'payload');
      expect((await object.stat()).mode & 511, 256);
      expect((await store.directory.stat()).mode & 511, 448);
    },
  );
}

VmSpec _spec(ImageId image) => VmSpec(
  cpu: 2,
  memoryBytes: 2147483648,
  boot: EfiBoot(),
  disks: [
    VmDisk(id: 'root', source: ManagedImageDiskSource(image), writable: true),
  ],
  networks: [SharedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.onFailure,
);
