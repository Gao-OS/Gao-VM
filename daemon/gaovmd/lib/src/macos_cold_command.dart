import 'dart:io';

import 'image_filesystem.dart';
import 'macos_release_inspection.dart';
import 'maintenance_command.dart';

// Shared internal command grammar and namespace checks, not state admission or
// permission to start through a persistent maintenance fence.
/// A failed command is not proof of the last physical placement. All outputs
/// and the persistent fence remain for an explicit fixed-location recovery.
final class ColdPublicationFailure implements Exception {
  const ColdPublicationFailure(this.stage, this.cause);
  final String stage;
  final Object cause;
  @override
  String toString() => 'cold publication failed ($stage): $cause';
}

const coldPublicationCommandLock = '.gaovm-cold-publication.lock';
const coldUninstallCommandLock = '.gaovm-cold-uninstall.lock';
const coldPreparationName = 'preparation', coldRetirementName = 'retirement';
const coldPublicationName = 'publication';

Set<String> coldWorkEntries(String? phase, {bool uninstall = false}) =>
    uninstall
    ? {
        coldUninstallCommandLock,
        if (phase != null) ...{'.gaovm-uninstall.lock', 'uninstall'},
        if (phase == coldRetirementName) ...{
          '.gaovm-app-retirement.lock',
          coldRetirementName,
        },
      }
    : {
        coldPublicationCommandLock,
        if (phase != null) ...{'.gaovm-upgrade.lock', coldPreparationName},
        if ({coldRetirementName, coldPublicationName}.contains(phase)) ...{
          '.gaovm-app-retirement.lock',
          coldRetirementName,
        },
        if (phase == coldPublicationName) ...{
          '.gaovm-candidate-publication.lock',
          coldPublicationName,
        },
      };

Future<void> verifyColdWork(
  OwnedImageDirectory root,
  OwnedImageLock lock,
  String? phase, {
  bool uninstall = false,
  bool candidateValidation = false,
}) async {
  await root.verifyPathBinding();
  if (root.mode & 0xfff != 0x1c0 ||
      (await root.maintenanceMetadata())['has_acl'] != false) {
    throw const FormatException('maintenance work privacy changed');
  }
  lock.verifyPathBinding();
  final file = root.file(
    uninstall ? coldUninstallCommandLock : coldPublicationCommandLock,
  );
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
  await verifyColdEntries(root, {
    ...coldWorkEntries(phase, uninstall: uninstall),
    if (candidateValidation) 'validation',
  });
  lock.verifyPathBinding();
}

Future<void> verifyColdEntries(
  OwnedImageDirectory root,
  Set<String> expected,
) async {
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

final class ColdMaintenanceOptions {
  ColdMaintenanceOptions._(this.values);
  final Map<String, String> values;
  String get app => values['--app']!;
  String get state => values['--state-dir']!;
  String get work => values['--work-dir']!;
  String get inspection => values['--inspection-dir']!;
  String? get candidate => values['--candidate-app'];
  String get bundle => values['--bundle-id']!;
  String get oldVersion => (values['--old-version'] ?? values['--version'])!;
  String get newVersion => values['--new-version']!;
  String get team => values['--team-id']!;
  String? get from => values['--from'];
  bool get resuming => from != null;
  int? get catalogSchema => int.tryParse(values['--catalog-schema'] ?? '');

  static ColdMaintenanceOptions parse(
    List<String> args, {
    bool uninstall = false,
  }) {
    if (args.isEmpty ||
        !(uninstall
                ? {'uninstall-app', 'resume-uninstall'}
                : {'publish-upgrade', 'resume-publication'})
            .contains(args.first)) {
      throw const FormatException('explicit maintenance action required');
    }
    final resume =
        args.first == (uninstall ? 'resume-uninstall' : 'resume-publication');
    final allowed = {
      '--app',
      '--state-dir',
      '--work-dir',
      '--inspection-dir',
      '--bundle-id',
      if (uninstall) '--version' else ...{'--old-version', '--new-version'},
      '--team-id',
      if (resume) ...{
        '--from',
        '--catalog-schema',
      } else if (!uninstall)
        '--candidate-app',
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
                  coldPreparationName,
                  coldRetirementName,
                  if (!uninstall) coldPublicationName,
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
        [
          (values['--old-version'] ?? values['--version'])!,
          if (!uninstall) values['--new-version']!,
        ].any(
          (version) =>
              version.length > 32 ||
              !RegExp(
                r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
              ).hasMatch(version),
        ) ||
        !values['--app']!.endsWith('.app') ||
        !resume && !uninstall && !values['--candidate-app']!.endsWith('.app')) {
      throw const FormatException(
        'explicit bundle ID, Team ID, X.Y.Z versions and app paths required',
      );
    }
    return ColdMaintenanceOptions._(values);
  }

  Future<void> verifyPaths({String? executingCandidate}) async {
    final paths = [
      app,
      state,
      work,
      inspection,
      if (candidate != null) candidate!,
    ];
    for (var i = 0; i < paths.length; i++) {
      final directory = Directory(paths[i]);
      final missingApp =
          i == 0 && {coldRetirementName, coldPublicationName}.contains(from);
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
      if (executingCandidate == '$app/Contents/MacOS/gaovmd' &&
          path == executingCandidate) {
        continue;
      }
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

Future<T> awaitColdCommandExit<T>(Future<T> Function() action) async {
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

final class OwnedColdInspection implements ReleaseInspectionHost {
  const OwnedColdInspection(this.delegate);
  final ReleaseInspectionHost delegate;
  @override
  bool get canExecuteArm64 => delegate.canExecuteArm64;
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    List<int>? input,
  }) => awaitColdCommandExit(
    () => delegate.run(executable, arguments, input: input),
  );
}
