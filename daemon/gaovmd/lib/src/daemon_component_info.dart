import 'package:gaovm_models/gaovm_models.dart';

import 'driver_protocol_v2.dart';
import 'runtime_driver.dart';
import 'sqlite_database.dart';

ComponentInfo daemonComponentInfo() => ComponentInfo(
  role: ComponentRole.daemon,
  version: gaovmImplementationVersion,
  publicApi: 'v1',
  vmSpec: vmApiVersion,
  driverProtocol: DriverProtocolV2.version,
  catalogMinimum: 0,
  catalogMaximum: GaoVmDatabase.latestSchemaVersion,
  offered: DriverProtocolV2.capabilityNames(DriverCapabilities.all),
  requiredCapabilities: DriverProtocolV2.capabilityNames(
    DriverCapabilities.runtimeCore,
  ),
);
