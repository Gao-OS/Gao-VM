import 'package:gaovm_models/gaovm_models.dart';

import 'driver_protocol_v2.dart';
import 'runtime_driver.dart';

void verifyReleaseCompatibility(
  Map<ComponentRole, ComponentInfo> components, {
  required String version,
  required int catalogSchema,
}) {
  void require(bool condition, String detail) {
    if (!condition) throw FormatException('incompatible release: $detail');
  }

  require(
    components.length == ComponentRole.values.length &&
        ComponentRole.values.every(components.containsKey),
    'all four actual component roles are required',
  );
  for (final role in ComponentRole.values) {
    final info = components[role]!;
    require(info.role == role, '${role.name} executable has the wrong role');
    require(
      info.version == version,
      '${role.name} implementation/bundle version mismatch',
    );
  }
  final daemon = components[ComponentRole.daemon]!;
  final cli = components[ComponentRole.cli]!;
  final driver = components[ComponentRole.driver]!;
  final service = components[ComponentRole.service]!;
  require(
    daemon.publicApi == 'v1' && cli.publicApi == daemon.publicApi,
    'public API version',
  );
  require(
    daemon.vmSpec == vmApiVersion && cli.vmSpec == daemon.vmSpec,
    'VmSpec version',
  );
  require(
    daemon.driverProtocol == DriverProtocolV2.version &&
        driver.driverProtocol == daemon.driverProtocol,
    'driver protocol version',
  );
  require(
    catalogSchema >= 0 &&
        daemon.catalogMinimum != null &&
        daemon.catalogMaximum != null &&
        daemon.catalogMinimum! <= catalogSchema &&
        daemon.catalogMaximum! >= catalogSchema,
    'catalog schema range',
  );
  final core = DriverProtocolV2.capabilityNames(
    DriverCapabilities.runtimeCore,
  ).toSet();
  final known = DriverProtocolV2.capabilityNames(
    DriverCapabilities.all,
  ).toSet();
  final p0 = known.difference({'guest.status'});
  require(
    daemon.offered.toSet().containsAll(p0) &&
        driver.offered.toSet().containsAll(p0),
    'P0 driver capabilities',
  );
  for (final (local, peer) in [(daemon, driver), (driver, daemon)]) {
    require(
      local.requiredCapabilities.toSet().containsAll(core) &&
          peer.offered
              .toSet()
              .intersection(local.offered.toSet())
              .containsAll(local.requiredCapabilities),
      'bidirectional required capabilities',
    );
    require(
      known.containsAll([
        ...local.offered,
        ...local.requiredCapabilities,
        ...local.developmentOnly,
      ]),
      'unknown driver capabilities',
    );
    require(
      local.offered.toSet().intersection(local.developmentOnly.toSet()).isEmpty,
      'development-only capabilities offered by default',
    );
  }
  require(
    service.serviceActions.toSet().length == 3 &&
        service.serviceActions.toSet().containsAll({
          'register',
          'status',
          'unregister',
        }),
    'service interface',
  );
  for (final info in [cli, driver, service]) {
    require(
      info.catalogMinimum == null && info.catalogMaximum == null,
      'catalog writer role',
    );
  }
  for (final info in [cli, service]) {
    require(
      info.driverProtocol == null &&
          info.offered.isEmpty &&
          info.requiredCapabilities.isEmpty &&
          info.developmentOnly.isEmpty,
      'non-driver role advertises driver capabilities',
    );
  }
  require(
    driver.publicApi == null &&
        driver.vmSpec == null &&
        service.publicApi == null &&
        service.vmSpec == null,
    'unexpected public/spec consumer role',
  );
  require(
    [daemon, cli, driver].every((info) => info.serviceActions.isEmpty),
    'unexpected service management role',
  );
}
