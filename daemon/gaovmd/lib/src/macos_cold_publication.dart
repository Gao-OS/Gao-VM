import 'dart:io';

import 'cold_catalog_inspection.dart';
import 'cold_state_lease.dart';
import 'image_filesystem.dart';
import 'macos_cold_state_host.dart';
import 'macos_driver_inventory.dart';
import 'macos_open_references.dart';
import 'macos_release_inspection.dart';
import 'maintenance_command.dart';
import 'maintenance_state_fence.dart';

/// A failed command is not proof of the last physical placement. All outputs
/// and the persistent fence remain for an explicit fixed-location recovery.
final class ColdPublicationFailure implements Exception {
  const ColdPublicationFailure(this.stage, this.cause);
  final String stage;
  final Object cause;
  @override
  String toString() => 'cold publication failed ($stage): $cause';
}

const _commandLock = '.gaovm-cold-publication.lock';
const _preparation = 'preparation', _retirement = 'retirement';
const _publication = 'publication';

/// The source/operator executable interface, not a daemon API or driver proxy.
/// Injection is confined to native observations, never command-line bypasses.
/// The caller must await completion; no deadline releases borrowed live inputs.
Future<Map<String, Object?>> runMacOsColdPublication(
  List<String> arguments, {
  ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
  MacOsOpenReferences? observer,
  Future<DriverInventorySnapshot> Function(String)? inventory,
}) async {
  final options = _Options.parse(arguments);
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
    await _entries(scratch, const {});
    await _entries(work, options.resuming ? _workEntries(options.from!) : {});
    commandLock = await work.tryAcquireMaintenanceLock(
      _commandLock,
      create: !options.resuming,
    );
    if (commandLock == null) throw StateError('maintenance work already owned');
    final lockFile = work.file(_commandLock);
    try {
      await lockFile.sync();
    } finally {
      lockFile.close();
    }
    await work.sync();
    await _verifyWork(work, commandLock, options.from);
    final state = Directory(options.state), app = Directory(options.app);
    stage = 'cold';
    if (options.resuming) fence = await MaintenanceStateFence.open(state);
    // Zero is a bootstrap compatibility requirement, NOT an observed catalog.
    // Preparation independently inspects SQLite, then re-inspects both releases
    // with its actual schema before any retirement/publication.
    coldHost = switch (options.from) {
      _retirement => await MacOsColdStateHost.openRetired(
        app,
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
      ),
      _publication => await MacOsColdStateHost.openPublished(
        app,
        state,
        fence!,
        work,
        _retirement,
        work,
        _publication,
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
    await _verifyWork(work, commandLock, options.from);
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
    await _verifyWork(work, commandLock, options.from);
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
            _preparation,
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
            _preparation,
            candidateApp: Directory(options.candidate!),
            oldVersion: options.oldVersion,
            newVersion: options.newVersion,
            teamIdentifier: options.team,
            host: execution,
            observer: references,
          );
    await _verifyWork(work, commandLock, options.from ?? _preparation);
    if (!options.resuming || options.from == _preparation) {
      stage = 'retirement';
      await prepared.retireOriginalApp(work, _retirement);
    }
    await _verifyWork(
      work,
      commandLock,
      options.from == _publication ? _publication : _retirement,
    );
    stage = 'publication';
    final result = await prepared.publishCandidate(work, _publication);
    await _verifyWork(work, commandLock, _publication);
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

Set<String> _workEntries(String? phase) => {
  _commandLock,
  if (phase != null) ...{'.gaovm-upgrade.lock', _preparation},
  if ({_retirement, _publication}.contains(phase)) ...{
    '.gaovm-app-retirement.lock',
    _retirement,
  },
  if (phase == _publication) ...{
    '.gaovm-candidate-publication.lock',
    _publication,
  },
};

Future<void> _verifyWork(
  OwnedImageDirectory root,
  OwnedImageLock lock,
  String? phase,
) async {
  await root.verifyPathBinding();
  if (root.mode & 0xfff != 0x1c0 ||
      (await root.maintenanceMetadata())['has_acl'] != false) {
    throw const FormatException('maintenance work privacy changed');
  }
  lock.verifyPathBinding();
  final file = root.file(_commandLock);
  try {
    final before = file.stat();
    if (before.mode & 0xfff != 0x180 ||
        before.size != 0 ||
        before.linkCount != 1 ||
        (await file.maintenanceMetadata())['has_acl'] != false) {
      throw const FormatException('maintenance command lock changed');
    }
    await file.verifyPathBinding();
    if (file.stat() != before) {
      throw const FormatException(
        'maintenance command lock changed during observation',
      );
    }
  } finally {
    file.close();
  }
  await _entries(root, _workEntries(phase));
  lock.verifyPathBinding();
}

Future<void> _entries(OwnedImageDirectory root, Set<String> expected) async {
  await root.verifyPathBinding();
  final actual = await Directory(root.path)
      .list(followLinks: false)
      .take(expected.length + 1)
      .map((entry) => entry.uri.pathSegments.where((s) => s.isNotEmpty).last)
      .toSet();
  if (actual.length != expected.length || !actual.containsAll(expected)) {
    throw const FormatException(
      'unknown, missing or partial maintenance work; retain for investigation',
    );
  }
  await root.verifyPathBinding();
}

final class _Options {
  _Options(this.values);
  final Map<String, String> values;
  String get app => values['--app']!;
  String get state => values['--state-dir']!;
  String get work => values['--work-dir']!;
  String get inspection => values['--inspection-dir']!;
  String? get candidate => values['--candidate-app'];
  String get bundle => values['--bundle-id']!;
  String get oldVersion => values['--old-version']!;
  String get newVersion => values['--new-version']!;
  String get team => values['--team-id']!;
  String? get from => values['--from'];
  bool get resuming => from != null;
  int? get catalogSchema => int.tryParse(values['--catalog-schema'] ?? '');

  static _Options parse(List<String> args) {
    if (args.isEmpty ||
        !{'publish-upgrade', 'resume-publication'}.contains(args.first)) {
      throw const FormatException('explicit maintenance action required');
    }
    final resume = args.first == 'resume-publication';
    final allowed = {
      '--app',
      '--state-dir',
      '--work-dir',
      '--inspection-dir',
      '--bundle-id',
      '--old-version',
      '--new-version',
      '--team-id',
      if (resume) ...{'--from', '--catalog-schema'} else '--candidate-app',
    };
    final values = <String, String>{};
    for (var i = 1; i < args.length; i += 2) {
      if (!allowed.contains(args[i]) ||
          i + 1 >= args.length ||
          args[i + 1].isEmpty ||
          args[i + 1].startsWith('--') ||
          values.containsKey(args[i])) {
        throw const FormatException(
          'unknown, repeated or incomplete maintenance option',
        );
      }
      values[args[i]] = args[i + 1];
    }
    if (values.length != allowed.length ||
        resume &&
            (!{
                  _preparation,
                  _retirement,
                  _publication,
                }.contains(values['--from']) ||
                !RegExp(
                  r'^(0|[1-9][0-9]*)$',
                ).hasMatch(values['--catalog-schema']!) ||
                int.tryParse(values['--catalog-schema']!) == null ||
                int.parse(values['--catalog-schema']!) > 2147483647)) {
      throw const FormatException(
        'all explicit inputs and a recognized recovery checkpoint are required',
      );
    }
    if (values['--bundle-id']!.length > 255 ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$',
        ).hasMatch(values['--bundle-id']!) ||
        !RegExp(r'^[A-Z0-9]{10}$').hasMatch(values['--team-id']!) ||
        [values['--old-version']!, values['--new-version']!].any(
          (version) =>
              version.length > 32 ||
              !RegExp(
                r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
              ).hasMatch(version),
        ) ||
        !values['--app']!.endsWith('.app') ||
        !resume && !values['--candidate-app']!.endsWith('.app')) {
      throw const FormatException(
        'explicit bundle ID, Team ID, X.Y.Z versions and app paths required',
      );
    }
    return _Options(values);
  }

  Future<void> verifyPaths() async {
    final paths = [
      app,
      state,
      work,
      inspection,
      if (candidate != null) candidate!,
    ];
    for (var i = 0; i < paths.length; i++) {
      final directory = Directory(paths[i]);
      final missingApp = i == 0 && {_retirement, _publication}.contains(from);
      if (!paths[i].startsWith('/') ||
          directory.absolute.path != paths[i] ||
          (missingApp
              ? await directory.parent.resolveSymbolicLinks() !=
                    directory.parent.path
              : await directory.resolveSymbolicLinks() != paths[i])) {
        throw const FormatException(
          'explicit canonical absolute paths required',
        );
      }
      for (var j = 0; j < i; j++) {
        if (_overlap(paths[i], paths[j])) {
          throw const FormatException('maintenance paths must be disjoint');
        }
      }
    }
    final executing = [
      await File(Platform.resolvedExecutable).resolveSymbolicLinks(),
      if (Platform.script.scheme == 'file')
        await File.fromUri(Platform.script).resolveSymbolicLinks(),
      await Directory.current.resolveSymbolicLinks(),
    ];
    for (final path in executing) {
      if (paths.any(
        (protected) => path == protected || path.startsWith('$protected/'),
      )) {
        throw const FormatException(
          'maintenance executable, source and cwd must remain outside protected trees',
        );
      }
    }
  }
}

bool _overlap(String a, String b) =>
    a == b || a.startsWith('$b/') || b.startsWith('$a/');

Future<ProcessResult> _terminal(Future<ProcessResult> Function() action) async {
  try {
    return await action();
  } on MaintenanceCommandFailure catch (error) {
    if (!error.exitConfirmed && error.ownedExit != null) {
      await error.ownedExit;
      throw MaintenanceCommandFailure(
        error.reason,
        error.pid,
        exitConfirmed: true,
      );
    }
    rethrow;
  }
}

final class _OwnedInspection implements ReleaseInspectionHost {
  const _OwnedInspection(this.delegate);
  final ReleaseInspectionHost delegate;
  @override
  bool get canExecuteArm64 => delegate.canExecuteArm64;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    List<int>? input,
  }) => _terminal(() => delegate.run(executable, arguments, input: input));
}
