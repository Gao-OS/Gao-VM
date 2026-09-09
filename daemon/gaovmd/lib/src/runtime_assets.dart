import 'package:gaovm_models/gaovm_models.dart';

import 'runtime_driver.dart';
import 'vm_controller_reducer.dart';

/// A validated asset snapshot for exactly one VM and retained spec generation.
/// Its paths may only be consumed within the resolver's callback scope.
final class VmRuntimeAssets {
  VmRuntimeAssets({
    required this.vmId,
    required this.specGeneration,
    required this.spec,
    required this.bundlePath,
    required this.boot,
    required List<RuntimeDiskConfiguration> disks,
  }) : disks = List.unmodifiable(disks);

  final VmId vmId;
  final int specGeneration;
  final VmSpec spec;
  final String bundlePath;
  final RuntimeBootConfiguration boot;
  final List<RuntimeDiskConfiguration> disks;
}

abstract interface class RuntimeAssetResolver {
  /// Keeps asset ownership and namespace protection until [use] completes.
  Future<void> withAssets(
    VmControllerState state,
    Future<void> Function(VmRuntimeAssets assets) use,
  );
}
