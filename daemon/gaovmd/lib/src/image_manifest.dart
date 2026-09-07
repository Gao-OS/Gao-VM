import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

/// Immutable manifest v1. The digest covers canonical JSON without `digest`.
final class ImageManifest {
  ImageManifest._(this._json);

  factory ImageManifest.create({
    required ImageType type,
    required Map<String, Map<String, Object?>> objects,
    String? guestProfile,
    String? version,
    String? buildId,
    String? channel,
    Map<String, Object?>? gaoos,
  }) {
    final content = <String, Object?>{
      'manifest_version': 1,
      'architecture': 'arm64',
      'type': imageTypeName(type),
      'objects': objects,
      if (guestProfile != null) 'guest_profile': guestProfile,
      if (version != null) 'version': version,
      if (buildId != null) 'build_id': buildId,
      if (channel != null) 'channel': channel,
      if (gaoos != null) 'gaoos': gaoos,
    };
    return ImageManifest.fromJson({
      ...content,
      'digest': contentDigest(content),
    });
  }

  factory ImageManifest.fromJson(Object? value) {
    if (value is! Map<String, dynamic>)
      throw FormatException('manifest must be an object');
    final json = Map<String, Object?>.of(value);
    const keys = {
      'manifest_version',
      'digest',
      'architecture',
      'type',
      'objects',
      'guest_profile',
      'version',
      'build_id',
      'channel',
      'gaoos',
    };
    if (json.keys.any((key) => !keys.contains(key)) ||
        json['manifest_version'] is! int ||
        json['manifest_version'] != 1 ||
        json['architecture'] != 'arm64') {
      throw FormatException(
        'unsupported manifest fields, version or architecture',
      );
    }
    final type = ImageType.values
        .where((type) => imageTypeName(type) == json['type'])
        .firstOrNull;
    if (type == null) throw FormatException('unsupported image type');
    final objects = json['objects'];
    if (objects is! Map<String, dynamic> ||
        objects.isEmpty ||
        objects.length > 64)
      throw FormatException('objects must contain 1 to 64 entries');
    for (final entry in objects.entries) {
      final object = entry.value;
      if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(entry.key) ||
          object is! Map<String, dynamic> ||
          object.length != 2 ||
          !object.containsKey('digest') ||
          !object.containsKey('size_bytes') ||
          object['size_bytes'] is! int ||
          (object['size_bytes'] as int) <= 0 ||
          object['digest'] is! String ||
          !RegExp(
            r'^sha256:[0-9a-f]{64}$',
          ).hasMatch(object['digest'] as String)) {
        throw FormatException('invalid manifest object: ${entry.key}');
      }
    }
    for (final key in ['guest_profile', 'version', 'build_id', 'channel']) {
      if (json.containsKey(key) &&
          (json[key] is! String ||
              (json[key] as String).isEmpty ||
              (json[key] as String).length > 1024))
        throw FormatException('invalid $key');
    }
    if (type == ImageType.gaoosBundle) {
      if ([
            'version',
            'build_id',
            'channel',
          ].any((key) => !json.containsKey(key)) ||
          json['guest_profile'] != 'gaoos')
        throw FormatException('GaoOS metadata is required');
      final profile = json['gaoos'];
      if (profile is! Map<String, dynamic> ||
          profile.length != 5 ||
          profile['default_command_line'] is! String ||
          profile['guest_agent_expected'] is! bool)
        throw FormatException('invalid GaoOS profile');
      for (final role in ['kernel', 'initrd', 'root_disk']) {
        if (profile[role] is! String || !objects.containsKey(profile[role]))
          throw FormatException('missing GaoOS $role object');
      }
      if ({profile['kernel'], profile['initrd'], profile['root_disk']}.length !=
          3)
        throw FormatException('GaoOS roles require distinct objects');
    } else if (json.containsKey('gaoos') ||
        objects.length != 1 ||
        !objects.containsKey('payload')) {
      throw FormatException('file images require exactly one payload object');
    }
    final digest = json.remove('digest');
    if (digest != contentDigest(json))
      throw FormatException('manifest digest mismatch');
    return ImageManifest._(
      JsonObjectValue.fromJson({...json, 'digest': digest}),
    );
  }

  final JsonObjectValue _json;
  Map<String, Object?> toJson() => _json.toJson();
  String get digest => toJson()['digest'] as String;
  ImageType get type => ImageType.values.firstWhere(
    (type) => imageTypeName(type) == toJson()['type'],
  );
  Map<String, Map<String, Object?>> get objects =>
      (toJson()['objects'] as Map).map(
        (key, value) =>
            MapEntry(key as String, Map<String, Object?>.from(value as Map)),
      );
  String? metadata(String key) => toJson()[key] as String?;
}

String imageTypeName(ImageType type) => switch (type) {
  ImageType.linuxKernel => 'linux-kernel',
  ImageType.initrd => 'initrd',
  ImageType.rawDisk => 'raw-disk',
  ImageType.gaoosBundle => 'gaoos-bundle',
};

String canonicalImageJson(Object? value) => jsonEncode(_canonical(value));
Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String contentDigest(Object? value) =>
    'sha256:${sha256.convert(utf8.encode(canonicalImageJson(value)))}';
