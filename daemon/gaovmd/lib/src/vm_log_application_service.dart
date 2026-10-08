import 'dart:convert';
import 'dart:io';

import 'package:gaovm_models/gaovm_models.dart';

import 'image_filesystem.dart';
import 'sqlite_database.dart';
import 'vm_bundle_manifest.dart';
import 'vm_provisioning_repository.dart';
import 'vm_repository.dart';

/// A bounded, read-only view of current log files. Immutable captured payloads
/// remain artifacts; a GET never snapshots or publishes a mutable log.
final class VmLogApplicationService {
  const VmLogApplicationService({
    required GaoVmDatabase database,
    required OwnedImageDirectory bundles,
  }) : _database = database,
       _bundles = bundles;

  final GaoVmDatabase _database;
  final OwnedImageDirectory _bundles;

  Future<List<LogReference>> listForVm(VmId id, {LogKind? kind}) async {
    if (await SqliteVmRepository(_database).get(id) == null) {
      throw VmNotFoundException(id);
    }
    final job = await SqliteVmProvisioningRepository(_database).get(id);
    await _bundles.verifyPathBinding();
    if (_bundles.mode & 0x1ff != 0x1c0) {
      throw FileSystemException(
        'VM bundle root must be private',
        _bundles.path,
      );
    }
    final bundle = _bundles.directoryOrNull('${id.value}.gaovm');
    if (bundle == null) {
      if (job?.completion?.kind == VmProvisioningCompletionKind.succeeded) {
        throw const FileSystemException('published VM bundle is missing');
      }
      return const [];
    }
    try {
      await _verifyDirectory(bundle);
      if (job == null)
        throw const FormatException('VM bundle origin is missing');
      final manifestFile = bundle.file('manifest.json');
      try {
        _verifyFile(manifestFile);
        final manifest = VmBundleManifest.fromJson(
          jsonDecode(utf8.decode(await manifestFile.readBounded(1024 * 1024))),
        );
        if (manifest.digest != VmBundleManifest.create(job.plan).digest) {
          throw const FormatException('VM bundle origin differs from catalog');
        }
        await manifestFile.verifyPathBinding();
      } finally {
        manifestFile.close();
      }
      final logs = bundle.directoryOrNull('logs');
      if (logs == null) return const [];
      try {
        await _verifyDirectory(logs);
        final items = <LogReference>[];
        for (final candidate in kind == null ? LogKind.values : [kind]) {
          final file = logs.fileOrNull('${candidate.name}.log');
          if (file == null) continue;
          try {
            final stat = _verifyFile(file);
            await file.verifyPathBinding();
            items.add(
              LogReference(
                kind: candidate,
                vmId: id,
                sizeBytes: stat.size,
                updatedAt: stat.modifiedAt,
              ),
            );
          } finally {
            file.close();
          }
        }
        await _verifyDirectory(logs);
        await _verifyDirectory(bundle);
        await _bundles.verifyPathBinding();
        return List.unmodifiable(items);
      } finally {
        logs.close();
      }
    } finally {
      bundle.close();
    }
  }
}

Future<void> _verifyDirectory(OwnedImageDirectory directory) async {
  await directory.verifyPathBinding();
  if (directory.mode & 0x12 != 0) {
    throw FileSystemException(
      'VM log directory is writable by others',
      directory.path,
    );
  }
}

({int size, int mode, int linkCount, DateTime modifiedAt}) _verifyFile(
  OwnedImageFile file,
) {
  final stat = file.stat();
  if (stat.linkCount != 1 || stat.mode & 0x12 != 0) {
    throw FileSystemException(
      'VM log file must be exclusively owned',
      file.path,
    );
  }
  return stat;
}
