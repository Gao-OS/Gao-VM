part of 'macos_cold_publication.dart';

/// Explicit cold commit; never registers, starts or signals a service/VM.
Future<Map<String, Object?>> runMacOsColdCommit(
  List<String> arguments, {
  ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
  MacOsOpenReferences? observer,
  Future<DriverInventorySnapshot> Function(String)? inventory,
}) async {
  if (arguments.isEmpty ||
      !{'commit-upgrade', 'resume-commit'}.contains(arguments.first) ||
      arguments.where((value) => value == '--allow-startup').length != 1) {
    throw const FormatException(
      'explicit commit-upgrade/resume-commit and one --allow-startup required',
    );
  }
  final options = ColdMaintenanceOptions.parse([
    'resume-publication',
    ...arguments.skip(1).where((value) => value != '--allow-startup'),
    '--from',
    coldPublicationName,
  ]);
  final resuming = arguments.first == 'resume-commit';
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
  ColdValidationCheckpoint? validation;
  MacOsColdStateHost? coldHost;
  ColdStateLease? lease;
  ColdStateSnapshot? snapshot;
  ColdCommitCheckpoint? commit;
  String? commitCheckpointName;
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
    await verifyColdEntries(scratch, {});
    if (resuming) {
      final published = maintenancePathEntryExists('${work.path}/commit');
      if (published ==
          maintenancePathEntryExists('${work.path}/.commit.partial')) {
        throw const FormatException(
          'exactly one cold commit checkpoint required',
        );
      }
      commitCheckpointName = published ? 'commit' : '.commit.partial';
    }
    await verifyColdEntries(work, {
      ...coldWorkEntries(coldPublicationName),
      'validation',
      if (resuming) ...{'.gaovm-cold-commit.lock', commitCheckpointName!},
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
      commitCheckpoint: commitCheckpointName,
    );
    final state = Directory(options.state);
    stage = 'commit_checkpoint';
    fence = resuming
        ? await ColdCommitCheckpoint.openRecoveryFence(work, state)
        : await MaintenanceStateFence.open(state);
    stage = 'validation_checkpoint';
    validation = await ColdValidationCheckpoint.open(
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
      commitCheckpoint: commitCheckpointName,
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
    await validation.recover(
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
      commitCheckpoint: commitCheckpointName,
    );
    stage = 'commit_preparation';
    commit = resuming
        ? await ColdCommitCheckpoint.open(
            validation,
            work,
            observer: references,
          )
        : await ColdCommitCheckpoint.prepare(
            validation,
            work,
            observer: references,
          );
    await verifyColdWork(
      work,
      commandLock,
      coldPublicationName,
      candidateValidation: true,
      commitCheckpoint: 'commit',
    );
    stage = 'commit';
    final result = await commit.commit(
      allowStartup: true,
      observer: references,
    );
    await verifyColdWork(
      work,
      commandLock,
      coldPublicationName,
      candidateValidation: true,
      commitCheckpoint: 'commit',
    );
    return {
      ...result,
      'status': 'observed',
      'action': arguments.first,
      'work_path': work.path,
      'inspection_path': scratch.path,
    };
  } catch (error) {
    throw ColdPublicationFailure(stage, error);
  } finally {
    commit?.close();
    validation?.close();
    snapshot?.close();
    lease?.close();
    coldHost?.close();
    fence?.close();
    commandLock?.close();
    scratch?.close();
    work?.close();
  }
}
