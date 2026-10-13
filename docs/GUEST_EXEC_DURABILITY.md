# Guest execution durability boundary

This is the host execution boundary for development-plan M6 and PRD `GST-004..007`
and `OP-001..007`, including production daemon composition, not installed-service
or GaoOS acceptance. The daemon registers `POST /v1/vms/{vm_id}/guest/exec` and
routes its cancellation through durable application services. Its bounded worker
uses [host stdout/stderr publication](GUEST_ARTIFACT_PUBLICATION.md). Host
collection is documented in [TEST_RUN_ARTIFACTS.md](TEST_RUN_ARTIFACTS.md);
native integration acceptance remains unfinished. Ordered TestRun execution
now uses this worker through the [durable step coordinator](TEST_RUN_STEPS.md).
The frozen [public request](../schemas/openapi/gaovm-v1.yaml),
[guest control protocol](../schemas/guest-protocol/v1.schema.json), and accepted
[bridge](proposals/GUEST_DRIVER_BRIDGE_V1.md) and
[binary](proposals/GUEST_BINARY_STREAMS_V1.md) contracts are unchanged.

## Acceptance

`GuestExecApplicationService.execute` uses the existing VM controller's short
durable-write gate. It does not call a driver or perform guest IO. SQLite checks
the current running VM, deletion fence, original driver generation, applied spec
and execution checkpoint, and authenticated readiness. Admission uses the
**applied** guest setting, not a newer unapplied spec. One unfinished exec per VM
conflicts; different VMs have independent intents.

One transaction commits the pending `guest.exec` Operation, immutable
`guest_exec_jobs` binding, operation-created event/event outbox, and `guest.exec`
work outbox. Schema migration 17 adds the job and cancellation tables. Acceptance
does not change VM desired state, spec, or runtime phase.

Idempotency is scoped to the exact method and VM. It hashes original request
bytes and replays the acceptance-time snapshot, even after completion, catalog
reopen, or VM unavailability. It never reconstructs acceptance from a later
operation state. Failed publication rolls back the retry reservation too.

## Attempt ownership

Before sending `exec.start`, a worker must capture the original authenticated
connection and call `beginAttempt` with its current-epoch predicate. This
database-only controller action atomically commits a one-shot attempt ID/start
marker, original `controlEpochId`, Operation transition, and event/outbox. Migration
18 adds the immutable control epoch binding; historical started jobs without that
evidence stay uncertain and cannot be rebound. It rejects caller-owned
uncommitted savepoints and rechecks epoch validity through the write boundary.
The worker also commits the original Operation deadline with that marker: the
requested execution budget plus one shared 65-second output completion allowance,
capped by the original parent deadline when the child belongs to a TestRun.
Polling, reconnect and sibling transfer cannot renew this monotonic deadline.

The marker proves authorization, **not** delivery or guest execution. A committed
marker cannot be cleared, claimed again, or transferred to a replacement
connection. Duplicate dispatch and catalog reopen cannot authorize another
`exec.start`. Recovery must resolve a started attempt's uncertainty rather than
replay it. A new explicit command is a separate operation, not recovery of the
old command. Original-owner retirement must be established before startup
recovery or a replacement connection is allowed to perform guest work.

## Cancellation and failure

Cancellation first commits intent, an `operation.cancel` action targeting the
original Operation, its immutable mapping, and a work wakeup. It does not mark
the target cancelled or claim that guest cleanup has completed. The intent
prevents an unstarted attempt from being claimed.

`cancelBeforeStart` can confirm cancellation only when no attempt was authorized.
It atomically cancels the target and succeeds all pending cancellation actions.
Once an attempt exists, an independently owned monitor sends `exec.cancel` on the
original connection even while `exec.status` is stalled. A validated terminal
receipt, complete output mappings and joined transfer cleanup are required before
settlement. A cancellation request alone never proves process-group cleanup.

`failAttempt` checks the original attempt ID and settles once. If the outcome is
unknown, the target and cancellation actions fail; they do not report successful
cancellation. Job completion, operation transitions, and event/outbox writes
commit together without modifying VM lifecycle or entering driver retry policy.

## Guest wire boundary

`GuestExecRequest` validates the frozen public argv/cwd/env/timeout/capture shape
and retains immutable guest data. It adds no shell expansion, host cwd lookup,
or invented public environment-count limit.

`GuestControlConnection.execStart/execStatus/execCancel` use the original
VM/generation/operation binding and bounded shared RPC pool. Results require
strict fields, UTF-8 inline byte accounting and the requested capture bound.
Integer-valued JSON decimals/exponents are checked from their exact tokens;
fractional values cannot round into integers. Streaming request encoding stops
at the 16 MiB frame budget before request admission or guest bytes; unsent
rejection leaves a healthy epoch usable.

Guest artifact IDs remain private correlations. A typed guest response is not a
durable public result and must not expose those IDs as host-owned artifacts.
The host artifact library snapshots a validated terminal result and both
sibling references before bounded binary receive. It commits host-generated
artifact IDs/mapping and managed bytes before ACK, and rewrites a complete public
result only after all output mappings exist. Those library reads never complete
an Operation or send a replayed command. `completeAttempt` atomically settles the
job, target Operation, cancellation actions and event/outbox using only this
original durable receipt. Failed and cancelled results retain mapped diagnostics.

## Dispatch and startup recovery

`GuestExecDispatchLoop` scans committed jobs in bounded, non-overlapping passes.
`GuestExecWorker` reserves one local owner before IO and allows different VMs to
progress concurrently. Repeated dispatch joins the original owner; a foreign
started marker is never adopted. Correlated work-outbox rows are acknowledged
only after terminal settlement. Shutdown fences producers, closes original
channels and joins actual IO/cleanup before releasing the shared catalog.

The runtime adapter exposes only an already-ready exact-generation connection;
this lookup cannot establish or reconnect a guest channel. Missing readiness
before authorization fails as `not_started`. Lost delivery or control after the
marker fails as non-retryable `unknown`, without changing VM lifecycle or issuing
a replacement `exec.start`. A durable terminal result with incomplete diagnostics
is reported separately as `known_result_incomplete`.

Startup recovery runs before controllers, workers or the public listener
activate. Production composition requires previous-owner teardown and a fresh
complete native driver census under daemon ownership. Unresolved executables
still fail the barrier. Only after retirement can it cancel/fail unstarted work,
finish known original results, or settle started uncertainty without guest IO.
Mapped output is revalidated against the managed manifest, inode, size and digest
before known recovery completion. Corruption cannot turn into a successful
publication. Fixture retirement callbacks do not prove native process retirement.
TestRun step recovery runs after this guest-job settlement and before either
dispatch loop starts; it cannot activate a controller or replay a child.

## Verification

From `daemon/gaovmd`:

```sh
mise exec dart@3.9.0 -- dart test \
  test/guest_exec_application_service_test.dart test/guest_exec_request_test.dart \
  test/host_guest_session_test.dart test/host_guest_artifacts_test.dart \
  test/guest_readiness_test.dart test/resource_api_handlers_test.dart \
  test/sqlite_database_test.dart
```

Tests use real SQLite transactions/reopen, authenticated Unix socket fixtures and
the public HTTP/UDS route, with hardware substituted only at the runtime boundary.
They cover acceptance/retry/conflicts, one-shot execution, mapped output download,
stalled-status cancellation, two-VM independence and original-owner recovery.
They do not prove
native vsock, Apple Silicon driver support, real GaoOS execution or spilled
artifacts, installed API completion, or daemon-restart E2E. Optional native guest
capability advertisement remains disabled pending that acceptance.
