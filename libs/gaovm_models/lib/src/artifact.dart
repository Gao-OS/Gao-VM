import 'common.dart';
import 'resource_id.dart';

final _artifactDigestPattern = RegExp(r'^sha256:[0-9a-f]{64}$');
final _downloadUrlPattern = RegExp(
  r'^/v1/artifacts/art_[0-7][0-9A-HJKMNP-TV-Z]{25}$',
);

enum ArtifactKind { stdout, stderr, serial, driver, guestLog, result, file }

ArtifactKind _parseArtifactKind(Object? value) => switch (value) {
  'stdout' => ArtifactKind.stdout,
  'stderr' => ArtifactKind.stderr,
  'serial' => ArtifactKind.serial,
  'driver' => ArtifactKind.driver,
  'guest-log' => ArtifactKind.guestLog,
  'result' => ArtifactKind.result,
  'file' => ArtifactKind.file,
  _ => throw FormatException('unsupported artifact kind: $value'),
};

String _artifactKindToJson(ArtifactKind value) => switch (value) {
  ArtifactKind.guestLog => 'guest-log',
  _ => value.name,
};

final class Artifact extends ValueObject {
  Artifact({
    required this.id,
    this.vmId,
    this.operationId,
    this.testRunId,
    required this.kind,
    required this.contentType,
    required this.sizeBytes,
    required this.digest,
    required this.downloadUrl,
    DateTime? retentionUntil,
    required DateTime createdAt,
  }) : retentionUntil = retentionUntil?.toUtc(),
       createdAt = createdAt.toUtc() {
    requireNonEmpty(contentType, 'contentType');
    if (sizeBytes < 0) {
      throw ArgumentError.value(sizeBytes, 'sizeBytes', 'must not be negative');
    }
    requirePattern(digest, _artifactDigestPattern, 'digest');
    requirePattern(downloadUrl, _downloadUrlPattern, 'downloadUrl');
  }

  factory Artifact.fromJson(Object? value) {
    final json = readJsonObject(value, 'Artifact');
    expectJsonKeys(
      json,
      required: const {
        'id',
        'vm_id',
        'operation_id',
        'test_run_id',
        'kind',
        'content_type',
        'size_bytes',
        'digest',
        'download_url',
        'retention_until',
        'created_at',
      },
      optional: const {},
      name: 'Artifact',
    );
    final vmId = nullableJson<String>(json, 'vm_id');
    final operationId = nullableJson<String>(json, 'operation_id');
    final testRunId = nullableJson<String>(json, 'test_run_id');
    return Artifact(
      id: ArtifactId(requireJson<String>(json, 'id')),
      vmId: vmId == null ? null : VmId(vmId),
      operationId: operationId == null ? null : OperationId(operationId),
      testRunId: testRunId == null ? null : TestRunId(testRunId),
      kind: _parseArtifactKind(json['kind']),
      contentType: requireJson<String>(json, 'content_type'),
      sizeBytes: requireJson<int>(json, 'size_bytes'),
      digest: requireJson<String>(json, 'digest'),
      downloadUrl: requireJson<String>(json, 'download_url'),
      retentionUntil: nullableDateTime(json, 'retention_until'),
      createdAt: requireDateTime(json, 'created_at'),
    );
  }

  final ArtifactId id;
  final VmId? vmId;
  final OperationId? operationId;
  final TestRunId? testRunId;
  final ArtifactKind kind;
  final String contentType;
  final int sizeBytes;
  final String digest;
  final String downloadUrl;
  final DateTime? retentionUntil;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id.value,
    'vm_id': vmId?.value,
    'operation_id': operationId?.value,
    'test_run_id': testRunId?.value,
    'kind': _artifactKindToJson(kind),
    'content_type': contentType,
    'size_bytes': sizeBytes,
    'digest': digest,
    'download_url': downloadUrl,
    'retention_until': retentionUntil == null
        ? null
        : formatDateTime(retentionUntil!),
    'created_at': formatDateTime(createdAt),
  };

  @override
  List<Object?> get equalityFields => [
    id,
    vmId,
    operationId,
    testRunId,
    kind,
    contentType,
    sizeBytes,
    digest,
    downloadUrl,
    retentionUntil,
    createdAt,
  ];
}
