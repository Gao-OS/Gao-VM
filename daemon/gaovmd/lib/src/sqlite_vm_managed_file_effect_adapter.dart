import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'image_filesystem.dart';
import 'image_manifest.dart';
import 'sqlite_database.dart';
import 'vm_bundle_manifest.dart';
import 'vm_controller_reducer.dart';
import 'vm_effect_runner.dart';
import 'vm_provisioning_repository.dart';
import 'vm_provisioning_plan.dart';

/// Deletes only a completed provisioning job's owned files. The controller and
/// startup barrier must prove driver exit before reaching this effect.
final class SqliteVmManagedFileEffectAdapter
    implements VmManagedFileEffectAdapter {
  const SqliteVmManagedFileEffectAdapter({
    required GaoVmDatabase database,
    required OwnedImageDirectory bundles,
  }) : _database = database,
       _bundles = bundles;

  final GaoVmDatabase _database;
  final OwnedImageDirectory _bundles;

  @override
  Future<void> remove(VmControllerState state, OperationId operationId) async {
    if (_database.hasActiveCallerTransaction) {
      throw StateError('managed deletion IO must be outside a transaction');
    }
    final operation = state.currentOperation;
    if (state.desiredState != DesiredState.stopped ||
        state.phase != VmPhase.deleting ||
        state.deletionState != VmDeletionState.removingFiles ||
        state.activeDriverGeneration != null ||
        state.leaseState != VmLeaseState.none ||
        operation?.id != operationId ||
        operation!.kind != VmOperationKind.delete ||
        operation.isTerminal) {
      throw StateError(
        'managed deletion requires a stopped, lease-free delete',
      );
    }
    final lock = await _bundles.acquireLock('.lock-${state.vmId.value}');
    try {
      await _bundles.verifyPathBinding();
      if (_bundles.mode & 0x3f != 0)
        throw StateError('bundle root must be private');
      final input = await _load(state, operationId);
      final manifest = input.manifest;
      final leaves = _leaves(manifest, managedEfi: input.managedEfi);
      final publicName = '${state.vmId.value}.gaovm';
      final quarantineName =
          '.deleting-${state.vmId.value}-${manifest.plan.operationId.value}';
      var public = _bundles.directoryOrNull(publicName);
      var quarantine = _bundles.directoryOrNull(quarantineName);
      try {
        if (public != null && quarantine != null) {
          throw StateError('both public and deletion bundles exist');
        }
        if (public != null) {
          await _inspect(public, manifest, leaves, allowEmpty: false);
          public.close();
          public = null;
          await _bundles.renameDirectoryNoReplace(publicName, quarantineName);
          quarantine = _bundles.directory(quarantineName);
        }
        if (quarantine == null) return;
        await _inspect(quarantine, manifest, leaves, allowEmpty: true);
        for (final entry in leaves.entries) {
          final child = quarantine.directoryOrNull(entry.key);
          if (child == null) continue;
          try {
            for (final leaf in entry.value) {
              final file = child.fileOrNull(leaf);
              if (file == null) continue;
              file.close();
              child.removeFile(leaf);
            }
            await child.sync();
          } finally {
            child.close();
          }
          quarantine.removeDirectory(entry.key);
        }
        final origin = quarantine.fileOrNull('manifest.json');
        if (origin != null) {
          origin.close();
          quarantine.removeFile('manifest.json');
        }
        await quarantine.sync();
        quarantine.close();
        quarantine = null;
        _bundles.removeDirectory(quarantineName);
        await _bundles.sync();
      } finally {
        public?.close();
        quarantine?.close();
      }
    } finally {
      lock.close();
    }
  }

  Future<({VmBundleManifest manifest, bool managedEfi})> _load(
    VmControllerState state,
    OperationId id,
  ) => _database.transaction((db) async {
    final rows = db.select(
      '''
          SELECT 1 FROM vms v JOIN vm_runtime r ON r.vm_id = v.id
          JOIN operations o ON o.id = r.active_operation_id
          WHERE v.id = ? AND v.deleting_at IS NOT NULL AND v.deleted_at IS NULL
            AND v.intent_revision = ? AND r.applied_intent_revision = ?
            AND r.phase = 'deleting' AND r.desired_state = 'stopped'
            AND r.execution_desired_state = 'stopped' AND r.driver_generation = ?
            AND r.execution_spec_generation = ?
            AND o.id = ? AND o.type IN ('vm.delete', 'vm.delete.recovery')
            AND o.resource_type = 'virtual_machine' AND o.resource_id = v.id
            AND o.state = 'running'
            AND NOT EXISTS (SELECT 1 FROM resource_leases l WHERE l.resource_id = v.id)
            AND NOT EXISTS (SELECT 1 FROM artifacts a WHERE a.vm_id = v.id)
        ''',
      [
        state.vmId.value,
        state.appliedIntentRevision,
        state.appliedIntentRevision,
        state.driverGeneration,
        state.specGeneration,
        id.value,
      ],
    );
    if (rows.length != 1) {
      throw StateError(
        'delete checkpoint, lease or artifact retention prevents managed cleanup',
      );
    }
    final job = await SqliteVmProvisioningRepository(_database).get(state.vmId);
    if (job?.completion?.kind != VmProvisioningCompletionKind.succeeded) {
      throw StateError(
        'managed deletion requires successful provisioning origin proof',
      );
    }
    final plan = job!.plan;
    final origins = db.select(
      'SELECT spec_json FROM vm_specs WHERE vm_id = ? AND generation = ?',
      [state.vmId.value, plan.specGeneration],
    );
    if (origins.length != 1)
      throw StateError('original provisioning spec is missing');
    final spec = VmSpec.fromJson(
      jsonDecode(origins.single['spec_json'] as String),
    );
    if (contentDigest(spec.toJson()) != plan.specDigest) {
      throw StateError('original spec disagrees with provisioning digest');
    }
    return (
      manifest: VmBundleManifest.create(plan),
      managedEfi:
          spec.boot is EfiBoot &&
          (spec.boot as EfiBoot).variableStore == EfiVariableStore.managed,
    );
  });

  Map<String, Set<String>> _leaves(
    VmBundleManifest manifest, {
    required bool managedEfi,
  }) => {
    'disks': {
      for (final disk in manifest.plan.disks)
        if (disk.source is VmProvisioningManagedDisk) '${disk.id}.raw',
    },
    'logs': {
      for (final log in ['driver.log', 'serial.log']) ...[
        log,
        for (var i = 1; i <= 3; i++) '$log.$i',
      ],
    },
    // Artifact removal requires a separate retention-aware authority.
    'artifacts': {},
    'runtime': {},
    'nvram': {if (managedEfi) 'efi-variable-store'},
  };

  Future<void> _inspect(
    OwnedImageDirectory root,
    VmBundleManifest manifest,
    Map<String, Set<String>> leaves, {
    required bool allowEmpty,
  }) async {
    await root.verifyPathBinding();
    if (root.mode & 0x3f != 0) throw StateError('bundle must be private');
    final names = await _names(root);
    final origin = root.fileOrNull('manifest.json');
    if (origin == null) {
      if (allowEmpty && names.isEmpty) return;
      throw StateError('bundle deletion origin proof is missing');
    }
    try {
      final actual = VmBundleManifest.fromJson(
        jsonDecode(utf8.decode(await origin.readBounded(1024 * 1024))),
      );
      if (actual.digest != manifest.digest)
        throw StateError('bundle origin mismatch');
    } finally {
      origin.close();
    }
    if (names.any(
      (name) => name != 'manifest.json' && !leaves.containsKey(name),
    )) {
      throw StateError('unknown bundle content prevents deletion');
    }
    for (final entry in leaves.entries) {
      final child = root.directoryOrNull(entry.key);
      if (child == null) continue;
      try {
        if (child.mode & 0x3f != 0)
          throw StateError('bundle child must be private');
        for (final name in await _names(child)) {
          if (!entry.value.contains(name))
            throw StateError('unproven ${entry.key} content prevents deletion');
          child
              .file(name)
              .close(); // Reject symlinks and special files before removal.
        }
      } finally {
        child.close();
      }
    }
    await root.verifyPathBinding();
  }

  Future<Set<String>> _names(OwnedImageDirectory directory) async {
    await directory.verifyPathBinding();
    final result = <String>{};
    await for (final entry in Directory(
      directory.path,
    ).list(followLinks: false)) {
      if (result.length >= 4096)
        throw StateError('bundle discovery limit exceeded');
      result.add(entry.uri.pathSegments.where((part) => part.isNotEmpty).last);
    }
    await directory.verifyPathBinding();
    return result;
  }
}
