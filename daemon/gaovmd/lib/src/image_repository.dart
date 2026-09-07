import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:sqlite3/sqlite3.dart';

import 'event_repository.dart';
import 'image_manifest.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';

final class ImageInUse implements Exception {
  ImageInUse(this.imageId, this.vmIds);
  final ImageId imageId;
  final List<String> vmIds;
  @override
  String toString() =>
      'image.in_use: $imageId is referenced by ${vmIds.join(', ')}';
}

/// Catalog access. File publication and removal must go through ImageStore.
final class ImageRepository {
  ImageRepository(this.database);
  final GaoVmDatabase database;

  Future<Image?> get(ImageId id) => database.read(
    (db) => _first(
      db.select('SELECT * FROM images WHERE id = ? AND deleted_at IS NULL', [
        id.value,
      ]),
    ),
  );
  Future<Image?> findDigest(String digest) => database.read(
    (db) => _first(
      db.select(
        'SELECT * FROM images WHERE digest = ? AND deleted_at IS NULL',
        [digest],
      ),
    ),
  );
  Future<List<Image>> list() => database.read(
    (db) => db
        .select(
          'SELECT * FROM images WHERE deleted_at IS NULL ORDER BY created_at, id',
        )
        .map(_decode)
        .toList(),
  );

  Future<Image> insert(Image image) => database.transaction((db) async {
    final manifest = ImageManifest.fromJson(image.manifest.toJson());
    if (manifest.digest != image.digest ||
        manifest.type != image.type ||
        manifest.metadata('guest_profile') != image.guestProfile ||
        manifest.metadata('version') != image.version ||
        manifest.metadata('build_id') != image.buildId ||
        manifest.metadata('channel') != image.channel)
      throw FormatException('image metadata disagrees with immutable manifest');
    final existing = await findDigest(image.digest);
    if (existing != null) return existing;
    final json = image.toJson();
    db.execute(
      '''INSERT INTO images(id,digest,type,architecture,guest_profile,version,build_id,channel,labels_json,manifest_json,created_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?)''',
      [
        image.id.value,
        image.digest,
        json['type'],
        json['architecture'],
        image.guestProfile,
        image.version,
        image.buildId,
        image.channel,
        jsonEncode(image.labels),
        jsonEncode(image.manifest.toJson()),
        formatPersistenceTimestamp(image.createdAt),
      ],
    );
    await SqliteEventRepository(database).append(
      type: 'image.imported',
      resourceType: ResourceType.image,
      resourceId: image.id,
      payload: JsonObjectValue.fromJson({'digest': image.digest}),
    );
    return image;
  });

  Future<List<String>> references(ImageId id) => database.read((db) {
    // Include every retained generation: current/pending and the running applied
    // spec may differ. Deleted VM history no longer owns managed images.
    return [
      for (final row in db.select(
        '''SELECT DISTINCT s.vm_id, s.spec_json FROM vm_specs s JOIN vms v ON v.id=s.vm_id WHERE v.deleted_at IS NULL''',
      ))
        if (_references(jsonDecode(row['spec_json'] as String), id.value))
          row['vm_id'] as String,
    ].toSet().toList();
  });

  Future<Image?> delete(ImageId id) => database.transaction((db) async {
    final image = await get(id);
    if (image == null) return null;
    final users = await references(id);
    if (users.isNotEmpty) throw ImageInUse(id, users);
    db.execute('DELETE FROM images WHERE id = ?', [id.value]);
    await SqliteEventRepository(database).append(
      type: 'image.deleted',
      resourceType: ResourceType.image,
      resourceId: id,
      payload: JsonObjectValue.fromJson({'digest': image.digest}),
    );
    return image;
  });
}

bool _references(Object? value, String id) {
  if (value is Map)
    return value.entries.any(
      (entry) =>
          ((entry.key == 'image_id' ||
                  entry.key == 'kernel_image_id' ||
                  entry.key == 'initrd_image_id') &&
              entry.value == id) ||
          _references(entry.value, id),
    );
  if (value is List) return value.any((child) => _references(child, id));
  return false;
}

Image? _first(ResultSet rows) => rows.isEmpty ? null : _decode(rows.first);
Image _decode(Row row) => Image.fromJson({
  'id': row['id'],
  'digest': row['digest'],
  'type': row['type'],
  'architecture': row['architecture'],
  'guest_profile': row['guest_profile'],
  'version': row['version'],
  'build_id': row['build_id'],
  'channel': row['channel'],
  'labels': jsonDecode(row['labels_json'] as String),
  'manifest': jsonDecode(row['manifest_json'] as String),
  'created_at': row['created_at'],
});
