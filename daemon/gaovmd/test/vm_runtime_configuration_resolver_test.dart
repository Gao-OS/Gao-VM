import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:gaovmd/src/vm_controller_reducer.dart';
import 'package:gaovmd/src/vm_runtime_configuration_resolver.dart';
import 'package:test/test.dart';

void main() {
  test(
    'resolves the exact spec generation into absolute runtime paths',
    () async {
      final resolver = VmRuntimeConfigurationResolver(
        specs: _Specs(_spec),
        assets: _Assets(),
        resolveBundlePath: (_) async => '/private/tmp/vm.gaovm',
      );
      final state = VmControllerState.initial(
        vmId: _vmId,
        specGeneration: 3,
        restartPolicy: RestartPolicy.onFailure,
      ).copyWith(activeSpecGeneration: 2);

      final configuration = await resolver.resolve(state);

      expect(configuration.bundlePath, '/private/tmp/vm.gaovm');
      expect(configuration.boot, isA<RuntimeLinuxBootConfiguration>());
      expect(
        (configuration.boot as RuntimeLinuxBootConfiguration).kernelPath,
        '/private/tmp/assets/${_kernelId.value}',
      );
      expect(configuration.disks.single.path, '/private/tmp/root.img');
      expect(configuration.networks.single.macAddress, startsWith('02:'));
      expect(
        configuration.driverLogPath,
        '/private/tmp/vm.gaovm/logs/driver.log',
      );
      expect(
        configuration.serial.logPath,
        '/private/tmp/vm.gaovm/logs/serial.log',
      );
    },
  );
}

final class _Specs implements VmSpecGenerationReader {
  const _Specs(this.spec);
  final VmSpec spec;

  @override
  Future<VmSpec> read(VmId vmId, int generation) async {
    expect(generation, 2);
    return spec;
  }
}

final class _Assets implements RuntimeAssetPathResolver {
  @override
  Future<String> resolveImage(ImageId imageId) async =>
      '/private/tmp/assets/${imageId.value}';

  @override
  Future<String> resolveManagedDisk(VmId vmId, VmDisk disk) async =>
      '/private/tmp/disks/${disk.id}.img';
}

final _vmId = VmId('vm_01J00000000000000000000000');
final _kernelId = ImageId('img_01J00000000000000000000000');
final _spec = VmSpec(
  cpu: 4,
  memoryBytes: 536870912,
  boot: LinuxKernelBoot(kernelImageId: _kernelId, commandLine: 'console=hvc0'),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/private/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [SharedNetwork(id: 'net0')],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.onFailure,
);
