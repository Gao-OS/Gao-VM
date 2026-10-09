import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  for (final probe in SystemHealthProbe.values) {
    test('$probe health freezes and round-trips arbitrary JSON checks', () {
      final checks = <String, Object?>{
        'database': false,
        'dependency': {'reason': 'not ready'},
      };
      final report = SystemHealth.fromJson({
        probe.name: false,
        'checks': checks,
      }, probe: probe);
      checks.clear();
      expect(report.healthy, isFalse);
      expect(report.checks!.toJson()['database'], isFalse);
      expect(SystemHealth.fromJson(report.toJson(), probe: probe), report);
      expect(
        SystemHealth.fromJson(report.toJson(), probe: probe).hashCode,
        report.hashCode,
      );
    });

    for (final invalid in [
      'missing flag',
      'flag type',
      'checks type',
      'extra',
    ]) {
      test('$probe health rejects $invalid', () {
        final json = <String, Object?>{probe.name: true, 'checks': {}};
        switch (invalid) {
          case 'missing flag':
            json.remove(probe.name);
          case 'flag type':
            json[probe.name] = 1;
          case 'checks type':
            json['checks'] = null;
          case 'extra':
            json['phase'] = 'running';
        }
        expect(
          () => SystemHealth.fromJson(json, probe: probe),
          throwsFormatException,
        );
      });
    }
  }

  test('liveness preserves omitted checks; readiness requires checks', () {
    final live = SystemHealth.fromJson({
      'live': true,
    }, probe: SystemHealthProbe.live);
    expect(live.checks, isNull);
    expect(live.toJson(), {'live': true});
    expect(
      () => SystemHealth.fromJson({
        'ready': true,
      }, probe: SystemHealthProbe.ready),
      throwsFormatException,
    );
    expect(
      () => SystemHealth(probe: SystemHealthProbe.ready, healthy: true),
      throwsArgumentError,
    );
  });

  test('public capabilities freeze collections and round-trip the schema', () {
    final backends = ['vz'];
    final guest = ['health', 'system.info', 'exec', 'artifact.collect'];
    final report = PublicCapabilities(
      backends: backends,
      guest: guest,
      maxDefinedVms: 128,
      maxRunningVms: 8,
      maxConcurrentBoots: 2,
    );
    backends.clear();
    guest.clear();
    expect(report.backends, ['vz']);
    expect(report.guest, hasLength(4));
    expect(() => report.backends.clear(), throwsUnsupportedError);
    expect(() => report.guest.clear(), throwsUnsupportedError);
    expect(PublicCapabilities.fromJson(report.toJson()), report);
    expect(
      PublicCapabilities.fromJson(report.toJson()).hashCode,
      report.hashCode,
    );
  });

  test('capability decoding preserves empty arrays and repeated backends', () {
    final json = _capabilities();
    json['backends'] = <String>[];
    json['guest'] = <String>[];
    expect(PublicCapabilities.fromJson(json).backends, isEmpty);
    json['backends'] = ['vz', 'vz'];
    expect(PublicCapabilities.fromJson(json).backends, ['vz', 'vz']);
  });

  for (final invalid in [
    'missing',
    'extra',
    'version',
    'backend',
    'backend type',
    'guest',
    'guest duplicates',
    'guest type',
    'limits extra',
    'limits missing',
    'defined limit',
    'running limit',
    'boot limit',
    'limit type',
  ]) {
    test('capability decoding rejects $invalid', () {
      final json = _capabilities();
      final limits = json['limits']! as Map<String, Object?>;
      switch (invalid) {
        case 'missing':
          json.remove('guest');
        case 'extra':
          json['driver_token'] = 'not public';
        case 'version':
          json['api_version'] = 'v2';
        case 'backend':
          json['backends'] = ['qemu'];
        case 'backend type':
          json['backends'] = [1];
        case 'guest':
          json['guest'] = ['file.transfer'];
        case 'guest duplicates':
          json['guest'] = ['exec', 'exec'];
        case 'guest type':
          json['guest'] = {};
        case 'limits extra':
          limits['arbitrary'] = 1;
        case 'limits missing':
          limits.remove('max_defined_vms');
        case 'defined limit':
          limits['max_defined_vms'] = 0;
        case 'running limit':
          limits['max_running_vms'] = -1;
        case 'boot limit':
          limits['max_concurrent_boots'] = 0;
        case 'limit type':
          limits['max_running_vms'] = 1.5;
      }
      expect(
        () => PublicCapabilities.fromJson(json),
        throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
      );
    });
  }
}

Map<String, Object?> _capabilities() => {
  'api_version': 'v1',
  'backends': ['vz'],
  'guest': ['health', 'exec'],
  'limits': <String, Object?>{
    'max_defined_vms': 128,
    'max_running_vms': 8,
    'max_concurrent_boots': 2,
  },
};
