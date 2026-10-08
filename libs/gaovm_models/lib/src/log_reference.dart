import 'common.dart';
import 'resource_id.dart';

enum LogKind {
  driver,
  serial,
  guest;

  static LogKind parse(Object? value) => switch (value) {
    'driver' => driver,
    'serial' => serial,
    'guest' => guest,
    _ => throw const FormatException('unsupported log kind'),
  };
}

final class LogReference extends ValueObject {
  LogReference({
    required this.kind,
    required this.vmId,
    required this.sizeBytes,
    required DateTime updatedAt,
    this.artifactId,
  }) : updatedAt = updatedAt.toUtc() {
    if (sizeBytes < 0) {
      throw ArgumentError.value(sizeBytes, 'sizeBytes', 'must not be negative');
    }
    if (this.updatedAt.year < 0 || this.updatedAt.year > 9999) {
      throw ArgumentError.value(
        updatedAt,
        'updatedAt',
        'requires a four-digit UTC year',
      );
    }
  }

  factory LogReference.fromJson(Object? value) {
    final json = readJsonObject(value, 'LogReference');
    expectJsonKeys(
      json,
      required: const {
        'kind',
        'vm_id',
        'size_bytes',
        'updated_at',
        'artifact_id',
      },
      optional: const {},
      name: 'LogReference',
    );
    final artifactId = nullableJson<String>(json, 'artifact_id');
    return LogReference(
      kind: LogKind.parse(json['kind']),
      vmId: VmId(requireJson<String>(json, 'vm_id')),
      sizeBytes: requireJson<int>(json, 'size_bytes'),
      updatedAt: requireDateTime(json, 'updated_at'),
      artifactId: artifactId == null ? null : ArtifactId(artifactId),
    );
  }

  final LogKind kind;
  final VmId vmId;
  final int sizeBytes;
  final DateTime updatedAt;
  final ArtifactId? artifactId;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'vm_id': vmId.value,
    'size_bytes': sizeBytes,
    'updated_at': formatDateTime(updatedAt),
    'artifact_id': artifactId?.value,
  };

  @override
  List<Object?> get equalityFields => [
    kind,
    vmId,
    sizeBytes,
    updatedAt,
    artifactId,
  ];
}
