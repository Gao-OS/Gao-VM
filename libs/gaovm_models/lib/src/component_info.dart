import 'common.dart';

/// Build/maintenance diagnostics, not a public HTTP or driver-session envelope.
const gaovmImplementationVersion = '0.1.0';

enum ComponentRole { daemon, cli, driver, service }

final class ComponentInfo extends ValueObject {
  ComponentInfo({
    required this.role,
    required this.version,
    this.publicApi,
    this.vmSpec,
    this.driverProtocol,
    this.catalogMinimum,
    this.catalogMaximum,
    Iterable<String> offered = const [],
    Iterable<String> requiredCapabilities = const [],
    Iterable<String> developmentOnly = const [],
    Iterable<String> serviceActions = const [],
  }) : offered = List.unmodifiable(offered),
       requiredCapabilities = List.unmodifiable(requiredCapabilities),
       developmentOnly = List.unmodifiable(developmentOnly),
       serviceActions = List.unmodifiable(serviceActions) {
    if (!RegExp(
          r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
        ).hasMatch(version) ||
        version.length > 32) {
      throw ArgumentError('component version must be numeric X.Y.Z');
    }
    for (final contract in [publicApi, vmSpec, driverProtocol]) {
      if (contract != null &&
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$').hasMatch(contract)) {
        throw ArgumentError('invalid component contract version');
      }
    }
    if ((catalogMinimum == null) != (catalogMaximum == null) ||
        catalogMinimum != null &&
            (catalogMinimum! < 0 ||
                catalogMaximum! < catalogMinimum! ||
                catalogMaximum! > 2147483647)) {
      throw ArgumentError('invalid catalog schema range');
    }
    for (final values in [
      this.offered,
      this.requiredCapabilities,
      this.developmentOnly,
      this.serviceActions,
    ]) {
      if (values.length > 32 ||
          values.toSet().length != values.length ||
          values.any(
            (value) =>
                !RegExp(
                  r'^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$',
                ).hasMatch(value) ||
                value.length > 128,
          )) {
        throw ArgumentError('invalid component capability/action list');
      }
    }
  }

  final ComponentRole role;
  final String version;
  final String? publicApi;
  final String? vmSpec;
  final String? driverProtocol;
  final int? catalogMinimum;
  final int? catalogMaximum;
  final List<String> offered;
  final List<String> requiredCapabilities;
  final List<String> developmentOnly;
  final List<String> serviceActions;

  factory ComponentInfo.fromJson(Object? value) {
    final json = readJsonObject(value, 'component info');
    expectJsonKeys(
      json,
      required: const {
        'format',
        'role',
        'version',
        'public_api',
        'vm_spec',
        'driver_protocol',
        'catalog_schema',
        'capabilities',
        'service_actions',
      },
      optional: const {},
      name: 'component info',
    );
    if (json['format'] != 'gaovm.component.v1') {
      throw const FormatException('unsupported component info format');
    }
    final role = switch (json['role']) {
      'daemon' => ComponentRole.daemon,
      'cli' => ComponentRole.cli,
      'driver-vz' => ComponentRole.driver,
      'service' => ComponentRole.service,
      _ => throw const FormatException('unsupported component role'),
    };
    final capabilities = readJsonObject(json['capabilities'], 'capabilities');
    expectJsonKeys(
      capabilities,
      required: const {'offered', 'required', 'development_only'},
      optional: const {},
      name: 'component capabilities',
    );
    final catalog = json['catalog_schema'] == null
        ? null
        : readJsonObject(json['catalog_schema'], 'catalog schema');
    if (catalog != null) {
      expectJsonKeys(
        catalog,
        required: const {'minimum', 'maximum'},
        optional: const {},
        name: 'catalog schema',
      );
    }
    List<String> strings(Object? value) =>
        readJsonList(value, 'component list', (item) {
          if (item is! String) {
            throw const FormatException('component list requires strings');
          }
          return item;
        });
    try {
      return ComponentInfo(
        role: role,
        version: requireJson<String>(json, 'version'),
        publicApi: nullableJson<String>(json, 'public_api'),
        vmSpec: nullableJson<String>(json, 'vm_spec'),
        driverProtocol: nullableJson<String>(json, 'driver_protocol'),
        catalogMinimum: catalog == null
            ? null
            : requireJson<int>(catalog, 'minimum'),
        catalogMaximum: catalog == null
            ? null
            : requireJson<int>(catalog, 'maximum'),
        offered: strings(capabilities['offered']),
        requiredCapabilities: strings(capabilities['required']),
        developmentOnly: strings(capabilities['development_only']),
        serviceActions: strings(json['service_actions']),
      );
    } on ArgumentError catch (error) {
      throw FormatException('invalid component info: $error');
    }
  }

  Map<String, Object?> toJson() => {
    'format': 'gaovm.component.v1',
    'role': role == ComponentRole.driver ? 'driver-vz' : role.name,
    'version': version,
    'public_api': publicApi,
    'vm_spec': vmSpec,
    'driver_protocol': driverProtocol,
    'catalog_schema': catalogMinimum == null
        ? null
        : {'minimum': catalogMinimum, 'maximum': catalogMaximum},
    'capabilities': {
      'offered': offered,
      'required': requiredCapabilities,
      'development_only': developmentOnly,
    },
    'service_actions': serviceActions,
  };

  @override
  List<Object?> get equalityFields => [
    role,
    version,
    publicApi,
    vmSpec,
    driverProtocol,
    catalogMinimum,
    catalogMaximum,
    offered,
    requiredCapabilities,
    developmentOnly,
    serviceActions,
  ];
}
