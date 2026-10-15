part of 'macos_cold_publication.dart';

/// Operator-established cold uninstall. Retires the exact app recoverably,
/// never deletes state/external bytes, and leaves ordinary startup fenced.
Future<Map<String, Object?>> runMacOsColdUninstall(
  List<String> arguments, {
  ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
  MacOsOpenReferences? observer,
  Future<DriverInventorySnapshot> Function(String)? inventory,
}) async {
  final options = _Options.parse(arguments, uninstall: true);
  final execution = _OwnedInspection(host);
  final references =
      observer ??
      MacOsOpenReferences(
        command: (path, args) =>
            _terminal(() => runMaintenanceCommand(path, args)),
      );
  final census =
      inventory ??
      (String path) =>
          MacOsDriverInventory(executablePath: path).snapshotForMaintenance();
  OwnedImageDirectory? work, scratch;
  OwnedImageLock? commandLock;
  MacOsColdStateHost? coldHost;
  ColdStateLease? lease;
  MaintenanceStateFence? fence;
  ColdStateSnapshot? snapshot;
  ColdUninstallPreparation? prepared;
  var stage = 'inputs';
  try {
    await options.verifyPaths();
    work = await OwnedImageDirectory.open(Directory(options.work));
    scratch = await OwnedImageDirectory.open(Directory(options.inspection));
    for (final directory in [work, scratch]) {
      await directory.verifyPathBinding();
      if (directory.mode & 0xfff != 0x1c0 ||
          (await directory.maintenanceMetadata())['has_acl'] != false) {
        throw const FormatException(
          'private 0700 work and inspection required',
        );
      }
    }
    await _entries(scratch, const {});
    await _entries(
      work,
      options.resuming ? _workEntries(options.from, uninstall: true) : const {},
    );
    commandLock = await work.tryAcquireMaintenanceLock(
      _uninstallCommandLock,
      create: !options.resuming,
    );
    if (commandLock == null) throw StateError('maintenance work already owned');
    final lockFile = work.file(_uninstallCommandLock);
    try {
      await lockFile.sync();
    } finally {
      lockFile.close();
    }
    await work.sync();
    await _verifyWork(work, commandLock, options.from, uninstall: true);
    final state = Directory(options.state);
    stage = 'cold';
    if (options.resuming) fence = await MaintenanceStateFence.open(state);
    coldHost = options.from == _retirement
        ? await MacOsColdStateHost.openRetired(
            Directory(options.app),
            state,
            fence!,
            work,
            _retirement,
            bundleIdentifier: options.bundle,
            version: options.oldVersion,
            teamIdentifier: options.team,
            catalogSchema: 0,
            host: execution,
            observer: references,
            inventory: census,
          )
        : await MacOsColdStateHost.open(
            Directory(options.app),
            bundleIdentifier: options.bundle,
            version: options.oldVersion,
            teamIdentifier: options.team,
            catalogSchema: 0,
            host: execution,
            observer: references,
            inventory: census,
          );
    await _verifyWork(work, commandLock, options.from, uninstall: true);
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: options.bundle,
      host: coldHost,
      maintenanceFence: fence,
    );
    stage = 'inspection';
    snapshot = await ColdStateSnapshot.prepare(
      lease,
      scratch,
      observer: references,
      inventory: census,
    );
    await _verifyWork(work, commandLock, options.from, uninstall: true);
    if (options.resuming &&
        options.catalogSchema != (snapshot.observedCatalogSchema ?? 0)) {
      throw const FormatException(
        'expected catalog schema disagrees with cold catalog',
      );
    }
    fence ??= await MaintenanceStateFence.begin(lease);
    stage = 'preparation';
    prepared = options.resuming
        ? await ColdUninstallPreparation.open(
            snapshot,
            fence,
            work,
            version: options.oldVersion,
            teamIdentifier: options.team,
            host: execution,
            observer: references,
          )
        : await ColdUninstallPreparation.create(
            snapshot,
            fence,
            work,
            version: options.oldVersion,
            teamIdentifier: options.team,
            host: execution,
            observer: references,
          );
    await _verifyWork(
      work,
      commandLock,
      options.from ?? _preparation,
      uninstall: true,
    );
    stage = 'retirement';
    final heldWork = work, heldLock = commandLock;
    final result = options.from == _retirement
        ? await prepared.observeRetiredApp()
        : await prepared.retireApp(
            verifyCommandWork: () =>
                _verifyWork(heldWork, heldLock, _retirement, uninstall: true),
          );
    await _verifyWork(work, commandLock, _retirement, uninstall: true);
    return {
      'format': 'gaovm.cold-uninstall-command.v1',
      'status': 'observed',
      'action': options.resuming ? 'resume-uninstall' : 'uninstall-app',
      ...result,
      'observed_catalog_schema': snapshot.observedCatalogSchema,
      'source_state': lease.path,
      'work_path': work.path,
      'inspection_path': scratch.path,
      'fence_path': fence.path,
      'ordinary_startup_fenced': true,
      'external_files_backed_up': false,
    };
  } catch (error) {
    throw ColdPublicationFailure(stage, error);
  } finally {
    prepared?.close();
    snapshot?.close();
    lease?.close();
    coldHost?.close();
    fence?.close();
    commandLock?.close();
    scratch?.close();
    work?.close();
  }
}
