# AGENTS.md — GaoVM Development Contract

This document defines architectural invariants and implementation rules for GaoVM.

Any AI agent or developer modifying this project MUST follow these constraints.

---

## 1. Architectural Invariants

1. Control plane (Dart) and runtime plane (Swift) must remain separated.
2. Daemon must NOT import or call Virtualization.framework.
3. Driver must NOT persist desired state.
4. IPC must use length-prefixed JSON-RPC.
5. One frame = one JSON-RPC object.
6. JSON-RPC batch requests are NOT supported.
7. Display window must be owned by driver process.
8. Daemon is source of truth for desired state.

---

## 2. IPC Rules

- 4-byte big-endian length prefix
- UTF-8 JSON payload
- JSON-RPC 2.0 subset
- Explicit subscribe_events method
- Bidirectional hello handshake required
- Capability mismatch must fail handshake

---

## 3. Supervision Rules

- Daemon monitors driver via Process.exitCode
- 5s reconcile safety tick
- Max 5 restart attempts
- Exponential backoff capped at 30s
- After limit → desired=stopped, emit permanent failure event

---

## 4. Driver Liveness Rules

Driver must exit if:

- Control socket EOF
OR
- No authenticated daemon RPC within 15 seconds

Driver must attempt graceful shutdown before force stop.

---

## 5. Config Rules

Restart-required fields:

- cpu
- memory
- boot.*
- disk.path
- network.mode
- graphics.*

If restart-required change while running:

- Write pending_config.json
- Replace existing pending (last-write-wins)
- Emit event.pending_config_replaced

---

## 6. Persistence Rules

- Atomic write (temp + fsync + rename)
- Never partially overwrite config
- Never corrupt daemon state

---

## 7. Logging Rules

- Log files must rotate at 10MB
- Keep last 3 rotations
- Log levels: error, warn, info, debug

---

## 8. Do Not

- Do not bypass handshake
- Do not implement JSON batch
- Do not move VM ownership into daemon
- Do not allow driver to run without auth token
- Do not introduce cross-process display hacks

---

This file defines non-negotiable architectural constraints.