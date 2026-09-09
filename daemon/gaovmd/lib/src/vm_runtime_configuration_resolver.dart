import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'runtime_driver.dart';
import 'runtime_assets.dart';
import 'vm_controller_reducer.dart';

final class VmRuntimeConfigurationResolver {
  const VmRuntimeConfigurationResolver({required RuntimeAssetResolver assets})
    : _assets = assets;

  final RuntimeAssetResolver _assets;

  Future<void> withConfiguration(
    VmControllerState state,
    Future<void> Function(RuntimeDriverConfiguration configuration) use,
  ) => _assets.withAssets(state, (assets) async {
    final generation = state.activeSpecGeneration ?? state.specGeneration;
    if (assets.vmId != state.vmId || assets.specGeneration != generation) {
      throw StateError(
        'runtime assets do not match the requested VM generation',
      );
    }
    final spec = assets.spec;
    final bundlePath = assets.bundlePath;
    final networks = <RuntimeNetworkConfiguration>[
      for (final network in spec.networks)
        switch (network) {
          SharedNetwork(:final id, :final macAddress) =>
            RuntimeNetworkConfiguration(
              id: id,
              mode: RuntimeNetworkMode.shared,
              macAddress: macAddress ?? _deterministicMac(state.vmId.value, id),
            ),
          DisconnectedNetwork(:final id) => RuntimeNetworkConfiguration(
            id: id,
            mode: RuntimeNetworkMode.none,
          ),
        },
    ];
    await use(
      RuntimeDriverConfiguration(
        architecture: spec.architecture,
        cpu: spec.cpu,
        memoryBytes: spec.memoryBytes,
        boot: assets.boot,
        disks: assets.disks,
        networks: networks,
        graphics: RuntimeGraphicsConfiguration(
          enabled: spec.graphics.enabled,
          width: spec.graphics.width,
          height: spec.graphics.height,
          pixelsPerInch: spec.graphics.enabled
              ? spec.graphics.pixelsPerInch
              : null,
        ),
        serial: RuntimeSerialConfiguration(
          enabled: spec.serial.enabled,
          capture: spec.serial.capture,
          logPath: '$bundlePath/logs/serial.log',
        ),
        guestAgent: RuntimeGuestAgentConfiguration(
          enabled: spec.guestAgent.enabled,
          vsockPort: spec.guestAgent.vsockPort,
        ),
        bundlePath: bundlePath,
        driverLogPath: '$bundlePath/logs/driver.log',
      ),
    );
  });
}

String _deterministicMac(String vmId, String networkId) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode('$vmId/$networkId')) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  final bytes = List<int>.generate(
    6,
    (index) => (hash >> (8 * (5 - index))) & 0xff,
  );
  bytes[0] = 0x02;
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(':');
}
