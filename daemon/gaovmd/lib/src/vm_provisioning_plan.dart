import 'dart:convert';

import 'package:gaovm_models/gaovm_models.dart';

import 'image_manifest.dart';
import 'image_repository.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'vm_repository.dart';

enum VmProvisioningImageRole { kernel, initrd, rootDisk }

final class VmProvisioningImageObject {
  VmProvisioningImageObject._(
    this.role,
    this.imageId,
    this.imageDigest,
    this.objectName,
    this.objectDigest,
    this.sizeBytes,
  );
  factory VmProvisioningImageObject.fromJson(Object? value) {
    final json = _object(value, {
      'role',
      'image_id',
      'image_digest',
      'object_name',
      'object_digest',
      'size_bytes',
    });
    final role = VmProvisioningImageRole.values
        .where((role) => _roleName(role) == json['role'])
        .firstOrNull;
    if (role == null) throw FormatException('invalid image object role');
    final name = _string(json['object_name']);
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(name))
      throw FormatException('invalid object name');
    return VmProvisioningImageObject._(
      role,
      ImageId(_string(json['image_id'])),
      _digest(json['image_digest']),
      name,
      _digest(json['object_digest']),
      _positive(json['size_bytes']),
    );
  }
  final VmProvisioningImageRole role;
  final ImageId imageId;
  final String imageDigest;
  final String objectName;
  final String objectDigest;
  final int sizeBytes;
  Map<String, Object?> toJson() => {
    'role': _roleName(role),
    'image_id': imageId.value,
    'image_digest': imageDigest,
    'object_name': objectName,
    'object_digest': objectDigest,
    'size_bytes': sizeBytes,
  };
}

sealed class VmProvisioningDiskSource {
  const VmProvisioningDiskSource();
  factory VmProvisioningDiskSource.fromJson(Object? value) {
    if (value is! Map) throw FormatException('invalid disk source');
    switch (value['type']) {
      case 'external':
        final json = _object(value, {'type', 'path'});
        final path = _string(json['path']);
        if (path.isEmpty || path.contains('\u0000'))
          throw FormatException('invalid external path');
        return VmProvisioningExternalDisk._(path);
      case 'managed_image':
        final json = _object(value, {'type', 'image'});
        final image = VmProvisioningImageObject.fromJson(json['image']);
        if (image.role != VmProvisioningImageRole.rootDisk)
          throw FormatException('disk requires root_disk role');
        return VmProvisioningManagedDisk._(image);
      default:
        throw FormatException('invalid disk source type');
    }
  }
  Map<String, Object?> toJson();
}

/// External paths remain caller-owned; planning never canonicalizes or opens them.
final class VmProvisioningExternalDisk extends VmProvisioningDiskSource {
  const VmProvisioningExternalDisk._(this.path);
  final String path;
  @override
  Map<String, Object?> toJson() => {'type': 'external', 'path': path};
}

final class VmProvisioningManagedDisk extends VmProvisioningDiskSource {
  const VmProvisioningManagedDisk._(this.image);
  final VmProvisioningImageObject image;
  @override
  Map<String, Object?> toJson() => {
    'type': 'managed_image',
    'image': image.toJson(),
  };
}

final class VmProvisioningDisk {
  const VmProvisioningDisk._(this.id, this.writable, this.source);
  factory VmProvisioningDisk.fromJson(Object? value) {
    final json = _object(value, {'id', 'writable', 'source'});
    final id = _string(json['id']);
    if (!RegExp(r'^[a-z][a-z0-9-]{0,31}$').hasMatch(id) ||
        json['writable'] is! bool)
      throw FormatException('invalid disk identity or writable flag');
    return VmProvisioningDisk._(
      id,
      json['writable'] as bool,
      VmProvisioningDiskSource.fromJson(json['source']),
    );
  }
  final String id;
  final bool writable;
  final VmProvisioningDiskSource source;
  Map<String, Object?> toJson() => {
    'id': id,
    'writable': writable,
    'source': source.toJson(),
  };
}

/// Immutable job input, not an independently writable VM configuration.
final class VmProvisioningPlan {
  VmProvisioningPlan._(
    this.vmId,
    this.operationId,
    this.specGeneration,
    this.specDigest,
    List<VmProvisioningDisk> disks,
    this.kernel,
    this.initrd,
  ) : disks = List.unmodifiable(disks);
  factory VmProvisioningPlan.fromJson(Object? value) {
    final json = _object(value, {
      'plan_version',
      'vm_id',
      'operation_id',
      'spec_generation',
      'spec_digest',
      'disks',
      'kernel',
      'initrd',
    });
    if (json['plan_version'] is! int ||
        json['plan_version'] != 1 ||
        json['disks'] is! List)
      throw FormatException('invalid provisioning plan version or disks');
    final rawDisks = json['disks'] as List;
    if (rawDisks.isEmpty || rawDisks.length > 32)
      throw FormatException('provisioning requires 1 to 32 disks');
    final disks = rawDisks.map(VmProvisioningDisk.fromJson).toList();
    if (disks.map((disk) => disk.id).toSet().length != disks.length)
      throw FormatException('duplicate disk ID');
    final kernel = json['kernel'] == null
        ? null
        : VmProvisioningImageObject.fromJson(json['kernel']);
    final initrd = json['initrd'] == null
        ? null
        : VmProvisioningImageObject.fromJson(json['initrd']);
    if (kernel != null && kernel.role != VmProvisioningImageRole.kernel ||
        initrd != null &&
            (kernel == null || initrd.role != VmProvisioningImageRole.initrd))
      throw FormatException('invalid boot image roles');
    return VmProvisioningPlan._(
      VmId(_string(json['vm_id'])),
      OperationId(_string(json['operation_id'])),
      _positive(json['spec_generation']),
      _digest(json['spec_digest']),
      disks,
      kernel,
      initrd,
    );
  }
  final VmId vmId;
  final OperationId operationId;
  final int specGeneration;
  final String specDigest;
  final List<VmProvisioningDisk> disks;
  final VmProvisioningImageObject? kernel;
  final VmProvisioningImageObject? initrd;
  Map<String, Object?> toJson() => {
    'plan_version': 1,
    'vm_id': vmId.value,
    'operation_id': operationId.value,
    'spec_generation': specGeneration,
    'spec_digest': specDigest,
    'disks': disks.map((disk) => disk.toJson()).toList(),
    'kernel': kernel?.toJson(),
    'initrd': initrd?.toJson(),
  };
}

final class SqliteVmProvisioningPlanner {
  const SqliteVmProvisioningPlanner(this._database);
  final GaoVmDatabase _database;

  /// Joins create acceptance's transaction. Terminal jobs replay their stored
  /// plan; they must not regenerate it from possibly changed catalog state.
  Future<VmProvisioningPlan> plan({
    required VmId vmId,
    required OperationId operationId,
    required int specGeneration,
  }) => _database.transaction((db) async {
    _positive(specGeneration);
    final rows = db.select(
      'SELECT s.spec_json FROM vm_specs s JOIN vms v ON v.id = s.vm_id WHERE s.vm_id = ? AND s.generation = ? AND v.deleted_at IS NULL',
      [vmId.value, specGeneration],
    );
    if (rows.isEmpty) throw VmNotFoundException(vmId);
    final spec = VmSpec.fromJson(
      jsonDecode(rows.single['spec_json'] as String),
    );
    final operation = await SqliteOperationRepository(
      _database,
    ).get(operationId);
    if (operation == null) throw OperationNotFoundException(operationId);
    final request = operation.request.toJson();
    if (operation.type != 'vm.create' ||
        operation.resourceType != ResourceType.virtualMachine ||
        operation.resourceId != vmId ||
        (operation.state != OperationState.pending &&
            operation.state != OperationState.running) ||
        (request.containsKey('spec_generation') &&
            (request['spec_generation'] is! int ||
                request['spec_generation'] != specGeneration))) {
      throw StateError('operation does not authorize this provisioning plan');
    }
    final images = ImageRepository(_database);
    final manifests = <ImageId, ImageManifest>{};
    Future<VmProvisioningImageObject> pin(
      ImageId id,
      VmProvisioningImageRole role,
    ) async {
      var manifest = manifests[id];
      if (manifest == null) {
        final image = await images.get(id);
        if (image == null)
          throw StateError('provisioning image is missing: $id');
        manifest = ImageManifest.fromJson(image.manifest.toJson());
        if (image.digest != manifest.digest ||
            image.type != manifest.type ||
            image.architecture != spec.architecture ||
            image.guestProfile != manifest.metadata('guest_profile') ||
            image.version != manifest.metadata('version') ||
            image.buildId != manifest.metadata('build_id') ||
            image.channel != manifest.metadata('channel')) {
          throw FormatException(
            'image catalog disagrees with immutable manifest',
          );
        }
        manifests[id] = manifest;
      }
      final expected = switch (role) {
        VmProvisioningImageRole.kernel => ImageType.linuxKernel,
        VmProvisioningImageRole.initrd => ImageType.initrd,
        VmProvisioningImageRole.rootDisk => ImageType.rawDisk,
      };
      final String name;
      if (manifest.type == ImageType.gaoosBundle) {
        name = (manifest.toJson()['gaoos'] as Map)[_roleName(role)] as String;
      } else {
        if (manifest.type != expected)
          throw FormatException(
            'image type does not match ${_roleName(role)} role',
          );
        name = 'payload';
      }
      final object = manifest.objects[name]!;
      return VmProvisioningImageObject.fromJson({
        'role': _roleName(role),
        'image_id': id.value,
        'image_digest': manifest.digest,
        'object_name': name,
        'object_digest': object['digest'],
        'size_bytes': object['size_bytes'],
      });
    }

    final boot = spec.boot;
    final kernel = boot is LinuxKernelBoot
        ? await pin(boot.kernelImageId, VmProvisioningImageRole.kernel)
        : null;
    final initrd = boot is LinuxKernelBoot && boot.initrdImageId != null
        ? await pin(boot.initrdImageId!, VmProvisioningImageRole.initrd)
        : null;
    final disks = <Map<String, Object?>>[];
    for (final disk in spec.disks) {
      final source = switch (disk.source) {
        ExternalDiskSource(:final path) => {'type': 'external', 'path': path},
        ManagedImageDiskSource(:final imageId) => {
          'type': 'managed_image',
          'image': (await pin(
            imageId,
            VmProvisioningImageRole.rootDisk,
          )).toJson(),
        },
      };
      disks.add({'id': disk.id, 'writable': disk.writable, 'source': source});
    }
    return VmProvisioningPlan.fromJson({
      'plan_version': 1,
      'vm_id': vmId.value,
      'operation_id': operationId.value,
      'spec_generation': specGeneration,
      'spec_digest': contentDigest(spec.toJson()),
      'disks': disks,
      'kernel': kernel?.toJson(),
      'initrd': initrd?.toJson(),
    });
  });
}

Map<String, Object?> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      value.keys.any((key) => !keys.contains(key)))
    throw FormatException('invalid provisioning fields');
  return Map<String, Object?>.of(value);
}

String _string(Object? value) {
  if (value is! String) throw FormatException('expected string');
  return value;
}

String _digest(Object? value) {
  final digest = _string(value);
  if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(digest))
    throw FormatException('invalid digest');
  return digest;
}

int _positive(Object? value) {
  if (value is! int || value < 1)
    throw FormatException('expected positive integer');
  return value;
}

String _roleName(VmProvisioningImageRole role) => switch (role) {
  VmProvisioningImageRole.rootDisk => 'root_disk',
  _ => role.name,
};
