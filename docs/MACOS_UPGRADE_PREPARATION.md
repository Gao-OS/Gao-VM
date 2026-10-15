# Fenced cold-upgrade preparation

The internal [`ColdUpgradePreparation`](../daemon/gaovmd/lib/src/cold_upgrade_preparation.dart)
composes a caller-held [cold state snapshot](MACOS_RELEASE_INSPECTION.md#guarded-persistent-state-snapshots)
and [persistent admission fence](MACOS_MAINTENANCE_FENCE.md). It creates and
reopens a `candidate_prepared` checkpoint. It does **not** replace the installed
app/state, activate a service, authorize rollback, or complete an upgrade.
There is no preparation/install CLI yet. The read-only release inspector's
command remains unchanged.

## Inputs and ownership

`create(state, fence, storage, name, candidateApp: ..., oldVersion: ...,
newVersion: ..., teamIdentifier: ...)` requires the original live
`ColdStateSnapshot`, matching typed `MaintenanceStateFence`, private canonical
same-user storage, and explicit candidate/expected identities. Source app,
state, inspection scratch, candidate and output must be disjoint. Names are
1–128 ASCII letters/digits/dots/underscores/hyphens, start with a letter/digit,
and cannot end in `.partial`. Hidden staging names are not recovery targets.

It derives the catalog requirement from the independently inspected source
catalog, not a caller-provided schema. A pre-catalog state requires schema 0;
the recorded observed schema remains null. Old app, candidate input and staged
candidate all undergo the existing strict Developer ID signature/actual-role/
version/API/VmSpec/driver/catalog checks. This does not prove applied migration,
runtime negotiation or product readiness. Current native ARM64 execution
requirements are unchanged; positive Intel tests replace that external boundary.

The object holds its storage kernel lock and original-app/workspace readers.
It borrows state, fence and storage; `close()` releases only its own handles.
The caller must retain all borrowed owners. A closed owner or failed fresh
cold check invalidates further verification. Closing never removes snapshots,
staging, namespace locks or the persistent daemon admission marker.

## Durable output

```text
storage/
  .gaovm-upgrade.lock
  name/
    intent.json
    original-app/{payload.app,receipt.json}
    original-state/{payload,receipt.json}
    candidate-app/{payload.app,receipt.json}
    prepared/record.json
    .gaovm-maintenance.lock
```

Preparation first creates private `.name.partial`, seals/fsyncs `intent.json`,
and syncs the workspace and parent **before copying**. The intent binds the
original app/state and workspace native identities, expected versions/Team ID,
bundle, catalog schema and held fence. Then it copies old app, complete persistent
state and candidate with the existing native-metadata-preserving snapshot
primitives. Only the guarded state snapshot omits root `run/`; external files
remain separately accounted original inputs, not backed-up payloads.

After checking the staged candidate it seals/fsyncs the completed record in
`.prepared.partial` and atomically publishes `prepared` without replacement.
It independently verifies original content/native metadata, all three payloads,
nested receipts, exact wrapper entries and records before and after publishing
the outer workspace via atomic no-replace rename. Full original persistent
reads run after the last external native callbacks, covering unknown data too.
Capacity is estimated for the combined copies; individual snapshot checks and
actual writes can still fail. No failure authorizes deleting retained output.

The completed record reports:

- `phase: candidate_prepared` and `ordinary_startup_fenced: true`;
- `installed_candidate_published: false`;
- `external_files_backed_up: false` and `rollback_authorized: false`.

These are bounded checkpoint facts, not a replacement-generation writer fence
or a transaction commit. Admission applies to this cooperating daemon build,
not an old non-cooperating binary; component versions alone do not establish
candidate cooperation. The marker remains necessary when maintenance exits.

## Reopen, refusal and remaining work

`open(state, fence, storage, name, oldVersion: ..., newVersion: ...,
teamIdentifier: ...)` needs a live original cold boundary again. After process
exit, reopen the persistent fence and acquire the actual original state kernel
lock, then prepare a fresh private inspection copy. A receipt or copied lock is
never a replacement for those steps.

Recovery opens only fixed children below explicit caller targets; imported paths
are provenance, not filesystem selectors. It requires the existing private
namespace lock without recreating/chmodding it; validates canonical sealed JSON
records (64 MiB each maximum), exact phase/expectations, native workspace/source
identities and all receipts/payloads; and repeats fresh signatures, component,
cold-state and reference checks. The original candidate download directory may
be gone: recovery checks the fixed `candidate-app/payload.app` instead. A copied
workspace, disagreeing operator identity, partial checkpoint, damaged record,
unknown entry or changed native boundary is refused, retaining all evidence.
There is no automatic promotion/repair/removal of partial or malformed output.

Tests use real private files, SQLite, native metadata and locks; only external
signing/component/service/process observations are boundary fixtures. They
exercise interruption before/after the prepared checkpoint, fresh reacquisition,
late source writes, record/payload/lock tampering and concurrent recovery. They
do not simulate a complete upgrade process crash, low-disk lifecycle, real
installed publication or migration.

The [accepted cold operator workflow](proposals/MACOS_UPGRADE_ROLLBACK.md) still
needs a maintenance executable outside renamed trees, original-app retirement
and cross-parent candidate publication, identity-safe interrupted replacement
recovery, activation/write isolation through validation/commit, fresh-cold
whole-state/app rollback with rewind acknowledgement, and data-preserving
uninstall. Genuine signed installed-product and ARM64/VZ/GaoOS acceptance remain
unproved. This preparation component does not complete M8 or the MVP goal.

## Bound cross-parent directory move prerequisite

The internal [`OwnedImageDirectory.moveForMaintenanceTo`](../daemon/gaovmd/lib/src/maintenance_directory_move.dart)
now provides the missing physical move between two held parent namespaces.
It requires the exact owned source directory and explicit source/destination
parent descriptors. Parents must be canonical, same-user, without shared write
bits, special permission bits or ACL grants; owned 0755 application directories
are allowed. It does not change permissions or remove an unknown destination.

Native no-follow source lookup must match the held source inode. One Darwin
`renameatx_np(..., RENAME_EXCL)` moves it without replacing any file, symlink or
even an empty directory. Both parent directory entries are fsynced; identity
and parent bindings/permissions are rechecked. Cross-device/native failures do
not fall back to copy/delete. The new reader binds the same inode at its new
path; the borrowed old reader deliberately keeps its old path and becomes
invalid there. All input handles remain caller-owned.

[`MaintenanceTree.moveForMaintenanceTo`](../daemon/gaovmd/lib/src/maintenance_tree.dart)
additionally verifies complete bytes/native metadata before and after moving,
then returns a new tree reader. A guarded state view cannot transfer its cold
boundary through this method. A post-rename verification/fsync failure is an
unverified move, **not** evidence that the old path still exists: retain both
namespaces for journal/identity-based recovery. Neither method auto-reverses,
deletes, retries, closes input owners or flushes uncommitted payload writes.

The caller must serialize both namespaces, flush the payload and persist intent
before moving, retain the cold state kernel lock/admission fence, confirm all
native helper exits, and run maintenance outside renamed trees. These primitives
are cooperative observed-identity checks, not protection from a malicious same-UID
writer racing the syscall. Source ACL/xattr/flags are preserved, not accepted
as signed-release or cold-state authorization.

These methods are not wired to an install command. Do not move the retained
`candidate-app/payload.app` out of the immutable preparation checkpoint; a later
publisher needs its own verified staged copy. Moving the installed old app also
invalidates its existing `MacOsColdStateHost`, original app reader and preparation
verification. A typed, journaled cold-host/ownership handoff and recovery of the
retirement gap are still required; releasing the state lock or ignoring those
failed checks is not a valid workaround. This prerequisite does not complete
candidate installation, activation/commit, rollback or uninstall.
