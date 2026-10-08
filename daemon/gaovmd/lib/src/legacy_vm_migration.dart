import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gaovm_models/gaovm_models.dart';

import 'daemon_ownership.dart';
import 'event_repository.dart';
import 'image_filesystem.dart';
import 'image_manifest.dart';
import 'image_store.dart';
import 'operation_repository.dart';
import 'persistence_timestamp.dart';
import 'sqlite_database.dart';
import 'vm_bundle_store.dart';
import 'vm_provisioning_plan.dart';
import 'vm_provisioning_repository.dart';
import 'vm_provisioning_work_repository.dart';
import 'vm_repository.dart';

const _key = 'legacy-single-vm-v1';
const _backupName = 'legacy-v1-backup';
const _stageName = '.legacy-v1-backup-stage';
const _ownerMarker = '.gaovm-legacy-backup-owner';
const _legacyFiles = [
  'config.json',
  'pending_config.json',
  'desired_state.json',
  'daemon_state.json',
];

enum LegacyMigrationCheckpoint {
  backupPublished,
  assetsImported,
  catalogAccepted,
  bundlePublished,
  completed,
}

/// Startup-only adapter. The caller must first finish native driver census and
/// previous-owner teardown, and must not activate other workers/public clients
/// until this returns. Never trusts a PID or observed state from legacy JSON.
/// The caller owns the roots and keeps daemon ownership through all IO/commits.
final class LegacyVmMigration {
  const LegacyVmMigration({
    required this.database,
    required this.state,
    required this.bundles,
    required this.images,
    required this.ownership,
    void Function(LegacyMigrationCheckpoint)? onCheckpoint,
  }) : _onCheckpoint = onCheckpoint;
  final GaoVmDatabase database;
  final OwnedImageDirectory state;
  final OwnedImageDirectory bundles;
  final OwnedImageDirectory images;
  final DaemonOwnership ownership;
  // Synchronous observer for diagnostic/process-crash fault injection only.
  final void Function(LegacyMigrationCheckpoint)? _onCheckpoint;

  Future<VirtualMachine?> migrate() async {
    if (database.hasActiveCallerTransaction) {
      throw StateError('legacy migration must own its commit boundaries');
    }
    if (ownership.stateDirectoryPath != state.path) {
      throw StateError(
        'migration ownership belongs to another state directory',
      );
    }
    await ownership.verify();
    final lock = await state.acquireLock('.legacy-v1-migration.lock');
    try {
      await ownership.verify();
      var record = await _record();
      final catalog = SqliteVmRepository(database);
      if (record?.completed == true) {
        final vm = await catalog.get(record!.vmId, includeDeleted: true);
        if (vm == null) throw StateError('completed migration lost its VM');
        return vm;
      }
      final backup = await _backup();
      if (backup == null) {
        if (record != null) {
          throw StateError('incomplete migration lost its backup and inputs');
        }
        return null;
      }
      if (record == null) {
        await _verifyOriginals(backup);
        final spec = await _spec(backup);
        _onCheckpoint?.call(LegacyMigrationCheckpoint.assetsImported);
        final desiredFile = backup.files['desired_state.json'];
        final desired = desiredFile == null
            ? 'stopped'
            : _object(desiredFile)['desired'];
        if (desired != 'stopped' && desired != 'running') {
          throw const FormatException('invalid legacy desired state');
        }
        await ownership.verify();
        await _verifyOriginals(backup);
        record = await database.transaction((db) async {
          final vm = await catalog.create(name: 'migrated-default', spec: spec);
          final operation = await SqliteOperationRepository(database).create(
            type: 'vm.create',
            resourceType: ResourceType.virtualMachine,
            resourceId: vm.metadata.id,
            requestId: RequestId.generate(),
            cancellable: true,
            request: JsonObjectValue.fromJson({'spec_generation': 1}),
          );
          final plan = await SqliteVmProvisioningPlanner(database).plan(
            vmId: vm.metadata.id,
            operationId: operation.id,
            specGeneration: 1,
          );
          await SqliteVmProvisioningRepository(database).accept(plan);
          db.execute(
            '''
            INSERT INTO legacy_vm_migrations(
              migration_key, vm_id, operation_id, backup_digest, desired_state
            ) VALUES (?, ?, ?, ?, ?)
          ''',
            [
              _key,
              vm.metadata.id.value,
              operation.id.value,
              backup.digest,
              desired,
            ],
          );
          return _MigrationRecord(
            vm.metadata.id,
            operation.id,
            backup.digest,
            desired as String,
            false,
          );
        });
        _onCheckpoint?.call(LegacyMigrationCheckpoint.catalogAccepted);
      } else if (record.backupDigest != backup.digest) {
        throw const FormatException(
          'legacy backup disagrees with migration checkpoint',
        );
      }
      final retained = record!;
      var job = (await SqliteVmProvisioningRepository(
        database,
      ).get(retained.vmId))!;
      if (job.completion == null) {
        // Exclusive daemon ownership and the migration namespace lock fence the
        // previous startup. No runtime worker is active at this boundary.
        await ownership.verify();
        await database.transaction((db) {
          db.execute(
            '''
            UPDATE outbox SET claimed_by = NULL, claim_expires_at = NULL
            WHERE topic = ? AND key = ? AND published_at IS NULL
          ''',
            [vmProvisioningOutboxTopic, retained.operationId.value],
          );
        });
        final work = SqliteVmProvisioningWorkRepository(database);
        final claims = await work.claim(
          owner: RequestId.generate().value,
          lease: const Duration(minutes: 5),
          operationId: retained.operationId,
          limit: 1,
        );
        if (claims.length != 1)
          throw StateError('migration provisioning claim unavailable');
        final claim = claims.single;
        try {
          await VmBundleStore(
            database: database,
            bundles: bundles,
            images: images,
          ).withBundle(claim.plan, (bundle) async {
            final manifest = await bundle.publish();
            _onCheckpoint?.call(LegacyMigrationCheckpoint.bundlePublished);
            await ownership.verify();
            if (!await work.completePublished(
              claim,
              manifestDigest: manifest.digest,
            )) {
              throw StateError('migration provisioning lease expired');
            }
          });
        } finally {
          await work.release(claim);
        }
        job = (await SqliteVmProvisioningRepository(
          database,
        ).get(retained.vmId))!;
      }
      if (job.completion?.kind != VmProvisioningCompletionKind.succeeded) {
        throw StateError('legacy VM provisioning did not succeed');
      }
      await ownership.verify();
      await database.transaction((db) async {
        final timestamp = formatPersistenceTimestamp(DateTime.now());
        db.execute('UPDATE vm_runtime SET desired_state = ? WHERE vm_id = ?', [
          retained.desired,
          retained.vmId.value,
        ]);
        db.execute(
          'UPDATE legacy_vm_migrations SET completed_at = ? WHERE migration_key = ?',
          [timestamp, _key],
        );
        await SqliteEventRepository(database).append(
          type: 'vm.legacy_migrated',
          resourceType: ResourceType.virtualMachine,
          resourceId: retained.vmId,
          vmId: retained.vmId,
          operationId: retained.operationId,
          payload: JsonObjectValue.fromJson({
            'legacy_alias': 'default',
            'backup_digest': retained.backupDigest,
            'desired_state': retained.desired,
          }),
        );
      });
      _onCheckpoint?.call(LegacyMigrationCheckpoint.completed);
      return catalog.get(retained.vmId);
    } finally {
      lock.close();
    }
  }

  Future<_MigrationRecord?> _record() => database.read((db) {
    final rows = db.select(
      'SELECT * FROM legacy_vm_migrations WHERE migration_key = ?',
      [_key],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return _MigrationRecord(
      VmId(row['vm_id'] as String),
      OperationId(row['operation_id'] as String),
      row['backup_digest'] as String,
      row['desired_state'] as String,
      row['completed_at'] != null,
    );
  });

  Future<_LegacyBackup?> _backup() async {
    final existing = state.directoryOrNull(_backupName);
    if (existing != null) {
      try {
        return await _readBackup(existing);
      } finally {
        existing.close();
      }
    }
    final files = <String, List<int>>{};
    for (final name in _legacyFiles) {
      final input = state.fileOrNull(name);
      if (input == null) continue;
      try {
        files[name] = await input.readBounded(1024 * 1024);
        await input.verifyPathBinding();
      } finally {
        input.close();
      }
    }
    if (files.isEmpty) return null;
    final configuration = files['pending_config.json'] ?? files['config.json'];
    if (configuration == null) {
      throw const FormatException('legacy VM configuration is missing');
    }
    final boot = _object(configuration)['boot'];
    if (boot is! Map) {
      throw const FormatException('legacy boot configuration is missing');
    }
    final bootSources = {
      'kernel': await _LegacyBootSource.capture(boot['kernelPath']),
      if (boot['initrdPath'] != null)
        'initrd': await _LegacyBootSource.capture(boot['initrdPath']),
    };
    final backup = _LegacyBackup(files, bootSources);
    final abandoned = state.directoryOrNull(_stageName);
    if (abandoned != null) {
      try {
        await abandoned.verifyPathBinding();
        final entries = await Directory(
          abandoned.path,
        ).list(followLinks: false).toList();
        final marker = abandoned.directoryOrNull(_ownerMarker);
        if (marker == null && entries.isNotEmpty) {
          throw StateError('unowned legacy migration staging directory');
        }
        if (marker != null) {
          try {
            if (await Directory(marker.path).list(followLinks: false).isEmpty ==
                false) {
              throw StateError(
                'legacy migration ownership marker is not empty',
              );
            }
            await marker.verifyPathBinding();
          } finally {
            marker.close();
          }
        }
        for (final entry in entries) {
          final name = entry.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last;
          if (name == _ownerMarker) continue;
          if (!_legacyFiles.contains(name) && name != 'manifest.json') {
            throw const FormatException('unknown migration staging entry');
          }
          final owned = abandoned.file(name);
          owned.close();
        }
        await abandoned.verifyPathBinding();
        for (final name in [..._legacyFiles, 'manifest.json']) {
          final owned = abandoned.fileOrNull(name);
          if (owned != null) {
            owned.close();
            abandoned.removeFile(name);
          }
        }
        if (marker != null) abandoned.removeDirectory(_ownerMarker);
        await abandoned.sync();
        state.removeDirectory(_stageName);
        await state.sync();
      } finally {
        abandoned.close();
      }
    }
    final stage = state.createDirectory(_stageName);
    try {
      stage.createDirectory(_ownerMarker).close();
      await stage.sync();
      await state.sync();
      for (final entry in files.entries) {
        await _write(stage, entry.key, entry.value);
      }
      await _write(
        stage,
        'manifest.json',
        utf8.encode(canonicalImageJson(backup.manifest)),
      );
      await stage.sync();
      await _verifyOriginals(backup);
      await ownership.verify();
      await state.renameDirectoryNoReplace(_stageName, _backupName);
      _onCheckpoint?.call(LegacyMigrationCheckpoint.backupPublished);
      return backup;
    } finally {
      stage.close();
    }
  }

  Future<_LegacyBackup> _readBackup(OwnedImageDirectory directory) async {
    final marker = directory.directory(_ownerMarker);
    try {
      if (!await Directory(marker.path).list(followLinks: false).isEmpty) {
        throw StateError('legacy backup ownership marker is not empty');
      }
      await marker.verifyPathBinding();
    } finally {
      marker.close();
    }
    final manifestFile = directory.file('manifest.json');
    late Map<String, Object?> manifest;
    try {
      manifest = _object(await manifestFile.readBounded(1024 * 1024));
    } finally {
      manifestFile.close();
    }
    final files = <String, List<int>>{};
    for (final name in _legacyFiles) {
      final input = directory.fileOrNull(name);
      if (input != null) {
        try {
          files[name] = await input.readBounded(1024 * 1024);
          await input.verifyPathBinding();
        } finally {
          input.close();
        }
      }
    }
    final sources = manifest['boot_sources'];
    if (sources is! Map ||
        !sources.containsKey('kernel') ||
        sources.keys.any((key) => key != 'kernel' && key != 'initrd')) {
      throw const FormatException('invalid legacy boot source manifest');
    }
    final backup = _LegacyBackup(files, {
      for (final entry in sources.entries)
        entry.key as String: _LegacyBootSource.fromJson(entry.value),
    });
    if (canonicalImageJson(manifest) != canonicalImageJson(backup.manifest)) {
      throw const FormatException('legacy backup manifest or bytes changed');
    }
    await directory.verifyPathBinding();
    return backup;
  }

  Future<void> _verifyOriginals(_LegacyBackup backup) async {
    final files = <String, List<int>>{};
    for (final name in _legacyFiles) {
      final input = state.fileOrNull(name);
      if (input != null) {
        try {
          files[name] = await input.readBounded(1024 * 1024);
          await input.verifyPathBinding();
        } finally {
          input.close();
        }
      }
    }
    if (_LegacyBackup(files, backup.bootSources).digest != backup.digest) {
      throw const FormatException(
        'legacy files changed since backup; migration not committed',
      );
    }
  }

  Future<VmSpec> _spec(_LegacyBackup backup) async {
    final configuration =
        backup.files['pending_config.json'] ?? backup.files['config.json'];
    if (configuration == null)
      throw const FormatException('legacy VM configuration is missing');
    final config = _object(configuration);
    if (config.length != 6 ||
        !config.keys.toSet().containsAll({
          'cpu',
          'memory',
          'boot',
          'disk',
          'network',
          'graphics',
        })) {
      throw const FormatException('unsupported legacy configuration fields');
    }
    final boot = Map<String, Object?>.from(config['boot'] as Map);
    if (boot['loader'] != 'linux' && boot['loader'] != 'auto') {
      throw const FormatException(
        'legacy migration requires a Linux kernel boot configuration',
      );
    }
    Future<File> source(Object? value) async {
      if (value is! String || !File(value).isAbsolute) {
        throw const FormatException(
          'legacy asset paths must be absolute and configured',
        );
      }
      final owned = await OwnedImageFile.open(File(value));
      try {
        if (owned.size == 0)
          throw const FormatException('legacy assets must not be empty');
        await owned.verifyPathBinding();
        return File(owned.path);
      } finally {
        owned.close();
      }
    }

    final store = ImageStore(database, Directory(images.path));
    Future<Image> importBootAsset(
      String role,
      Object? path,
      ImageType type,
    ) async {
      final pin = backup.bootSources[role];
      final input = await source(path);
      if (pin == null ||
          input.path != pin.path ||
          await input.length() != pin.sizeBytes) {
        throw const FormatException('legacy boot source changed since backup');
      }
      return store.importFile(
        input,
        type: type,
        expectedObjectDigest: pin.digest,
      );
    }

    final kernel = await importBootAsset(
      'kernel',
      boot['kernelPath'],
      ImageType.linuxKernel,
    );
    final initrd = boot['initrdPath'] == null
        ? null
        : await importBootAsset('initrd', boot['initrdPath'], ImageType.initrd);
    final disk = await source((config['disk'] as Map)['path']);
    final mode = (config['network'] as Map)['mode'];
    final network = switch (mode) {
      'shared' => SharedNetwork(id: 'net0'),
      'none' => DisconnectedNetwork(id: 'net0'),
      _ => throw const FormatException('unsupported legacy network mode'),
    };
    final graphics = config['graphics'] as Map;
    return VmSpec(
      cpu: config['cpu'] as int,
      memoryBytes: config['memory'] as int,
      boot: LinuxKernelBoot(
        kernelImageId: kernel.id,
        initrdImageId: initrd?.id,
        commandLine: boot['commandLine'] as String? ?? '',
      ),
      disks: [
        VmDisk(
          id: 'root',
          source: ExternalDiskSource(disk.path),
          writable: true,
        ),
      ],
      networks: [network],
      graphics: GraphicsConfig(
        enabled: graphics['enabled'] as bool,
        width: graphics['width'] as int,
        height: graphics['height'] as int,
      ),
      serial: const SerialConfig(enabled: true, capture: true),
      guestAgent: GuestAgentConfig(enabled: false, requiredForReady: false),
      restartPolicy: RestartPolicy.onFailure,
    );
  }
}

final class _MigrationRecord {
  const _MigrationRecord(
    this.vmId,
    this.operationId,
    this.backupDigest,
    this.desired,
    this.completed,
  );
  final VmId vmId;
  final OperationId operationId;
  final String backupDigest;
  final String desired;
  final bool completed;
}

// Opaque historic JSON lives only at this serialization/file-copy boundary.
final class _LegacyBackup {
  const _LegacyBackup(this.files, this.bootSources);
  final Map<String, List<int>> files;
  final Map<String, _LegacyBootSource> bootSources;
  String get digest => contentDigest(_unsigned);
  Map<String, Object?> get _unsigned => {
    'migration_version': 1,
    'boot_sources': {
      for (final entry in bootSources.entries) entry.key: entry.value.toJson(),
    },
    'files': {
      for (final name in _legacyFiles)
        name: files[name] == null
            ? null
            : {
                'sha256': sha256.convert(files[name]!).toString(),
                'size_bytes': files[name]!.length,
              },
    },
  };
  Map<String, Object?> get manifest => {..._unsigned, 'digest': digest};
}

final class _LegacyBootSource {
  const _LegacyBootSource(this.path, this.digest, this.sizeBytes);
  final String path;
  final String digest;
  final int sizeBytes;

  static Future<_LegacyBootSource> capture(Object? value) async {
    if (value is! String || !File(value).isAbsolute) {
      throw const FormatException('legacy boot paths must be absolute');
    }
    final input = await OwnedImageFile.open(File(value));
    try {
      if (input.size == 0) {
        throw const FormatException('legacy boot assets must not be empty');
      }
      var read = 0;
      final digest = await sha256
          .bind(
            input.openRead().map((chunk) {
              read += chunk.length;
              return chunk;
            }),
          )
          .first;
      await input.verifyPathBinding();
      if (read != input.size) {
        throw const FormatException('legacy boot asset changed while hashing');
      }
      return _LegacyBootSource(input.path, 'sha256:$digest', input.size);
    } finally {
      input.close();
    }
  }

  factory _LegacyBootSource.fromJson(Object? value) {
    if (value is! Map ||
        value.length != 3 ||
        value['path'] is! String ||
        !File(value['path'] as String).isAbsolute ||
        value['digest'] is! String ||
        !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(value['digest'] as String) ||
        value['size_bytes'] is! int ||
        (value['size_bytes'] as int) <= 0) {
      throw const FormatException('invalid legacy boot source');
    }
    return _LegacyBootSource(
      value['path'] as String,
      value['digest'] as String,
      value['size_bytes'] as int,
    );
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'digest': digest,
    'size_bytes': sizeBytes,
  };
}

Map<String, Object?> _object(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map)
    throw const FormatException('legacy file must contain a JSON object');
  return Map<String, Object?>.from(decoded);
}

Future<void> _write(
  OwnedImageDirectory parent,
  String name,
  List<int> bytes,
) async {
  final output = parent.createFile(name);
  try {
    final writer = await output.openWrite();
    try {
      await writer.writeFrom(bytes);
      await writer.flush();
    } finally {
      await writer.close();
    }
  } finally {
    output.close();
  }
}
