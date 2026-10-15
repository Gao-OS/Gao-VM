part of 'cold_catalog_inspection.dart';

/// Read-only managed asset evidence, not a backup or a complete cold boundary.
final class ColdManagedAssets {
  ColdManagedAssets._(
    this._files,
    Map<String, Object?> evidence,
    Iterable<String> absentFiles,
    this._trees,
  ) : _evidence = JsonObjectValue.fromJson(evidence),
      _absentFiles = List.unmodifiable(absentFiles);
  final ColdFileReferences _files;
  final JsonObjectValue _evidence;
  final List<String> _absentFiles;
  final Map<String, ({MaintenanceTree tree, Map<String, Object?> manifest})>
  _trees;

  static Future<ColdManagedAssets> inspect(
    ColdCatalogInspection catalog, {
    MacOsOpenReferences? observer,
  }) async {
    catalog.requireQuiescent();
    await catalog.verify();
    final bindings = <Map<String, Object?>>[];
    final manifests = <String, ImageManifest>{};
    final objects = <String, Map<String, Object?>>{};
    final bundleManifests = <String, VmBundleManifest>{};
    final vms = <Map<String, Object?>>[];
    final absentFiles = <String>{};
    final directories = <String, bool>{};
    final roots = <String>{};
    for (final image in catalog._managedImages) {
      final root =
          '${catalog.sourcePath}/images/sha256-${image.digest.substring(7)}';
      roots.add('${catalog.sourcePath}/images');
      directories['${catalog.sourcePath}/images'] = true;
      directories[root] = false;
      directories['$root/objects'] = false;
      final manifest = ImageManifest.fromJson(image.manifest.toJson());
      manifests['$root/manifest.json'] = manifest;
      bindings.add({
        'path': '$root/manifest.json',
        'kind': 'image_manifest',
        'image_id': image.id.value,
      });
      for (final object in manifest.objects.entries) {
        final path = '$root/objects/${object.key}';
        objects[path] = object.value;
        bindings.add({
          'path': path,
          'kind': 'image_object',
          'image_id': image.id.value,
          'object_name': object.key,
        });
      }
      if (bindings.length > 16384) {
        throw const ColdStateFailure(
          'managed_assets',
          'managed evidence exceeds bounds',
        );
      }
    }
    final images = {
      for (final image in catalog._managedImages) image.id: image,
    };
    for (final vm in catalog._managedVms) {
      final origin = _validateManagedVm(vm, images);
      vms.add({
        'vm_id': vm.id,
        'provisioning_outcome': vm.proof!['completion_kind'],
        'origin_digest': origin.digest,
        'spec_generations': vm.specs.keys.toList()..sort(),
      });
      final root = '${catalog.sourcePath}/vms/${vm.id}.gaovm';
      roots.add('${catalog.sourcePath}/vms');
      directories['${catalog.sourcePath}/vms'] = true;
      directories[root] = true;
      for (final name in ['disks', 'logs', 'artifacts', 'runtime', 'nvram']) {
        directories['$root/$name'] = true;
      }
      bundleManifests['$root/manifest.json'] = origin;
      bindings.add({
        'path': '$root/manifest.json',
        'kind': 'bundle_manifest',
        'vm_id': vm.id,
      });
      for (final spec in vm.specs.entries) {
        for (final disk in spec.value.disks) {
          if (disk.source is ManagedImageDiskSource) {
            bindings.add({
              'path': '$root/disks/${disk.id}.raw',
              'kind': 'managed_disk',
              'vm_id': vm.id,
              'spec_generation': spec.key,
              'device_id': disk.id,
              'writable': disk.writable,
            });
          }
        }
        if (spec.value.boot case EfiBoot(
          variableStore: EfiVariableStore.managed,
        )) {
          final path = '$root/nvram/efi-variable-store';
          if (await FileSystemEntity.type(path, followLinks: false) ==
              FileSystemEntityType.notFound) {
            if (vm.driverGeneration != 0 ||
                vm.observedGeneration != 0 ||
                await Directory('$root/nvram').resolveSymbolicLinks() !=
                    '$root/nvram' ||
                await FileSystemEntity.type(
                      '$root/nvram',
                      followLinks: false,
                    ) !=
                    FileSystemEntityType.directory) {
              throw const ColdStateFailure(
                'managed_assets',
                'managed EFI is missing after runtime use or has no bound parent',
              );
            }
            absentFiles.add(path);
            continue;
          }
          bindings.add({
            'path': path,
            'kind': 'managed_efi',
            'vm_id': vm.id,
            'spec_generation': spec.key,
            'writable': true,
          });
        }
      }
      if (bindings.length > 16384) {
        throw const ColdStateFailure(
          'managed_assets',
          'managed evidence exceeds bounds',
        );
      }
    }
    ColdFileReferences? heldFiles;
    final trees =
        <String, ({MaintenanceTree tree, Map<String, Object?> manifest})>{};
    try {
      for (final root in roots) {
        final tree = await MaintenanceTree.open(Directory(root));
        try {
          trees[root] = (
            tree: tree,
            manifest: await tree.capture(nativeMetadata: true),
          );
        } catch (_) {
          tree.close();
          rethrow;
        }
      }
      for (final entry in directories.entries) {
        final root = roots.singleWhere(
          (root) => entry.key == root || entry.key.startsWith('$root/'),
        );
        final relative = entry.key == root
            ? ''
            : entry.key.substring(root.length + 1);
        final facts = trees[root]!.manifest[relative] as Map?;
        if (facts == null ||
            facts['kind'] != 'directory' ||
            (entry.value && (facts['mode'] as int) & 0xc3f != 0) ||
            (facts['metadata'] as Map)['has_acl'] != false) {
          throw const ColdStateFailure(
            'managed_assets',
            'managed directory is absent, unsafe or grants ACL access',
          );
        }
      }
      final files = heldFiles = await ColdFileReferences._inspect(
        catalog,
        bindings,
        observer: observer,
      );
      for (final entry in manifests.entries) {
        final held = files._files[entry.key]!;
        final actual = ImageManifest.fromJson(
          jsonDecode(utf8.decode(await held.file.readBounded(1024 * 1024))),
        );
        if (JsonValue.fromJson(actual.toJson()) !=
            JsonValue.fromJson(entry.value.toJson())) {
          throw const ColdStateFailure(
            'managed_assets',
            'image manifest disagrees with catalog',
          );
        }
      }
      for (final entry in objects.entries) {
        final actual = files._files[entry.key]!.evidence.toJson();
        if (actual['size'] != entry.value['size_bytes'] ||
            actual['digest'] != entry.value['digest']) {
          throw const ColdStateFailure(
            'managed_assets',
            'immutable image object changed',
          );
        }
      }
      for (final entry in bundleManifests.entries) {
        final actual = VmBundleManifest.fromJson(
          jsonDecode(
            utf8.decode(
              await files._files[entry.key]!.file.readBounded(1024 * 1024),
            ),
          ),
        );
        if (actual.digest != entry.value.digest) {
          throw const ColdStateFailure(
            'managed_assets',
            'bundle origin disagrees with completion proof',
          );
        }
      }
      final assets = ColdManagedAssets._(
        files,
        {
          'format': 'gaovm.cold-managed-assets.v1',
          'source_state': catalog.sourcePath,
          'images': [
            for (final image in catalog._managedImages)
              {'image_id': image.id.value, 'digest': image.digest},
          ],
          'vms': vms,
          'absent_files': absentFiles.toList()..sort(),
          'files': files.toJson()['files'],
          'trees': {
            for (final entry in trees.entries) entry.key: entry.value.manifest,
          },
        },
        absentFiles,
        trees,
      );
      await assets.verify();
      return assets;
    } catch (error) {
      heldFiles?.close();
      for (final held in trees.values) {
        held.tree.close();
      }
      if (error is FormatException)
        throw ColdStateFailure('managed_assets', error.message);
      rethrow;
    }
  }

  Future<void> verify() async {
    if (_files._closed) throw StateError('managed asset inspection is closed');
    await _files._catalog.verify();
    await _verifyAbsences();
    for (final held in _trees.values) {
      await held.tree.verify(held.manifest, nativeMetadata: true);
    }
    await _files.verify();
    await _verifyAbsences();
    for (final held in _trees.values) {
      await held.tree.verify(held.manifest, nativeMetadata: true);
    }
    await _files._catalog.verify();
  }

  Future<void> _verifyAbsences() async {
    for (final path in _absentFiles) {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const ColdStateFailure(
          'managed_assets',
          'previously absent managed EFI appeared',
        );
      }
    }
  }

  Map<String, Object?> toJson() {
    if (_files._closed) throw StateError('managed asset inspection is closed');
    return _evidence.toJson();
  }

  void close() {
    _files.close();
    for (final held in _trees.values) {
      held.tree.close();
    }
  }
}

List<Image> _readManagedImages(Database database) {
  if (database.userVersion == 0) return const [];
  final count =
      database
              .select(
                'SELECT COUNT(*) AS count FROM images WHERE deleted_at IS NULL',
              )
              .single['count']
          as int;
  if (count > 16384) {
    throw const ColdStateFailure(
      'managed_assets',
      'image evidence exceeds bounds',
    );
  }
  final rows = database.select(
    'SELECT * FROM images WHERE deleted_at IS NULL '
    'AND length(CAST(manifest_json AS BLOB)) <= 1048576 '
    'AND length(CAST(labels_json AS BLOB)) <= 65536 ORDER BY id',
  );
  if (rows.length != count) {
    throw const ColdStateFailure('managed_assets', 'image JSON exceeds bounds');
  }
  return List.unmodifiable(
    rows.map((row) {
      final image = Image.fromJson({
        'id': row['id'],
        'digest': row['digest'],
        'type': row['type'],
        'architecture': row['architecture'],
        'guest_profile': row['guest_profile'],
        'version': row['version'],
        'build_id': row['build_id'],
        'channel': row['channel'],
        'labels': jsonDecode(row['labels_json'] as String),
        'manifest': jsonDecode(row['manifest_json'] as String),
        'created_at': row['created_at'],
      });
      final manifest = ImageManifest.fromJson(image.manifest.toJson());
      if (image.digest != manifest.digest ||
          image.type != manifest.type ||
          image.architecture != Architecture.arm64 ||
          image.guestProfile != manifest.metadata('guest_profile') ||
          image.version != manifest.metadata('version') ||
          image.buildId != manifest.metadata('build_id') ||
          image.channel != manifest.metadata('channel')) {
        throw const ColdStateFailure(
          'managed_assets',
          'image catalog disagrees with immutable manifest',
        );
      }
      return image;
    }),
  );
}

final class _ColdManagedVm {
  _ColdManagedVm(
    this.id,
    this.driverGeneration,
    this.observedGeneration,
    Map<int, VmSpec> specs,
    this.originSpec,
    this.proof,
  ) : specs = Map.unmodifiable(specs);
  final String id;
  final int driverGeneration;
  final int observedGeneration;
  final Map<int, VmSpec> specs;
  final VmSpec? originSpec;
  final Map<String, Object?>? proof;
}

// Read only while SQLite is bound to the private inspection copy. Raw proof
// rows remain private; callers cannot substitute facts from serialized JSON.
List<_ColdManagedVm> _readManagedVms(Database database) {
  final version = database.userVersion;
  if (version == 0) return const [];
  final execution = version >= 4
      ? 'r.execution_spec_generation'
      : 'NULL AS execution_spec_generation';
  final rows = database.select('''
    SELECT v.id, v.spec_generation, r.driver_generation,
      r.observed_generation, $execution FROM vms v JOIN vm_runtime r ON r.vm_id = v.id
    WHERE v.deleted_at IS NULL ORDER BY v.id
  ''');
  VmSpec? spec(String id, int generation) {
    final values = database.select(
      '''
      SELECT spec_json FROM vm_specs WHERE vm_id = ? AND generation = ?
      AND length(CAST(spec_json AS BLOB)) <= 1048576 LIMIT 2
    ''',
      [id, generation],
    );
    return values.length == 1
        ? VmSpec.fromJson(jsonDecode(values.single['spec_json'] as String))
        : null;
  }

  return List.unmodifiable(
    rows.map((row) {
      final id = row['id'] as String;
      final generations = {
        row['spec_generation'] as int,
        if ((row['observed_generation'] as int) > 0)
          row['observed_generation'] as int,
        if (row['execution_spec_generation'] != null)
          row['execution_spec_generation'] as int,
      };
      final proofs = version >= 6
          ? database.select(
              '''
      SELECT p.*, o.type AS op_type, o.resource_type AS op_resource_type,
        o.resource_id AS op_resource_id, o.state AS op_state,
        o.completed_at AS op_completed_at, o.request_json AS op_request_json
      FROM vm_provisioning p JOIN operations o ON o.id = p.operation_id
      WHERE p.vm_id = ? AND length(CAST(p.plan_json AS BLOB)) <= 1048576
        AND length(CAST(o.request_json AS BLOB)) <= 1048576 LIMIT 2
    ''',
              [id],
            )
          : const <Row>[];
      final proof = proofs.length == 1
          ? Map<String, Object?>.unmodifiable(proofs.single)
          : null;
      return _ColdManagedVm(
        id,
        row['driver_generation'] as int,
        row['observed_generation'] as int,
        {
          for (final generation in generations)
            generation: spec(id, generation)!,
        },
        proof?['spec_generation'] is int
            ? spec(id, proof!['spec_generation'] as int)
            : null,
        proof,
      );
    }),
  );
}

VmBundleManifest _validateManagedVm(
  _ColdManagedVm vm,
  Map<ImageId, Image> images,
) {
  final proof = vm.proof;
  if (proof == null || vm.originSpec == null) {
    throw const ColdStateFailure(
      'managed_assets',
      'VM has no bounded terminal provisioning proof',
    );
  }
  final plan = VmProvisioningPlan.fromJson(
    jsonDecode(proof['plan_json'] as String),
  );
  final manifest = VmBundleManifest.create(plan);
  final kind = proof['completion_kind'];
  final request = jsonDecode(proof['op_request_json'] as String);
  // Failed/cancelled create completion tombstones the definition. A live VM,
  // including a retained failed TestRun VM, needs successful publication proof.
  if (kind != 'succeeded' ||
      plan.vmId.value != vm.id ||
      plan.operationId.value != proof['operation_id'] ||
      plan.specGeneration != proof['spec_generation'] ||
      contentDigest(vm.originSpec!.toJson()) != plan.specDigest ||
      proof['op_type'] != 'vm.create' ||
      proof['op_resource_type'] != 'virtual_machine' ||
      proof['op_resource_id'] != vm.id ||
      proof['op_state'] != kind ||
      proof['completed_at'] == null ||
      proof['op_completed_at'] != proof['completed_at'] ||
      proof['manifest_digest'] != manifest.digest ||
      proof['cancellation_requested'] != 0 ||
      request is! Map<String, dynamic> ||
      (request.containsKey('spec_generation') &&
          (request['spec_generation'] is! int ||
              request['spec_generation'] != plan.specGeneration))) {
    throw const ColdStateFailure(
      'managed_assets',
      'VM provisioning proof disagrees with catalog or Operation',
    );
  }
  DateTime.parse(proof['completed_at'] as String);
  for (final entry in vm.specs.entries) {
    if (entry.key < plan.specGeneration) {
      throw const ColdStateFailure(
        'managed_assets',
        'VM spec precedes its provisioning proof',
      );
    }
    _requireManagedSpecBinding(entry.value, vm.originSpec!, plan);
  }
  _requireManagedSpecBinding(vm.originSpec!, vm.originSpec!, plan);
  for (final pin in [
    plan.kernel,
    plan.initrd,
    ...plan.disks
        .map((disk) => disk.source)
        .whereType<VmProvisioningManagedDisk>()
        .map((source) => source.image),
  ].nonNulls) {
    final image = images[pin.imageId];
    if (image == null)
      throw const ColdStateFailure(
        'managed_assets',
        'provisioning image is missing',
      );
    final imageManifest = ImageManifest.fromJson(image.manifest.toJson());
    final role = pin.role == VmProvisioningImageRole.rootDisk
        ? 'root_disk'
        : pin.role.name;
    final expectedType = switch (pin.role) {
      VmProvisioningImageRole.kernel => ImageType.linuxKernel,
      VmProvisioningImageRole.initrd => ImageType.initrd,
      VmProvisioningImageRole.rootDisk => ImageType.rawDisk,
    };
    final objectName = image.type == ImageType.gaoosBundle
        ? (imageManifest.toJson()['gaoos'] as Map)[role]
        : 'payload';
    final object = imageManifest.objects[objectName];
    if (image.digest != pin.imageDigest ||
        (image.type != ImageType.gaoosBundle && image.type != expectedType) ||
        pin.objectName != objectName ||
        object == null ||
        object['digest'] != pin.objectDigest ||
        object['size_bytes'] != pin.sizeBytes) {
      throw const ColdStateFailure(
        'managed_assets',
        'provisioning image pin disagrees with immutable catalog',
      );
    }
  }
  return manifest;
}

void _requireManagedSpecBinding(
  VmSpec spec,
  VmSpec origin,
  VmProvisioningPlan plan,
) {
  final bootMatches = switch (spec.boot) {
    LinuxKernelBoot(:final kernelImageId, :final initrdImageId) =>
      origin.boot is LinuxKernelBoot &&
          kernelImageId == plan.kernel?.imageId &&
          initrdImageId == plan.initrd?.imageId,
    EfiBoot() =>
      origin.boot is EfiBoot &&
          plan.kernel == null &&
          plan.initrd == null &&
          JsonValue.fromJson(spec.boot.toJson()) ==
              JsonValue.fromJson(origin.boot.toJson()),
  };
  if (!bootMatches || spec.disks.length != plan.disks.length) {
    throw const ColdStateFailure(
      'managed_assets',
      'VM boot or disk sources lack completed asset binding',
    );
  }
  for (final disk in spec.disks) {
    final pinned = plan.disks
        .where((item) => item.id == disk.id)
        .firstOrNull
        ?.source;
    final matches = switch ((disk.source, pinned)) {
      (
        ManagedImageDiskSource(:final imageId),
        VmProvisioningManagedDisk(:final image),
      ) =>
        imageId == image.imageId,
      (
        ExternalDiskSource(:final path),
        VmProvisioningExternalDisk(path: final pinnedPath),
      ) =>
        path == pinnedPath,
      _ => false,
    };
    if (!matches)
      throw const ColdStateFailure(
        'managed_assets',
        'VM disk source lacks completed asset binding',
      );
  }
}
