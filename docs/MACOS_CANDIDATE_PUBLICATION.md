# Fenced candidate publication and recovery

The internal [`ColdUpgradePreparation.publishCandidate`](../daemon/gaovmd/lib/src/cold_upgrade_preparation.dart)
continues [old-app retirement](MACOS_APP_RETIREMENT.md). It publishes an
independent candidate copy at the fixed original installation slot while the
original state-inode kernel lock and persistent startup fence remain held.
This does not start/register a service, migrate the catalog, clear the fence,
commit an upgrade, or authorize rollback. The bounded
[cold operator command](MACOS_COLD_MAINTENANCE.md) composes these phases and
explicit recovery; neither interface authorizes changes to an actual installation.

## Inputs and ownership

`preparation.publishCandidate(storage, name)` requires the completed immutable
preparation, its original cold state/snapshot owners, matching typed fence and
native retired-app host. It derives the candidate from the fixed
`candidate-app/payload.app`, expected versions/Team ID from preparation, and the
catalog requirement from the independently inspected original catalog. The
candidate snapshot, old signed app and state snapshot are never moved out of
the preparation. Operator-owned external files remain separate accounted inputs,
not backed-up rollback payloads.

Storage is explicit private canonical same-user storage, disjoint from all
protected app/state/preparation/scratch inputs. Names follow the preparation's
1–128-character ASCII policy. The maintenance executable must remain outside
renamed inputs. The same `ColdStateLease` retains its actual original-state
kernel lock throughout; close is refused while publication is pending. Closing
after a terminal result releases readers, not retained bytes or the marker.

## Durable publication

```text
publication-storage/
  .gaovm-candidate-publication.lock
  name/
    intent.json
    candidate/{receipt.json,payload.app}  # payload moves to original app slot
    probe/
      state/canary
      .gaovmd-maintenance-<hash>/
    prepared/record.json
    .gaovm-maintenance.lock
```

Sealed/fsynced intent binds the original app/state/fence, retirement intent
digest/workspace, native parent/state/workspace identities, explicit candidate
provenance, complete candidate native manifest and expected release. It is
atomically published without replacement **before** copying/probing so probe
paths remain stable. An intent-only/partial workspace is retained, not promoted.

The candidate is copied independently with native metadata and capacity checks.
Fresh strict Developer ID, actual component/role/version/protocol/schema checks
precede execution. Its ordinary daemon entry is invoked against an isolated
private state with a synthetic blocking marker. It must exit 1 with the exact
maintenance-refusal diagnostic, no stdout, and no change to the complete probe
tree. A different failure, successful startup, new lock/DB/socket, or unconfirmed
child exit is not cooperation evidence. No new startup bypass flag is added.
The synthetic marker is **not** a typed state-maintenance authority.
Native unconfirmed command failures carry the original owned process's eventual
exit future. Cold-host/publication execution awaits that same handle before
unwinding readers or namespace ownership, then reports the command failure; it
does not restart the command or infer exit from a PID/time limit.

The sealed prepared record binds the exact staged candidate inode, wrapper,
receipt, release and probe evidence. After fresh cold/reference observations,
the coordinator re-reads complete original persistent/external inputs and all
preparation outputs using filesystem-only checks. One bound no-replace move
publishes the staged inode at the fixed original slot; both parents must sync.
The installed candidate is freshly inspected and probed again. Final original
input/output reads follow the last native observers. No unknown target is
removed, overwritten or permission-normalized.

Returned placement is `candidate_published`, with
`installed_candidate_published: true`, `activation_authorized: false`,
`rollback_authorized: false`, and `committed: false`. The immutable original
preparation still reports `candidate_prepared`; it is not rewritten into a
commit record. Candidate fence refusal proves this bounded cooperating-build
check, not isolation after an operator activates it.

## Explicit recovery

`MacOsColdStateHost.openPublished(...)` requires the original app/state, matching
typed fence, both explicit storage/name pairs, old/new versions, bundle/Team ID,
old inspection's catalog requirement and candidate catalog requirement. It
opens fixed children only. Journal paths are compared as provenance, never used
as arbitrary target selectors. Existing strict namespace locks are required.

Before any helper runs, recovery verifies sealed canonical bounded JSON,
workspace/parent/state bindings, retirement digest, every candidate/probe byte
and native metadata, and the independent receipt. Exactly one of the fixed
staged path or original installation slot must contain the recorded candidate
inode. Both/neither, a copy/substituted inode, foreign occupied slot, unknown
entry, damaged record/lock or disagreeing operator expectation is refused.
Fresh signatures/components, isolated ordinary-startup refusal and reference
checks then repeat. Reopening does not perform the physical publication.

After process exit, a fresh `ColdStateLease.acquire(...,
maintenanceFence: fence)` must still acquire the actual original state kernel
lock and re-establish native cold observations. No copied lock or receipt grants
ownership. The same publication call explicitly resumes a validated staged
candidate or revalidates an already-published one; it never automatically retries,
reverses, deletes evidence, or treats a failed post-rename check as proof that
the candidate stayed at its old path.
Explicit publication also re-syncs both held candidate-wrapper/installation
parents, including an already-observed published candidate after an earlier
post-rename failure. It attempts both and preserves the first sync failure.

## Verification boundary and remaining work

Local tests use real private files, native metadata, directory moves/inodes,
SQLite and kernel locks; external signature/ARM64/component/service/process
boundaries are fixtures. A focused test delegates the ordinary startup probe to
the actual source daemon, not the ARM64 header fixture. Neither is a genuine
signed installed-product acceptance result.

The accepted [cold operator workflow](proposals/MACOS_UPGRADE_ROLLBACK.md) still
needs activation/write isolation through validation/commit, fresh-cold
whole-state/app rollback with rewind acknowledgement and first install.
A separate [cold uninstall action](MACOS_COLD_MAINTENANCE.md#data-preserving-cold-uninstall)
composes exact-app retirement, retained-data evidence and explicit recovery.
Full process-crash/fsync/low-disk lifecycle and
genuine installed-product acceptance remain unproved. Apple Silicon/VZ/GaoOS
execution remains assigned to the user; this phase does not complete M8/MVP.
