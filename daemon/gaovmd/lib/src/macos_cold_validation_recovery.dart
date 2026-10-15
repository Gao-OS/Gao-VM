part of 'macos_cold_publication.dart';

/// Reopens only a complete sealed validation checkpoint. Runs outside the app,
/// without a validating-self exception, migration replay or ordinary startup.
Future<Map<String, Object?>> runMacOsColdValidationRecovery(
  List<String> arguments, {
  ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
  MacOsOpenReferences? observer,
  Future<DriverInventorySnapshot> Function(String)? inventory,
}) async {
  if (arguments.isEmpty || arguments.first != 'resume-validation') {
    throw const FormatException('explicit resume-validation action required');
  }
  final options = ColdMaintenanceOptions.parse([
    'resume-publication',
    ...arguments.skip(1),
    '--from',
    coldPublicationName,
  ]);
  final execution = OwnedColdInspection(host);
  final references =
      observer ??
      MacOsOpenReferences(
        command: (path, args) =>
            awaitColdCommandExit(() => runMaintenanceCommand(path, args)),
      );
  final census =
      inventory ??
      (String path) =>
          MacOsDriverInventory(executablePath: path).snapshotForMaintenance();
  OwnedImageDirectory? work, scratch;
  OwnedImageLock? commandLock;
  MaintenanceStateFence? fence;
  ColdValidationCheckpoint? checkpoint;
  MacOsColdStateHost? coldHost;
  ColdStateLease? lease;
  ColdStateSnapshot? snapshot;
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
    await verifyColdEntries(scratch, const {});
    await verifyColdEntries(work, {
      ...coldWorkEntries(coldPublicationName),
      'validation',
    });
    commandLock = await work.tryAcquireMaintenanceLock(
      coldPublicationCommandLock,
      create: false,
    );
    if (commandLock == null) throw StateError('maintenance work already owned');
    await verifyColdWork(
      work,
      commandLock,
      coldPublicationName,
      candidateValidation: true,
    );
    final state = Directory(options.state);
    fence = await MaintenanceStateFence.open(state);
    stage = 'validation_checkpoint';
    checkpoint = await ColdValidationCheckpoint.open(
      work,
      fence,
      appPath: options.app,
      statePath: options.state,
      bundleIdentifier: options.bundle,
      oldVersion: options.oldVersion,
      newVersion: options.newVersion,
      teamIdentifier: options.team,
      sourceCatalogSchema: options.catalogSchema!,
    );
    stage = 'cold';
    coldHost = await MacOsColdStateHost.openPublished(
      Directory(options.app),
      state,
      fence,
      work,
      coldRetirementName,
      work,
      coldPublicationName,
      bundleIdentifier: options.bundle,
      oldVersion: options.oldVersion,
      newVersion: options.newVersion,
      teamIdentifier: options.team,
      retiredCatalogSchema: 0,
      catalogSchema: options.catalogSchema!,
      host: execution,
      observer: references,
      inventory: census,
    );
    await verifyColdWork(
      work,
      commandLock,
      coldPublicationName,
      candidateValidation: true,
    );
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: options.bundle,
      host: coldHost,
      maintenanceFence: fence,
    );
    stage = 'current_state';
    snapshot = await ColdStateSnapshot.prepare(
      lease,
      scratch,
      observer: references,
      inventory: census,
    );
    stage = 'retained_validation';
    final result = await checkpoint.recover(
      snapshot,
      work,
      coldHost,
      inspectionHost: execution,
      observer: references,
    );
    await verifyColdWork(
      work,
      commandLock,
      coldPublicationName,
      candidateValidation: true,
    );
    return {
      ...result,
      'status': 'observed',
      'action': 'resume-validation',
      'work_path': work.path,
      'inspection_path': scratch.path,
    };
  } catch (error) {
    throw ColdPublicationFailure(stage, error);
  } finally {
    // Original native child exits settle before any reader or lock is released.
    checkpoint?.close();
    snapshot?.close();
    lease?.close();
    coldHost?.close();
    fence?.close();
    commandLock?.close();
    scratch?.close();
    work?.close();
  }
}
