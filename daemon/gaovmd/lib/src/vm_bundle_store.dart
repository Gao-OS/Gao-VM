import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'image_filesystem.dart';
import 'image_manifest.dart';
import 'managed_disk_materializer.dart';
import 'operation_repository.dart';
import 'sqlite_database.dart';
import 'vm_bundle_manifest.dart';
import 'vm_provisioning_plan.dart';
import 'vm_provisioning_repository.dart';
import 'vm_repository.dart';

enum VmBundleCheckpoint { staged, published, cleanupContentsRemoved }

/// The caller owns private roots and keeps their descriptors open. The lock
/// spans filesystem publication AND the caller's terminal database commit, so
/// an expired delivery cannot race a newer worker's cleanup or completion.
final class VmBundleStore {
  VmBundleStore({
    required GaoVmDatabase database,
    required OwnedImageDirectory bundles,
    required OwnedImageDirectory images,
    ManagedDiskMaterializer? materializer,
    void Function(VmBundleCheckpoint)? onCheckpoint,
  }) : _database = database,
       _bundles = bundles,
       _images = images,
       _materializer = materializer ?? ManagedDiskMaterializer(),
       _onCheckpoint = onCheckpoint;

  final GaoVmDatabase _database;
  final OwnedImageDirectory _bundles;
  final OwnedImageDirectory _images;
  final ManagedDiskMaterializer _materializer;
  final void Function(VmBundleCheckpoint)? _onCheckpoint;

  Future<T> withBundle<T>(
    VmProvisioningPlan plan,
    Future<T> Function(VmBundleSession bundle) action,
  ) async {
    _requireOutsideTransaction();
    final lock = await _bundles.acquireLock('.lock-${plan.vmId.value}');
    final session = VmBundleSession._(this, VmBundleManifest.create(plan));
    try {
      return await action(session);
    } finally {
      session._active = false;
      lock.close();
    }
  }

  void _requireOutsideTransaction() {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('VM bundle IO must be outside a caller transaction');
    }
  }
}

/// Use only within [VmBundleStore.withBundle], and await every operation before
/// returning. Publication is not a durable create completion by itself.
final class VmBundleSession {
  VmBundleSession._(this._store, this.manifest);
  final VmBundleStore _store;
  final VmBundleManifest manifest;
  bool _active = true;
  String get _name => '${manifest.plan.vmId.value}.gaovm';
  String get _stageName =>
      '.staging-${manifest.plan.vmId.value}-${manifest.plan.operationId.value}';

  Future<VmBundleManifest> publish({
    bool Function()? isCancelled,
    void Function(int)? onProgress,
  }) async {
    _requireActive();
    await _requireUncommitted();
    _checkCancelled(isCancelled);
    final published = _store._bundles.directoryOrNull(_name);
    if (published != null) {
      try {
        await _verifyPublished(published, isCancelled);
      } finally {
        published.close();
      }
      await _cleanAbandonedStage();
      return manifest;
    }
    await _cleanAbandonedStage();
    final stage = _store._bundles.createDirectory(_stageName);
    try {
      final output = stage.createFile('manifest.json');
      try {
        final writer = await output.openWrite();
        try {
          await writer.writeFrom(
            utf8.encode(canonicalImageJson(manifest.toJson())),
          );
          await writer.flush();
        } finally {
          await writer.close();
        }
      } finally {
        output.close();
      }
      for (final name in _directories) {
        final child = stage.createDirectory(name);
        try {
          await child.sync();
        } finally {
          child.close();
        }
      }
      final disks = stage.directory('disks');
      try {
        var completed = 0;
        for (final disk in manifest.plan.disks) {
          final source = disk.source;
          if (source is VmProvisioningManagedDisk) {
            final image = _openImage(source.image);
            try {
              await _store._materializer.materialize(
                source: image,
                destination: disks,
                name: '${disk.id}.raw',
                expectedSize: source.image.sizeBytes,
                expectedDigest: source.image.objectDigest,
                isCancelled: isCancelled,
                onProgress: (bytes) => onProgress?.call(completed + bytes),
              );
              completed += source.image.sizeBytes;
            } finally {
              image.close();
            }
          } else if (source is VmProvisioningExternalDisk) {
            await _validateExternal(source);
          }
        }
        await disks.sync();
      } finally {
        disks.close();
      }
      for (final image in [
        manifest.plan.kernel,
        manifest.plan.initrd,
      ].nonNulls) {
        final file = _openImage(image);
        try {
          await _verify(file, image.sizeBytes, image.objectDigest, isCancelled);
        } finally {
          file.close();
        }
      }
      await stage.sync();
      _store._onCheckpoint?.call(VmBundleCheckpoint.staged);
      _checkCancelled(isCancelled);
      await _store._bundles.renameDirectoryNoReplace(_stageName, _name);
      _store._onCheckpoint?.call(VmBundleCheckpoint.published);
      return manifest;
    } catch (_) {
      await _removeOwnedTree(_stageName);
      rethrow;
    } finally {
      stage.close();
    }
  }

  /// Caller holds a current work claim. Never use to delete a completed VM;
  /// delete lifecycle owns that path. Only this pinned job's files are removed.
  Future<void> removeUncommitted() async {
    _requireActive();
    await _requireUncommitted();
    await _cleanAbandonedStage();
    final published = _store._bundles.directoryOrNull(_name);
    if (published != null) {
      try {
        await _verifyOrigin(published);
      } finally {
        published.close();
      }
      // Keep destructive cleanup in a recognizable resumable namespace. A
      // crash after removing manifest.json must not leave a public bundle
      // whose origin can no longer be established on the next delivery.
      await _store._bundles.renameDirectoryNoReplace(_name, _stageName);
    }
    await _cleanAbandonedStage();
  }

  Future<void> _requireUncommitted() => _store._database.transaction((_) async {
    final plan = manifest.plan;
    final job = await SqliteVmProvisioningRepository(
      _store._database,
    ).get(plan.vmId);
    final vm = await SqliteVmRepository(_store._database).get(plan.vmId);
    final operation = await SqliteOperationRepository(
      _store._database,
    ).get(plan.operationId);
    if (job == null ||
        job.completion != null ||
        VmBundleManifest.create(job.plan).digest != manifest.digest ||
        vm == null ||
        vm.status.phase != VmPhase.provisioning ||
        vm.status.desiredState != DesiredState.stopped ||
        vm.status.driverGeneration != 0 ||
        vm.status.specGeneration != plan.specGeneration ||
        operation == null ||
        (operation.state != OperationState.pending &&
            operation.state != OperationState.running)) {
      throw StateError(
        'bundle mutation requires this active unpublished create job',
      );
    }
  });

  Future<void> _cleanAbandonedStage() async {
    final stage = _store._bundles.directoryOrNull(_stageName);
    if (stage == null) return;
    try {
      final file = stage.fileOrNull('manifest.json');
      if (file != null) {
        VmBundleManifest? origin;
        try {
          final bytes = await file.readBounded(1024 * 1024);
          try {
            origin = VmBundleManifest.fromJson(jsonDecode(utf8.decode(bytes)));
          } on FormatException {
            // A process may exit while writing its initial staging manifest.
            // Cleanup is bounded to this job's exact private directory/layout;
            // unknown entries and symlinks still cause removal to fail closed.
          }
        } finally {
          file.close();
        }
        if (origin != null && origin.digest != manifest.digest) {
          throw const FormatException(
            'staging belongs to a different provisioning plan',
          );
        }
      }
    } finally {
      stage.close();
    }
    await _removeOwnedTree(_stageName);
  }

  Future<void> _verifyPublished(
    OwnedImageDirectory root,
    bool Function()? cancelled,
  ) async {
    await _verifyOrigin(root);
    for (final name in _directories) {
      root.directory(name).close();
    }
    final disks = root.directory('disks');
    try {
      for (final disk in manifest.plan.disks) {
        final source = disk.source;
        if (source is VmProvisioningManagedDisk) {
          final file = disks.file('${disk.id}.raw');
          try {
            await _verify(
              file,
              source.image.sizeBytes,
              source.image.objectDigest,
              cancelled,
            );
          } finally {
            file.close();
          }
        } else if (source is VmProvisioningExternalDisk) {
          await _validateExternal(source);
        }
      }
    } finally {
      disks.close();
    }
    for (final image in [manifest.plan.kernel, manifest.plan.initrd].nonNulls) {
      final file = _openImage(image);
      try {
        await _verify(file, image.sizeBytes, image.objectDigest, cancelled);
      } finally {
        file.close();
      }
    }
    _checkCancelled(cancelled);
    await _store._bundles.sync();
  }

  Future<void> _verifyOrigin(OwnedImageDirectory root) async {
    final file = root.file('manifest.json');
    try {
      final origin = VmBundleManifest.fromJson(
        jsonDecode(utf8.decode(await file.readBounded(1024 * 1024))),
      );
      if (origin.digest != manifest.digest) {
        throw const FormatException(
          'published bundle belongs to a different provisioning plan',
        );
      }
    } finally {
      file.close();
    }
  }

  Future<void> _removeOwnedTree(String name) async {
    final root = _store._bundles.directoryOrNull(name);
    if (root == null) return;
    try {
      final disks = root.directoryOrNull('disks');
      if (disks != null) {
        try {
          for (final disk in manifest.plan.disks) {
            if (disk.source is VmProvisioningManagedDisk) {
              _removeFileIfPresent(disks, '${disk.id}.raw');
            }
          }
          await disks.sync();
        } finally {
          disks.close();
        }
      }
      for (final childName in _directories) {
        final child = root.directoryOrNull(childName);
        if (child == null) continue;
        child.close();
        root.removeDirectory(childName);
      }
      _removeFileIfPresent(root, 'manifest.json');
      _store._onCheckpoint?.call(VmBundleCheckpoint.cleanupContentsRemoved);
      await root.sync();
    } finally {
      root.close();
    }
    _store._bundles.removeDirectory(name);
    await _store._bundles.sync();
  }

  OwnedImageFile _openImage(VmProvisioningImageObject image) {
    final root = _store._images.directory(
      'sha256-${image.imageDigest.substring(7)}',
    );
    try {
      final objects = root.directory('objects');
      try {
        return objects.file(image.objectName);
      } finally {
        objects.close();
      }
    } finally {
      root.close();
    }
  }

  void _requireActive() {
    if (!_active) throw StateError('VM bundle session is closed');
    _store._requireOutsideTransaction();
  }
}

Future<void> _validateExternal(VmProvisioningExternalDisk source) async {
  final path = File(source.path);
  if (!path.isAbsolute) {
    throw const FormatException('external disk must use an absolute host path');
  }
  final file = await OwnedImageFile.open(path);
  try {
    if (file.size < 1) throw const FormatException('external disk is empty');
  } finally {
    file.close();
  }
}

const _directories = ['disks', 'logs', 'artifacts', 'runtime', 'nvram'];

void _removeFileIfPresent(OwnedImageDirectory directory, String name) {
  final file = directory.fileOrNull(name);
  if (file == null) return;
  file.close();
  directory.removeFile(name);
}

void _checkCancelled(bool Function()? cancelled) {
  if (cancelled?.call() ?? false) throw const ManagedDiskCancelled();
}

Future<void> _verify(
  OwnedImageFile file,
  int size,
  String digest,
  bool Function()? cancelled,
) async {
  if (file.size != size)
    throw const FormatException('bundle object size mismatch');
  var read = 0;
  final actual = await sha256
      .bind(
        file.openRead().map((chunk) {
          _checkCancelled(cancelled);
          read += chunk.length;
          if (read > size)
            throw const FormatException('bundle object grew while reading');
          return chunk;
        }),
      )
      .first;
  _checkCancelled(cancelled);
  if (read != size || 'sha256:$actual' != digest) {
    throw const FormatException('bundle object digest mismatch');
  }
}
