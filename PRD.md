# GaoVM — Product Requirements Document (v1.2)

## 1. Overview

GaoVM is a macOS virtual machine manager for GaoOS built on Apple Virtualization.framework.

v1.2 focuses on macOS (Apple Silicon) and implements:

- Dart control-plane daemon (`gaovmd`)
- Swift runtime driver (`gaovm-driver-vz`)
- Flutter menubar UI
- Dart CLI
- Length-prefixed JSON-RPC protocol
- Event-driven supervision
- Reopenable VM display window
- Atomic persistence
- Restart-required config staging

---

## 2. Target Platform

- macOS 14+
- Apple Silicon
- Linux guests via `VZLinuxBootLoader`

---

## 3. Core Goals

### Functional

- Start / Stop VM
- Persist VM spec
- Declarative desired-state model
- Supervise driver processes
- Headless VM mode
- Open / Close display independently of VM lifecycle
- CLI control
- Menubar UI control
- Crash recovery with bounded retries
- Structured logging + rotation

### Non-Goals (v1)

- Linux / Windows / FreeBSD backends
- Snapshots
- Bridged networking
- Guest agent
- Suspend / resume
- Multi-user security isolation

---

## 4. Architecture Summary

Flutter UI + CLI → Unix Socket → `gaovmd` (Dart)  
`gaovmd` → Unix Socket → `gaovm-driver-vz` (Swift)  
Driver → Virtualization.framework  

Control plane and runtime plane are strictly separated.

---

## 5. Key Design Decisions

- Length-prefixed JSON-RPC (no batch support)
- Bidirectional hello handshake
- Capability negotiation
- Per-driver auth token via environment variable
- Driver self-termination on socket EOF or heartbeat timeout
- Event-driven supervision + 5s safety reconcile
- Bounded restart backoff (max 5 attempts, capped 30s)
- Restart-required config staging via `pending_config.json`
- Atomic file writes

---

## 6. Success Criteria

- VM can be started and stopped reliably
- Display window can be closed and reopened without stopping VM
- Driver crash is detected immediately
- Permanent failure after bounded retries
- No orphaned drivers when daemon exits
- No corrupted state files on crash

---

## 7. Future Extensions (Planned)

- Linux backend (QEMU / libvirt)
- Windows backend (Hyper-V)
- FreeBSD backend (bhyve)
- Guest agent via vsock
- Snapshots
- Bridged networking
