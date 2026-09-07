import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'image_manifest.dart';
import 'image_filesystem.dart';
import 'image_repository.dart';
import 'event_repository.dart';
import 'sqlite_database.dart';

final class ImageStore {
  ImageStore(
    this.database,
    this.directory, {
    Future<int> Function(Directory)? availableBytes,
    void Function(ImageImportCheckpoint)? onCheckpoint,
  }) : repository = ImageRepository(database),
       _availableBytes = availableBytes ?? _diskAvailableBytes,
       _onCheckpoint = onCheckpoint;
  final GaoVmDatabase database;
  final Directory directory;
  final ImageRepository repository;
  final Future<int> Function(Directory) _availableBytes;

  /// Synchronous diagnostic observer, also used for process-crash fault injection.
  final void Function(ImageImportCheckpoint)? _onCheckpoint;

  Future<List<Image>> list() => repository.list();
  Future<Image?> get(ImageId id) => repository.get(id);

  Future<Image> importFile(
    File source, {
    required ImageType type,
    String? guestProfile,
    String? version,
    String? buildId,
    String? channel,
    Map<String, String> labels = const {},
    String? expectedObjectDigest,
    bool Function()? isCancelled,
    void Function(int)? onProgress,
  }) => _locked(() async {
    if (type == ImageType.gaoosBundle)
      throw ArgumentError('use importBundle for GaoOS bundles');
    _checkCancelled(isCancelled);
    final input = await OwnedImageFile.open(source);
    try {
      await directory.create(recursive: true);
      final expectedSize = input.size;
      await _checkSpace(expectedSize);
      final stage = await directory.createTemp('.staging-');
      try {
        final objects = await Directory('${stage.path}/objects').create();
        final target = File('${objects.path}/payload');
        await _copy(
          input,
          target,
          expectedSize: expectedSize,
          isCancelled: isCancelled,
          onProgress: onProgress,
        );
        final digest = await _fileDigest(target, isCancelled: isCancelled);
        if (expectedObjectDigest != null && digest != expectedObjectDigest)
          throw FormatException('source digest mismatch');
        final manifest = ImageManifest.create(
          type: type,
          objects: {
            'payload': {'digest': digest, 'size_bytes': await target.length()},
          },
          guestProfile: guestProfile,
          version: version,
          buildId: buildId,
          channel: channel,
        );
        _checkCancelled(isCancelled);
        return await _publish(stage, manifest, labels: labels);
      } finally {
        if (await stage.exists()) await stage.delete(recursive: true);
      }
    } finally {
      input.close();
    }
  });

  Future<Image> importBundle(
    Directory source, {
    Map<String, String> labels = const {},
    bool Function()? isCancelled,
    void Function(int)? onProgress,
  }) => _locked(() async {
    _checkCancelled(isCancelled);
    final bundle = await OwnedImageDirectory.open(source);
    try {
      final manifestFile = bundle.file('manifest.json');
      late ImageManifest manifest;
      try {
        manifest = ImageManifest.fromJson(
          jsonDecode(utf8.decode(await manifestFile.readBounded(1024 * 1024))),
        );
      } finally {
        manifestFile.close();
      }
      if (manifest.type != ImageType.gaoosBundle)
        throw FormatException('bundle must have gaoos-bundle type');
      await directory.create(recursive: true);
      await _checkSpace(
        manifest.objects.values.fold<int>(
          0,
          (sum, entry) => sum + (entry['size_bytes'] as int),
        ),
      );
      final stage = await directory.createTemp('.staging-');
      try {
        final sourceObjects = bundle.directory('objects');
        try {
          final objects = await Directory('${stage.path}/objects').create();
          var completedBytes = 0;
          for (final entry in manifest.objects.entries) {
            final sourceObject = sourceObjects.file(entry.key);
            try {
              final target = File('${objects.path}/${entry.key}');
              await _copy(
                sourceObject,
                target,
                expectedSize: entry.value['size_bytes'] as int,
                isCancelled: isCancelled,
                onProgress: (bytes) => onProgress?.call(completedBytes + bytes),
              );
              if (await target.length() != entry.value['size_bytes'] ||
                  await _fileDigest(target, isCancelled: isCancelled) !=
                      entry.value['digest'])
                throw FormatException(
                  'bundle object digest/size mismatch: ${entry.key}',
                );
              completedBytes += entry.value['size_bytes'] as int;
            } finally {
              sourceObject.close();
            }
          }
          _checkCancelled(isCancelled);
          return await _publish(stage, manifest, labels: labels);
        } finally {
          sourceObjects.close();
        }
      } finally {
        if (await stage.exists()) await stage.delete(recursive: true);
      }
    } finally {
      bundle.close();
    }
  });

  Future<T> _locked<T>(Future<T> Function() action) async {
    if (database.hasActiveCallerTransaction) {
      throw StateError(
        'image store filesystem mutations require an independent transaction',
      );
    }
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory)
      throw FileSystemException(
        'image store must be a directory, not a symlink',
        directory.path,
      );
    await directory.create(recursive: true);
    await requireImagePathOwner(directory.path);
    imageFileMode(directory.path, 448); // 0700
    final key = await directory.resolveSymbolicLinks();
    final previous = _storeGates[key] ?? Future<void>.value();
    final complete = Completer<void>();
    _storeGates[key] = complete.future;
    await previous;
    try {
      final lockType = await FileSystemEntity.type(
        '$key/.lock',
        followLinks: false,
      );
      if (lockType != FileSystemEntityType.notFound &&
          lockType != FileSystemEntityType.file)
        throw FileSystemException('invalid image store lock', '$key/.lock');
      final lock = await File('$key/.lock').open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        return await action();
      } finally {
        await lock.close();
      }
    } finally {
      complete.complete();
      if (identical(_storeGates[key], complete.future)) _storeGates.remove(key);
    }
  }

  Future<bool> delete(ImageId id) => _locked(() async {
    final image = await repository.delete(id);
    if (image == null) return false;
    // Catalog deletion commits first. A crash leaves an unreferenced directory
    // for reconcile; it never leaves a visible image without its objects.
    final path = Directory(
      '${directory.path}/sha256-${image.digest.substring(7)}',
    );
    if (await FileSystemEntity.type(path.path, followLinks: false) ==
        FileSystemEntityType.directory)
      await path.delete(recursive: true);
    syncImageDirectory(directory.path);
    return true;
  });

  Future<ImageReconciliation> reconcile() => _locked(() async {
    final images = await list();
    final liveNames = {
      for (final image in images) 'sha256-${image.digest.substring(7)}',
    };
    final removed = <String>[];
    final damaged = <ImageId>[];
    await for (final entry in directory.list(followLinks: false)) {
      final name = entry.path.split(Platform.pathSeparator).last;
      if (entry is Directory &&
          (name.startsWith('.staging-') ||
              (RegExp(r'^sha256-[0-9a-f]{64}$').hasMatch(name) &&
                  !liveNames.contains(name)))) {
        await entry.delete(recursive: true);
        removed.add(entry.path);
      }
    }
    for (final image in images) {
      try {
        await _validatePublished(image);
      } catch (_) {
        damaged.add(image.id);
      }
    }
    if (removed.isNotEmpty) {
      syncImageDirectory(directory.path);
      await SqliteEventRepository(database).append(
        type: 'image.store_cleaned',
        resourceType: ResourceType.system,
        payload: JsonObjectValue.fromJson({'removed_paths': removed}),
      );
    }
    return ImageReconciliation(
      List.unmodifiable(removed),
      List.unmodifiable(damaged),
    );
  });

  Future<void> _checkSpace(int bytes) async {
    if (bytes <= 0) throw FormatException('image objects must not be empty');
    if (await _availableBytes(directory) < bytes + 1024 * 1024)
      throw ImageInsufficientSpace(bytes);
  }

  Future<void> _copy(
    OwnedImageFile source,
    File target, {
    required int expectedSize,
    bool Function()? isCancelled,
    void Function(int)? onProgress,
  }) async {
    final output = await target.open(mode: FileMode.write);
    var written = 0;
    try {
      await for (final chunk in source.openRead()) {
        _checkCancelled(isCancelled);
        written += chunk.length;
        if (written > expectedSize)
          throw FormatException('source grew during import');
        await output.writeFrom(chunk);
        onProgress?.call(written);
      }
      _checkCancelled(isCancelled);
      if (written != expectedSize)
        throw FormatException('source size changed during import');
      await output.flush();
    } finally {
      await output.close();
    }
    imageFileMode(target.path, 256); // 0400 immutable managed bytes
  }

  Future<Image> _publish(
    Directory stage,
    ImageManifest manifest, {
    Map<String, String> labels = const {},
  }) async {
    await File(
      '${stage.path}/manifest.json',
    ).writeAsString(canonicalImageJson(manifest.toJson()), flush: true);
    imageFileMode('${stage.path}/manifest.json', 256);
    syncImageDirectory('${stage.path}/objects');
    syncImageDirectory(stage.path);
    _onCheckpoint?.call(ImageImportCheckpoint.staged);
    final image = Image(
      id: ImageId.generate(),
      digest: manifest.digest,
      type: manifest.type,
      architecture: Architecture.arm64,
      guestProfile: manifest.metadata('guest_profile'),
      version: manifest.metadata('version'),
      buildId: manifest.metadata('build_id'),
      channel: manifest.metadata('channel'),
      labels: labels,
      manifest: JsonObjectValue.fromJson(manifest.toJson()),
      createdAt: DateTime.now(),
    );
    final published = Directory(
      '${directory.path}/sha256-${manifest.digest.substring(7)}',
    );
    final result = await database.transaction((_) async {
      final existing = await repository.findDigest(manifest.digest);
      if (existing != null) {
        await _validatePublished(existing);
        return existing;
      }
      // A prior process may have crashed after publication, before commit.
      // No catalog reference exists, so this complete new staging copy replaces
      // the orphan. Never overwrite a registered immutable image.
      final type = await FileSystemEntity.type(
        published.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.directory)
        await published.delete(recursive: true);
      else if (type != FileSystemEntityType.notFound)
        throw FileSystemException(
          'unexpected image publication entry',
          published.path,
        );
      await stage.rename(published.path);
      syncImageDirectory(directory.path);
      try {
        _onCheckpoint?.call(ImageImportCheckpoint.published);
        return await repository.insert(image);
      } catch (_) {
        await published.delete(recursive: true);
        syncImageDirectory(directory.path);
        rethrow;
      }
    });
    // Observability cannot turn a committed import into an apparent failure.
    try {
      _onCheckpoint?.call(ImageImportCheckpoint.committed);
    } catch (_) {}
    return result;
  }

  Future<File> objectFile(ImageId id, String name) async {
    final image = await get(id);
    if (image == null) throw StateError('image.not_found: $id');
    final manifest = ImageManifest.fromJson(image.manifest.toJson());
    if (!manifest.objects.containsKey(name))
      throw StateError('image.object_not_found: $name');
    final file = File(
      '${directory.path}/sha256-${image.digest.substring(7)}/objects/$name',
    );
    await _checkManagedObjectPath(file);
    return file;
  }

  Future<void> _checkManagedObjectPath(File file) async {
    for (final path in [
      directory.path,
      file.parent.parent.path,
      file.parent.path,
    ]) {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.directory)
        throw FileSystemException(
          'managed image directory was replaced or is missing',
          path,
        );
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file)
      throw FileSystemException(
        'managed image object was replaced or is missing',
        file.path,
      );
  }

  Future<void> _validatePublished(Image image) async {
    final root = '${directory.path}/sha256-${image.digest.substring(7)}';
    if (await FileSystemEntity.type(root, followLinks: false) !=
        FileSystemEntityType.directory)
      throw FileSystemException('invalid published image directory', root);
    final manifestFile = File('$root/manifest.json');
    if (await FileSystemEntity.type(manifestFile.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await manifestFile.length() > 1024 * 1024)
      throw FormatException('invalid published manifest');
    final manifest = ImageManifest.fromJson(
      jsonDecode(await manifestFile.readAsString()),
    );
    if (manifest.digest != image.digest ||
        canonicalImageJson(manifest.toJson()) !=
            canonicalImageJson(image.manifest.toJson()))
      throw FormatException('catalog manifest mismatch');
    for (final object in manifest.objects.entries) {
      final file = File('$root/objects/${object.key}');
      await _checkManagedObjectPath(file);
      if (await file.length() != object.value['size_bytes'] ||
          await _fileDigest(file) != object.value['digest'])
        throw FormatException('corrupt image object');
    }
  }
}

Future<String> _fileDigest(File file, {bool Function()? isCancelled}) async =>
    'sha256:${await sha256.bind(file.openRead().map((chunk) {
      _checkCancelled(isCancelled);
      return chunk;
    })).first}';

enum ImageImportCheckpoint { staged, published, committed }

void _checkCancelled(bool Function()? cancelled) {
  if (cancelled?.call() ?? false) throw ImageImportCancelled();
}

final class ImageImportCancelled implements Exception {
  @override
  String toString() => 'image.import_cancelled';
}

final class ImageInsufficientSpace implements Exception {
  ImageInsufficientSpace(this.requiredBytes);
  final int requiredBytes;
  @override
  String toString() =>
      'image.insufficient_space: $requiredBytes bytes required';
}

Future<int> _diskAvailableBytes(Directory directory) async {
  final result = await Process.run(
    '/bin/df',
    ['-Pk', directory.absolute.path],
    environment: {'LC_ALL': 'C'},
  );
  if (result.exitCode != 0)
    throw FileSystemException(
      'cannot determine image store capacity',
      directory.path,
    );
  final lines = (result.stdout as String).trim().split('\n');
  final fields = lines.last.trim().split(RegExp(r'\s+'));
  final blocks = fields.length >= 6 ? int.tryParse(fields[3]) : null;
  if (blocks == null || blocks < 0)
    throw FileSystemException('invalid filesystem capacity', directory.path);
  return blocks * 1024;
}

final _storeGates = <String, Future<void>>{};

final class ImageReconciliation {
  const ImageReconciliation(this.removedPaths, this.damagedImageIds);
  final List<String> removedPaths;
  final List<ImageId> damagedImageIds;
}
