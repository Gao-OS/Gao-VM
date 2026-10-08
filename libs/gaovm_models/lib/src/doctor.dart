import 'common.dart';

enum DoctorCheckStatus { ok, warning, error }

final class DoctorCheck extends ValueObject {
  const DoctorCheck({
    required this.name,
    required this.status,
    required this.message,
  });

  factory DoctorCheck.fromJson(Object? value) {
    final json = readJsonObject(value, 'DoctorCheck');
    expectJsonKeys(
      json,
      required: const {'name', 'status', 'message'},
      optional: const {},
      name: 'DoctorCheck',
    );
    return DoctorCheck(
      name: requireJson<String>(json, 'name'),
      status: switch (json['status']) {
        'ok' => DoctorCheckStatus.ok,
        'warning' => DoctorCheckStatus.warning,
        'error' => DoctorCheckStatus.error,
        _ => throw const FormatException('invalid doctor check status'),
      },
      message: requireJson<String>(json, 'message'),
    );
  }

  final String name;
  final DoctorCheckStatus status;
  final String message;

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status.name,
    'message': message,
  };

  @override
  List<Object?> get equalityFields => [name, status, message];
}

final class DoctorResult extends ValueObject {
  DoctorResult({required this.healthy, required Iterable<DoctorCheck> checks})
    : checks = List.unmodifiable(checks);

  factory DoctorResult.fromChecks(Iterable<DoctorCheck> checks) {
    final snapshot = List<DoctorCheck>.of(checks);
    return DoctorResult(
      healthy: !snapshot.any(
        (check) => check.status == DoctorCheckStatus.error,
      ),
      checks: snapshot,
    );
  }

  factory DoctorResult.fromJson(Object? value) {
    final json = readJsonObject(value, 'DoctorResult');
    expectJsonKeys(
      json,
      required: const {'healthy', 'checks'},
      optional: const {},
      name: 'DoctorResult',
    );
    return DoctorResult(
      healthy: requireJson<bool>(json, 'healthy'),
      checks: readJsonList(json['checks'], 'checks', DoctorCheck.fromJson),
    );
  }

  final bool healthy;
  final List<DoctorCheck> checks;

  Map<String, Object?> toJson() => {
    'healthy': healthy,
    'checks': checks.map((check) => check.toJson()).toList(),
  };

  @override
  List<Object?> get equalityFields => [healthy, checks];
}
