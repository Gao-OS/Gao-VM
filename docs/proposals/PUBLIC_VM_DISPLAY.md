---
project: GaoVM
title: Public VM display operations
status: accepted
updated: 2026-10-11
---

# Public VM display operations

The user approved this scoped extension on 2026-10-11 with "approve them all",
covering the pending public-display and service-registration proposals. It closes
the contract gap between PRD UC-03 and the frozen public API; it is not evidence
that these routes, CLI commands, or native display acceptance are implemented.

The current uncommitted implementation and its component/native verification
boundaries are documented in [Public VM display](../PUBLIC_VM_DISPLAY.md).

## Accepted scope

- `POST /v1/vms/{vm_id}/actions/open-display`
- `POST /v1/vms/{vm_id}/actions/close-display`
- `GET /v1/vms/{vm_id}/display`
- Corresponding CLI display commands that use only the public API.

The two actions return durable Operations, use public action idempotency keys,
and dispatch through application services and the owning per-VM controller. The
operation transition, durable events, and outbox changes remain transactional.
Handlers must not connect to a driver or expose a driver passthrough. Results and
events must retain VM, operation, and driver-generation correlation and fence
retired generations.

Open and close are repeatable. Closing a display does not stop its VM. Display
commands coordinate with runtime lifecycle; status is an observation, not a VM
boot, guest-readiness, or operation-completion signal. Preserve the existing
driver capability negotiation and the driver-owned window.

The implementation may extend `schemas/openapi/gaovm-v1.yaml` for these routes and
their typed inputs/results, updating application services, persistence, API
client, CLI, tests, and documentation together. Approval does not authorize
unrelated public API, driver-protocol, or guest-protocol changes.

## Verification boundary

Check real public UDS requests and CLI-to-API behavior, durable operation/outbox
publication, idempotent retries, per-VM ordering, stale generations, and
close-without-stop. Driver command success alone does not establish durable
public operation success. Native Apple Silicon/GaoOS framebuffer, input,
close/reopen survival, simultaneous displays, and signed/installed acceptance
remain separate gates; component approval does not provide a native test host
or image.
