import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';
import 'package:test/test.dart';

void main() {
  final json =
      jsonDecode(r'''
{
  "api_version": "gaovm.io/v1alpha1",
  "kind": "VirtualMachine",
  "metadata": {
    "id": "vm_01J00000000000000000000000",
    "name": "gaoos-nightly-network",
    "labels": {"gaoos.channel": "nightly"},
    "revision": 7,
    "created_at": "2026-09-04T08:00:00Z",
    "updated_at": "2026-09-04T08:10:00Z"
  },
  "spec": {
    "backend": "vz",
    "architecture": "arm64",
    "guest_profile": "gaoos",
    "cpu": 4,
    "memory_bytes": 4294967296,
    "boot": {
      "type": "linux_kernel",
      "kernel_image_id": "img_01J00000000000000000000001",
      "initrd_image_id": "img_01J00000000000000000000002",
      "command_line": "console=hvc0"
    },
    "disks": [{
      "id": "root",
      "source": {"type": "managed_image", "image_id": "img_01J00000000000000000000003"},
      "writable": true
    }],
    "networks": [{"id": "net0", "mode": "shared", "mac_address": "02:00:00:00:00:01"}],
    "graphics": {"enabled": true, "width": 1280, "height": 800, "pixels_per_inch": 144},
    "serial": {"enabled": true, "capture": true},
    "guest_agent": {"enabled": true, "required_for_ready": true, "vsock_port": 10777},
    "restart_policy": "on_failure"
  },
  "status": {
    "desired_state": "running",
    "phase": "running",
    "spec_generation": 3,
    "observed_generation": 3,
    "driver_generation": 8,
    "guest_agent": "ready",
    "restart_required": false,
    "last_transition_at": "2026-09-04T08:10:00Z",
    "last_error": null
  }
}
''')
          as Map<String, Object?>;

  test('VirtualMachine performs a schema-shaped JSON round trip', () {
    final vm = VirtualMachine.fromJson(json);

    expect(vm.metadata.id, VmId('vm_01J00000000000000000000000'));
    expect(vm.spec.boot, isA<LinuxKernelBoot>());
    expect(vm.spec.disks.single.source, isA<ManagedImageDiskSource>());
    expect(vm.spec.networks.single, isA<SharedNetwork>());
    expect(vm.status.phase, VmPhase.running);
    expect(VirtualMachine.fromJson(vm.toJson()), vm);
  });

  test('VmSpec rejects CPU below the schema minimum', () {
    final spec = Map<String, Object?>.from(json['spec']! as Map);
    spec['cpu'] = 0;
    expect(() => VmSpec.fromJson(spec), throwsArgumentError);
  });

  test('VmSpec rejects memory that is not MiB aligned', () {
    final spec = Map<String, Object?>.from(json['spec']! as Map);
    spec['memory_bytes'] = 268435457;
    expect(() => VmSpec.fromJson(spec), throwsArgumentError);
  });

  test('VmSpec rejects an unsupported backend', () {
    final spec = Map<String, Object?>.from(json['spec']! as Map);
    spec['backend'] = 'qemu';
    expect(() => VmSpec.fromJson(spec), throwsFormatException);
  });

  test('reject an unknown boot discriminator', () {
    expect(
      () => BootConfig.fromJson({'type': 'netboot'}),
      throwsFormatException,
    );
  });

  test('reject an unknown network discriminator', () {
    expect(
      () => VmNetwork.fromJson({'id': 'net0', 'mode': 'bridged'}),
      throwsFormatException,
    );
  });

  test('reject an unknown VM phase', () {
    expect(() => parseVmPhase('paused'), throwsFormatException);
  });

  test('missing optional field defaults while explicit null is rejected', () {
    final boot = Map<String, Object?>.from(
      (json['spec']! as Map)['boot']! as Map,
    )..remove('command_line');
    expect(LinuxKernelBoot.fromJson(boot).commandLine, isEmpty);

    boot['command_line'] = null;
    expect(() => LinuxKernelBoot.fromJson(boot), throwsFormatException);
  });

  test('EFI variable store path is non-empty whenever present', () {
    expect(() => EfiBoot(variableStorePath: ''), throwsArgumentError);
  });

  test('missing EFI variable store defaults to managed', () {
    expect(
      EfiBoot.fromJson({'type': 'efi'}).variableStore,
      EfiVariableStore.managed,
    );
  });

  test('explicit null EFI variable store is rejected', () {
    expect(
      () => EfiBoot.fromJson({'type': 'efi', 'variable_store': null}),
      throwsFormatException,
    );
  });

  test('date-only values are rejected as resource date-times', () {
    final metadata = Map<String, Object?>.from(json['metadata']! as Map)
      ..['created_at'] = '2026-09-04';
    expect(() => VmMetadata.fromJson(metadata), throwsFormatException);
  });

  test('date-times without an explicit offset are rejected', () {
    final metadata = Map<String, Object?>.from(json['metadata']! as Map)
      ..['updated_at'] = '2026-09-04T08:10:00';
    expect(() => VmMetadata.fromJson(metadata), throwsFormatException);
  });

  test('RFC3339 numeric offsets are accepted and normalized to UTC', () {
    final metadata = Map<String, Object?>.from(json['metadata']! as Map)
      ..['updated_at'] = '2026-09-04T16:10:00+08:00';
    expect(
      VmMetadata.fromJson(metadata).updatedAt,
      DateTime.utc(2026, 9, 4, 8, 10),
    );
  });

  test('collections are immutable snapshots', () {
    final vm = VirtualMachine.fromJson(json);
    expect(() => vm.metadata.labels['new'] = 'value', throwsUnsupportedError);
    expect(
      () => vm.spec.disks.add(vm.spec.disks.single),
      throwsUnsupportedError,
    );
  });
}
