part of 'cold_catalog_inspection.dart';

/// A durable matching old-app/state pair, not an upgrade or restore command.
/// Holds only local readers; never closes the caller's original cold lease.
final class ColdUpgradeSnapshot {
  static Future<Map<String, Object?>> create(
    ColdStateLease state,
    OwnedImageDirectory inspection,
    OwnedImageDirectory parent,
    String name, {
    required String version,
    required String teamIdentifier,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) async {
    await state.verify();
    const lockName = '.gaovm-maintenance.lock';
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name == lockName ||
        name.contains('/') ||
        name.contains('\x00')) {
      throw ArgumentError.value(name, 'name');
    }
    final destination = '${parent.path}/$name';
    final stagingName = '.$name.partial';
    final stagingPath = '${parent.path}/$stagingName';
    for (final source in [state.path, state.appPath, inspection.path]) {
      if (parent.path == source ||
          parent.path.startsWith('$source/') ||
          [destination, stagingPath].any(
            (target) =>
                target == source ||
                target.startsWith('$source/') ||
                source.startsWith('$target/'),
          )) {
        throw const FormatException('paired snapshot storage overlaps inputs');
      }
    }
    await parent.verifyPathBinding();
    if (parent.mode & 0xc3f != 0 ||
        (await parent.maintenanceMetadata())['has_acl'] != false) {
      throw const FormatException('private paired snapshot storage required');
    }
    for (final child in [name, stagingName]) {
      final previous = parent.directoryOrNull(child);
      if (previous != null) {
        previous.close();
        throw const FormatException('paired snapshot output already exists');
      }
    }
    final previousLock = parent.fileOrNull(lockName);
    if (previousLock != null) {
      try {
        await previousLock.verifyPathBinding();
        final stat = previousLock.stat();
        if (stat.mode & 0xfff != 0x180 ||
            stat.size != 0 ||
            stat.linkCount != 1) {
          throw const FormatException('unrecognized snapshot namespace lock');
        }
      } finally {
        previousLock.close();
      }
    }
    final lock = await parent.tryAcquireLock(lockName);
    if (lock == null) throw StateError('snapshot storage already has an owner');
    ColdStateSnapshot? prepared;
    MaintenanceTree? app;
    OwnedImageDirectory? staging;
    try {
      prepared = await ColdStateSnapshot.prepare(
        state,
        inspection,
        observer: observer,
        inventory: inventory,
      );
      final schema = prepared._catalog?.schemaVersion;
      final release = await inspectMacOsRelease(
        Directory(state.appPath),
        bundleIdentifier: state.bundleIdentifier,
        version: version,
        teamIdentifier: teamIdentifier,
        catalogSchema: schema ?? 0,
        host: host,
      );
      app = await MaintenanceTree.open(Directory(state.appPath));
      await app.verify(release['tree'] as Map<String, Object?>);
      final appManifest = await app.capture(nativeMetadata: true);
      if (appManifest.values.cast<Map>().any(
        (entry) => (entry['metadata'] as Map)['has_acl'] != false,
      )) {
        throw const ColdStateFailure(
          'app_metadata',
          'app ACL grants require independent investigation',
        );
      }
      await app.verify(release['tree'] as Map<String, Object?>);
      final stateManifest = await prepared._capture();
      final heldApp = app;
      final heldState = prepared;
      final appReferences = observer ?? MacOsOpenReferences();
      Future<void> verifyAppReferences() async {
        if ((await appReferences.directory(
          Directory(heldApp.path),
        )).any((process) => process != pid)) {
          throw const ColdStateFailure(
            'app_references',
            'other app references remain',
          );
        }
      }

      Future<void> verifySources() async {
        await heldState.verify();
        await verifyAppReferences();
        await heldApp.verify(appManifest, nativeMetadata: true);
        await state.verify();
        await verifyAppReferences();
        if (jsonEncode(await heldState._capturePersistent()) !=
            jsonEncode(stateManifest)) {
          throw const FormatException('paired snapshot source state changed');
        }
        await heldApp.verify(appManifest, nativeMetadata: true);
      }

      await verifySources();
      var requiredBytes =
          1024 * 1024 +
          utf8.encode(jsonEncode(release)).length +
          utf8.encode(jsonEncode(await heldState._boundary())).length * 2;
      for (final manifest in [appManifest, stateManifest]) {
        requiredBytes += utf8.encode(jsonEncode(manifest)).length * 2;
        for (final entry in manifest.values.cast<Map<String, Object?>>()) {
          requiredBytes += ((entry['size'] as int?) ?? 0) + 4096;
          for (final value
              in ((entry['metadata'] as Map)['xattrs'] as Map).values
                  .cast<Map>()) {
            requiredBytes += value['size'] as int;
          }
        }
      }
      if (await parent.availableBytes() < requiredBytes) {
        throw const FormatException('insufficient paired snapshot space');
      }
      await parent.verifyPathBinding();
      lock.verifyPathBinding();
      staging = parent.createDirectory(stagingName);
      await staging.sync();
      await parent.sync();
      final appReceipt = await heldApp.snapshotTo(staging, 'app');
      await verifySources();
      final stateReceipt = await heldState.snapshotTo(staging, 'state');
      final receipt = <String, Object?>{
        'format': 'gaovm.cold-upgrade-snapshot.v1',
        'source_app': state.appPath,
        'source_state': state.path,
        'snapshot_path': destination,
        'catalog_schema': schema,
        'app_payload': 'app/payload.app',
        'state_payload': 'state/payload',
        'app_release': release,
        'app_receipt': appReceipt,
        'state_receipt': stateReceipt,
        'paired_app_snapshot': true,
        'external_files_backed_up': false,
        'candidate_publication_authorized': false,
        'replacement_startup_fenced': false,
        'rollback_authorized': false,
      };
      final encoded = utf8.encode('${jsonEncode(receipt)}\n');
      final record = staging.createFile('receipt.json');
      try {
        final writer = await record.openWrite();
        try {
          await writer.writeFrom(encoded);
          await writer.flush();
        } finally {
          await writer.close();
        }
        await record.seal();
      } finally {
        record.close();
      }
      await staging.sync();
      Future<void> verifyOutput(OwnedImageDirectory directory) async {
        await directory.verifyPathBinding();
        final names = await Directory(directory.path)
            .list(followLinks: false)
            .take(5)
            .map(
              (entry) => entry.uri.pathSegments.where((s) => s.isNotEmpty).last,
            )
            .toList();
        if (names.length != 4 ||
            !names.toSet().containsAll({
              'app',
              'state',
              'receipt.json',
              lockName,
            }) ||
            directory.mode & 0xfff != 0x1c0 ||
            (await directory.maintenanceMetadata())['has_acl'] != false) {
          throw const FormatException('paired snapshot wrapper changed');
        }
        final storageLock = directory.file(lockName);
        try {
          await storageLock.verifyPathBinding();
          final stat = storageLock.stat();
          if (stat.size != 0 ||
              stat.linkCount != 1 ||
              stat.mode & 0xfff != 0x180 ||
              (await storageLock.maintenanceMetadata())['has_acl'] != false) {
            throw const FormatException('paired snapshot storage lock changed');
          }
        } finally {
          storageLock.close();
        }
        for (final entry in {
          'app': appReceipt,
          'state': stateReceipt,
        }.entries) {
          final child = directory.directory(entry.key);
          try {
            await MaintenanceTree.verifySnapshotContents(child, entry.value);
          } finally {
            child.close();
          }
        }
        final record = directory.file('receipt.json');
        try {
          final stat = record.stat();
          if (stat.size != encoded.length ||
              stat.linkCount != 1 ||
              stat.mode & 0xfff != 0x100 ||
              (await record.maintenanceMetadata())['has_acl'] != false ||
              sha256
                      .convert(await record.readBounded(encoded.length))
                      .toString() !=
                  sha256.convert(encoded).toString()) {
            throw const FormatException('paired snapshot receipt changed');
          }
          await record.verifyPathBinding();
          if (record.stat() != stat) {
            throw const FormatException('paired receipt changed while reading');
          }
        } finally {
          record.close();
        }
        await directory.verifyPathBinding();
      }

      await verifySources();
      await verifyOutput(staging);
      await parent.verifyPathBinding();
      lock.verifyPathBinding();
      await parent.renameDirectoryNoReplace(stagingName, name);
      await verifySources();
      final published = parent.directory(name);
      try {
        await verifyOutput(published);
      } finally {
        published.close();
      }
      await parent.verifyPathBinding();
      lock.verifyPathBinding();
      return JsonObjectValue.fromJson(receipt).toJson();
    } catch (error) {
      if (staging != null) {
        throw MaintenanceSnapshotFailure(stagingPath, destination, error);
      }
      rethrow;
    } finally {
      staging?.close();
      app?.close();
      prepared?.close();
      lock.close();
    }
  }
}
