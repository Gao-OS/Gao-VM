import 'dart:typed_data';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:test/test.dart';

void main() {
  test('correlation requires a positive driver generation', () {
    expect(
      () => DriverCorrelation(
        vmId: _vmId,
        driverGeneration: 0,
        operationId: _operationId,
      ),
      throwsArgumentError,
    );
    expect(
      () => DriverCorrelation(
        vmId: _vmId,
        driverGeneration: 9007199254740992,
        operationId: _operationId,
      ),
      throwsArgumentError,
    );
  });

  test('capability negotiation is immutable and explicit', () {
    final source = <DriverCapability>{DriverCapability.runtimeStart};
    final offered = DriverCapabilities(source);
    source.add(DriverCapability.displayOpen);
    final accepted = offered.negotiate(
      DriverCapabilities({
        DriverCapability.runtimeStart,
        DriverCapability.runtimeStop,
      }),
    );

    expect(offered.contains(DriverCapability.displayOpen), isFalse);
    expect(accepted.values, {DriverCapability.runtimeStart});
    expect(
      accepted.containsAll(DriverCapabilities({DriverCapability.runtimeStart})),
      isTrue,
    );
  });

  test('log chunks defensively copy mutable bytes', () {
    final source = Uint8List.fromList([1, 2, 3]);
    final chunk = RuntimeDriverLogChunk(
      correlation: DriverCorrelation(
        vmId: _vmId,
        driverGeneration: 1,
        operationId: _operationId,
      ),
      stream: RuntimeDriverLogStream.stdout,
      bytes: source,
    );
    source[0] = 9;
    final firstRead = chunk.bytes;
    firstRead[1] = 9;

    expect(chunk.bytes, [1, 2, 3]);
  });

  test('operation commands and runtime configuration enforce v2 bounds', () {
    final queryCorrelation = DriverCorrelation(
      vmId: _vmId,
      driverGeneration: 1,
      operationId: null,
    );

    expect(
      () => RuntimeStartCommand(correlation: queryCorrelation),
      throwsArgumentError,
    );
    expect(
      () => RuntimeDriverConfiguration(
        architecture: Architecture.arm64,
        cpu: 0,
        memoryBytes: 268435456,
        boot: RuntimeLinuxBootConfiguration(
          kernelPath: '/kernel',
          commandLine: '',
        ),
        disks: [
          RuntimeDiskConfiguration(id: 'root', path: '/disk', writable: true),
        ],
        networks: [
          RuntimeNetworkConfiguration(
            id: 'net0',
            mode: RuntimeNetworkMode.none,
          ),
        ],
        graphics: RuntimeGraphicsConfiguration(enabled: false),
        serial: RuntimeSerialConfiguration(
          enabled: false,
          capture: false,
          logPath: '/serial.log',
        ),
        guestAgent: RuntimeGuestAgentConfiguration(
          enabled: false,
          vsockPort: 1024,
        ),
        bundlePath: '/bundle',
        driverLogPath: '/driver.log',
      ),
      throwsArgumentError,
    );
  });

  test('runtime configuration rejects values outside driver-v2 schema', () {
    final invalidConfigurations = <RuntimeDriverConfiguration Function()>[
      () => _validConfiguration(
        boot: RuntimeLinuxBootConfiguration(kernelPath: '', commandLine: ''),
      ),
      () => _validConfiguration(
        boot: RuntimeLinuxBootConfiguration(
          kernelPath: '/kernel',
          commandLine: List.filled(8193, 'x').join(),
        ),
      ),
      () => _validConfiguration(
        disks: [
          RuntimeDiskConfiguration(id: 'ROOT', path: '/disk', writable: true),
        ],
      ),
      () => _validConfiguration(
        networks: [
          RuntimeNetworkConfiguration(
            id: 'net0',
            mode: RuntimeNetworkMode.shared,
            macAddress: 'not-a-mac',
          ),
        ],
      ),
      () => _validConfiguration(
        graphics: RuntimeGraphicsConfiguration(
          enabled: true,
          width: 319,
          height: 800,
          pixelsPerInch: 144,
        ),
      ),
      () => _validConfiguration(
        serial: RuntimeSerialConfiguration(
          enabled: true,
          capture: true,
          logPath: '',
        ),
      ),
      () => _validConfiguration(
        guestAgent: RuntimeGuestAgentConfiguration(
          enabled: true,
          vsockPort: 1023,
        ),
      ),
    ];

    for (final build in invalidConfigurations) {
      expect(build, throwsArgumentError);
    }
  });
}

final _vmId = VmId('vm_01J00000000000000000000000');
final _operationId = OperationId('op_01J00000000000000000000001');

RuntimeDriverConfiguration _validConfiguration({
  RuntimeBootConfiguration? boot,
  List<RuntimeDiskConfiguration>? disks,
  List<RuntimeNetworkConfiguration>? networks,
  RuntimeGraphicsConfiguration? graphics,
  RuntimeSerialConfiguration? serial,
  RuntimeGuestAgentConfiguration? guestAgent,
}) => RuntimeDriverConfiguration(
  architecture: Architecture.arm64,
  cpu: 2,
  memoryBytes: 1073741824,
  boot:
      boot ??
      RuntimeLinuxBootConfiguration(kernelPath: '/kernel', commandLine: ''),
  disks:
      disks ??
      [RuntimeDiskConfiguration(id: 'root', path: '/disk', writable: true)],
  networks:
      networks ??
      [
        RuntimeNetworkConfiguration(
          id: 'net0',
          mode: RuntimeNetworkMode.shared,
          macAddress: '02:00:00:00:00:01',
        ),
      ],
  graphics: graphics ?? RuntimeGraphicsConfiguration(enabled: false),
  serial:
      serial ??
      RuntimeSerialConfiguration(
        enabled: true,
        capture: true,
        logPath: '/serial.log',
      ),
  guestAgent:
      guestAgent ??
      RuntimeGuestAgentConfiguration(enabled: false, vsockPort: 1024),
  bundlePath: '/bundle',
  driverLogPath: '/driver.log',
);
