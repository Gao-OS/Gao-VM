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

Readiness and ordered guest execution are still unfinished. An allocated run
reaching `waiting_ready` is not evidence of a successful guest test.

## Host artifact collection

`TestRunCollectionWorker` reserves stable artifact IDs and an execution snapshot
in schema-v14 `test_run_collection` / `test_run_collection_items`. It publishes
driver and serial log snapshots, when present, and a structured JSON result under
the independent managed artifact root described in [ARTIFACTS.md](ARTIFACTS.md).
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

This path reuses schema-v14 checkpoints and the frozen TestRun DTO; it needs no
new migration or public response fields. Existing unrelated `cleaning_up`
decisions are not silently reinterpreted as `not_required`.

Cleanup for allocated VMs is still unfinished: stop/delete intents, ownership and
generation checks, cleanup failures, and final retention decisions must use the
existing VM primitives. The interaction of `always_delete` with
`retain_on_failure: true` needs an explicit accepted precedence decision; this
implementation does not choose one or silently delete a failed environment.

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
| TST-009, OP-002/004/006 | Pre-allocation abort completion, cancellation actions, rollback/reopen and background dispatch tests | Allocated-VM/active-step cancellation and cleanup |
| TST-007/008 | No-VM completion does not delete resources; failed environments remain intact during collection | Complete cleanup-policy/retention execution |

Focused validation:

```sh
cd daemon/gaovmd
mise exec dart@3.9 -- dart test --concurrency=1 \
  test/test_run_cleanup_worker_test.dart \
  test/test_run_collection_worker_test.dart \
  test/test_run_repository_test.dart \
  test/test_run_application_service_test.dart \
  test/test_run_api_handlers_test.dart \
  test/test_run_provisioning_worker_test.dart
mise exec dart@3.9 -- dart format --output=none --set-exit-if-changed bin lib test
mise exec dart@3.9 -- dart analyze
```

The standalone cleanup child must exit naturally after `close()`; the test does
not call `exit(0)` to hide timers or resource leaks. This proves component draining,
not an installed-daemon, launchd, or VZ transaction. The installed-daemon regression
in `daemon_application_test.dart` waits for durable completion before checking
TestRun/operation state and downloading the result through HTTP over UDS.

On the current macOS x86_64 validation host, installed startup is blocked before
listening: the native process census rejects unresolved executables. The same
guard failure was reproduced with the previously committed and current binaries;
source-based startup checks can also expire waiting for listening. No census,
ownership, handshake, or authentication guard is bypassed. Apple Silicon VZ,
native guest transport, GaoOS AC-06/07, packaging, launchd, signing, and release
validation remain unproven. These component checks do not satisfy those gates.
