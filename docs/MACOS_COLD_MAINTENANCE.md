# Cold operator maintenance commands

[`tool/maintain_macos.dart`](../daemon/gaovmd/tool/maintain_macos.dart) composes
the accepted [explicit cold operator workflow](proposals/MACOS_UPGRADE_ROLLBACK.md)
through immutable preparation, old-app retirement and independent candidate
publication, an outside-app verified candidate-validation launcher, sealed
validation-checkpoint recovery, explicit cold commit and a separate recoverable
data-preserving uninstall. It is
separate from the public API client and never exposes a driver passthrough.
It performs no registration, stop, VM action, activation, rollback
or retained-file cleanup. Only `validate-upgrade` can apply controlled catalog/
legacy migration through the candidate-only validation composition.

**This is not a production-ready upgrade transaction.** A successful publication
intentionally leaves ordinary startup blocked by a persistent fence. A separate
explicit cold commit can retire that fence after full revalidation and startup
acknowledgement; it does not start a service or prove readiness. Paired whole-state/
app rollback and native lifecycle acceptance remain unfinished. Recovery below
recognizes only complete fixed sealed checkpoints. Neither candidate
validation nor its outside-app launcher is activation.
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
and app inputs must be mutually disjoint. Fresh publication/uninstall requires
empty work and inspection directories; no existing output is normalized.
Validation requires completed publication work and a new empty inspection directory.
Commit requires completed validation and another new empty inspection directory;
explicit recovery requires the corresponding retained fixed checkpoint.
Work must support the no-replace same-filesystem moves to/from the installation
slot and, for commit, from the state fence's parent into the work checkpoint.
There is no cross-filesystem copy-and-delete substitute for those moves.

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

## Candidate-only validation

The published-candidate integration passes with private populated schema-21 and
pre-catalog legacy state, real managed files, restricted HTTP UDS and retained
snapshots. Legacy migration preserves the complete pre-upgrade rollback pair,
original JSON and external disk bytes. An unsupported legacy network mode keeps
partial migration output and refuses a blind repeat without further state/work
changes. Signature/service/ARM64/process boundaries are fixtures, not an
installed native upgrade result. Earlier timed-out inputs remain retained; see the
[acceptance ledger](MVP_ACCEPTANCE.md). The complete upgrade transaction is still
unfinished.

The outside-app tool's `validate-upgrade` action independently verifies the
published candidate, complete original app/state rollback pair and original cold
source before executing the installed candidate daemon. This is not a generic
fence bypass or a complete production upgrade transaction. This source interface
does not authorize executing any command against an actual installation as part
of the current development task.

After completed publication, with a new empty private inspection directory and
the working directory outside all protected trees, the interface is:

```sh
/absolute/outside-protected/gaovm-maintenance validate-upgrade \
  --app /absolute/install/GaoVM.app \
  --state-dir /absolute/private-state \
  --work-dir /absolute/private-upgrade-work \
  --inspection-dir /absolute/private-new-validation-inspection \
  --bundle-id org.example.GaoVM \
  --old-version 0.1.0 --new-version 0.1.1 --team-id ABCDEFGHIJ \
  --catalog-schema 21
```

The schema input describes the pre-migration catalog, independently rechecked
against the publication and cold source (0 means pre-catalog). The validation
child must resolve to exactly the explicitly selected installed candidate daemon.
Source Dart execution of that child, another binary or a staged candidate cannot
opt in; this does not prohibit the outside-app operator's source invocation.
Native signatures, component/contract identity, publication/preparation receipts,
service status, unresolved/other processes and real state/work/fence ownership
are still checked; only the exact versioned candidate self PID is admitted.

The launcher first holds all cold ownership and verifies the complete inputs,
then releases the actual state/work/fence/namespace locks and all protected
app/state readers while retaining the persistent startup marker and only the
in-memory manifest/identity expectations. A read-only app descriptor in the
parent would still block the child's real open-reference check. The one-shot child
independently reacquires those locks and rechecks admission; a receipt or copied
lock never substitutes for ownership. A private stdin handshake binds a random
256-bit per-launch nonce to the parent's native observation of the original
child's versioned PID/UID/start time/executable. No nonce enters arguments,
environment, logs or durable records; only its grant digest is sealed in the
v3 validation intent. The internal daemon entry remains `--validate-upgrade`;
its private `--launch-grant-stdin` handoff is not an ordinary startup option.

The actual catalog is migrated under the original-state lease, its writer closes,
and the normal read handlers/doctor are exercised over the restricted private
UDS with a native read-only connection. No normal startup/recovery or background
workers run. All original request/native probe work drains before ownership is
released, and the persistent read-only interval is verified unchanged. See the
[validation composition](MACOS_VALIDATION_ISOLATION.md#candidate-only-controlled-validation)
for the exact limits and evidence.

The launcher drains bounded stdout/stderr and waits for the original child exit,
without applying the short native-probe deadline to a catalog migration. It
then independently reopens sealed recovery with zero candidate/daemon/driver
processes and actual state ownership. The sealed intent/record must match this
launch grant, preflight preparation/publication bindings and the child's exact
stdout record. Complete post-validation state, original rollback inputs and
candidate bytes/native metadata are rechecked after native observations. No
automatic retry, adoption of another launch, registration or fence removal occurs.
The candidate reader is reopened only after the original child exit, spans
independent native-identity recovery and the final full manifest comparison,
and never grants a parent-PID exception to cold admission.

Launcher success is one `gaovm.cold-validation-launch-command.v1` JSON object with
`phase: candidate_validated` and the applied catalog schema. A sealed full record
is retained at `work/validation/completed/record.json`, with an independent full
post-validation state snapshot at `work/validation/validated-state`. The original
rollback pair remains intact. The process exits; ordinary startup stays fenced,
and `committed`, `activation_authorized` and `rollback_authorized` stay false.
Neither a green doctor nor this receipt authorizes registration or commit.
The launcher additionally reports `candidate_exit_confirmed: true` and
`post_exit_reverified: true`. The candidate's own sealed record keeps the
`gaovm.cold-validation-command.v1` format. Interruptions/failures retain all
outputs and the fence; do not remove inputs while original child work is pending.

Partial/unknown validation output is retained. A blind repeat refuses it.
Do not delete the fence/output to force retry, reuse publication-only recovery
after migration, or substitute the new snapshot for the original rollback pair.
The separate commit must independently re-establish the cold boundary and validate
the retained app/state identities and intervening-write boundary.

## Sealed validation recovery

After the candidate validation process has exited, an outside-app operator can
explicitly re-open a complete sealed result. Use the original source schema
(0 for pre-catalog), not the schema applied by migration, and a new empty private
inspection directory:

```sh
/absolute/outside-protected/gaovm-maintenance resume-validation \
  --app /absolute/install/GaoVM.app \
  --state-dir /absolute/private-state \
  --work-dir /absolute/private-upgrade-work \
  --inspection-dir /absolute/private-new-recovery-inspection \
  --bundle-id org.example.GaoVM \
  --old-version 0.1.0 --new-version 0.1.1 --team-id ABCDEFGHIJ \
  --catalog-schema 0
```

This is not migration replay, a validating-self exception, activation or commit.
The command independently checks that services and all daemon/driver processes
are absent, reacquires the original-state kernel owner and existing fence, and
re-inspects the published candidate. It verifies the complete current persistent
state against the post-validation snapshot, the immutable original app/state
rollback pair and the original external-file evidence, including legacy inputs
no longer referenced by the migrated catalog. No API or worker is started.

The fixed `validation/` directory must contain exactly `intent.json`,
`validated-state/`, `.gaovm-maintenance.lock` and either `completed/` or
`.completed.partial/`. Both completion forms require the same complete sealed
`record.json`. Bound v2 and v3 intents bind the original validation workspace
inode; v3 additionally records a launch-grant digest when launched that way.
Older unbound intents are retained and refused, not silently upgraded. Missing
or unknown entries, partial state snapshots, changed bytes/metadata/identities,
an active or unresolved process and mismatched explicit inputs are refused.

An existing completion is reverified without rewriting it. A complete sealed
`.completed.partial` can be atomically renamed to `completed` without replacement
only after all checks pass, and is then reverified. Other interrupted migration
or validation states remain retained for investigation; they are not guessed or
automatically replayed. Unexpected failures may be after that rename: keep all
fixed output locations for subsequent identity-based investigation.

Success is a `gaovm.cold-validation-recovery-command.v1` JSON object with
`phase: candidate_validation_recovered`, `completion_checkpoint_promoted`,
`public_api_rerun: false` and `state_unchanged: true`. The applied catalog and IDs
are rechecked, but this is not a new API/doctor run. Ordinary startup stays
fenced, with `committed`, `activation_authorized` and `rollback_authorized` false.
Arbitrary interrupted-validation recovery and whole-state rollback remain
unfinished; this command is not a complete upgrade transaction.

## Explicit cold commit and manual startup

The accepted sequence is **cold commit, then manual operator registration/start**.
After completed candidate validation, use the original source schema (0 for
pre-catalog state), the same explicit release identities and a new empty private
inspection directory:

```sh
/absolute/outside-protected/gaovm-maintenance commit-upgrade \
  --allow-startup \
  --app /absolute/install/GaoVM.app \
  --state-dir /absolute/private-state \
  --work-dir /absolute/private-upgrade-work \
  --inspection-dir /absolute/private-new-commit-inspection \
  --bundle-id org.example.GaoVM \
  --old-version 0.1.0 --new-version 0.1.1 --team-id ABCDEFGHIJ \
  --catalog-schema 0
```

Exactly one standalone `--allow-startup` is required. It acknowledges lifting the
startup fence, not permission for the tool to register/start anything. The tool
freshly verifies zero daemon/driver processes, no unresolved processes, owning
service `notRegistered`, native candidate identity and the real state kernel
lease. It recovers and rechecks the complete current validated state, original
app/state pair and external inputs. No migration, API validation, background
worker, driver or service action is rerun. A coldness or intervening-write
failure refuses without repairing the evidence or recreating a retired fence.

Internally, `ColdCommitCheckpoint.prepare` requires a successfully recovered
`ColdValidationCheckpoint` and its continuously held real cold owner. Imported
JSON, an opened-but-unrecovered checkpoint or a closed owner cannot opt in.

The new private `commit/intent.json` binds the actual work/checkpoint/state/fence
identities, release inputs, validation intent/record digests, publication and
preparation bindings, and the closed-session state digest. The sealed
`commit/prepared/record.json` has format `gaovm.cold-commit-preparation.v1` and
phase `cold_commit_prepared`. Both are fsynced before no-replace publication from
`.commit.partial`. Ordinary startup remains fenced; `committed` and
`activation_authorized` are false. `state_unchanged: true` refers to the retained
state, not the newly created preparation output; no API validation is rerun.

With explicit acknowledgement, a complete terminal candidate is sealed under
`commit/.completed.partial/record.json`. This candidate alone is **not commit
authority**, even though its proposed terminal flags are true. After complete
reverification following the last native observer, the exact original fence
inode moves atomically without replacement to `commit/retired-fence`. That move
is the commit point; there is no copy/delete fallback. Both parent directories
are synced, the whole evidence is reverified, the complete terminal directory
is published as `completed`, and everything is rechecked before success. The
real state lease remains held throughout, preventing ordinary startup from
acquiring that state during the final checks. The original app/state rollback
pair, failed TestRuns, managed files and external bytes are not changed or cleaned.

Success is one `gaovm.cold-upgrade-commit.v1` JSON object, with
`phase: upgrade_committed`, `committed: true`, `startup_allowed: true`,
`ordinary_startup_fenced: false`, `manual_start_required: true`,
`service_actions_performed: false` and `ordinary_ready: false`. `state_unchanged`
refers to both retained state generations, not the new commit output or fence
placement. The operator separately registers/starts the service and tests actual
readiness; this result is not installed, Apple Silicon, VZ or Guest acceptance.

## Explicit commit recovery

A blind repeat of `commit-upgrade` refuses existing output. For an interrupted
commit, retain all fixed outputs and use **`resume-commit --allow-startup`**, with
the same explicit inputs and another new empty private inspection directory:

```sh
/absolute/outside-protected/gaovm-maintenance resume-commit \
  --allow-startup \
  --app /absolute/install/GaoVM.app \
  --state-dir /absolute/private-state \
  --work-dir /absolute/private-upgrade-work \
  --inspection-dir /absolute/private-new-commit-recovery-inspection \
  --bundle-id org.example.GaoVM \
  --old-version 0.1.0 --new-version 0.1.1 --team-id ABCDEFGHIJ \
  --catalog-schema 0
```

Recovery recognizes only complete sealed preparation in `.commit.partial`
(`prepared` or `.prepared.partial`) or published `commit/prepared`. Only the
published preparation can additionally contain `.completed.partial`, with either
the original active fence or the exact retained `retired-fence`. Final
`completed` requires the retained fence. Impossible combinations, unknown entries,
incomplete records, substituted identities and forged flags refuse without
repair, cleanup or promotion. Existing namespace locks are reacquired, never
inferred from a marker or recreated if missing. Every record is reread after
the last native observer; original pending native exits drain while ownership
remains held. A valid fixed partial can be promoted only after fresh real cold
ownership and full validation recovery. A complete committed checkpoint is
reverified without rewriting it. Recovery does not rerun migration or the API.

An error can occur **after** the fence move. Error JSON therefore reports
`committed: null` and `startup_allowed: null`, not an invented uncommitted state.
Do not manually clear, recreate or move the fence, delete output, automatically
undo, or infer completion from JSON/file existence. Explicit recovery must
re-establish coldness and both state/app identities; service registration,
intervening writes or unresolved processes can make it refuse. Fixed sealed
directory and injected-failure coverage is not arbitrary interrupted upgrade,
process-kill/power-loss or native installed acceptance.

## Internal rollback preservation boundary

There is still no `rollback-upgrade` operator command. The internal
`ColdRollbackPreparation.prepare/open` can verify and independently stage the
matching old app and whole old state without replacing the current generation.
Its `preserveCurrentState` now implements the first cutover phase: move the entire
current/failed state directory into the fixed `retained-current/state` checkpoint,
keeping its actual kernel owner and publishing a second persistent startup fence
before that path exists. The original canonical path stays fenced too, including
while vacant and after the maintenance process releases its locks.

`PreservedColdState.open` can reopen the fixed completed checkpoint, or finish a
post-move checkpoint with a complete sealed preparation and either a missing
completion or a complete sealed staged completion. It requires the exact original
state inode, both active fences, complete native contents, fresh kernel ownership
and cold observations; it never infers permission from JSON alone. Incomplete or foreign entries are
retained and refused. Preservation includes `run/`: entries not representable by
the full native manifest, such as links or special files, are refused rather than
silently omitted. This is not a general interrupted-rollback recovery protocol.

Preservation results keep `canonical_state_restored`, `committed`,
`startup_allowed` and `service_actions_performed` false. Preservation does not
install the old app/state at canonical paths or authorize manual fence removal.

The next internal primitive, `ColdStateLease.restoreForRollback`, can move an
independently held old whole-state directory into the original canonical state
slot while retaining the current generation, both real kernel owners and both
unchanged persistent markers. Its filesystem-only preparation callback must
prove the matching old pair and external inputs. The no-replace move preserves
the old directory inode and complete native contents, including `run/` rather
than silently omitting entries. A separate sealed restoration checkpoint binds
the old inode, preservation/fence evidence, both parents and all app placements.
Only that held typed context admits the replacement inode for owner rebind;
ordinary startup and the original fence's `verifyFor` remain strict.

`ColdStateRestoration` reports `phase: old_state_restored` and
`canonical_state_restored: true`, but `installed_pair_restored`, `committed`,
`startup_allowed` and `service_actions_performed` remain false. It does not move
an app, retire either fence, register or start a service. Pending restoration or
typed verification cannot release either owner. Late changed bytes, an occupied
target or changed provenance refuse success without automatic undo or repair;
a failure does not prove that the state move did not happen. Preserve every
input and checkpoint, await the original future and only then close handles.

`ColdStateRestoration.open` reopens only an explicitly selected post-move
checkpoint. The caller supplies the vacated staging slot, old/retained/logical
app slots, held original fence, preservation storage/name and restoration
storage/name; journal paths do not select arbitrary targets. The complete native
read set, both markers, exact parent/workspace/state identities and sealed records
are verified before either real state ownership or any host callback. Recovery
opens existing ownership and namespace files without recreating or normalizing
them. A contended state owner refuses before helpers and releases only newly
acquired recovery handles, not markers or another owner's lock.

Complete recovery is read-only. A post-move checkpoint with complete sealed
preparation and the exact moved old inode may finish a missing completion or
atomically promote a complete sealed `.completed.partial` without rewriting it.
Fresh cold observations, both kernel owners and the caller's filesystem-only
old-pair/external-input checks precede completion and are rechecked afterward.
Incomplete/ambiguous records, copied state, changed inputs or unknown entries
are retained and refused; recovery never reruns the state move or infers startup
permission from a JSON flag. Pending callbacks retain both owners and cannot
report completion or close the context early. Native hosts returned by recovery
factories are owned and closed by that context, including on failure.

Native retired/published host recovery can borrow the restoration's exact retained
fence and typed proof to verify the occupied canonical slot. The normal native
and preservation routes still refuse that layout without this proof. Published
host recovery repeats its existing isolated startup-refusal probe, never an
ordinary startup against either actual state generation. Do not reuse another
recovery route or alter markers to bypass a refusal.

This is not yet composed into `ColdRollbackPreparation` or an operator command.
Old-app/whole-state paired installation, interrupted paired replacement and
rollback commit remain unfinished. The cold-commit/manual-start upgrade sequence
above does not settle rollback fence retirement or imply that rollback is complete.

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
provide the fail-closed HTTP and native SQLite read-only components used by the
candidate-only composition above. They do not introduce an ordinary startup
bypass or service activation. Cold commit is the separate acknowledged action
described above, not a change to restricted validation admission.

Malformed/refused input returns exit 2; unverified native/filesystem/maintenance
completion returns exit 3. JSON includes the failed stage and false activation/
rollback authorization. Commit errors use the unknown (`null`) commit/startup
flags described above; other actions keep `committed: false`. A failure is
**not** proof that a rename did not happen. Retain all inputs, snapshots, work,
inspection output and every original/retained fence placement for investigation.
Do not retry with a different `--from` merely to bypass a refusal, manually clear
the fence, remove unknown entries, or overwrite a target.

Native command deadlines remain failures. If child exit is not yet confirmed,
the command waits on that original owned exit future while retaining its readers
and locks. Cold inventory awaits its original native isolate rather than
abandoning it on an observation deadline. Neither path restarts a command.

Local positive integration checks use real private files, SQLite, native metadata,
directory moves and kernel locks, with explicit external signature/ARM64/
component/service/process observation fixtures. Process-level help/input refusal
uses the real source command and Intel AOT entry checks. These are not genuine signed installed-product,
power-loss, whole-upgrade, Apple Silicon/VZ/GaoOS or M8/MVP acceptance results.
Apple Silicon execution remains assigned to the user.

The existing [CI workflow](../.github/workflows/ci.yml) compiles this separate
entry in the daemon's static-check matrix. Its macOS component job includes the
operator/recovery and inventory tests above. Workflow wiring and local checks
are not evidence that remote CI or signed installed-product acceptance ran.
