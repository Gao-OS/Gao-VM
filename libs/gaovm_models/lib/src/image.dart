import 'common.dart';
import 'json_value.dart';
import 'resource_id.dart';

final _digestPattern = RegExp(r'^sha256:[0-9a-f]{64}$');

enum ImageType { linuxKernel, initrd, rawDisk, gaoosBundle }

ImageType _parseImageType(Object? value) => switch (value) {
  'linux-kernel' => ImageType.linuxKernel,
  'initrd' => ImageType.initrd,
  'raw-disk' => ImageType.rawDisk,
  'gaoos-bundle' => ImageType.gaoosBundle,
  _ => throw FormatException('unsupported image type: $value'),
};

String _imageTypeToJson(ImageType value) => switch (value) {
  ImageType.linuxKernel => 'linux-kernel',
  ImageType.rawDisk => 'raw-disk',
  ImageType.gaoosBundle => 'gaoos-bundle',
  ImageType.initrd => 'initrd',
};

final class Image extends ValueObject {
  Image({
    required this.id,
    required this.digest,
    required this.type,
    required this.architecture,
    this.guestProfile,
    this.version,
    this.buildId,
    this.channel,
    Map<String, String> labels = const {},
    required this.manifest,
    required DateTime createdAt,
  }) : labels = immutableStringMap(labels),
       createdAt = createdAt.toUtc() {
    requirePattern(digest, _digestPattern, 'digest');
    validateLabels(this.labels);
  }

  factory Image.fromJson(Object? value) {
    final json = readJsonObject(value, 'Image');
    expectJsonKeys(
      json,
      required: const {
        'id',
        'digest',
        'type',
        'architecture',
        'manifest',
        'created_at',
      },
      optional: const {
        'guest_profile',
        'version',
        'build_id',
        'channel',
        'labels',
      },
      name: 'Image',
    );
    return Image(
      id: ImageId(requireJson<String>(json, 'id')),
      digest: requireJson<String>(json, 'digest'),
      type: _parseImageType(json['type']),
      architecture: parseArchitecture(json['architecture']),
      guestProfile: nullableJson<String>(json, 'guest_profile'),
      version: nullableJson<String>(json, 'version'),
      buildId: nullableJson<String>(json, 'build_id'),
      channel: nullableJson<String>(json, 'channel'),
      labels: json.containsKey('labels')
          ? readStringMap(json['labels'], 'labels')
          : const {},
      manifest: JsonObjectValue.fromJson(json['manifest']),
      createdAt: requireDateTime(json, 'created_at'),
    );
  }

  final ImageId id;
  final String digest;
  final ImageType type;
  final Architecture architecture;
  final String? guestProfile;
  final String? version;
  final String? buildId;
  final String? channel;
  final Map<String, String> labels;
  final JsonObjectValue manifest;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id.value,
    'digest': digest,
    'type': _imageTypeToJson(type),
    'architecture': architectureToJson(architecture),
    'guest_profile': guestProfile,
    'version': version,
    'build_id': buildId,
    'channel': channel,
    'labels': Map<String, String>.of(labels),
    'manifest': manifest.toJson(),
    'created_at': formatDateTime(createdAt),
  };

  @override
  List<Object?> get equalityFields => [
    id,
    digest,
    type,
    architecture,
    guestProfile,
    version,
    buildId,
    channel,
    labels,
    manifest,
    createdAt,
  ];
}
