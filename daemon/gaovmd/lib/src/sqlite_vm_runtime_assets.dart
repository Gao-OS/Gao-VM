import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'image_filesystem.dart';
import 'image_manifest.dart';
import 'runtime_assets.dart';
import 'runtime_driver.dart';
import 'sqlite_database.dart';
import 'vm_bundle_manifest.dart';
import 'vm_controller_reducer.dart';
import 'vm_provisioning_plan.dart';
import 'vm_provisioning_repository.dart';
import 'vm_repository.dart';

/// Resolves completed provisioning assets and retains the per-VM namespace lock
/// and descriptors until driver configuration returns. Callers own the roots.
/// Changed asset identities need a new durable binding; they are never rebuilt
/// or silently substituted here. Mutable managed disks are not image-hashed.
final class SqliteVmRuntimeAssets implements RuntimeAssetResolver {
  const SqliteVmRuntimeAssets({
    required GaoVmDatabase database,
    required OwnedImageDirectory bundles,
    required OwnedImageDirectory images,
  }) : _database = database,
       _bundles = bundles,
       _images = images;

  final GaoVmDatabase _database;
  final OwnedImageDirectory _bundles;
  final OwnedImageDirectory _images;

  @override
  Future<void> withAssets(
    VmControllerState state,
    Future<void> Function(VmRuntimeAssets) use,
  ) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('runtime asset IO must be outside a caller transaction');
    }
    final directories = <OwnedImageDirectory>[];
    final files = <OwnedImageFile>[];
    final OwnedImageLock lock;
    try {
      lock = await _bundles.acquireLock('.lock-${state.vmId.value}');
    } on FileSystemException catch (error) {
      throw _invalid(state, error.message);
    }
    try {
      late VmRuntimeAssets assets;
      try {
        final input = await _load(state);
        _private(_bundles);
        _private(_images);
        OwnedImageDirectory child(
          OwnedImageDirectory parent,
          String name, {
          bool private = true,
        }) {
          final result = parent.directory(name);
          directories.add(result);
          if (private) _private(result);
          return result;
        }

        OwnedImageFile file(OwnedImageDirectory parent, String name) {
          final result = parent.file(name);
          files.add(result);
          return result;
        }

        final bundle = child(_bundles, '${state.vmId.value}.gaovm');
        final originFile = file(bundle, 'manifest.json');
        final origin = VmBundleManifest.fromJson(
          jsonDecode(utf8.decode(await originFile.readBounded(1024 * 1024))),
        );
        if (origin.digest != VmBundleManifest.create(input.plan).digest) {
          throw const FormatException(
            'runtime bundle origin does not match completion proof',
          );
        }
        final disks = child(bundle, 'disks');
        final logs = child(bundle, 'logs');
        final nvram = child(bundle, 'nvram');
        for (final name in ['artifacts', 'runtime']) {
          child(bundle, name);
        }
        void existingLeaf(
          OwnedImageDirectory directory,
          String name, {
          bool nonempty = false,
        }) {
          final leaf = directory.fileOrNull(name);
          if (leaf != null) {
            files.add(leaf);
            if (nonempty && leaf.size == 0)
              throw const FormatException(
                'managed EFI variable store is empty',
              );
          }
        }

        // The driver may create absent writable leaves, but must never follow
        // pre-existing symlinks or special files outside the owned namespace.
        for (final name in ['driver.log', 'serial.log']) {
          existingLeaf(logs, name);
          for (var rotation = 1; rotation <= 3; rotation++) {
            existingLeaf(logs, '$name.$rotation');
          }
        }
        if (input.spec.boot case EfiBoot(
          variableStore: EfiVariableStore.managed,
        )) {
          existingLeaf(nvram, 'efi-variable-store', nonempty: true);
        }
        Future<String> bootObject(VmProvisioningImageObject object) async {
          // The image store's private root protects its immutable children;
          // existing object directories need not themselves have mode 0700.
          final image = child(
            _images,
            'sha256-${object.imageDigest.substring(7)}',
            private: false,
          );
          final objects = child(image, 'objects', private: false);
          final source = file(objects, object.objectName);
          if (source.size != object.sizeBytes ||
              'sha256:${await sha256.bind(source.openRead()).first}' !=
                  object.objectDigest) {
            throw const FormatException(
              'runtime boot object failed size/digest verification',
            );
          }
          return source.path;
        }

        Future<String> external(String path) async {
          if (!File(path).isAbsolute)
            throw const FormatException(
              'external runtime path must be absolute',
            );
          final source = await OwnedImageFile.open(File(path));
          files.add(source);
          if (source.size == 0)
            throw const FormatException('external runtime file is empty');
          return source.path;
        }

        final boot = switch (input.spec.boot) {
          LinuxKernelBoot(:final commandLine) => RuntimeLinuxBootConfiguration(
            kernelPath: await bootObject(input.plan.kernel!),
            initrdPath: input.plan.initrd == null
                ? null
                : await bootObject(input.plan.initrd!),
            commandLine: commandLine,
          ),
          EfiBoot(:final variableStore, :final variableStorePath) =>
            RuntimeEfiBootConfiguration(
              variableStorePath: variableStore == EfiVariableStore.external
                  ? await external(variableStorePath!)
                  : '${bundle.path}/nvram/efi-variable-store',
            ),
        };
        final resolvedDisks = <RuntimeDiskConfiguration>[];
        for (final disk in input.spec.disks) {
          final String path;
          switch (disk.source) {
            case ManagedImageDiskSource():
              final managed = file(disks, '${disk.id}.raw');
              if (managed.size == 0)
                throw const FormatException('managed runtime disk is empty');
              path = managed.path;
            case ExternalDiskSource(path: final externalPath):
              path = await external(externalPath);
          }
          resolvedDisks.add(
            RuntimeDiskConfiguration(
              id: disk.id,
              path: path,
              writable: disk.writable,
            ),
          );
        }
        // Resolution involved asynchronous hashing/opens. Recheck both durable
        // identity and pathname bindings before passing paths to another process.
        final current = await _load(state);
        if (contentDigest(current.spec.toJson()) !=
                contentDigest(input.spec.toJson()) ||
            VmBundleManifest.create(current.plan).digest != origin.digest) {
          throw const FormatException(
            'runtime asset snapshot changed during resolution',
          );
        }
        for (final directory in [_bundles, _images, ...directories]) {
          await directory.verifyPathBinding();
        }
        for (final source in files) {
          await source.verifyPathBinding();
        }
        assets = VmRuntimeAssets(
          vmId: state.vmId,
          specGeneration: state.activeSpecGeneration ?? state.specGeneration,
          spec: input.spec,
          bundlePath: bundle.path,
          boot: boot,
          disks: resolvedDisks,
        );
      } on FileSystemException catch (error) {
        throw _invalid(state, error.message);
      } on FormatException catch (error) {
        throw _invalid(state, error.message);
      }
      // Do not translate exceptions from the consumer as asset-validation errors.
      await use(assets);
    } finally {
      for (final source in files.reversed) {
        source.close();
      }
      for (final directory in directories.reversed) {
        directory.close();
      }
      lock.close();
    }
  }

  Future<({VmSpec spec, VmProvisioningPlan plan})> _load(
    VmControllerState state,
  ) => _database.transaction((db) async {
    final generation = state.activeSpecGeneration ?? state.specGeneration;
    final vm = await SqliteVmRepository(_database).get(state.vmId);
    final live = db.select(
      'SELECT 1 FROM vms WHERE id = ? AND deleting_at IS NULL AND deleted_at IS NULL',
      [state.vmId.value],
    );
    final job = await SqliteVmProvisioningRepository(_database).get(state.vmId);
    if (vm == null ||
        live.isEmpty ||
        vm.status.phase == VmPhase.provisioning ||
        vm.status.driverGeneration != state.driverGeneration ||
        job?.completion?.kind != VmProvisioningCompletionKind.succeeded) {
      throw _invalid(
        state,
        'VM does not have live completed assets for this driver generation',
      );
    }
    VmSpec retained(int generation) {
      final rows = db.select(
        'SELECT spec_json FROM vm_specs WHERE vm_id = ? AND generation = ?',
        [state.vmId.value, generation],
      );
      if (rows.isEmpty)
        throw _invalid(state, 'runtime spec generation is not retained');
      return VmSpec.fromJson(jsonDecode(rows.single['spec_json'] as String));
    }

    final plan = job!.plan;
    if (generation < plan.specGeneration ||
        generation > vm.status.specGeneration) {
      throw _invalid(
        state,
        'runtime generation is outside the provisioned retained range',
      );
    }
    final origin = retained(plan.specGeneration);
    if (contentDigest(origin.toJson()) != plan.specDigest) {
      throw const FormatException(
        'provisioning spec disagrees with its pinned digest',
      );
    }
    final spec = retained(generation);
    final bool bootMatches;
    switch (spec.boot) {
      case LinuxKernelBoot(:final kernelImageId, :final initrdImageId):
        bootMatches =
            origin.boot is LinuxKernelBoot &&
            kernelImageId == plan.kernel?.imageId &&
            initrdImageId == plan.initrd?.imageId;
      case EfiBoot():
        bootMatches =
            origin.boot is EfiBoot &&
            contentDigest(spec.boot.toJson()) ==
                contentDigest(origin.boot.toJson());
    }
    var diskMatches = spec.disks.length == plan.disks.length;
    for (final disk in spec.disks) {
      final pinned = plan.disks
          .where((item) => item.id == disk.id)
          .firstOrNull
          ?.source;
      diskMatches =
          diskMatches &&
          switch ((disk.source, pinned)) {
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
    }
    if (!bootMatches || !diskMatches)
      throw _invalid(
        state,
        'changed boot/disk sources require a completed generation-specific asset binding',
      );
    return (spec: spec, plan: plan);
  });
}

void _private(OwnedImageDirectory directory) {
  if (directory.mode & 0x3f != 0)
    throw FileSystemException(
      'runtime asset directory must be private',
      directory.path,
    );
}

RuntimeDriverError _invalid(VmControllerState state, String message) =>
    RuntimeDriverError(
      code: RuntimeDriverErrorCode.invalidRuntimeConfig,
      message: message,
      retryable: false,
      details: JsonObjectValue.fromJson({
        'vm_id': state.vmId.value,
        'spec_generation': state.activeSpecGeneration ?? state.specGeneration,
      }),
    );
