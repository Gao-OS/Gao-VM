# Cold old-app retirement and recovery

The internal [cold preparation](MACOS_UPGRADE_PREPARATION.md) can now retire
its exact original app into a private journal namespace, keeping the original
state-inode kernel lock continuously held. It does **not** install a candidate,
start/register a service, clear a fence, commit an upgrade or authorize rollback.
There is still no install/upgrade maintenance CLI. These interfaces do not grant
permission to act on a real installed app/state/service.

## Ownership and inputs

`ColdUpgradePreparation.retireOriginalApp(storage, name)` first verifies the
completed checkpoint, source catalog/runtime/external-file boundary, all retained
payloads and the existing typed admission fence. Storage is an explicit private,
canonical, same-user directory, disjoint from the app/state/preparation/scratch
inputs. The maintenance executable must be outside every renamed input. Names
use the preparation's 1–128-character ASCII policy and cannot end in `.partial`.
An unknown final or partial destination is refused without cleanup.

The state lease must have a freshly inspected `MacOsColdStateHost`, not a generic
service-status fixture or arbitrary path override. Its new `installationPath`
is the fixed original installation slot; `appPath` is the currently verified
observed app. The existing state lock is neither closed nor reacquired during
the move or subsequent host adoption. The original state inode and fence's
original app/bundle binding are unchanged; this does not admit a replacement
state directory. Closing a lease while retirement/adoption/publication is pending
refuses without releasing ownership. Callers must await its actual terminal result.

## Intent before movement

```text
retirement-storage/
  .gaovm-app-retirement.lock
  name/
    intent.json
    GaoVM.app/
```

A private `.name.partial/intent.json` is sealed and fsynced, its directory and
parent synced, then atomically published as `name` without replacement **before**
moving the original app. The bounded canonical JSON binds the explicit original
app/state/fence, bundle/version/Team ID/catalog requirement, original app and
parent identities, state/workspace identities, and full native/content manifest
plus release evidence. The namespace lock is private, empty, single-link and
ACL-free; an existing lock is never normalized.

After the last external service/process/reference callback, the coordinator
rechecks all persistent bytes, held external dependencies, runtime/legacy files,
original app/native metadata and independent checkpoint payloads/records using
filesystem-only reads. A late unknown state write is refused before movement.
One [bound no-replace move](MACOS_UPGRADE_PREPARATION.md#bound-cross-parent-directory-move-prerequisite)
then relocates the original app into the fixed `GaoVM.app` child. Both parent
namespaces must sync and pass binding checks; the original inode is retained.

The relocated app undergoes fresh strict Developer ID/actual-component/version/
compatibility inspection and full native-manifest verification. Only then does
the held lease adopt a new native host bound to that tree. Service status invokes
only that app's owning helper; inventories cover both original and retired daemon/
driver paths, even though the original slot is absent. All unresolved PIDs remain
blockers. State references and other processes' references to the retired app
are also blockers. No PID is signalled and no service action is orchestrated.

The returned observation is `old_app_retired`, with candidate publication,
activation and rollback authorization all false. The original immutable
`candidate_prepared` record is not rewritten into a transaction/commit record.
Its snapshots, candidate and receipts remain intact and can be reopened against
the verified retired host and original held state boundary.

## Explicit gap recovery

`MacOsColdStateHost.openRetired(originalApp, state, fence, storage, name, ...)`
requires every target and expected bundle/version/Team ID/catalog requirement
explicitly. It opens only the fixed namespace and fixed `GaoVM.app` child;
journal paths are compared, never followed as target selectors. The existing
namespace lock is required. Before running any helper it checks exact entries,
private canonical storage, original parent/workspace/app identities, original
state/fence binding, native metadata and complete content. It repeats fresh
signature/component/reference checks and filesystem validation after callbacks.

For `openRetired`, the original installation slot must be absent. An occupied slot
is unknown input, **not** an inferred candidate, and is never replaced. Copies, substituted
inodes, damaged/foreign records, changed locks, unexpected entries, mismatched
operator expectations and concurrent recovery are refused without repair.
Partial-only or intent-only pre-move output is not promoted or automatically
continued; inspect and retain it alongside the still-original app.
The separate [`openPublished` recovery](MACOS_CANDIDATE_PUBLICATION.md) admits
only the exact independently staged candidate under its matching typed journal;
it does not weaken `openRetired` or infer a candidate from an occupied slot.

After a maintenance process exits, reopen the persistent state fence and this
retired host, then `ColdStateLease.acquire(..., maintenanceFence: fence)` must
acquire the actual original state kernel lock and re-establish all native cold
observations. The journal cannot grant ownership. A fresh state inspection and
preparation reopen are still required before transaction work continues.

If an in-process move finished but its later inspection failed, the existing
lease retains its actual state lock. Explicitly reopen the typed retired host
and call `lease.adoptRetiredApp(host, fence)` to revalidate and transfer host
ownership **without** releasing that state lock. Failure never causes an implicit
reverse move, app deletion, state replacement or retry. A failure may be after
rename; inspect both locations and retained intent rather than assuming that
the original path remains intact.

## Acceptance and remaining work

Tests use real private files, SQLite, directory moves/inodes, native metadata and
kernel locks; only external signature/component/service/process/reference
observations are explicit fixtures. They cover prepared-state integration,
reopen, continuous ownership, post-move inspection failure and typed adoption,
pending-close refusal, late state writes, app references, unresolved processes
at both locations, foreign-slot preservation and record/lock/inode tampering.
The integrated test now also exercises independent candidate publication with
its own five-minute limit. Cleanup retains inputs/owners if work has not settled.

This is recovery of the **old-app retirement gap**, not replacement-generation
or full transaction recovery. Independent staged candidate publication and
candidate fence-cooperation evidence now have a separate
[implementation](MACOS_CANDIDATE_PUBLICATION.md). Activation/write isolation through
explicit validation/commit, whole-state/app rollback with rewind acknowledgement,
data-preserving uninstall and the operator command remain unfinished. Full
process-crash/fsync/low-disk lifecycle and genuine signed installed-product
acceptance are unproved. Apple Silicon/VZ/GaoOS execution remains assigned to
the user; no M8/MVP or release-completion claim follows from this component.
