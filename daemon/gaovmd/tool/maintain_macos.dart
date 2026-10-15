import 'dart:convert';
import 'dart:io';

import 'package:gaovmd/src/cold_state_lease.dart';
import 'package:gaovmd/src/macos_cold_publication.dart';
import 'package:gaovmd/src/macos_release_inspection.dart';
import 'package:gaovmd/src/maintenance_command.dart';

const _usage = '''Usage:
  maintain_macos.dart publish-upgrade --app PATH --state-dir PATH
    --candidate-app PATH --work-dir PATH --inspection-dir PATH
    --bundle-id ID --old-version X.Y.Z --new-version X.Y.Z --team-id TEAMID
  maintain_macos.dart resume-publication --app PATH --state-dir PATH
    --work-dir PATH --inspection-dir PATH --bundle-id ID
    --old-version X.Y.Z --new-version X.Y.Z --team-id TEAMID
    --from preparation|retirement|publication --catalog-schema N
  maintain_macos.dart uninstall-app --app PATH --state-dir PATH
    --work-dir PATH --inspection-dir PATH --bundle-id ID
    --version X.Y.Z --team-id TEAMID
  maintain_macos.dart resume-uninstall --app PATH --state-dir PATH
    --work-dir PATH --inspection-dir PATH --bundle-id ID
    --version X.Y.Z --team-id TEAMID
    --from preparation|retirement --catalog-schema N

Explicit cold-operator publication or data-preserving uninstall; does not activate, register, stop,
migrate, commit, roll back, or remove retained files. Quiesce clients, services
and VMs first. All paths are explicit canonical absolute paths. State, work and
inspection are private; work and inspection are disjoint from all app inputs.
Fresh publication requires empty work and inspection directories. Every resume
requires a new empty inspection directory. Catalog schema on resume is an
expected compatibility input, independently checked against the cold catalog.
The command executable and source must remain outside all protected trees.
''';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--help') {
    stdout.write(_usage);
    return;
  }
  final uninstall =
      arguments.isNotEmpty &&
      {'uninstall-app', 'resume-uninstall'}.contains(arguments.first);
  try {
    stdout.writeln(
      jsonEncode(
        await (uninstall
            ? runMacOsColdUninstall(arguments)
            : runMacOsColdPublication(arguments)),
      ),
    );
  } catch (error) {
    final cause = error is ColdPublicationFailure ? error.cause : error;
    final incompatible =
        cause is FormatException ||
        cause is ColdStateFailure ||
        cause is StateError ||
        cause is ReleaseInspectionFailure && cause.status == 'incompatible';
    stdout.writeln(
      jsonEncode({
        'format': uninstall
            ? 'gaovm.cold-uninstall-command.v1'
            : 'gaovm.cold-publication-command.v1',
        'status': incompatible ? 'refused' : 'unverified',
        'stage': error is ColdPublicationFailure ? error.stage : 'inputs',
        'reason': switch (cause) {
          FormatException() => cause.message,
          ColdStateFailure() => cause.reason,
          ReleaseInspectionFailure() => cause.reason,
          MaintenanceCommandFailure() => cause.reason,
          _ => 'maintenance did not complete; retain all inputs and outputs',
        },
        if (cause is MaintenanceCommandFailure) ...{
          'child_pid': cause.pid,
          'child_exit_confirmed': cause.exitConfirmed,
        },
        'retain_inputs_and_outputs': true,
        'activation_authorized': false,
        'rollback_authorized': false,
        'committed': false,
      }),
    );
    exitCode = incompatible ? 2 : 3;
  }
}
