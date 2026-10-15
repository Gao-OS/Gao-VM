import 'dart:io';

import 'cold_catalog_inspection.dart';
import 'cold_state_lease.dart';
import 'image_filesystem.dart';
import 'macos_cold_command.dart';
import 'macos_cold_state_host.dart';
import 'macos_driver_inventory.dart';
import 'macos_open_references.dart';
import 'macos_release_inspection.dart';
import 'maintenance_command.dart';
import 'maintenance_state_fence.dart';

export 'macos_cold_command.dart' show ColdPublicationFailure;

part 'macos_cold_uninstall.dart';

/// The source/operator executable interface, not a daemon API or driver proxy.
/// Injection is confined to native observations, never command-line bypasses.
/// The caller must await completion; no deadline releases borrowed live inputs.
Future<Map<String, Object?>> runMacOsColdPublication(
  List<String> arguments, {
  ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
  MacOsOpenReferences? observer,
  Future<DriverInventorySnapshot> Function(String)? inventory,
}) async {
  final options = ColdMaintenanceOptions.parse(arguments);
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
  MacOsColdStateHost? coldHost;
  ColdStateLease? lease;
  MaintenanceStateFence? fence;
  ColdStateSnapshot? snapshot;
  ColdUpgradePreparation? prepared;
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
    await verifyColdEntries(
      work,
      options.resuming ? coldWorkEntries(options.from!) : {},
    );
    commandLock = await work.tryAcquireMaintenanceLock(
      coldPublicationCommandLock,
      create: !options.resuming,
    );
    if (commandLock == null) throw StateError('maintenance work already owned');
    final lockFile = work.file(coldPublicationCommandLock);
    try {
      await lockFile.sync();
    } finally {
      lockFile.close();
    }
    await work.sync();
    await verifyColdWork(work, commandLock, options.from);
    final state = Directory(options.state), app = Directory(options.app);
    stage = 'cold';
    if (options.resuming) fence = await MaintenanceStateFence.open(state);
    // Zero is a bootstrap compatibility requirement, NOT an observed catalog.
    // Preparation independently inspects SQLite, then re-inspects both releases
    // with its actual schema before any retirement/publication.
    coldHost = switch (options.from) {
      coldRetirementName => await MacOsColdStateHost.openRetired(
        app,
        state,
        fence!,
        work,
        coldRetirementName,
        bundleIdentifier: options.bundle,
        version: options.oldVersion,
        teamIdentifier: options.team,
        catalogSchema: 0,
        host: execution,
        observer: references,
        inventory: census,
      ),
      coldPublicationName => await MacOsColdStateHost.openPublished(
        app,
        state,
        fence!,
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
      ),
      _ => await MacOsColdStateHost.open(
        app,
        bundleIdentifier: options.bundle,
        version: options.oldVersion,
        teamIdentifier: options.team,
        catalogSchema: 0,
        host: execution,
        observer: references,
        inventory: census,
      ),
    };
    await verifyColdWork(work, commandLock, options.from);
    lease = await ColdStateLease.acquire(
      state,
      bundleIdentifier: options.bundle,
      host: coldHost,
      maintenanceFence: fence,
    );
    fence ??= await MaintenanceStateFence.begin(lease);
    stage = 'preparation';
    snapshot = await ColdStateSnapshot.prepare(
      lease,
      scratch,
      observer: references,
      inventory: census,
    );
    await verifyColdWork(work, commandLock, options.from);
    if (options.resuming &&
        options.catalogSchema != (snapshot.observedCatalogSchema ?? 0)) {
      throw const FormatException(
        'expected catalog schema disagrees with cold catalog',
      );
    }
    prepared = options.resuming
        ? await ColdUpgradePreparation.open(
            snapshot,
            fence,
            work,
            coldPreparationName,
            oldVersion: options.oldVersion,
            newVersion: options.newVersion,
            teamIdentifier: options.team,
            host: execution,
            observer: references,
          )
        : await ColdUpgradePreparation.create(
            snapshot,
            fence,
            work,
            coldPreparationName,
            candidateApp: Directory(options.candidate!),
            oldVersion: options.oldVersion,
            newVersion: options.newVersion,
            teamIdentifier: options.team,
            host: execution,
            observer: references,
          );
    await verifyColdWork(
      work,
      commandLock,
      options.from ?? coldPreparationName,
    );
    if (!options.resuming || options.from == coldPreparationName) {
      stage = 'retirement';
      await prepared.retireOriginalApp(work, coldRetirementName);
    }
    await verifyColdWork(
      work,
      commandLock,
      options.from == coldPublicationName
          ? coldPublicationName
          : coldRetirementName,
    );
    stage = 'publication';
    final result = await prepared.publishCandidate(work, coldPublicationName);
    await verifyColdWork(work, commandLock, coldPublicationName);
    return {
      'format': 'gaovm.cold-publication-command.v1',
      'status': 'observed',
      'action': options.resuming ? 'resume-publication' : 'publish-upgrade',
      ...result,
      'observed_catalog_schema': snapshot.observedCatalogSchema,
      'source_state': lease.path,
      'work_path': work.path,
      'preparation_path': prepared.path,
      'inspection_path': scratch.path,
      'fence_path': fence.path,
      'ordinary_startup_fenced': true,
      'external_files_backed_up': false,
    };
  } catch (error) {
    throw ColdPublicationFailure(stage, error);
  } finally {
    // All awaited native observations (including their original owned-exit
    // futures) have settled before releasing readers or kernel ownership.
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
