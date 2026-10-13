# Durable TestRun guest steps

This implements the host coordinator boundary for development-plan M6.6 and PRD
`TST-004`, `TST-005`, and the ordered-step portion of `TST-009`. It is wired into
the production daemon; fixture checks do not establish installed-service,
native vsock, or GaoOS acceptance. [Host artifact/system-info collection](TEST_RUN_ARTIFACTS.md)
is now composed with this worker; the real-image M6/M8 gates remain unfinished.

## Acceptance and execution

`TestRunStepWorker` scans committed `running_steps` runs. It accepts only the
first unfinished step, through `GuestExecApplicationService.executeStep` and the
existing VM controller's short database-write gate. It never performs guest IO
or exposes a public driver passthrough. The original VM-start operation,
driver generation, accepted/applied intent and spec checkpoint must still match.
The guest worker checks that checkpoint again before authorizing IO.

One SQLite transaction starts the step, creates its child `guest.exec`
Operation, job, events and outbox rows, and records their immutable association
in `test_run_step_execs`. Migration 19 adds this association without changing
historical jobs, operations, steps, events or pending work. Duplicate acceptance
returns the original child; later steps cannot start out of order. Binding
publication failure rolls back the entire acceptance.

The frozen TestRun step request has no capture configuration. Execution uses
the persisted argv/cwd/env/timeout, captures both outputs, and uses a 64 KiB
inline threshold with the existing 16 MiB combined output limit. No public field
or frozen schema was added. An invalid guest request fails durably as
`INVALID_REQUEST` before child acceptance.

The [guest execution worker](GUEST_EXEC_DURABILITY.md) owns the original
authenticated connection, one-shot authorization marker, terminal receipt and
joined transfer cleanup. It retains the requested execution timeout and caps
its whole completion budget by the original overall TestRun deadline, when
present. Neither polling nor the next step renews that overall deadline.
Managed stdout/stderr artifacts are associated with the parent TestRun and
downloadable through `/v1/artifacts/{artifact_id}`; guest artifact IDs remain
private correlations.

Only a completed child job can finish its step. A successful result permits
the next step; failure preserves diagnostics and skips pending steps. When
all steps finish, the run enters `collecting`, not a terminal success state.
Existing collection and cleanup workers own the remaining lifecycle.

## Cancellation and interruption

Parent cancellation atomically flags the original unfinished child and emits
its work wakeup. The independent guest cancellation monitor can send
`exec.cancel` while status polling is stalled. The coordinator waits for actual
child settlement and cleanup before leaving the running step; no subsequent
step starts. Pre-step cancellation skips pending steps without guest IO.
Overall deadline expiry similarly stops future steps and reports `WAIT_TIMEOUT`.
Unknown child outcomes are failures, not proof of successful cancellation.

Startup order is original-owner teardown and complete native driver census,
guest-job recovery, step recovery, then diagnostic recovery, before any current controller, dispatch
loop or public listener activates. A failed retirement barrier cannot settle a
run. Recovery consumes durable original results without guest IO. It does not
accept pending steps on a replacement generation. A historical running step
without an execution binding is failed as `unknown` only after positive
retirement; migration itself never manufactures that evidence.

Both dispatch loops are non-overlapping. Different VMs can advance concurrently
while each TestRun remains ordered. Closing the step worker fences new dispatch
and joins its current scan and startup recovery before the catalog is released.

## Verification

From `daemon/gaovmd`:

```sh
mise exec dart@3.9.0 -- dart test \
  test/host_guest_artifacts_test.dart test/sqlite_database_test.dart \
  test/test_run_repository_test.dart test/test_run_application_service_test.dart \
  test/test_run_provisioning_worker_test.dart \
  test/test_run_collection_worker_test.dart test/test_run_cleanup_worker_test.dart
```

Checks cover real SQLite rollback/reopen, authenticated Unix socket guest
fixtures, public HTTP/UDS artifact download, ordered results, cancellation,
deadlines, VM checkpoint fences, two-VM dispatch independence and non-replay
recovery. Hardware is substituted only at the runtime boundary. Native process
retirement, real guest process-group cleanup, installed TestRun completion and
GaoOS end-to-end acceptance still require their separate gates.
