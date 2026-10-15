import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  test(
    'component evidence freezes lists and round-trips the strict format',
    () {
      final offered = ['runtime.configure'];
      final info = ComponentInfo(
        role: ComponentRole.daemon,
        version: '0.1.0',
        publicApi: 'v1',
        vmSpec: vmApiVersion,
        driverProtocol: 'gaovm.driver.v2',
        catalogMinimum: 0,
        catalogMaximum: 21,
        offered: offered,
        requiredCapabilities: offered,
      );
      final json = info.toJson();
      offered.clear();
      expect(info.offered, ['runtime.configure']);
      expect(ComponentInfo.fromJson(json), info);
      expect(ComponentInfo.fromJson(json).hashCode, info.hashCode);
    },
  );

  test(
    'component evidence refuses missing, unknown, ambiguous or malformed fields',
    () {
      final valid = ComponentInfo(
        role: ComponentRole.cli,
        version: '0.1.0',
        publicApi: 'v1',
        vmSpec: vmApiVersion,
      ).toJson();
      for (final invalid in [
        {...valid}..remove('catalog_schema'),
        {...valid, 'extra': true},
        {...valid, 'format': 'other'},
        {...valid, 'role': 'unknown'},
        {...valid, 'version': '1.0'},
        {...valid, 'public_api': true},
        {
          ...valid,
          'catalog_schema': {'minimum': 21, 'maximum': 20},
        },
        {
          ...valid,
          'catalog_schema': {'minimum': 0, 'maximum': 21, 'extra': true},
        },
        {
          ...valid,
          'capabilities': {
            'offered': ['runtime.start', 'runtime.start'],
            'required': <String>[],
            'development_only': <String>[],
          },
        },
        {
          ...valid,
          'capabilities': {
            'offered': <String>[],
            'required': [true],
            'development_only': <String>[],
          },
        },
        {
          ...valid,
          'service_actions': ['status', 'status'],
        },
      ]) {
        expect(
          () => ComponentInfo.fromJson(invalid),
          throwsFormatException,
          reason: '$invalid',
        );
      }
    },
  );
}
