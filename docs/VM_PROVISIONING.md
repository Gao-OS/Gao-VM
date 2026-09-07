# VM provisioning foundations (PR021)

This document records the implemented plan, disk primitives, and durable create
acceptance for M5.3/M5.4. They do **not yet** constitute a public VM-create
workflow. Bundle publication, worker recovery, cancellation cleanup, and public
application composition remain integration work. The accepted architecture and
PRD remain authoritative.

## Pinned plan v1

`SqliteVmProvisioningPlanner.plan` reads a retained spec generation, a matching
pending/running `vm.create` operation, and its images in one SQLite transaction.
It can join the enclosing acceptance transaction; it performs no filesystem IO.

The immutable plan contains `plan_version: 1`, `vm_id`, `operation_id`,
`spec_generation`, `spec_digest`, `disks`, `kernel`, and `initrd`. The spec digest
is SHA-256 of the canonical serialized typed spec, using the image manifest's
canonical JSON encoding. Kernel/initrd are explicit nulls when absent.

Each disk retains its ID and writable flag. An external source retains its path
without moving, opening, canonicalizing, or assuming ownership of the file.
A managed source pins image ID/digest plus object name/digest/size and its role.
Standalone image types must match the requested role. GaoOS bundle references
resolve the manifest's `kernel`, `initrd`, and `root_disk` object names.
Plans validate their wire fields, digests, roles, and 1–32 unique disk IDs.
Terminal jobs must replay their stored plan, not regenerate it from newer specs.

## Disk materialization

`ManagedDiskMaterializer` creates one new child in a caller-owned, private staging
directory. The caller must serialize that namespace and keep its owned source and
directory handles open until completion. Both clone and fallback copy are bound
to descriptors; pathname replacement cannot substitute the source or destination.

On macOS, `fclonefileat` is attempted first, off the controller isolate. Only
unsupported/cross-volume errors select copy fallback. Permission, existing-file,
and space errors remain failures. New outputs are private files; source modes and
bytes are unchanged. Fallback IO is streamed, with cancellation/progress checks.
The resulting bytes must match the pinned size and SHA-256 before success.
Files and directory entries are flushed. Failure removes only this attempt's
new child; cleanup failures propagate rather than claiming successful cleanup.

Available space is measured against the held destination descriptor. Preflight
requires the logical disk size plus 1 MiB headroom. This is **not** a concurrent
reservation: the bundle worker still needs admission/reservation coordination.
Successful materialization is not bundle publication or Operation completion.

## Durable create acceptance

`SqliteVmCreateAcceptance.accept` owns its commit boundary and performs no
filesystem IO. One transaction creates the VM/spec, pending `vm.create`
Operation, pinned provisioning job, durable events, dedicated work outbox row,
and immutable idempotency response. Missing/invalid images roll back the entire
acceptance. Identical request retries return the acceptance-time snapshot even
after the operation becomes terminal; changed bytes conflict within retention.

Schema v5 adds `vm_provisioning`, keyed by VM and uniquely linked to the create
operation and retained spec generation. Work uses outbox topic `vm.provisioning`,
not lifecycle `vm.commands`; acceptance leaves lifecycle intent checkpoints at
zero. The VM remains desired=`stopped`, phase=`provisioning`, until a future
worker publishes its bundle and commits completion. `requestCancellation`
durably records intent and emits one event without terminalizing the operation:
it does not claim that owned-file cleanup has already happened.

Registry startup skips provisioning VMs, and lazy activation rejects them before
operation recovery can mistake `vm.create` for an orphan. Lifecycle acceptance
and metadata/spec writes reject provisioning with `VM_OPERATION_CONFLICT`
(HTTP 409 at the resource API boundary). Legacy `defined` VMs remain supported.

## Remaining integration contract

- Keep provisioning jobs separate from lifecycle `vm.commands` and its applied
  intent checkpoint; create/patch are not lifecycle adoption commands.
- Connect durable create acceptance to the public application mutation adapter
  only alongside the provisioning worker; acceptance alone cannot finish create.
- Prevent runtime activation until bundle publication and its durable completion
  proof commit. Validate external files before declaring provisioning complete.
- Publish a complete owned bundle without replacing an existing publication;
  recovery must distinguish staged, published-uncommitted, and committed work.
- After successful completion, do not rehash mutable VM disks to prove redelivery:
  a running guest may legitimately have changed them. Use durable job proof.
- On failure/cancellation, clean owned files before compensating catalog rollback
  (Architecture §17.6). Tombstoning the provisional VM preserves operation/event
  references while removing it from active list/get. Never delete external disks.

The focused tests cover plan pinning/validation, APFS clone isolation, exclusive
output creation, descriptor/path swaps, copy verification, cancellation, capacity,
and existing-file preservation. Apple Silicon and Linux runtime execution remain
separate platform gates; compilation alone does not prove native behavior there.

Database-only tests additionally verify job/acceptance durability, rollback,
idempotent replay/conflicts, cancellation intent, and provisioning readiness
gates. These contribute evidence for `VM-002`, `VM-009`, `API-005`/`API-006`,
`OP-002`/`OP-004`/`OP-007`, and `IMG-005`/`IMG-006`; none of those requirements is
declared end-to-end complete by this foundation.
