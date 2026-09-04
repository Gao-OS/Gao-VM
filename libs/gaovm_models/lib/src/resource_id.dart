import 'dart:math';

import 'common.dart';

const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final _ulidPattern = RegExp(r'^[0-7][0-9A-HJKMNP-TV-Z]{25}$');
final _secureRandom = Random.secure();

sealed class ResourceId extends ValueObject {
  ResourceId._(this.value, String prefix) {
    if (!value.startsWith('${prefix}_') ||
        !_ulidPattern.hasMatch(value.substring(prefix.length + 1))) {
      throw FormatException('invalid $prefix resource ID: $value');
    }
  }

  factory ResourceId.parse(String value) {
    final separator = value.indexOf('_');
    if (separator < 0) throw FormatException('invalid resource ID: $value');
    return switch (value.substring(0, separator)) {
      'vm' => VmId(value),
      'img' => ImageId(value),
      'op' => OperationId(value),
      'evt' => EventId(value),
      'tr' => TestRunId(value),
      'art' => ArtifactId(value),
      'req' => RequestId(value),
      _ => throw FormatException('unknown resource ID prefix: $value'),
    };
  }

  final String value;

  bool matchesResourceType(ResourceType type) => switch (type) {
    ResourceType.virtualMachine => this is VmId,
    ResourceType.image => this is ImageId,
    ResourceType.operation => this is OperationId,
    ResourceType.testRun => this is TestRunId,
    ResourceType.artifact => this is ArtifactId,
    ResourceType.system => false,
  };

  DateTime get timestamp {
    var milliseconds = 0;
    for (
      var index = value.indexOf('_') + 1;
      index < value.indexOf('_') + 11;
      index++
    ) {
      milliseconds = (milliseconds << 5) | _crockford.indexOf(value[index]);
    }
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }

  @override
  List<Object?> get equalityFields => [value];

  @override
  String toString() => value;
}

String _generate(String prefix, DateTime? value) {
  var timestamp = (value ?? DateTime.now()).millisecondsSinceEpoch;
  if (timestamp < 0 || timestamp > 0xFFFFFFFFFFFF) {
    throw ArgumentError.value(value, 'timestamp', 'is outside the ULID range');
  }
  final chars = List<String>.filled(26, '0');
  for (var index = 9; index >= 0; index--) {
    chars[index] = _crockford[timestamp & 31];
    timestamp >>= 5;
  }
  for (var index = 10; index < 26; index++) {
    chars[index] = _crockford[_secureRandom.nextInt(32)];
  }
  return '${prefix}_${chars.join()}';
}

final class VmId extends ResourceId {
  VmId(String value) : super._(value, 'vm');
  factory VmId.generate({DateTime? timestamp}) =>
      VmId(_generate('vm', timestamp));
}

final class ImageId extends ResourceId {
  ImageId(String value) : super._(value, 'img');
  factory ImageId.generate({DateTime? timestamp}) =>
      ImageId(_generate('img', timestamp));
}

final class OperationId extends ResourceId {
  OperationId(String value) : super._(value, 'op');
  factory OperationId.generate({DateTime? timestamp}) =>
      OperationId(_generate('op', timestamp));
}

final class EventId extends ResourceId {
  EventId(String value) : super._(value, 'evt');
  factory EventId.generate({DateTime? timestamp}) =>
      EventId(_generate('evt', timestamp));
}

final class TestRunId extends ResourceId {
  TestRunId(String value) : super._(value, 'tr');
  factory TestRunId.generate({DateTime? timestamp}) =>
      TestRunId(_generate('tr', timestamp));
}

final class ArtifactId extends ResourceId {
  ArtifactId(String value) : super._(value, 'art');
  factory ArtifactId.generate({DateTime? timestamp}) =>
      ArtifactId(_generate('art', timestamp));
}

final class RequestId extends ResourceId {
  RequestId(String value) : super._(value, 'req');
  factory RequestId.generate({DateTime? timestamp}) =>
      RequestId(_generate('req', timestamp));
}
