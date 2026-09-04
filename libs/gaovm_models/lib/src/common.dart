import 'dart:collection';

abstract base class ValueObject {
  const ValueObject();

  List<Object?> get equalityFields;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      runtimeType == other.runtimeType &&
          other is ValueObject &&
          _deepEquals(equalityFields, other.equalityFields);

  @override
  int get hashCode => Object.hash(runtimeType, _deepHash(equalityFields));
}

bool _deepEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_deepEquals(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_deepEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

int _deepHash(Object? value) {
  if (value is List) return Object.hashAll(value.map(_deepHash));
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
    return Object.hashAll(
      entries.map((entry) => Object.hash(entry.key, _deepHash(entry.value))),
    );
  }
  return value.hashCode;
}

Map<String, Object?> readJsonObject(Object? value, String name) {
  if (value is! Map) throw FormatException('$name must be a JSON object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$name must have string keys');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

void expectJsonKeys(
  Map<String, Object?> json, {
  required Set<String> required,
  required Set<String> optional,
  required String name,
}) {
  final missing = required.difference(json.keys.toSet());
  if (missing.isNotEmpty) {
    throw FormatException('$name is missing ${missing.join(', ')}');
  }
  final unknown = json.keys.toSet().difference({...required, ...optional});
  if (unknown.isNotEmpty) {
    throw FormatException('$name has unknown fields: ${unknown.join(', ')}');
  }
}

T requireJson<T>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! T) throw FormatException('$key must be a $T');
  return value;
}

T? optionalJson<T>(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  final value = json[key];
  if (value is! T) throw FormatException('$key must be a $T when present');
  return value;
}

T? nullableJson<T>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! T) throw FormatException('$key must be a $T or null');
  return value as T;
}

final _rfc3339DateTimePattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
);

DateTime _parseRfc3339DateTime(String value, String key) {
  if (!_rfc3339DateTimePattern.hasMatch(value)) {
    throw FormatException(
      '$key must include a full RFC 3339 time and explicit offset',
    );
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$key must be an RFC 3339 date-time');
  }
  return parsed.toUtc();
}

DateTime requireDateTime(Map<String, Object?> json, String key) =>
    _parseRfc3339DateTime(requireJson<String>(json, key), key);

DateTime? optionalDateTime(Map<String, Object?> json, String key) {
  final value = optionalJson<String>(json, key);
  if (value == null) return null;
  return _parseRfc3339DateTime(value, key);
}

DateTime? nullableDateTime(Map<String, Object?> json, String key) {
  final value = nullableJson<String>(json, key);
  if (value == null) return null;
  return _parseRfc3339DateTime(value, key);
}

String formatDateTime(DateTime value) => value.toUtc().toIso8601String();

List<T> readJsonList<T>(
  Object? value,
  String name,
  T Function(Object? value) parse,
) {
  if (value is! List) throw FormatException('$name must be a JSON array');
  return List<T>.unmodifiable(value.map(parse));
}

Map<String, String> readStringMap(Object? value, String name) {
  final json = readJsonObject(value, name);
  final result = <String, String>{};
  for (final entry in json.entries) {
    if (entry.value is! String) {
      throw FormatException('$name values must be strings');
    }
    result[entry.key] = entry.value! as String;
  }
  return UnmodifiableMapView(result);
}

Map<String, String> immutableStringMap(Map<String, String> value) =>
    UnmodifiableMapView(Map<String, String>.of(value));

final _labelNamePattern = RegExp(
  r'^[A-Za-z0-9](?:[A-Za-z0-9._/-]*[A-Za-z0-9])?$',
);

void validateLabels(Map<String, String> labels) {
  if (labels.length > 64) {
    throw ArgumentError.value(
      labels,
      'labels',
      'must contain at most 64 labels',
    );
  }
  for (final entry in labels.entries) {
    if (entry.key.length > 253 || !_labelNamePattern.hasMatch(entry.key)) {
      throw ArgumentError.value(entry.key, 'labels', 'invalid label name');
    }
    if (entry.value.length > 253) {
      throw ArgumentError.value(
        entry.value,
        'labels',
        'label value is too long',
      );
    }
  }
}

enum Architecture { arm64 }

Architecture parseArchitecture(Object? value) => switch (value) {
  'arm64' => Architecture.arm64,
  _ => throw FormatException('unsupported architecture: $value'),
};

String architectureToJson(Architecture value) => value.name;

enum ResourceType {
  virtualMachine,
  image,
  operation,
  testRun,
  artifact,
  system,
}

ResourceType parseResourceType(Object? value) => switch (value) {
  'virtual_machine' => ResourceType.virtualMachine,
  'image' => ResourceType.image,
  'operation' => ResourceType.operation,
  'test_run' => ResourceType.testRun,
  'artifact' => ResourceType.artifact,
  'system' => ResourceType.system,
  _ => throw FormatException('unsupported resource_type: $value'),
};

String resourceTypeToJson(ResourceType value) => switch (value) {
  ResourceType.virtualMachine => 'virtual_machine',
  ResourceType.image => 'image',
  ResourceType.operation => 'operation',
  ResourceType.testRun => 'test_run',
  ResourceType.artifact => 'artifact',
  ResourceType.system => 'system',
};

enum ErrorCode {
  vmNotFound,
  vmAlreadyRunning,
  vmNotRunning,
  vmOperationConflict,
  vmSpecInvalid,
  revisionConflict,
  hostResourceExhausted,
  driverStartFailed,
  driverUnhealthy,
  guestAgentUnavailable,
  guestExecFailed,
  waitTimeout,
  operationNotFound,
  operationNotCancellable,
  idempotencyConflict,
  imageNotFound,
  imageInUse,
  testRunNotFound,
  artifactNotFound,
  invalidRequest,
  internalError,
}

const _errorCodeJson = {
  ErrorCode.vmNotFound: 'VM_NOT_FOUND',
  ErrorCode.vmAlreadyRunning: 'VM_ALREADY_RUNNING',
  ErrorCode.vmNotRunning: 'VM_NOT_RUNNING',
  ErrorCode.vmOperationConflict: 'VM_OPERATION_CONFLICT',
  ErrorCode.vmSpecInvalid: 'VM_SPEC_INVALID',
  ErrorCode.revisionConflict: 'REVISION_CONFLICT',
  ErrorCode.hostResourceExhausted: 'HOST_RESOURCE_EXHAUSTED',
  ErrorCode.driverStartFailed: 'DRIVER_START_FAILED',
  ErrorCode.driverUnhealthy: 'DRIVER_UNHEALTHY',
  ErrorCode.guestAgentUnavailable: 'GUEST_AGENT_UNAVAILABLE',
  ErrorCode.guestExecFailed: 'GUEST_EXEC_FAILED',
  ErrorCode.waitTimeout: 'WAIT_TIMEOUT',
  ErrorCode.operationNotFound: 'OPERATION_NOT_FOUND',
  ErrorCode.operationNotCancellable: 'OPERATION_NOT_CANCELLABLE',
  ErrorCode.idempotencyConflict: 'IDEMPOTENCY_CONFLICT',
  ErrorCode.imageNotFound: 'IMAGE_NOT_FOUND',
  ErrorCode.imageInUse: 'IMAGE_IN_USE',
  ErrorCode.testRunNotFound: 'TEST_RUN_NOT_FOUND',
  ErrorCode.artifactNotFound: 'ARTIFACT_NOT_FOUND',
  ErrorCode.invalidRequest: 'INVALID_REQUEST',
  ErrorCode.internalError: 'INTERNAL_ERROR',
};

ErrorCode parseErrorCode(Object? value) {
  for (final entry in _errorCodeJson.entries) {
    if (entry.value == value) return entry.key;
  }
  throw FormatException('unsupported error code: $value');
}

String errorCodeToJson(ErrorCode value) => _errorCodeJson[value]!;

void requireRange(num value, num minimum, num maximum, String name) {
  if (!value.isFinite || value < minimum || value > maximum) {
    throw ArgumentError.value(
      value,
      name,
      'must be between $minimum and $maximum',
    );
  }
}

void requirePattern(String value, RegExp pattern, String name) {
  if (!pattern.hasMatch(value)) {
    throw ArgumentError.value(value, name, 'has an invalid format');
  }
}

void requireNonEmpty(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
}

// Re-exported through gaovm_models.dart without exporting all parsing helpers.
VmPhase parseVmPhase(String value) => VmPhaseParsing.parse(value);

enum VmPhase {
  defined,
  provisioning,
  stopped,
  spawningDriver,
  handshaking,
  configuring,
  starting,
  running,
  stopping,
  crashed,
  failed,
  deleting,
  deleted,
}

abstract final class VmPhaseParsing {
  static VmPhase parse(Object? value) => switch (value) {
    'defined' => VmPhase.defined,
    'provisioning' => VmPhase.provisioning,
    'stopped' => VmPhase.stopped,
    'spawning_driver' => VmPhase.spawningDriver,
    'handshaking' => VmPhase.handshaking,
    'configuring' => VmPhase.configuring,
    'starting' => VmPhase.starting,
    'running' => VmPhase.running,
    'stopping' => VmPhase.stopping,
    'crashed' => VmPhase.crashed,
    'failed' => VmPhase.failed,
    'deleting' => VmPhase.deleting,
    'deleted' => VmPhase.deleted,
    _ => throw FormatException('unsupported VM phase: $value'),
  };

  static String toJson(VmPhase value) => switch (value) {
    VmPhase.spawningDriver => 'spawning_driver',
    _ => value.name,
  };
}
