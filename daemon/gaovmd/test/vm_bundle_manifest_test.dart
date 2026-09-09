import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:gaovmd/src/image_manifest.dart';
import 'package:gaovmd/src/vm_bundle_manifest.dart';
import 'package:gaovmd/src/vm_provisioning_plan.dart';
import 'package:test/test.dart';

void main() {
  test(
    'origin manifest binds immutable plan identity and safe managed paths',
    () {
      final plan = VmProvisioningPlan.fromJson({
        'plan_version': 1,
        'vm_id': VmId.generate().value,
        'operation_id': OperationId.generate().value,
        'spec_generation': 1,
        'spec_digest': contentDigest('spec'),
        'kernel': null,
        'initrd': null,
        'disks': [
          {
            'id': 'root',
            'writable': true,
            'source': {
              'type': 'managed_image',
              'image': {
                'role': 'root_disk',
                'image_id': ImageId.generate().value,
                'image_digest': contentDigest('image'),
                'object_name': 'payload',
                'object_digest': contentDigest('disk'),
                'size_bytes': 4,
              },
            },
          },
          {
            'id': 'external',
            'writable': true,
            'source': {'type': 'external', 'path': '/user/disk'},
          },
        ],
      });
      final manifest = VmBundleManifest.create(plan);
      final encoded = manifest.toJson();
      final restored = VmBundleManifest.fromJson(
        jsonDecode(jsonEncode(encoded)),
      );
      expect(restored.digest, manifest.digest);
      expect(restored.plan.toJson(), plan.toJson());
      expect(manifest.managedDiskPath('root'), 'disks/root.raw');
      expect(() => manifest.managedDiskPath('external'), throwsArgumentError);
      expect(() => manifest.managedDiskPath('../root'), throwsArgumentError);
      (encoded['plan'] as Map)['vm_id'] = VmId.generate().value;
      expect(manifest.plan.vmId, plan.vmId);
      expect(() => VmBundleManifest.fromJson(encoded), throwsFormatException);
      for (final changed in [
        {...manifest.toJson(), 'bundle_version': 2},
        {...manifest.toJson(), 'bundle_version': 1.0},
        {...manifest.toJson(), 'extra': 'ignored'},
        {...manifest.toJson(), 'digest': contentDigest('wrong')},
      ]) {
        expect(() => VmBundleManifest.fromJson(changed), throwsFormatException);
      }
      final other = VmBundleManifest.create(
        VmProvisioningPlan.fromJson({
          ...plan.toJson(),
          'operation_id': OperationId.generate().value,
        }),
      );
      expect(other.digest, isNot(manifest.digest));
    },
  );
}
