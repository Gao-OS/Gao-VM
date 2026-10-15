import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/daemon_component_info.dart';
import 'package:gaovmd/src/release_compatibility.dart';
import 'package:test/test.dart';

void main() {
  test(
    'release compatibility uses actual roles, contracts and the current catalog schema',
    () {
      expect(
        () => verifyReleaseCompatibility(
          _components(),
          version: '0.1.0',
          catalogSchema: 21,
        ),
        returnsNormally,
      );
    },
  );

  test('missing actual evidence and an unsupported catalog fail closed', () {
    final incomplete = _components()..remove(ComponentRole.driver);
    expect(
      () => verifyReleaseCompatibility(
        incomplete,
        version: '0.1.0',
        catalogSchema: 21,
      ),
      throwsFormatException,
    );
    for (final schema in [-1, 22]) {
      expect(
        () => verifyReleaseCompatibility(
          _components(),
          version: '0.1.0',
          catalogSchema: schema,
        ),
        throwsFormatException,
      );
    }
  });

  for (final (role, change) in <(ComponentRole, Map<String, Object?>)>[
    (ComponentRole.cli, {'role': 'daemon'}),
    (ComponentRole.cli, {'version': '0.2.0'}),
    (ComponentRole.cli, {'public_api': 'v2'}),
    (ComponentRole.cli, {'vm_spec': 'gaovm.io/v2'}),
    (ComponentRole.driver, {'driver_protocol': 'gaovm.driver.v3'}),
    (
      ComponentRole.service,
      {
        'service_actions': ['status'],
      },
    ),
    (
      ComponentRole.cli,
      {
        'catalog_schema': {'minimum': 0, 'maximum': 21},
      },
    ),
    (ComponentRole.driver, {'public_api': 'v1'}),
    (
      ComponentRole.driver,
      {
        'capabilities': {'offered': [], 'required': [], 'development_only': []},
      },
    ),
    (
      ComponentRole.driver,
      {
        'capabilities': {
          'offered': ['unknown.capability'],
          'required': [],
          'development_only': [],
        },
      },
    ),
  ]) {
    test('rejects incompatible ${role.name} evidence $change', () {
      final components = _components();
      components[role] = ComponentInfo.fromJson({
        ...components[role]!.toJson(),
        ...change,
      });
      expect(
        () => verifyReleaseCompatibility(
          components,
          version: '0.1.0',
          catalogSchema: 21,
        ),
        throwsFormatException,
      );
    });
  }

  test(
    'development capability cannot be enabled by default or satisfy a required capability',
    () {
      final components = _components();
      final driver = components[ComponentRole.driver]!;
      for (final capabilities in [
        {
          'offered': [...driver.offered, 'guest.status'],
          'required': driver.requiredCapabilities,
          'development_only': ['guest.status'],
        },
        {
          'offered': driver.offered,
          'required': [...driver.requiredCapabilities, 'guest.status'],
          'development_only': ['guest.status'],
        },
      ]) {
        components[ComponentRole.driver] = ComponentInfo.fromJson({
          ...driver.toJson(),
          'capabilities': capabilities,
        });
        expect(
          () => verifyReleaseCompatibility(
            components,
            version: '0.1.0',
            catalogSchema: 21,
          ),
          throwsFormatException,
        );
      }
    },
  );
}

Map<ComponentRole, ComponentInfo> _components() {
  final daemon = daemonComponentInfo();
  return {
    ComponentRole.daemon: daemon,
    ComponentRole.cli: ComponentInfo(
      role: ComponentRole.cli,
      version: '0.1.0',
      publicApi: 'v1',
      vmSpec: vmApiVersion,
    ),
    ComponentRole.driver: ComponentInfo(
      role: ComponentRole.driver,
      version: '0.1.0',
      driverProtocol: daemon.driverProtocol,
      offered: daemon.offered.where((value) => value != 'guest.status'),
      requiredCapabilities: daemon.requiredCapabilities,
      developmentOnly: ['guest.status'],
    ),
    ComponentRole.service: ComponentInfo(
      role: ComponentRole.service,
      version: '0.1.0',
      serviceActions: ['register', 'status', 'unregister'],
    ),
  };
}
