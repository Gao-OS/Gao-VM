# Persistent daemon admission during cold maintenance

The internal [`MaintenanceStateFence`](../daemon/gaovmd/lib/src/maintenance_state_fence.dart)
adds a cooperative startup guard outside the replaceable state directory. It is
a prerequisite for the accepted [cold upgrade design](proposals/MACOS_UPGRADE_ROLLBACK.md),
**not** an installed upgrade/recovery command or a complete transaction journal.
It does not replace an app/state tree, activate a daemon, clear a fence or authorize
rollback. No public API or driver authentication/generation rule changes.

## Ordinary startup

For a canonical state path, the marker is a sibling directory named
`.gaovmd-maintenance-<sha256-of-UTF8-canonical-state-path>`. The associated
`<marker>.lock` is a persistent private kernel-lock file. Neither is part of a
state snapshot; copying `.gaovmd.lock` does not transfer the original kernel lock
or protect a replacement root.

[`DaemonApplication.start`](../daemon/gaovmd/lib/src/daemon_application.dart)
checks marker presence before creating a missing state root, opening ownership
or SQLite, migrating legacy inputs, creating runtime directories or resolving
the driver. It checks again after observing a missing root, before `mkdir` can
fill a cold transaction's rename gap. New
[`DaemonOwnership`](../daemon/gaovmd/lib/src/daemon_ownership.dart) acquisition
checks before touching `.gaovmd.lock` and again after obtaining its kernel lock.
Existing held ownership stays valid while maintenance arms the guard.

Any marker entry blocks admission: directory, ordinary file, symlink or malformed
record. Startup neither reads its JSON nor repairs/deletes it. Native no-follow
presence lookup treats **only ENOENT** as absent; EACCES and other unavailable
evidence refuse startup. Dart's `FileSystemEntity.type()` is insufficient here:
the regression fixture reproduces its permission-error-to-`notFound` behavior.
Parent aliases such as `/tmp` resolve to the same canonical namespace. Unfenced
lookup supports missing ancestors without creating anything or requiring normal
startup's parent to be owned/private. Component/help probes remain state-free.

## Arm and retain

`begin` requires the caller's verified, still-held
[`ColdStateLease`](../daemon/gaovmd/lib/src/cold_state_lease.dart). It independently
checks the canonical, same-user parent and held path binding. The parent cannot
have group/other write access, special permission bits or ACL grants; `0755`
is permitted, while shared `0770` is refused without chmod. The parent's canonical
path must remain unchanged. Maintenance never moves the parent namespace.

An unused `<marker>.partial` is created privately. Its sealed `intent.json`
contains the original state path, native device/inode/UID/birth identity, owning
app path and bundle identifier (`gaovm.maintenance-state-fence.v1`). Files and
directory entries are synced, the cold boundary and exact staged record are
rechecked, then atomic no-replace rename publishes the marker. The published
record and original identity are checked again. Unknown existing destinations
are never overwritten. The native namespace-lock acquisition refuses unexpected
permissions, contents, hardlinks and ACLs on the opened inode, without normalizing
an existing lock.

The caller retains the original cold lease. `close` releases only this component's
readers and namespace kernel lock, **never the durable marker**. A process crash
therefore cannot silently enable ordinary startup. Failure retains partial/final
checkpoints and original state; post-publication failure never returns success.
A partial-only record is not an active guard: no tree retirement/publication may
start until `begin` has returned a valid, verified published fence.

## Explicit original-state recovery

`open` accepts an explicit canonical state target, derives only its fixed sibling
namespace and acquires the existing namespace lock nonblockingly. It never
recreates a missing lock. Private ownership, exact entries, bounded canonical
JSON/schema, sealed record permissions, single-link files and live path bindings
are checked. Concurrent recovery, foreign markers and damaged records refuse
without cleanup. Imported JSON paths do not select filesystem targets.

Only a held typed fence can be supplied to `ColdStateLease.acquire` through its
internal `maintenanceFence` argument. This still requires the real state-inode
kernel lock, matching original native identity and caller-supplied app/bundle
expectations, plus fresh owning-service, complete daemon/driver inventory and
state-reference checks. Native callbacks are followed by another fence/identity
check. A copied replacement root is refused; closing the fence invalidates its
dependent lease. Normal daemon startup has no recovery/bypass option.

The separate [old-app retirement phase](MACOS_APP_RETIREMENT.md) preserves this
original state inode and original app-slot binding. A freshly verified typed
retired host distinguishes the fixed installation slot from the observed old
app path; explicit adoption retains the same state kernel lock. This does not
widen `verifyFor` to copied/replacement state roots or clear ordinary admission.

This is cooperative admission for this daemon build, not an ACL barrier against
privileged/malicious writers, an old non-cooperating binary, or arbitrary external
renaming of the containing namespace. The future transaction must retain and
verify the parent, require a cooperating candidate, account for external writers,
and keep client writes fenced through explicit validation/commit. Record privacy
and current native checks are not independent signed-app or snapshot evidence.

## Acceptance boundary

The focused tests exercise real private files, SQLite, native metadata/ACLs,
kernel locks, the absent-root publication window, replacement-inode refusal and
a genuinely killed owned maintenance fixture whose exit is confirmed before
cleanup. Only external service/process/reference observations are replaced.
They also cover damaged/foreign records, concurrent recovery, cold revalidation,
late native-callback changes and publication failures with original preservation.

There is no begin/recover/clear CLI yet, no replacement-generation checkpoint,
activation/write isolation, validated commit/retirement, whole-state rollback or
uninstall transaction. The separate [paired snapshot](MACOS_RELEASE_INSPECTION.md#paired-old-app-and-state-snapshots)
does not arm this guard and still reports `replacement_startup_fenced: false`.
The separate [candidate preparation](MACOS_UPGRADE_PREPARATION.md) requires an
already-held typed guard and retains it; its durable `candidate_prepared`
checkpoint is not installed publication or replacement-generation recovery.
Its old-app retirement/gap-recovery step is separate from those later phases.
Full lifecycle crash/low-disk, genuine signed installed-product, ARM64/VZ and
GaoOS acceptance remain separate; this component does not complete M8.
