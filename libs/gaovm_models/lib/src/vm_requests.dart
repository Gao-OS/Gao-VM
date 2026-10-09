import 'common.dart';
import 'vm.dart';

/// A create input, deliberately excluding server-owned resource metadata.
final class VmCreateRequest extends ValueObject {
  VmCreateRequest({
    required this.name,
    Map<String, String> labels = const {},
    required this.spec,
  }) : labels = immutableStringMap(labels) {
    _validateName(name);
    validateLabels(this.labels);
  }

  factory VmCreateRequest.fromJson(Object? value) {
    final json = readJsonObject(value, 'VM create request');
    expectJsonKeys(
      json,
      required: const {'api_version', 'kind', 'metadata', 'spec'},
      optional: const {},
      name: 'VM create request',
    );
    if (json['api_version'] != vmApiVersion || json['kind'] != vmKind) {
      throw const FormatException('unsupported VM api_version or kind');
    }
    final metadata = readJsonObject(json['metadata'], 'metadata');
    expectJsonKeys(
      metadata,
      required: const {'name'},
      optional: const {'labels'},
      name: 'create metadata',
    );
    return VmCreateRequest(
      name: requireJson<String>(metadata, 'name'),
      labels: metadata.containsKey('labels')
          ? readStringMap(metadata['labels'], 'labels')
          : const {},
      spec: VmSpec.fromJson(json['spec']),
    );
  }

  final String name;
  final Map<String, String> labels;
  final VmSpec spec;

  Map<String, Object?> toJson() => {
    'api_version': vmApiVersion,
    'kind': vmKind,
    'metadata': {'name': name, 'labels': Map<String, String>.of(labels)},
    'spec': spec.toJson(),
  };

  @override
  List<Object?> get equalityFields => [name, labels, spec];
}

/// A partial metadata/spec write. Absence and explicit spec null stay distinct.
final class VmPatchRequest extends ValueObject {
  VmPatchRequest({this.name, Map<String, String>? labels, this.spec})
    : labels = labels == null ? null : immutableStringMap(labels) {
    if (name == null && labels == null && spec == null) {
      throw ArgumentError('VM patch must contain at least one field');
    }
    if (name != null) _validateName(name!);
    if (this.labels != null) validateLabels(this.labels!);
  }

  factory VmPatchRequest.fromJson(Object? value) {
    final json = readJsonObject(value, 'VM patch request');
    expectJsonKeys(
      json,
      required: const {},
      optional: const {'metadata', 'spec'},
      name: 'VM patch request',
    );
    String? name;
    Map<String, String>? labels;
    if (json.containsKey('metadata')) {
      final metadata = readJsonObject(json['metadata'], 'metadata');
      expectJsonKeys(
        metadata,
        required: const {},
        optional: const {'name', 'labels'},
        name: 'patch metadata',
      );
      if (metadata.isEmpty) {
        throw const FormatException('metadata patch is empty');
      }
      name = optionalJson<String>(metadata, 'name');
      if (metadata.containsKey('labels')) {
        labels = readStringMap(metadata['labels'], 'labels');
      }
    }
    return VmPatchRequest(
      name: name,
      labels: labels,
      spec: json.containsKey('spec')
          ? VmSpecPatch.fromJson(json['spec'])
          : null,
    );
  }

  final String? name;
  final Map<String, String>? labels;
  final VmSpecPatch? spec;

  Map<String, Object?> toJson() => {
    if (name != null || labels != null)
      'metadata': {
        if (name != null) 'name': name,
        if (labels != null) 'labels': Map<String, String>.of(labels!),
      },
    if (spec != null) 'spec': spec!.toJson(),
  };

  @override
  List<Object?> get equalityFields => [name, labels, spec];
}

void _validateName(String name) {
  requireNonEmpty(name, 'name');
  if (name.length > 128) {
    throw ArgumentError.value(
      name,
      'name',
      'must contain at most 128 characters',
    );
  }
}
