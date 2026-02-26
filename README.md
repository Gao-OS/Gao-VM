# GaoVM

GaoVM is a macOS-native virtual machine manager for GaoOS built on Apple Virtualization.framework.

---

## Architecture

- Dart daemon (`gaovmd`) — control plane
- Swift driver (`gaovm-driver-vz`) — VM runtime
- Flutter UI — menubar app
- Dart CLI — command line tool

IPC uses length-prefixed JSON-RPC over Unix domain sockets.

---

## Current Status

v1.2 (macOS only)

- Linux boot via VZLinuxBootLoader
- NAT networking
- Headless VM support
- Reopenable display window
- Event-driven supervision
- Bounded restart backoff
- Atomic state persistence

---

## Build Instructions

### Build Swift Driver

```bash
cd drivers/vz_macos
swift build
````

### Run Daemon

```bash
cd daemon/gaovmd
dart run
```

---

## Project Structure

```
gaovm/
  PRD.md
  AGENTS.md
  README.md
  libs/
  daemon/
  drivers/
  clients/
```

---

## Design Principles

* Strict separation of control and runtime
* Deterministic IPC framing
* Declarative desired-state model
* Safe crash recovery
* Future backend extensibility

---

## Roadmap

* VZ integration
* Display window implementation
* Flutter menubar UI
* Linux backend

