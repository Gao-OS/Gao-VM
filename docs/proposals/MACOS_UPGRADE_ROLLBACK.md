---
title: macOS cold upgrade and whole-state rollback
status: accepted
updated: 2026-10-16
---

# macOS cold upgrade and whole-state rollback

This accepted design resolves the implementation boundary for development-plan
[M8.2/M8.3](../DEVELOPMENT_PLAN.md#m82-packaging). On 2026-10-15 the user selected
the **explicit cold operator workflow**, not automatic orchestration. The
transaction implementation and its acceptance remain unfinished.
Neither this document nor that implementation choice authorizes this agent to
replace an installed app/state tree or register/unregister a real service.

## Verified starting point

At local `main` revision `d0dd2c6`:

- [The assembler](../MACOS_PACKAGING.md) signs and atomically publishes a new
  app, refusing an existing destination. It checks architecture and signatures,
  not the actual daemon/CLI/driver roles or protocol compatibility.
- [The service helper](../MACOS_SERVICE.md) operates only on its own signed
  bundle. An unregister acknowledgement/`notRegistered` snapshot does not prove
  daemon or independent-driver exit. Its accepted interface is unchanged.
- [Cold backup/restore](../DATA_BACKUP.md) has isolated same-path filesystem/
  SQLite coverage, not an installed upgrade transaction. Current catalog code
  supports schema 21 and rejects newer schemas; this is not downgrade support.
- [DaemonOwnership](../../daemon/gaovmd/lib/src/daemon_ownership.dart) holds a
  state-directory lock; rename/publication requires retaining inode/path
  bindings, not assuming that a copied lock file protects a replacement tree.
- [Native inventory](../../daemon/gaovmd/lib/src/macos_driver_inventory.dart)
  rejects unresolved processes. Preserve that rule; do not filter unknown PIDs
  or infer exit from a missing executable, basename, socket or elapsed deadline.

The accepted plan requires a failed-upgrade rollback workflow, but does not
require *automatic* rollback. Either interface below must implement the same
data and ownership guarantees and still pass native lifecycle acceptance.

## Accepted interface

| Choice | Who establishes shutdown/activation | What the new tool must do |
| --- | --- | --- |
| Explicit cold operator workflow | Operator stops VMs/clients and unregisters the owning service; operator later acknowledges cold commit then manually starts, or requests rollback | Independently verify the cold boundary, snapshot, publish the candidate, retain old app/data, and perform explicit whole-state rollback only after a fresh cold check |
| Automatically orchestrated workflow | Tool previews required downtime and performs public VM actions and owning-helper service actions after explicit operator confirmation | All cold-workflow guarantees plus terminal Operation waits, authenticated readiness/compatibility probes, consent handling and failed-activation rollback |

Only the first choice is in the accepted implementation scope. The second is
retained here to identify the unselected alternative, not as additional work or
authority. The user also accepted one release cycle of public-API-only legacy
CLI compatibility; neither choice permits a second VM runtime or driver passthrough.

The maintenance implementation is separate from the `gaovm` public-API client.
VM actions, if orchestrated, still use the public API; do not add private driver
passthroughs, direct desired-state edits or alternate service-helper selectors.
Keep the maintenance executable outside any app/state tree it may rename, and
confirm each invoked helper's exit before moving its owning app. Do not unlink
a running maintenance/helper executable.

## Common upgrade state machine

| Phase | Required evidence before proceeding | Failure behavior |
| --- | --- | --- |
| Inspect | Exact original/candidate app identity, code signatures, canonical owned targets and independently verified role/version compatibility | Refuse before source app/data mutation; never report unverified compatibility as success |
| Establish cold boundary | Service cannot restart; actual daemon/driver exits, drained workers, exclusive bound state ownership, no active mutating Operations or external writers | Retain original paths and runtime evidence; an acknowledgement or timeout is not quiescence |
| Snapshot | Complete private state plus separately accounted external files; matching old signed app; verified durable snapshot/receipts at unused destinations | Retain partial output and original state; no force-overwrite or cleanup-based retry |
| Publish candidate | Verified staged signed candidate, retained old app/state, durable transaction checkpoint and startup/writer fencing through the publication window | Preserve both generations; incomplete publication must fail closed and expose a recovery action |
| Validate/commit | Expected versions, schema migration, installed public API/doctor, catalog identities and downloadable evidence; no intervening client writes before commit | Before fence retirement remain uncommitted; after an uncertain move retain all evidence for explicit recovery. Never equate a commit or static signature with product readiness |
| Roll back | Fresh proven cold boundary, verified old app and complete pre-upgrade state, same canonical path/UID, explicit acceptance of history/data rewind | Preserve post-upgrade state separately; restore the matching pair, not an old binary over a newer catalog |

Activation is distinct from publication. On 2026-10-16 the user selected the
cold-interface sequence: explicit `commit-upgrade` with complete cold revalidation
and `--allow-startup` acknowledgement, atomic retirement (not deletion) of the
startup fence, then manual operator registration/start. The tool does not start
the service or declare installed/Guest readiness. A prepared transaction is not
a commit; an interrupted commit requires explicit fixed-checkpoint recovery,
not blind retry or manually clearing a marker. This sequence does not authorize
this agent to operate an installed service or app/state tree.
For automatic activation, required user consent is a
distinct waiting/action-needed outcome, not failed readiness or permission to
retry registration. If quiescence cannot be re-established after failed
activation, retain all generations and stop before restoring over live writers.

## Data, safety and compatibility rules

1. Take the snapshot before any new daemon can migrate or write the catalog.
   It contains SQLite and sidecars, images, current writable VM disks/NVRAM,
   artifacts, logs, legacy backups, staging and ownership records. Unknown entries
   are retained, not classified as disposable by name. Omit `run/` only after
   the complete cold boundary is proven.
2. Keep operator-owned external disks/EFI stores at their original canonical
   paths. Account for their writers and matching bytes separately. Refuse a
   rollback whose external-file boundary cannot be validated; a managed-state
   archive is not their backup.
3. Require explicit canonical, same-user targets, disjoint source/candidate/
   backup trees, private snapshot storage and adequate disk space. Reject broad
   roots, symlink/identity substitution and unknown existing destinations.
   Preserve source inputs and failed staging. Do not delete state during install,
   upgrade, rollback or uninstall.
4. Use held directory identities, bounded locks, fsync and atomic no-replace
   publication with durable recovery checkpoints. App and state replacement are
   not one filesystem rename: fence startup/writes at every intermediate state.
   Recovery validates journal ownership, expected identities and current files;
   it does not trust journal paths as authority for arbitrary mutation.
5. Check actual component roles/build identities, public API major, VmSpec
   version, driver protocol/capabilities and supported catalog versions. A
   filename, `Info.plist` version, C signature fixture or assembly success does
   not prove those facts. Define the read-only component/version evidence before
   building the replacement transaction; an unavailable native probe is
   `unverified`, not compatible. Keep mandatory bidirectional hello/token/UID/
   generation checks for actual driver sessions.
6. Version doctor must distinguish installed app metadata, actual component
   versions, applied catalog schema and negotiated runtime compatibility. It
   remains read-only and is not a VZ boot or GaoOS Guest/TestRun acceptance probe.
7. Restore whole state for rollback. Never lower `user_version`, hand-edit IDs/
   revisions/generations or replace only `gaovm.db`. Retained failed TestRun VMs
   and their diagnostics are not upgrade garbage. Surface any shutdown that
   loses their live debugging state before obtaining downtime consent.
8. A snapshot rollback loses later writes and rewinds events/idempotency. Require
   explicit acknowledgement and a fresh client snapshot/cursor/retry review.
   Preserve both state generations and the snapshot until recovery is verified.

## First install and uninstall boundaries

First install uses the same identity/compatibility/publication checks, with no
overwrite of a foreign app or existing state. Register only the newly published
app's owning helper after operator authorization. A fresh catalog must not create
an implicit default VM; failed startup preserves newly created state for review.

Uninstall requires the same proven cold boundary and verified owning-app
identity. Retire the exact app recoverably, keep all VM/image/artifact/state and
external bytes, and report the retained paths. Service `notRegistered` alone is
not permission to remove the app or executable. Data deletion is a separate
explicitly authorized operation, outside this proposal.

## Implementation and acceptance work packages

1. Define and implement read-only component/version evidence and compatibility
   checks. Test wrong roles, API/driver/spec mismatches, unsupported catalog
   versions, tampering and missing evidence. Do not rewrite frozen public/driver
   schemas merely to avoid a mismatch.
2. Implement cold-boundary acquisition and complete durable snapshot/validation
   using the existing ownership/file primitives. Exercise real private files/
   SQLite; replace only external native process/service boundaries in fixtures.
3. Implement candidate publication and whole-state rollback with writer fencing
   and durable interrupted-transaction recovery. Implement the selected command
   interface, including explicit prepared/committed/retained recovery outcomes.
4. Cover crash/low-disk/injected-failure checkpoints before/after snapshot
   publication, app retirement, candidate publication, migration, activation and
   rollback. Assert complete byte/catalog preservation and no unknown/live target
   deletion, including retained failed TestRuns and external disks.
5. Test actual install, consent, installed start/restart, update with schema/
   protocol checks, failed-upgrade rollback and uninstall on an authorized native
   host. Then verify controlled VZ/Guest recovery and complete release gates.

The initial 2026-10-15 proposal checkpoint **did not claim any of those new work
packages implemented or passing**. Subsequent component evidence is recorded in
the [acceptance ledger](../MVP_ACCEPTANCE.md). Existing assembly/service/backup component results
are prerequisites, not lifecycle transaction acceptance. Apple Silicon execution
remains assigned to the user; no machine switch, live service action or release
publication is part of this design turn.
