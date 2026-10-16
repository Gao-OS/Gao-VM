part of 'macos_cold_publication.dart';

/// Outside-app preflight, private handoff, owned exit, then independent recovery.
/// No state ownership/namespace lock is carried across the child handoff.
Future<Map<String, Object?>> runMacOsColdValidationLaunch(
  List<String> arguments, {
  ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
  MacOsOpenReferences? observer,
  Future<DriverInventorySnapshot> Function(String)? inventory,
  CandidateValidationLauncher? launcher,
}) async {
  if (arguments.isEmpty || arguments.first != 'validate-upgrade') {
    throw const FormatException('explicit validate-upgrade action required');
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
  OwnedImageDirectory? work, scratch, before, childInspection, after;
  OwnedImageLock? commandLock;
  MaintenanceStateFence? fence;
  MacOsColdStateHost? coldHost;
  ColdStateLease? lease;
  ColdStateSnapshot? snapshot;
  ColdUpgradePreparation? prepared;
  MaintenanceTree? candidate;
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
    await verifyColdEntries(work, coldWorkEntries(coldPublicationName));
    commandLock = await work.tryAcquireMaintenanceLock(
      coldPublicationCommandLock,
      create: false,
    );
    if (commandLock == null) throw StateError('maintenance work already owned');
    await verifyColdWork(work, commandLock, coldPublicationName);
    fence = await MaintenanceStateFence.open(Directory(options.state));
    stage = 'cold';
    coldHost = await MacOsColdStateHost.openPublished(
      Directory(options.app),
      Directory(options.state),
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
    lease = await ColdStateLease.acquire(
      Directory(options.state),
      bundleIdentifier: options.bundle,
      host: coldHost,
      maintenanceFence: fence,
    );
    before = scratch.createDirectory('before');
    childInspection = scratch.createDirectory('candidate');
    after = scratch.createDirectory('after');
    await scratch.sync();
    stage = 'pre_validation';
    snapshot = await ColdStateSnapshot.prepare(
      lease,
      before,
      observer: references,
      inventory: census,
    );
    if (options.catalogSchema != (snapshot.observedCatalogSchema ?? 0)) {
      throw const FormatException(
        'expected catalog schema disagrees with cold catalog',
      );
    }
    prepared = await ColdUpgradePreparation.open(
      snapshot,
      fence,
      work,
      coldPreparationName,
      oldVersion: options.oldVersion,
      newVersion: options.newVersion,
      teamIdentifier: options.team,
      host: execution,
      observer: references,
    );
    final preparationDigest =
        'sha256:${sha256.convert(utf8.encode(jsonEncode(prepared.toJson())))}';
    final publication = coldHost.publicationBindingEvidence;
    candidate = await MaintenanceTree.open(Directory(options.app));
    final manifest = await candidate.capture(nativeMetadata: true);
    if ('sha256:${sha256.convert(utf8.encode('${jsonEncode(manifest)}\n'))}' !=
        publication['candidate_manifest_digest']) {
      throw const FormatException('launch candidate manifest changed');
    }
    await prepared.verify();
    await verifyColdWork(work, commandLock, coldPublicationName);
    await candidate.verify(manifest, nativeMetadata: true);
    final nonce = List.generate(
      32,
      (_) => Random.secure().nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final selectors = [
      '--app',
      options.app,
      '--state-dir',
      options.state,
      '--work-dir',
      options.work,
      '--bundle-id',
      options.bundle,
      '--old-version',
      options.oldVersion,
      '--new-version',
      options.newVersion,
      '--team-id',
      options.team,
      '--catalog-schema',
      '${options.catalogSchema}',
    ];
    // Retain only the marker and in-memory expected evidence. Even a read-only
    // app descriptor makes this parent an external reference to the child.
    // Release all protected app/state readers AND actual kernel ownership.
    prepared.close();
    prepared = null;
    snapshot.close();
    snapshot = null;
    lease.close();
    lease = null;
    coldHost.close();
    coldHost = null;
    fence.close();
    fence = null;
    commandLock.close();
    commandLock = null;
    candidate.close();
    candidate = null;
    stage = 'candidate_launch';
    final launched = await awaitColdCommandExit(
      () => (launcher ?? launchOwnedCandidateValidation)(
        '${options.app}/Contents/MacOS/gaovmd',
        [
          '--validate-upgrade',
          '--launch-grant-stdin',
          ...selectors,
          '--inspection-dir',
          childInspection!.path,
        ],
        nonce,
      ),
    );
    final result = launched.result;
    if (launched.grant.nonce != nonce ||
        launched.grant.process.pid != result.pid ||
        launched.grant.process.executablePath !=
            '${options.app}/Contents/MacOS/gaovmd' ||
        result.exitCode != 0 ||
        result.stderr != '') {
      throw const FormatException(
        'owned candidate validation did not complete; retain all inputs',
      );
    }
    Map<String, Object?> record;
    try {
      final decoded = jsonDecode(result.stdout as String);
      if (decoded is! Map<String, Object?>) throw const FormatException();
      record = decoded;
    } catch (_) {
      throw const FormatException(
        'invalid candidate validation result; retain all inputs',
      );
    }
    stage = 'post_exit_validation';
    // Only after the original child exit. Recovery rechecks the preflight
    // publication's exact native identity; this new reader spans that check
    // and the final full manifest read, without a parent-reference exception.
    candidate = await MaintenanceTree.open(Directory(options.app));
    await runMacOsColdValidationRecovery(
      ['resume-validation', ...selectors, '--inspection-dir', after.path],
      host: execution,
      observer: references,
      inventory: census,
      expectedLaunch: ValidationLaunchExpectation(
        grant: launched.grant,
        preparationDigest: preparationDigest,
        publication: publication,
        record: record,
      ),
    );
    // The last native callback is over: verify the entire held candidate again.
    await candidate.verify(manifest, nativeMetadata: true);
    return {
      ...record,
      'format': 'gaovm.cold-validation-launch-command.v1',
      'status': 'observed',
      'action': 'validate-upgrade',
      'candidate_pid': result.pid,
      'candidate_exit_confirmed': true,
      'post_exit_reverified': true,
      'work_path': work.path,
      'inspection_path': scratch.path,
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
    candidate?.close();
    before?.close();
    childInspection?.close();
    after?.close();
    scratch?.close();
    work?.close();
  }
}
