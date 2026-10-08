# TestRun implementation boundaries

This records the current PR026 / M6 orchestration implementation against
[the development plan](DEVELOPMENT_PLAN.md) and [PRD TST-001..010](PRD.md#89-testrun).
It is not a claim that PR026, M6, or the MVP release gates are complete.

## Durable orchestration

The public create/get/cancel routes use `TestRunApplicationService`. Acceptance
persists the complete immutable spec, ordered step requests, a parent `test.run`
operation, events, and idempotent acceptance in SQLite. Handlers do not perform
provisioning, contact a driver, or wait for the test to finish.

Background workers currently implement:

1. Provisioning acceptance and recovery through a durable `vm.create` child and
   `test_run_vm_provisioning` ownership. The existing managed-disk worker publishes
   the isolated VM bundle before TestRun advances to `starting_vm`.
2. VM start acceptance and observation through durable lifecycle intents and
   `test_run_vm_start`. Driver generation and intent revision are checked before
   advancing to `waiting_ready`; start aborts have durable stop checkpoints.
3. Host artifact collection for runs in `collecting`.
4. Terminal completion for collected failures/cancellations which never allocated
   a VM, including cancellation or an overall deadline before provisioning.
5. Terminal completion of collected failures with `retain` or `delete_on_success`,
   preserving the allocated VM's current runtime state for manual debugging.
6. Allocated-VM cleanup through durable stop/delete child operations. The parent
   remains active until the selected lifecycle operation has finished and its
   generation, intent, resource, and lease checks prove cleanup completed.

Readiness and ordered guest execution are still unfinished. An allocated run
reaching `waiting_ready` is not evidence of a successful guest test.

## Host artifact collection

`TestRunCollectionWorker` reserves stable artifact IDs and an execution snapshot
in `test_run_collection` / `test_run_collection_items`, introduced in schema v14.
It publishes driver and serial log snapshots, when present, and a structured JSON
result under the independent managed artifact root described in [ARTIFACTS.md](ARTIFACTS.md).
Its result format is `gaovm.test-result.v1`.

Collection holds the existing per-VM filesystem lock, verifies provisioning and
bundle ownership, and reads held inodes without following links. Rotations are
concatenated oldest-first (`.3`, `.2`, `.1`, current), bounded to their sizes when
opened. Each log has a 64 MiB budget and the result has a 16 MiB budget; the
artifact store's global publication cap remains 256 MiB. A missing legitimate
log is recorded as absent; unsafe, unreadable, truncated, or oversized sources
have durable failure records. One run's failure does not stop another run.

Storage/SQLite failures are retryable infrastructure failures, not permanent log
source failures. Reserved-ID replay checks already committed metadata and bytes
before reopening a possibly rotated source. Completion verifies published payloads
and their associations before committing `completed_at` and
`test_run.artifacts_collected`. A published artifact is not republished on retry.

Collection does not stop/delete VMs or complete a parent operation. Its snapshot
records the execution outcome at collection reservation, not a claim about later
cleanup. Host artifacts currently receive a conservative 30-day retention deadline
because cleanup may still fail. Successful-run 7-day retention and retention-aware
garbage collection remain unfinished.

Guest stdout/stderr, guest system information, and native binary-stream collection
are not implemented by this host-log worker. It never invents guest output.

## Completion when no VM was allocated

`TestRunCleanupWorker` requires both a committed collection-completion checkpoint
and proof that no VM is bound **or owned by provisioning/start work**. A null
`TestRun.vm_id` alone is insufficient: provisioning can already own a VM before
the public TestRun binding is set.

For an eligible failed/cancelled run, one SQLite transaction:

1. Records `cleaning_up` with `cleanup_decision: not_required`.
2. Completes the TestRun and its parent operation with the durable planned outcome.
3. Completes matching TestRun/operation cancellation actions.
4. Commits their events and outbox rows together.

`not_required` means no VM was ever allocated; it does not attest VM deletion.
No filesystem removal, VM lifecycle command, or cleanup-policy precedence choice
occurs on this path. The original failure remains primary. A failed final commit
leaves the run collecting, its operation active, and its artifacts intact for retry.
Reopening the catalog does not duplicate completion or artifact publication.

This path still uses the collection checkpoint and frozen TestRun DTO; schema v15
does not change VM-free completion or public response fields. Existing unrelated
`cleaning_up` decisions are not silently reinterpreted as `not_required`.

## Retaining a failed VM

PRD UC-03 requires a failed test VM to remain running for manual debugging.
For a failed outcome, neither `retain` nor `delete_on_success` requests deletion.
After committed collection, the cleanup worker verifies the exact provisioning
ownership, its settled `vm.create` child, and any existing start VM binding. One
transaction records `cleanup_decision: retain`, completes the failed TestRun and
parent/cancellation actions, and commits their events/outbox rows. It does not
stop/restart the VM or change its spec, desired state, phase, or driver generation.
It also leaves already-stopped/failed VMs in their current state rather than
inventing a successful runtime recovery.

Retention must inspect the catalog's deletion fence, not just runtime phase:
`vm.delete` acceptance sets `deleting_at` before its asynchronous command begins
teardown. If deletion has been accepted or the VM is already tombstoned, cleanup
records a non-retryable secondary `VM_OPERATION_CONFLICT` or `VM_NOT_FOUND` failure
at `cleaning_up` and completes the failed run without interfering with deletion.
`retain` records the selected decision, not a claim that a concurrently deleted
VM was retained. The failure event carries the retention diagnostic; the original
failure (including a guest exit code when supplied) remains primary on the run and
parent operation. A lost/mismatched ownership checkpoint is an infrastructure
error which blocks that run, not authority to adopt another VM or starve peers.

Retention and all terminal records are atomic. A failed commit leaves the run
collecting, cancellation actions pending, and published artifacts/VM state intact;
reopen/retry completes once without duplicate artifacts or completion events.
This uses existing public fields/decisions. Unrelated durable cleanup decisions
are not silently reinterpreted as retention.

## Allocated-VM lifecycle cleanup

Schema v15 adds the immutable `test_run_vm_cleanup` checkpoint and a bounded-scan
index. The checkpoint links the run and its owned VM to one stop/delete child,
intent revision, spec generation, and driver generation. The migration is additive;
existing TestRun specs, ownership, collection checkpoints, and artifact references
remain unchanged. It adds no public API or driver/guest protocol fields.

After collection, the selected actions are:

| Outcome | Policy | Cleanup action |
| --- | --- | --- |
| Succeeded | `delete_on_success` or `always_delete` | Delete through the normal stop/release/remove/tombstone lifecycle |
| Succeeded | `retain` | Stop and retain the bundle |
| Cancelled | `always_delete` | Delete through the normal VM lifecycle |
| Cancelled | `retain` or `delete_on_success` | Stop and retain the bundle |
| Failed | `always_delete`, `retain_on_failure: false` | Delete through the normal VM lifecycle |
| Failed | `retain` or `delete_on_success` | Preserve the current runtime for manual debugging, as described above |
| Failed | `always_delete`, `retain_on_failure: true` | Defer pending an accepted precedence decision |

The last combination remains unresolved; no policy precedence is invented.
Successful-artifact 7-day retention and retention-aware garbage collection also
remain unfinished.

Stop/delete acceptance runs under the existing per-VM controller gate. One SQLite
transaction records `cleaning_up`, the selected decision, the child operation and
command, immutable checkpoint, events, and outbox. Filesystem/driver work stays
outside that transaction and uses the existing guarded VM primitives. Repeated
passes and catalog reopen reuse the same child rather than accepting another
destructive intent. Cleanup does not inherit an already-expired TestRun deadline.

Before accepting a stop/delete, the worker checks provisioning ownership and the
TestRun's last owned start/abort intent, applied intent, pinned spec, and known
driver generation. A newer user intent, spec, or generation produces a durable
cleanup conflict instead of stopping/deleting that environment. Terminal observation
also requires the checkpoint's revision/generations, desired `stopped`, no VM leases,
and either a stopped unfenced VM or a deleted tombstone. A failed child or mismatched
completion fails the run; an earlier test failure stays primary, with the cleanup
failure recorded independently. Managed artifacts and source images are not removed
with the temporary VM bundle.

## Daemon lifecycle

The daemon starts provisioning, VM-start, collection, and cleanup loops only after
native previous-owner recovery, store reconciliation, scheduler recovery, and
ownership verification. Each loop has bounded, non-overlapping passes, per-run
failure reporting with available correlation IDs, and a fenced/drained close.
Shutdown closes public requests/streams, fences the producers, and drains them
alongside controller/scheduler shutdown before closing shared SQLite and roots.
These workers are not activated by status requests or client polling.

## Requirement evidence and remaining scope

| Requirement | Current component evidence | Still required |
| --- | --- | --- |
| TST-001/002/010 | Durable acceptance, isolated provisioning and start checkpoint tests | Full parallel guest-test transactions |
| TST-006 | Real host log/result bytes, stable-ID replay, crash and corruption tests | Guest stdout/stderr/system info and real GaoOS collection |
| TST-009, OP-002/004/006 | Pre-allocation abort completion, cancellation actions, retained-VM stop before cancellation completion, rollback/reopen and background dispatch tests | Active-step cancellation and full guest-to-cleanup transactions |
| TST-007/008, UC-03 | Failed-runtime retention, deletion/stop child completion, independent artifact survival, schema upgrade and checkpoint replay tests | Complete policy/fault matrix, accepted failure-override precedence, successful-artifact retention, and real guest failure retention |

Focused validation:

```sh
cd daemon/gaovmd
mise exec dart@3.9 -- dart test --concurrency=1 \
  test/test_run_cleanup_worker_test.dart \
  test/test_run_collection_worker_test.dart \
  test/test_run_repository_test.dart \
  test/test_run_application_service_test.dart \
  test/test_run_api_handlers_test.dart \
  test/test_run_provisioning_worker_test.dart \
  test/artifact_repository_test.dart \
  test/sqlite_database_test.dart \
  test/sqlite_vm_managed_file_effect_adapter_test.dart
mise exec dart@3.9 -- dart format --output=none --set-exit-if-changed bin lib test
mise exec dart@3.9 -- dart analyze
```

The standalone cleanup child must exit naturally after `close()`; the test does
not call `exit(0)` to hide timers or resource leaks. This proves component draining,
not an installed-daemon, launchd, or VZ transaction. The installed-daemon regression
in `daemon_application_test.dart` waits for durable completion before checking
TestRun/operation state and downloading the result through HTTP over UDS.

Allocated fixtures supply upstream success/failure/cancellation through the durable
repository because readiness and guest execution are not yet wired. Their
provisioning, image store, artifacts, lifecycle dispatcher/controller, scheduler,
and managed deletion are real components; only the VZ boundary, clock, and host
metrics are simulated.
They prove retention/cleanup behavior, not native guest execution or GaoOS AC-06/07.

On the current macOS x86_64 validation host, installed startup is blocked before
listening: the native process census rejects unresolved executables. The same
guard failure was reproduced with the previously committed binary and current
source-based startup checks. No census, ownership, handshake, or authentication
guard is bypassed. Apple Silicon VZ,
native guest transport, GaoOS AC-06/07, packaging, launchd, signing, and release
validation remain unproven. These component checks do not satisfy those gates.
