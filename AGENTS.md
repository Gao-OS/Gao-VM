# AGENTS.md — GaoVM Development Contract

This document defines the non-negotiable implementation rules for GaoVM. The accepted contracts live in [`docs/PRD.md`](docs/PRD.md), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), and [`docs/DEVELOPMENT_PLAN.md`](docs/DEVELOPMENT_PLAN.md); when code and those documents differ, implement toward the accepted documents and keep migration compatibility in an adapter rather than weakening the target model.

## 1. Architectural Invariants

1. Multi-VM is the core model. Do not introduce an implicit `default` VM or a global VM runtime singleton.
2. The Dart control plane and Swift runtime plane remain separated. The daemon must not import or call `Virtualization.framework`.
3. SQLite is the source of truth for the VM catalog, specs, desired/observed state, operations, events, and leases. A driver must not persist desired state.
4. Each VM has exactly one logical `VmController`; commands for one VM are serialized while different VMs may progress concurrently.
5. Each running/starting/stopping VM owns one independent driver process and one active driver generation.
6. The driver owns its display window. Closing display must not stop the VM.
7. GaoOS-specific behavior belongs in Guest Profile/TestRun layers, not the generic VM controller.

## 2. Public API and Internal IPC

- The MVP public API is HTTP/1.1 over a private Unix Domain Socket and is versioned under `/v1`.
- CLI and all later UI/MCP clients call only the public API. Flutter UI and MCP are Beta deliverables and do not block MVP.
- Public handlers call application services; they must not connect to a driver or expose a driver passthrough such as `driver.exec`.
- Daemon-to-driver IPC uses a 4-byte big-endian length prefix followed by one UTF-8 JSON-RPC 2.0 object. Batch requests are not supported.
- Internal driver sessions require a bidirectional hello, capability negotiation, and a per-generation auth token. A capability/version mismatch fails the handshake.
- Every VM action and asynchronous driver result carries `vm_id` plus the relevant generation/correlation ID.

## 3. Resource, Operation, and Event Rules

- Public resource IDs are server-generated prefixed ULIDs: `vm_`, `img_`, `op_`, `evt_`, `tr_`, `art_`, and `req_` followed by a 26-character Crockford Base32 ULID.
- Long-running actions return a durable `Operation`; API handlers never block for a complete VM boot or TestRun.
- Durable events have a monotonic sequence and support cursor resume.
- Resource/desired-state updates, operation transitions, durable events, and outbox rows commit atomically through the SQLite transactional outbox. Dispatch is idempotent and only publishes committed rows.
- Public action retries use idempotency keys; spec writes use revision/ETag conflict checks.

## 4. Supervision and Generation Rules

- The daemon monitors each driver via `Process.exitCode` and retains a 5-second reconcile safety tick.
- Restart attempts are bounded (maximum 5 in the current policy), use exponential backoff capped at 30 seconds, and are scoped per VM.
- On retry-budget exhaustion, atomically set desired=`stopped`, phase=`failed`, fail the operation, and emit `vm.permanent_failure`. Only a new explicit start begins another retry cycle.
- Late callbacks or exits from an old driver generation are ignored and must not overwrite current state.
- A driver exits on control socket EOF or after 15 seconds without an authenticated daemon RPC, attempting graceful VM shutdown before force stop.

## 5. Spec and Persistence Rules

Restart-required fields include:

- `cpu`
- `memory`
- `boot.*`
- `disk.path`
- `network.mode`
- `graphics.*`

When one changes while the VM is running, persist the new versioned spec and increment `spec_generation`; keep `observed_generation` on the applied spec and report restart-required until the next driver generation applies it. Legacy JSON files are migration inputs only and must not remain an active source of truth.

Managed file publication and legacy migration must be crash-consistent: stage, fsync where required, atomically publish, and reconcile with the SQLite transaction. Never partially overwrite a config, manifest, or database-owned state.

## 6. Swift VZ Queue Rules

- Bind each `VZVirtualMachine` to an explicit serial runtime queue.
- Access every VZ property/method only on that queue.
- Do not block the VZ queue with a semaphore or synchronous wait for an async VZ completion.
- Do not access VZ runtime state directly from concurrent RPC handlers or AppKit MainActor.
- Queue lifecycle commands in order and report completion/delegate events asynchronously; heartbeat/session control must remain responsive.

## 7. Logging Rules

- Log levels are `error`, `warn`, `info`, and `debug`.
- Logs include applicable `vm_id`, `operation_id`, `driver_generation`, and `request_id`.
- Driver and serial logs are independent per VM, rotate at 10 MB, keep the last 3 rotations, and must not block the controller path.

## 8. Do Not

- Do not bypass handshake or authentication.
- Do not implement JSON-RPC batch requests.
- Do not move VZ VM ownership into the daemon.
- Do not add a public driver passthrough.
- Do not introduce cross-process display hacks.
- Do not maintain separate singleton and multi-VM runtime implementations; legacy behavior belongs behind adapters during migration.
- Do not make P1 VM clone, Flutter UI, MCP, or optional Guest Agent extensions prerequisites for the MVP.

This file and the accepted documents under `docs/` define the frozen M0 contract.

## Agent Note

Agent Note project: gao-vm

Use the shared `agent-note` skill for project knowledge.
Before substantial design or debugging, recall relevant project notes.
At accepted decisions, validated work boundaries, or reproducible blocker handoffs,
evaluate durable findings and create/update notes only when the skill's quality gate
passes. This authorizes scoped capture, not whole-project curation or deletion.
No note is required for an ordinary completed task.
Contributors return candidates; the coordinating agent writes shared notes.
Apply recalled guidance only after checking its sources and target-version scope.
If the skill or MCP is unavailable, report the limitation without claiming a write.
