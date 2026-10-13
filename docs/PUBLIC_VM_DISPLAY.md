# Public VM display operations

The [approved extension](proposals/PUBLIC_VM_DISPLAY.md) connects PRD UC-03 to
the public API. The implementation described here is uncommitted work on `main`;
component checks do not establish native or installed acceptance.

## Client contract

```sh
gaovm vm open-display VM_ID --idempotency-key open-once --json
gaovm operation get OP_ID --json
gaovm operation wait OP_ID --timeout-seconds 30 --json
gaovm vm display VM_ID --json
gaovm vm close-display VM_ID --idempotency-key close-once --json
```

`POST /v1/vms/{vm_id}/actions/open-display` and `close-display` return HTTP 202
with the existing `OperationAccepted` shape. Their operation types are
`vm.open_display` and `vm.close_display`. Replaying the same endpoint/key/body
returns the original acceptance, not a new window command or the operation's
latest state. Poll or wait for the Operation to learn its durable outcome.

The action body permits the existing optional `reason` and `deadline_at` fields;
the CLI sends an empty body and generates a key unless one is supplied. The typed
API client provides `openDisplay`, `closeDisplay`, and `displayStatus`. All use
only the public socket, check the response status and VM identity, preserve
structured Problems, and do not automatically retry. The CLI keeps its standard
JSON, timeout, transport, protocol, usage, and Problem exit behavior.

Display actions are non-cancellable through the public operation-cancel API.
The window SDK call is not safely preemptible; stopping/killing a VM is not an
acceptable cancellation mechanism. A local timeout or connection cancellation
does not cancel an already accepted Operation. Retain an explicit key when an
acceptance response may have been lost.

`GET /v1/vms/{vm_id}/display` returns the last committed observation:

```json
{
  "vm_id": "vm_01J00000000000000000000000",
  "driver_generation": 1,
  "state": "closed",
  "observed_at": "2026-10-11T03:00:00.000Z"
}
```

States are `unknown`, `closed`, `opening`, `open`, `closing`, and `error`.
The generation is the catalog's last allocated driver counter, or null before
allocation; it is not proof of a currently connected driver. `observed_at` is
null when no observation is confirmed. The GET does not probe a driver, wait for
AppKit, create an Operation, or prove VM/guest readiness. A historical snapshot
must be interpreted together with VM status and its timestamp.

## Ownership and durability

Application services accept each action transactionally with its operation,
intent revision, event, idempotency record, and command outbox row. The owning
per-VM controller adopts committed commands in order. A running VM requires its
exact active generation for open/close; an already absent runtime can close as
a no-op. An open with no running runtime fails its Operation with
`VM_NOT_RUNNING`. Driver/window failures fail only the display operation.

The display Operation must not replace `driverOperationId` in the controller,
the runtime adapter's lifecycle callback owner, or the real process session's
runtime exit owner. The session orders display mutations with VM commands, but
display cancellation cannot enter its lifecycle process-termination path.
Closing a window never changes
desired VM state, stops the runtime, releases its lease, or completes a boot.
Old-generation or old-operation callbacks cannot complete a current action.
Manual close observations have null operation correlation and do not rewrite a
previously completed Operation.

SQLite migration 21 stores display state/time and the independent driver operation
owner in `vm_runtime`. Completion, result, display event, and runtime checkpoint
commit in one durable batch. An aborted completion batch cannot publish success
or trigger the generic VM-stop failure path. An aborted observation transaction
keeps its previous committed snapshot and invalidates only the uncommitted
in-memory display cache. An interrupted display fails as unconfirmed; any VM
recovery owns a separate Operation, including after a subsequent cold restore.

## Verification boundary

Component coverage uses real public Unix sockets, the typed client and CLI,
SQLite migrations/outbox, per-VM registry/controller, and the runtime adapter.
The SDK/driver and host-resource boundaries are fixtures: no guest boot,
framebuffer, installed service, or real resource allocation is claimed. Focused
checks cover replay, same-VM ordering, manual close, stale generations,
completion/observation rollback, interruption/recovery, failure isolation, and
CLI validation/timeout behavior.

A real fixture process also exercises authenticated driver IPC: an in-flight
display RPC is held until a ping releases it. Cancelling that display command
must keep the process responsive and preserve runtime exit correlation; the
separate lifecycle cancellation test still requires process termination. This
checks session ownership, not a real AppKit or VZ display.

The existing [Swift display checks](DRIVER_DISPLAY.md) separately exercise
AppKit window ownership and authenticated headless driver IPC. Driver and guest
control schemas are unchanged by this extension; only the approved public
OpenAPI contract is extended.

Apple Silicon/GaoOS acceptance remains pending: framebuffer/input, manual
close/reopen while the guest survives, simultaneous displays, actual lifecycle
races, and signed/installed execution. Neither fixture coverage nor an ARM64
cross-build satisfies those gates.
