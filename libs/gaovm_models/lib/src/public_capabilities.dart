import 'common.dart';

/// Public API advertisements, independent from a negotiated driver session.
final class PublicCapabilities extends ValueObject {
  PublicCapabilities({
    required Iterable<String> backends,
    required Iterable<String> guest,
    required this.maxDefinedVms,
    required this.maxRunningVms,
    required this.maxConcurrentBoots,
  }) : backends = List.unmodifiable(backends),
       guest = List.unmodifiable(guest) {
    if (this.backends.any((backend) => backend != 'vz') ||
        this.guest.any((capability) => !_guest.contains(capability)) ||
        this.guest.toSet().length != this.guest.length ||
        maxDefinedVms < 1 ||
        maxRunningVms < 1 ||
        maxConcurrentBoots < 1) {
      throw ArgumentError('invalid public capabilities');
    }
  }

  factory PublicCapabilities.fromJson(Object? value) {
    final json = readJsonObject(value, 'Capabilities');
    expectJsonKeys(
      json,
      required: const {'api_version', 'backends', 'guest', 'limits'},
      optional: const {},
      name: 'Capabilities',
    );
    if (json['api_version'] != 'v1') {
      throw const FormatException('unsupported public capability version');
    }
    final limits = readJsonObject(json['limits'], 'Capabilities.limits');
    expectJsonKeys(
      limits,
      required: const {
        'max_defined_vms',
        'max_running_vms',
        'max_concurrent_boots',
      },
      optional: const {},
      name: 'Capabilities.limits',
    );
    return PublicCapabilities(
      backends: readJsonList(json['backends'], 'backends', _string),
      guest: readJsonList(json['guest'], 'guest', _string),
      maxDefinedVms: requireJson<int>(limits, 'max_defined_vms'),
      maxRunningVms: requireJson<int>(limits, 'max_running_vms'),
      maxConcurrentBoots: requireJson<int>(limits, 'max_concurrent_boots'),
    );
  }

  static const _guest = {
    'health',
    'system.info',
    'exec',
    'artifact.collect',
    'service.status',
    'shutdown',
    'reboot',
  };

  static String _string(Object? value) {
    if (value is! String) {
      throw const FormatException('capabilities must be strings');
    }
    return value;
  }

  final List<String> backends;
  final List<String> guest;
  final int maxDefinedVms;
  final int maxRunningVms;
  final int maxConcurrentBoots;

  Map<String, Object?> toJson() => {
    'api_version': 'v1',
    'backends': backends,
    'guest': guest,
    'limits': {
      'max_defined_vms': maxDefinedVms,
      'max_running_vms': maxRunningVms,
      'max_concurrent_boots': maxConcurrentBoots,
    },
  };

  @override
  List<Object?> get equalityFields => [
    backends,
    guest,
    maxDefinedVms,
    maxRunningVms,
    maxConcurrentBoots,
  ];
}
