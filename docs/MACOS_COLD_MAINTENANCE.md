# Cold operator maintenance commands

[`tool/maintain_macos.dart`](../daemon/gaovmd/tool/maintain_macos.dart) composes
the accepted [explicit cold operator workflow](proposals/MACOS_UPGRADE_ROLLBACK.md)
through immutable preparation, old-app retirement and independent candidate
publication, plus a separate recoverable data-preserving uninstall. It is
separate from the public API client and never exposes a driver passthrough.
It performs no registration, stop, VM action, catalog migration, activation,
upgrade commit, rollback or retained-file cleanup.

**This is not a production-ready upgrade transaction.** A successful publication
intentionally leaves ordinary startup blocked by a persistent fence. Activation,
validation/commit and paired whole-state/app rollback are not implemented yet.
The command must not be substituted for a complete upgrade, and this document
does not authorize running it against an actual installation.

## Build and explicit inputs

Use pinned Dart 3.9.0. A production maintenance executable must be compiled and
kept outside every protected app, state, work and inspection tree. For example,
from `daemon/gaovmd`, with an existing output directory outside those trees:

```sh
mise exec dart@3.9.0 -- dart compile exe tool/maintain_macos.dart \
  -o /absolute/outside-protected/gaovm-maintenance
/absolute/outside-protected/gaovm-maintenance --help
```

Source development invocation is also supported, but both the resolved Dart
executable and source script, as well as the working directory, must remain
outside protected trees. Genuine release probes require native ARM64 macOS and
strict Apple-issued Developer ID signatures with the explicit bundle/Team ID.
There is no command-line fixture, signature bypass, service-control option or
unsafe mode. Compiling or executing help on Intel is not ARM64 product evidence.

An authorized operator must independently quiesce clients, services and VMs.
The command still verifies the owning app's read-only `notRegistered` status,
daemon/driver inventories (including unresolved PIDs), open references and
actual original-state kernel ownership. It never infers coldness from a missing
socket or a copied lock file.

All paths must be canonical and absolute. App inputs end in `.app`; state and
existing work/inspection directories must be private and same-user owned, with
work and inspection exactly `0700` and without ACL grants. These directories
and app inputs must be mutually disjoint. Every fresh action requires empty
work and inspection directories; no existing output is reused or normalized.
Work must support the no-replace same-filesystem moves to/from the installation
slot; there is no cross-filesystem copy-and-delete substitute for those moves.

```sh
/absolute/outside-protected/gaovm-maintenance publish-upgrade \
  --app /absolute/install/GaoVM.app \
  --state-dir /absolute/private-state \
  --candidate-app /absolute/download/Candidate.app \
  --work-dir /absolute/private-upgrade-work \
  --inspection-dir /absolute/private-unused-inspection \
  --bundle-id org.example.GaoVM \
  --old-version 0.1.0 --new-version 0.1.1 --team-id ABCDEFGHIJ
```

The old app's initial catalog compatibility requirement is conservatively zero;
this is not a claim about the database. After acquiring the actual state lock
and persistent fence, a private catalog copy is independently inspected. Both
old and candidate releases are re-inspected with that observed schema before
retirement/publication. An old release not compatible with the bootstrap
requirement is refused, not admitted by weakening its compatibility range.
Pre-catalog state has `observed_catalog_schema: null`, not an invented schema 0.

## Fixed work layout and result

The command holds its strict `.gaovm-cold-publication.lock` plus the phase-specific
namespace locks inside the explicit work directory. Fixed children are:

```text
work/
  preparation/     # immutable old app, original state and candidate snapshots
  retirement/      # exact original app inode under GaoVM.app
  publication/     # independent candidate, probe and durable publication record
```

Work privacy, the command lock's single-link/empty/private contents and exact
phase entries are rechecked after native cold observations and between phases,
before original-state acquisition and app moves, and before returning success.
Unexpected contents are retained and refused, never repaired by the command.

The separate inspection directory contains a disposable catalog inspection
copy, not a rollback payload. It is retained too. Operator-owned external VM
files are accounted inputs, not automatically backed-up rollback files.

One continuously held original-state kernel lease spans preparation, retirement
and publication. Candidate code is inspected first and its ordinary daemon
entry must refuse an isolated synthetic-fenced canary state without changing it.
The same check repeats at the installed candidate path. Complete persistent,
external and preparation-file reads follow the last native observers before
physical moves. The immutable preparation is never moved or rewritten as a
commit record. See [publication details](MACOS_CANDIDATE_PUBLICATION.md).

Successful stdout is one `gaovm.cold-publication-command.v1` JSON object, exit 0,
with `status: observed`, `phase: candidate_published`, the independently observed
catalog schema, work/preparation/inspection/fence paths and candidate placement.
`ordinary_startup_fenced` is true; `activation_authorized`, `rollback_authorized`,
`external_files_backed_up` and `committed` are false. Closing releases readers
and kernel ownership only; it never clears the marker or deletes retained data.

## Explicit publication recovery

Resume is a separate action with an operator-selected completed checkpoint.
It does not guess a phase from file existence or promote intent-only output.

| `--from` | Required fixed placement before recovery |
| --- | --- |
| `preparation` | Complete immutable preparation; original app still at its slot. |
| `retirement` | Complete preparation and retired old app; original slot absent. |
| `publication` | Both preceding checkpoints plus complete publication record; exactly one recorded candidate inode at its staged or installed location. |

Every resume uses the same explicit app/state/work and expected release identity,
but a **new empty private inspection directory**. The original candidate download
is not required: only the fixed prepared candidate snapshot is selected.

```sh
/absolute/outside-protected/gaovm-maintenance resume-publication \
  --app /absolute/install/GaoVM.app \
  --state-dir /absolute/private-state \
  --work-dir /absolute/private-upgrade-work \
  --inspection-dir /absolute/private-new-inspection \
  --bundle-id org.example.GaoVM \
  --old-version 0.1.0 --new-version 0.1.1 --team-id ABCDEFGHIJ \
  --from publication --catalog-schema 21
```

`--catalog-schema` is an expected compatibility input, never database truth.
Supply the independently known schema (0 for pre-catalog state). Recovery still
acquires the original-state kernel lock and independently inspects the catalog;
a mismatch is refused before advancing preparation. Publication journals must
also match this expectation before any candidate helper executes.

Existing strict locks, canonical sealed records, native identities, complete
receipts/bytes/metadata and the typed fence must agree with the explicit paths
and expectations. Journal paths are provenance, not filesystem selectors.
Unknown entries, incomplete records, a substituted inode, a foreign occupied slot,
or both/neither candidate locations are refused. Already-published recovery
revalidates the same candidate without replacing it. No automatic undo occurs.

## Data-preserving cold uninstall

`uninstall-app` is a separate explicit action, not a side effect of publication.
The operator must first quiesce clients and VMs and unregister the owning
service. The tool independently proves that boundary; it never unregisters,
stops, signals or retries a service/VM on the operator's behalf.

```sh
/absolute/outside-protected/gaovm-maintenance uninstall-app \
  --app /absolute/install/GaoVM.app \
  --state-dir /absolute/private-state \
  --work-dir /absolute/private-unused-uninstall-work \
  --inspection-dir /absolute/private-unused-inspection \
  --bundle-id org.example.GaoVM --version 0.1.0 --team-id ABCDEFGHIJ
```

The command inspects the cold catalog, managed files, external disk/EFI inputs,
legacy dependencies and runtime records without migrating or cleaning them.
Before retiring anything, it publishes a sealed `uninstall/record.json` under
the private work directory. This binds the app/state identities, expected release,
independently observed catalog schema, complete persistent state/app manifests,
external file evidence and runtime metadata. It is retained-data evidence, not
a backup or rollback payload. The strict work and uninstall namespace locks
are `.gaovm-cold-uninstall.lock` and `.gaovm-uninstall.lock`.

With one continuously held original-state kernel lease and a persistent startup
fence, only the exact app inode moves to `work/retirement/GaoVM.app` through
the existing no-replace retirement primitive. Complete persistent and external
bytes/metadata, runtime and namespace bindings are re-read after the last native
observers before that move and before success. No state or external file is
removed, rewound or rewritten, including retained failed TestRuns, current disks/
NVRAM, diagnostics, images, artifacts and unknown staging data.
Establishing state ownership may create the persistent empty `.gaovmd.lock` if
it did not already exist; it is not deleted afterward. Checkpoint space is
checked before the sealed record is written; failed work is retained.

Successful stdout is `gaovm.cold-uninstall-command.v1`, with `status: observed`,
`phase: uninstalled_data_retained`, `uninstall_completed: true`, retained app/
state/work/inspection/fence paths and the observed schema. `state_retained` and
`ordinary_startup_fenced` are true; `data_deleted`, `activation_authorized`,
`rollback_authorized`, `external_files_backed_up` and upgrade `committed` are
false. This is a cold app-retirement result, not native lifecycle acceptance
or permission to delete its retained app/data. Ordinary startup remains blocked;
do not manually clear that fence to reinstall or reuse the data.

For an interrupted command, use a **new empty private inspection directory** and
select the exact completed checkpoint:

```sh
/absolute/outside-protected/gaovm-maintenance resume-uninstall \
  --app /absolute/install/GaoVM.app \
  --state-dir /absolute/private-state \
  --work-dir /absolute/private-unused-uninstall-work \
  --inspection-dir /absolute/private-new-inspection \
  --bundle-id org.example.GaoVM --version 0.1.0 --team-id ABCDEFGHIJ \
  --from retirement --catalog-schema 21
```

`--from preparation` requires the complete uninstall checkpoint and original app
still at its slot; it proceeds to retirement. `--from retirement` requires that
checkpoint plus the exact old app in its fixed retirement child and an absent
original slot; it revalidates without another move. Both reacquire actual state
ownership, inspect a fresh private catalog copy, compare the expected schema and
prove the sealed app/state/external/runtime evidence is unchanged. Partial or
unknown output, wrong selectors, changed data, a substituted inode or an occupied
original slot are retained and refused. Recovery does not infer a phase, recreate
locks, promote intent-only output, undo a move or clear the startup fence.

## Failures and verification boundary

The separate [validation request/catalog restrictions](MACOS_VALIDATION_ISOLATION.md)
provide internal fail-closed HTTP and native SQLite read-only components. They
do not introduce an activation/commit command, startup-fence bypass or disabled
worker composition; those remain unfinished.

Malformed/refused input returns exit 2; unverified native/filesystem/maintenance
completion returns exit 3. JSON includes the failed stage and false authorization/
commit flags. A failure is **not** proof that a rename did not happen. Retain all
inputs, snapshots, work, inspection output and the fence for investigation.
Do not retry with a different `--from` merely to bypass a refusal, manually clear
the fence, remove unknown entries, or overwrite a target.

Native command deadlines remain failures. If child exit is not yet confirmed,
the command waits on that original owned exit future while retaining its readers
and locks. Cold inventory awaits its original native isolate rather than
abandoning it on an observation deadline. Neither path restarts a command.

Local positive integration checks use real private files, SQLite, native metadata,
directory moves and kernel locks, with explicit external signature/ARM64/
component/service/process observation fixtures. Process-level help/input refusal
uses the real source command. These are not genuine signed installed-product,
power-loss, whole-upgrade, Apple Silicon/VZ/GaoOS or M8/MVP acceptance results.
Apple Silicon execution remains assigned to the user.

The existing [CI workflow](../.github/workflows/ci.yml) compiles this separate
entry in the daemon's static-check matrix. Its macOS component job includes the
operator/recovery and inventory tests above. Workflow wiring and local checks
are not evidence that remote CI or signed installed-product acceptance ran.
