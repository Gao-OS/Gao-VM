# GaoVM

GaoVM is a macOS-native virtual machine manager for GaoOS built on Apple `Virtualization.framework`.

## v1.2 Scope

v1.2 targets macOS 14+ on Apple Silicon and defines a two-process architecture:

- Dart daemon (`gaovmd`) as the control plane
- Swift driver (`gaovm-driver-vz`) as the runtime plane
- Dart CLI client (`gaovm_cli`)
- Flutter menubar UI (planned client)

IPC uses length-prefixed JSON-RPC over Unix sockets with a bidirectional `hello` handshake and capability negotiation.

## Architecture

`CLI/UI -> gaovmd (Dart) -> gaovm-driver-vz (Swift) -> Virtualization.framework`

Design invariants are enforced by `AGENTS.md` and the product behavior is defined in `PRD.md`.

## Repository Layout

```text
.
├── PRD.md
├── AGENTS.md
├── README.md
├── libs/
│   └── gaovm_rpc/
├── daemon/
│   └── gaovmd/
├── drivers/
│   └── vz_macos/
└── clients/
    └── gaovm_cli/
```

## Build (Current)

### Swift driver

```bash
cd drivers/vz_macos
swift build
```

### Dart daemon

```bash
cd daemon/gaovmd
dart run
```

### Dart CLI

```bash
cd clients/gaovm_cli
dart run bin/gaovm_cli.dart --help
```
