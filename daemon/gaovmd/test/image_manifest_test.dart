import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/image_manifest.dart';
import 'package:test/test.dart';

void main() {
  ImageManifest kernel() => ImageManifest.create(
    type: ImageType.linuxKernel,
    objects: {
      'payload': {'digest': 'sha256:${'a' * 64}', 'size_bytes': 100},
    },
  );

  test(
    'canonical manifest is immutable and independent of key insertion order',
    () {
      final manifest = kernel();
      final json = manifest.toJson();
      final reversed = Map<String, Object?>.fromEntries(
        json.entries.toList().reversed,
      );
      expect(ImageManifest.fromJson(reversed).digest, manifest.digest);
      expect(
        () => (json['objects'] as Map)['payload'] = {},
        throwsUnsupportedError,
      );
      expect(manifest.objects['payload']!['size_bytes'], 100);
    },
  );

  for (final change in <String, Object?>{
    'manifest_version': 1.0,
    'architecture': 'x86_64',
    'digest': 'sha256:${'b' * 64}',
    'surprise': true,
  }.entries) {
    test('rejects invalid ${change.key}', () {
      final json = Map<String, Object?>.of(kernel().toJson())
        ..[change.key] = change.value;
      if (change.key != 'digest') {
        json.remove('digest');
        json['digest'] = contentDigest(json);
      }
      expect(() => ImageManifest.fromJson(json), throwsFormatException);
    });
  }

  test('rejects object path traversal even with a valid digest', () {
    expect(
      () => ImageManifest.create(
        type: ImageType.rawDisk,
        objects: {
          '../payload': {'digest': 'sha256:${'a' * 64}', 'size_bytes': 100},
        },
      ),
      throwsFormatException,
    );
  });
}
