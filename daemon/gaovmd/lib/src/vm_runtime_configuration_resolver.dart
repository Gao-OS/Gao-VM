import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'runtime_driver.dart';
import 'sqlite_database.dart';
import 'vm_controller_reducer.dart';
import 'vm_repository.dart';

abstract interface class VmSpecGenerationReader {
  Future<VmSpec> read(VmId vmId, int generation);
}

final class SqliteVmSpecGenerationReader implements VmSpecGenerationReader {
  const SqliteVmSpecGenerationReader(this._database);

  final GaoVmDatabase _database;

  @override
  Future<VmSpec> read(VmId vmId, int generation) =>
      _database.read((connection) {
        final rows = connection.select(
          'SELECT spec_json FROM vm_specs WHERE vm_id = ? AND generation = ?',
          [vmId.value, generation],
        );
        if (rows.isEmpty) throw VmNotFoundException(vmId);
        return VmSpec.fromJson(jsonDecode(rows.single['spec_json']! as String));
      });
}

abstract interface class RuntimeAssetPathResolver {
  Future<String> resolveImage(ImageId imageId);

  Future<String> resolveManagedDisk(VmId vmId, VmDisk disk);
}

typedef RuntimeBundlePathResolver = Future<String> Function(VmId vmId);

final class VmRuntimeConfigurationResolver {
  const VmRuntimeConfigurationResolver({
    required VmSpecGenerationReader specs,
    required RuntimeAssetPathResolver assets,
    required RuntimeBundlePathResolver resolveBundlePath,
  }) : _specs = specs,
       _assets = assets,
       _resolveBundlePath = resolveBundlePath;

  final VmSpecGenerationReader _specs;
  final RuntimeAssetPathResolver _assets;
  final RuntimeBundlePathResolver _resolveBundlePath;

  Future<RuntimeDriverConfiguration> resolve(VmControllerState state) async {
    final generation = state.activeSpecGeneration ?? state.specGeneration;
    final spec = await _specs.read(state.vmId, generation);
    final bundlePath = await _resolveBundlePath(state.vmId);
    _requireAbsolute(bundlePath, 'bundlePath');
    final boot = await _resolveBoot(spec.boot, bundlePath);
    final disks = <RuntimeDiskConfiguration>[];
    for (final disk in spec.disks) {
      final path = switch (disk.source) {
        ExternalDiskSource(:final path) => path,
        ManagedImageDiskSource() => await _assets.resolveManagedDisk(
          state.vmId,
          disk,
        ),
      };
      _requireAbsolute(path, 'disk ${disk.id}');
      disks.add(
        RuntimeDiskConfiguration(
          id: disk.id,
          path: path,
          writable: disk.writable,
        ),
      );
    }
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
    return RuntimeDriverConfiguration(
      architecture: spec.architecture,
      cpu: spec.cpu,
      memoryBytes: spec.memoryBytes,
      boot: boot,
      disks: disks,
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
    );
  }

  Future<RuntimeBootConfiguration> _resolveBoot(
    BootConfig boot,
    String bundlePath,
  ) async => switch (boot) {
    LinuxKernelBoot(
      :final kernelImageId,
      :final initrdImageId,
      :final commandLine,
    ) =>
      RuntimeLinuxBootConfiguration(
        kernelPath: _absolute(
          await _assets.resolveImage(kernelImageId),
          'kernel image',
        ),
        initrdPath: initrdImageId == null
            ? null
            : _absolute(
                await _assets.resolveImage(initrdImageId),
                'initrd image',
              ),
        commandLine: commandLine,
      ),
    EfiBoot(:final variableStore, :final variableStorePath) =>
      RuntimeEfiBootConfiguration(
        variableStorePath: variableStore == EfiVariableStore.external
            ? _absolute(variableStorePath!, 'EFI variable store')
            : '$bundlePath/nvram/efi-variable-store',
      ),
  };
}

String _absolute(String path, String name) {
  _requireAbsolute(path, name);
  return path;
}

void _requireAbsolute(String path, String name) {
  if (!path.startsWith('/')) {
    throw ArgumentError.value(path, name, 'runtime path must be absolute');
  }
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
