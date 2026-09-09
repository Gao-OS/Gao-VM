import 'image_manifest.dart';
import 'vm_provisioning_plan.dart';

/// Immutable publication origin, not an active spec or a hash of a running
/// guest's mutable disks. SQLite remains authoritative after provisioning.
final class VmBundleManifest {
  const VmBundleManifest._(this.plan, this.digest);

  factory VmBundleManifest.create(VmProvisioningPlan plan) =>
      VmBundleManifest._(plan, contentDigest(_unsigned(plan)));

  factory VmBundleManifest.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 3 ||
        value['bundle_version'] is! int ||
        value['bundle_version'] != 1 ||
        !value.containsKey('plan') ||
        !value.containsKey('digest')) {
      throw const FormatException('invalid VM bundle manifest');
    }
    final manifest = VmBundleManifest.create(
      VmProvisioningPlan.fromJson(value['plan']),
    );
    if (value['digest'] != manifest.digest) {
      throw const FormatException('VM bundle manifest digest mismatch');
    }
    return manifest;
  }

  final VmProvisioningPlan plan;
  final String digest;

  String managedDiskPath(String diskId) {
    final disk = plan.disks.where((disk) => disk.id == diskId).firstOrNull;
    if (disk == null || disk.source is! VmProvisioningManagedDisk) {
      throw ArgumentError.value(diskId, 'diskId', 'requires a managed disk');
    }
    return 'disks/${disk.id}.raw';
  }

  Map<String, Object?> toJson() => {..._unsigned(plan), 'digest': digest};
}

Map<String, Object?> _unsigned(VmProvisioningPlan plan) => {
  'bundle_version': 1,
  'plan': plan.toJson(),
};
