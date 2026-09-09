import 'dart:async';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/runtime_assets.dart';
import 'package:gaovmd/src/runtime_driver.dart';
import 'package:gaovmd/src/vm_controller_reducer.dart';
import 'package:gaovmd/src/vm_runtime_configuration_resolver.dart';
import 'package:test/test.dart';

void main() {
  test(
    'maps the exact active-generation snapshot while keeping its scope held',
    () async {
      final assets = _Assets(_snapshot());
      final resolver = VmRuntimeConfigurationResolver(assets: assets);
      final state = VmControllerState.initial(
        vmId: _vmId,
        specGeneration: 3,
        restartPolicy: RestartPolicy.onFailure,
      ).copyWith(activeSpecGeneration: 2);

      final entered = Completer<void>();
      final release = Completer<void>();
      final pending = resolver.withConfiguration(state, (configuration) async {
        expect(assets.held, isTrue);
        expect(configuration.cpu, 4);
        expect(configuration.memoryBytes, 536870912);
        expect(configuration.bundlePath, '/private/tmp/vm.gaovm');
        expect(configuration.boot, isA<RuntimeLinuxBootConfiguration>());
        expect(
          (configuration.boot as RuntimeLinuxBootConfiguration).kernelPath,
          '/private/tmp/images/bundle/objects/kernel',
        );
        expect(
          (configuration.boot as RuntimeLinuxBootConfiguration).initrdPath,
          '/private/tmp/images/bundle/objects/initrd',
        );
        expect(
          (configuration.boot as RuntimeLinuxBootConfiguration).commandLine,
          'console=hvc0',
        );
        expect(
          configuration.disks.single.path,
          '/private/tmp/canonical/root.img',
        );
        expect(configuration.networks[0].macAddress, startsWith('02:'));
        expect(configuration.networks[1].macAddress, '02:00:00:00:00:77');
        expect(configuration.networks[2].mode, RuntimeNetworkMode.none);
        expect(
          configuration.driverLogPath,
          '/private/tmp/vm.gaovm/logs/driver.log',
        );
        expect(
          configuration.serial.logPath,
          '/private/tmp/vm.gaovm/logs/serial.log',
        );
        expect(configuration.serial.capture, isTrue);
        expect(configuration.graphics.enabled, isFalse);
        expect(configuration.guestAgent.enabled, isFalse);
        entered.complete();
        await release.future;
        expect(assets.held, isTrue);
      });
      await entered.future;
      expect(assets.held, isTrue);
      expect(assets.observedState, same(state));
      release.complete();
      await pending;
      expect(assets.held, isFalse);
    },
  );

  test(
    'rejects a snapshot from another VM or retained generation before use',
    () async {
      final state = VmControllerState.initial(
        vmId: _vmId,
        specGeneration: 3,
        restartPolicy: RestartPolicy.onFailure,
      ).copyWith(activeSpecGeneration: 2);
      for (final snapshot in [
        _snapshot(vmId: VmId('vm_01J00000000000000000000001')),
        _snapshot(generation: 3),
      ]) {
        final assets = _Assets(snapshot);
        var used = false;
        await expectLater(
          VmRuntimeConfigurationResolver(assets: assets).withConfiguration(
            state,
            (_) async {
              used = true;
            },
          ),
          throwsStateError,
        );
        expect(used, isFalse);
        expect(assets.held, isFalse);
      }
    },
  );

  test(
    'uses requested generation without an active runtime and releases after consumer failure',
    () async {
      final state = VmControllerState.initial(
        vmId: _vmId,
        specGeneration: 3,
        restartPolicy: RestartPolicy.onFailure,
      );
      final assets = _Assets(_snapshot(generation: 3));
      final resolver = VmRuntimeConfigurationResolver(assets: assets);
      final failure = StateError('driver configure failed');
      await expectLater(
        resolver.withConfiguration(state, (_) async {
          expect(assets.held, isTrue);
          throw failure;
        }),
        throwsA(same(failure)),
      );
      expect(assets.held, isFalse);
      String? mac;
      await resolver.withConfiguration(state, (config) async {
        mac = config.networks.first.macAddress;
      });
      await resolver.withConfiguration(state, (config) async {
        expect(config.networks.first.macAddress, mac);
      });
      expect(assets.held, isFalse);
    },
  );

  test('asset snapshot copies its disk list and exposes it as immutable', () {
    final disk = RuntimeDiskConfiguration(
      id: 'root',
      path: '/owned/root.raw',
      writable: true,
    );
    final disks = [disk];
    final snapshot = VmRuntimeAssets(
      vmId: _vmId,
      specGeneration: 1,
      spec: _spec,
      bundlePath: '/owned/vm.gaovm',
      boot: _snapshot().boot,
      disks: disks,
    );
    disks.clear();
    expect(snapshot.disks, [disk]);
    expect(() => snapshot.disks.clear(), throwsUnsupportedError);
  });
}

final class _Assets implements RuntimeAssetResolver {
  _Assets(this.snapshot);
  final VmRuntimeAssets snapshot;
  bool held = false;
  VmControllerState? observedState;
  @override
  Future<void> withAssets(
    VmControllerState state,
    Future<void> Function(VmRuntimeAssets) use,
  ) async {
    observedState = state;
    held = true;
    try {
      await use(snapshot);
    } finally {
      held = false;
    }
  }
}

VmRuntimeAssets _snapshot({VmId? vmId, int generation = 2}) => VmRuntimeAssets(
  vmId: vmId ?? _vmId,
  specGeneration: generation,
  spec: _spec,
  bundlePath: '/private/tmp/vm.gaovm',
  boot: RuntimeLinuxBootConfiguration(
    kernelPath: '/private/tmp/images/bundle/objects/kernel',
    initrdPath: '/private/tmp/images/bundle/objects/initrd',
    commandLine: 'console=hvc0',
  ),
  disks: [
    RuntimeDiskConfiguration(
      id: 'root',
      path: '/private/tmp/canonical/root.img',
      writable: true,
    ),
  ],
);

final _vmId = VmId('vm_01J00000000000000000000000');
final _kernelId = ImageId('img_01J00000000000000000000000');
final _spec = VmSpec(
  cpu: 4,
  memoryBytes: 536870912,
  boot: LinuxKernelBoot(
    kernelImageId: _kernelId,
    initrdImageId: _kernelId,
    commandLine: 'console=hvc0',
  ),
  disks: [
    VmDisk(
      id: 'root',
      source: ExternalDiskSource('/private/tmp/root.img'),
      writable: true,
    ),
  ],
  networks: [
    SharedNetwork(id: 'net0'),
    SharedNetwork(id: 'net1', macAddress: '02:00:00:00:00:77'),
    DisconnectedNetwork(id: 'net2'),
  ],
  graphics: GraphicsConfig(enabled: false),
  serial: const SerialConfig(enabled: true, capture: true),
  guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
  restartPolicy: RestartPolicy.onFailure,
);
