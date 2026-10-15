import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'candidate_validation_session.dart';
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
import 'public_openapi_document.dart';
import 'system_doctor_host.dart';

export 'macos_cold_command.dart' show ColdPublicationFailure;

/// Candidate-only entry, never a generic ordinary-startup fence bypass.
Future<Map<String, Object?>> runMacOsCandidateValidation(
  List<String> arguments, {
  ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
  MacOsOpenReferences? observer,
  Future<DriverInventorySnapshot> Function(String)? inventory,
  Future<String> Function()? currentExecutable,
  DoctorHost? doctorHost,
}) async {
  final options = _validationOptions(arguments);
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
  OwnedImageDirectory? work, scratch, before, after, journal;
  OwnedImageLock? commandLock;
  MaintenanceStateFence? fence;
  MacOsColdStateHost? coldHost;
  ColdStateLease? lease;
  ColdStateSnapshot? snapshot;
  ColdUpgradePreparation? prepared;
  var stage = 'candidate_admission';
  try {
    final executing =
        await (currentExecutable?.call() ??
            File(Platform.resolvedExecutable).resolveSymbolicLinks());
    if (executing != '${options.app}/Contents/MacOS/gaovmd') {
      throw const FormatException(
        'validation must execute the installed candidate daemon',
      );
    }
    await options.verifyPaths(executingCandidate: executing);
    work = await OwnedImageDirectory.open(Directory(options.work));
    scratch = await OwnedImageDirectory.open(Directory(options.inspection));
    await _validationPrivate(work);
    await _validationPrivate(scratch);
    await verifyColdEntries(scratch, {});
    await verifyColdEntries(work, coldWorkEntries(coldPublicationName));
    commandLock = await work.tryAcquireMaintenanceLock(
      coldPublicationCommandLock,
      create: false,
    );
    if (commandLock == null) throw StateError('maintenance work already owned');
    await verifyColdWork(work, commandLock, coldPublicationName);
    fence = await MaintenanceStateFence.open(Directory(options.state));
    coldHost = await MacOsColdStateHost.openPublishedForValidation(
      Directory(options.app),
      Directory(options.state),
      fence,
      work,
      bundleIdentifier: options.bundle,
      oldVersion: options.oldVersion,
      newVersion: options.newVersion,
      teamIdentifier: options.team,
      catalogSchema: options.catalogSchema!,
      host: execution,
      observer: references,
      inventory: census,
      currentExecutable: currentExecutable,
    );
    await verifyColdWork(work, commandLock, coldPublicationName);
    lease = await ColdStateLease.acquire(
      Directory(options.state),
      bundleIdentifier: options.bundle,
      host: coldHost,
      maintenanceFence: fence,
    );
    stage = 'pre_validation';
    before = scratch.createDirectory('before');
    await scratch.sync();
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
    await verifyColdWork(work, commandLock, coldPublicationName);
    final document = await loadPublicOpenApiDocument(
      File('${options.app}/Contents/Resources/schemas/openapi/gaovm-v1.yaml'),
    );
    final intent = <String, Object?>{
      'format': 'gaovm.candidate-validation-intent.v1',
      'source_app': options.app,
      'source_state': options.state,
      'bundle_identifier': options.bundle,
      'old_version': options.oldVersion,
      'new_version': options.newVersion,
      'team_identifier': options.team,
      'source_catalog_schema': snapshot.observedCatalogSchema,
      'preparation_digest':
          'sha256:${sha256.convert(utf8.encode(jsonEncode(prepared.toJson())))}',
      'publication': coldHost.validationAdmissionEvidence,
      'fence_path': fence.path,
    };
    journal = work.createDirectory('.validation.partial');
    await _writeValidationRecord(journal, 'intent.json', intent);
    await journal.sync();
    await work.sync();
    await work.renameDirectoryNoReplace('.validation.partial', 'validation');
    journal.close();
    journal = work.directory('validation');
    final ownedPrepared = prepared,
        ownedWork = work,
        ownedLock = commandLock,
        ownedJournal = journal;
    stage = 'controlled_validation';
    final result = await lease.validateCandidate(
      openApiDocument: document,
      doctorHost: doctorHost,
      verifyBeforeMigration: () async {
        await ownedPrepared.verify();
        await verifyColdWork(
          ownedWork,
          ownedLock,
          coldPublicationName,
          candidateValidation: true,
        );
        await _validationPrivate(ownedJournal);
        await verifyColdEntries(ownedJournal, {'intent.json'});
        await _checkValidationRecord(ownedJournal, 'intent.json', intent);
      },
    );
    stage = 'validation_evidence';
    await verifyColdWork(
      work,
      commandLock,
      coldPublicationName,
      candidateValidation: true,
    );
    await _checkValidationRecord(journal, 'intent.json', intent);
    after = scratch.createDirectory('after');
    await scratch.sync();
    final retained = await prepared.retainValidatedState(
      after,
      journal,
      observer: references,
      inventory: census,
    );
    if (retained['manifest_digest'] != result['closed_session_state_digest']) {
      throw const FormatException(
        'persistent state changed after validation session',
      );
    }
    await verifyColdWork(
      work,
      commandLock,
      coldPublicationName,
      candidateValidation: true,
    );
    await _checkValidationRecord(journal, 'intent.json', intent);
    final record = <String, Object?>{
      'format': 'gaovm.cold-validation-command.v1',
      'phase': 'candidate_validated',
      'source_app': options.app,
      'source_state': options.state,
      'fence_path': fence.path,
      'validation_path': journal.path,
      'intent_digest':
          'sha256:${sha256.convert(utf8.encode('${jsonEncode(intent)}\n'))}',
      'validated_state': retained,
      ...result,
      'ordinary_startup_fenced': true,
      'activation_authorized': false,
      'rollback_authorized': false,
      'committed': false,
    };
    final completed = journal.createDirectory('.completed.partial');
    try {
      await _writeValidationRecord(completed, 'record.json', record);
      await completed.sync();
      await journal.sync();
    } finally {
      completed.close();
    }
    await journal.renameDirectoryNoReplace('.completed.partial', 'completed');
    await journal.sync();
    await _validationPrivate(journal);
    await verifyColdEntries(journal, {
      'intent.json',
      'validated-state',
      'completed',
      '.gaovm-maintenance.lock',
    });
    final snapshotLock = journal.file('.gaovm-maintenance.lock');
    try {
      final stat = snapshotLock.stat();
      if (stat.mode & 0xfff != 0x180 || stat.size != 0 || stat.linkCount != 1) {
        throw const FormatException('validation snapshot lock changed');
      }
      await snapshotLock.verifyPathBinding();
    } finally {
      snapshotLock.close();
    }
    await _checkValidationRecord(journal, 'intent.json', intent);
    final sealed = journal.directory('completed');
    try {
      await _validationPrivate(sealed);
      await verifyColdEntries(sealed, {'record.json'});
      await _checkValidationRecord(sealed, 'record.json', record);
    } finally {
      sealed.close();
    }
    if (jsonEncode(coldHost.validationAdmissionEvidence) !=
        jsonEncode(intent['publication'])) {
      throw const FormatException('candidate admission evidence changed');
    }
    await verifyColdWork(
      work,
      commandLock,
      coldPublicationName,
      candidateValidation: true,
    );
    return record;
  } catch (error) {
    throw ColdPublicationFailure(stage, error);
  } finally {
    prepared?.close();
    snapshot?.close();
    lease?.close();
    coldHost?.close();
    fence?.close();
    journal?.close();
    before?.close();
    after?.close();
    commandLock?.close();
    scratch?.close();
    work?.close();
  }
}

Future<void> _validationPrivate(OwnedImageDirectory directory) async {
  await directory.verifyPathBinding();
  if (directory.mode & 0xfff != 0x1c0 ||
      (await directory.maintenanceMetadata())['has_acl'] != false) {
    throw const FormatException('private validation directory required');
  }
}

Future<void> _writeValidationRecord(
  OwnedImageDirectory directory,
  String name,
  Map<String, Object?> value,
) async {
  final bytes = utf8.encode('${jsonEncode(value)}\n');
  if (bytes.length > 64 * 1024 * 1024)
    throw const FormatException('validation evidence exceeds bounds');
  final file = directory.createFile(name);
  try {
    final writer = await file.openWrite();
    try {
      await writer.writeFrom(bytes);
      await writer.flush();
    } finally {
      await writer.close();
    }
    await file.seal();
  } finally {
    file.close();
  }
}

Future<void> _checkValidationRecord(
  OwnedImageDirectory directory,
  String name,
  Map<String, Object?> expected,
) async {
  await _validationPrivate(directory);
  final file = directory.file(name);
  try {
    final before = file.stat();
    if (before.mode & 0xfff != 0x100 ||
        before.linkCount != 1 ||
        (await file.maintenanceMetadata())['has_acl'] != false ||
        utf8.decode(await file.readBounded(64 * 1024 * 1024)) !=
            '${jsonEncode(expected)}\n') {
      throw const FormatException('validation evidence changed');
    }
    await file.verifyPathBinding();
    if (before != file.stat())
      throw const FormatException('validation evidence changed while reading');
  } finally {
    file.close();
  }
}

ColdMaintenanceOptions _validationOptions(List<String> arguments) {
  if (arguments.isEmpty || arguments.first != 'validate-upgrade') {
    throw const FormatException('explicit candidate validation required');
  }
  return ColdMaintenanceOptions.parse([
    'resume-publication',
    ...arguments.skip(1),
    '--from',
    coldPublicationName,
  ]);
}
