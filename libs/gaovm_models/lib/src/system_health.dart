import 'common.dart';
import 'json_value.dart';

enum SystemHealthProbe { live, ready }

/// A health snapshot, not a VM state or negotiated driver capability.
final class SystemHealth extends ValueObject {
  SystemHealth({required this.probe, required this.healthy, this.checks}) {
    if (probe == SystemHealthProbe.ready && checks == null) {
      throw ArgumentError('readiness requires checks');
    }
  }

  factory SystemHealth.fromJson(
    Object? value, {
    required SystemHealthProbe probe,
  }) {
    final json = readJsonObject(value, 'SystemHealth');
    expectJsonKeys(
      json,
      required: {probe.name, if (probe == SystemHealthProbe.ready) 'checks'},
      optional: {if (probe == SystemHealthProbe.live) 'checks'},
      name: 'SystemHealth',
    );
    return SystemHealth(
      probe: probe,
      healthy: requireJson<bool>(json, probe.name),
      checks: json.containsKey('checks')
          ? JsonObjectValue.fromJson(json['checks'])
          : null,
    );
  }

  final SystemHealthProbe probe;
  final bool healthy;
  final JsonObjectValue? checks;

  Map<String, Object?> toJson() => {
    probe.name: healthy,
    if (checks != null) 'checks': checks!.toJson(),
  };

  @override
  List<Object?> get equalityFields => [probe, healthy, checks];
}
