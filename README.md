# GaoVM

GaoVM is a macOS-native, multi-VM manager for ARM64 Linux guests built on Apple's `Virtualization.framework`. GaoOS is its first Guest Profile and automated-test target, while the VM core remains guest-independent.

## Project Status

The checked-in code is a working single-VM prototype being migrated to the accepted multi-VM v2 contract. The canonical documents are:

- [Product requirements](docs/PRD.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Development plan](docs/DEVELOPMENT_PLAN.md)
- [Non-negotiable implementation rules](AGENTS.md)

Those documents are frozen for M0. Prototype commands and JSON state paths documented below describe current behavior only; they are not alternatives to the SQLite/public-API target.

---

## Scope & Target Platform

- **Platform:** macOS 14.0+ (Sonoma) on Apple Silicon (`arm64`)
- **Guest Support:** Linux guests via `VZLinuxBootLoader`
- **Architecture:** Two-process separation
  - **Control Plane:** Dart daemon (`gaovmd`) managing the SQLite catalog, per-VM controllers, operations, events, and driver supervision
  - **Runtime Plane:** One Swift driver (`gaovm-driver-vz`) per active VM, interfacing directly with `Virtualization.framework` and AppKit
  - **MVP Client:** Dart CLI (`gaovm_cli`) over the public HTTP API
  - **Beta Clients:** Flutter UI and MCP Adapter; neither blocks MVP
  - **Internal RPC:** Length-prefixed JSON-RPC 2.0 only between daemon and drivers

---

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────┐
│ CLI / API Agent             Beta: Flutter UI / MCP Adapter  │
└──────────────────────────────┬──────────────────────────────┘
                               │ HTTP/1.1 over private UDS
┌──────────────────────────────▼──────────────────────────────┐
│ gaovmd: public API, SQLite, Operation/Event/Outbox           │
│          VmRegistry + one serialized VmController per VM    │
└───────────────────┬────────────────────────┬─────────────────┘
                    │ framed JSON-RPC v2     │ framed JSON-RPC v2
┌───────────────────▼────────────┐ ┌─────────▼────────────────┐
│ Swift driver VM-A + VZ queue   │ │ Swift driver VM-B + VZ  │
│ AppKit display owned here      │ │ AppKit display owned here│
└────────────────────────────────┘ └───────────────────────────┘
```

### Architectural Invariants

As specified in [`AGENTS.md`](AGENTS.md), [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), and [`docs/PRD.md`](docs/PRD.md):

1. **Strict Plane Separation:** The daemon never imports `Virtualization.framework`; the driver never persists desired state.
2. **Multi-VM Ownership:** SQLite is the source of truth; each VM has one serialized controller and each active VM has one independent driver generation.
3. **Protocol Separation:** The public API is HTTP/1.1 over UDS. Internal IPC uses length-prefixed JSON-RPC 2.0; one frame equals one object and batch requests are unsupported.
4. **Handshake & Capability Negotiation:** Every driver session requires a bidirectional `hello`, capability negotiation, and a per-generation auth token.
5. **Operation/Event Durability:** Long actions return Operations; state, operation, event, and outbox rows commit through a SQLite transactional outbox.
6. **Generation Safety:** All asynchronous runtime results carry VM/generation correlation; stale generations cannot overwrite current state.
7. **No Public Passthrough:** Public handlers and clients never call arbitrary driver methods.
8. **VZ Queue Safety:** Every VZ access uses the driver's associated serial queue without semaphore-blocking that queue.
9. **Independent Display Lifecycle:** The driver owns the display, which may close and reopen without stopping the VM.

---

## Repository Layout

```text
.
├── AGENTS.md                          # Architectural invariants and rules
├── README.md                          # Project documentation
├── docs/
│   ├── PRD.md                         # Product requirements
│   ├── ARCHITECTURE.md                # Accepted v2 architecture
│   └── DEVELOPMENT_PLAN.md            # Milestones and verification gates
├── libs/
│   └── gaovm_rpc/                     # Length-prefixed JSON-RPC 2.0 Dart library
├── daemon/
│   └── gaovmd/                        # Control daemon (state, supervision, RPC server)
├── drivers/
│   └── vz_macos/                      # Swift runtime driver (Virtualization.framework)
│       ├── Resources/
│       │   └── entitlements.plist     # macOS virtualization entitlements
│       ├── Sources/
│       │   └── vz_macos/              # Driver implementation
│       └── Tests/                     # Driver unit tests
├── clients/
│   └── gaovm_cli/                     # CLI client for gaovmd
└── scripts/
    └── e2e_macos14_happy_path.sh      # End-to-end automation test script
```

---

## Prerequisites

- **macOS:** 14.0 or newer (Apple Silicon)
- **Xcode Command Line Tools / Swift:** Swift 5.9+ (`xcode-select --install`)
- **Dart SDK:** Dart 3.9+ (or a Flutter SDK that bundles Dart 3.9+)

---

## Building the Current Prototype

### 1. Swift Driver (`gaovm-driver-vz`)

```bash
cd drivers/vz_macos
swift build

# Sign with the virtualization entitlement (required by Apple Virtualization.framework)
codesign --entitlements Resources/entitlements.plist --force -s - .build/debug/gaovm-driver-vz
```

> **Note:** macOS requires binaries using `Virtualization.framework` to have the `com.apple.security.virtualization` entitlement. The entitlement file is located in `drivers/vz_macos/Resources/entitlements.plist`.

### 2. Dart RPC Library & Daemon (`gaovmd`)

```bash
# Fetch dependencies for gaovm_rpc
cd libs/gaovm_rpc
dart pub get

# Fetch dependencies for gaovmd
cd ../../daemon/gaovmd
dart pub get
```

### 3. Dart CLI (`gaovm_cli`)

```bash
cd clients/gaovm_cli
dart pub get
```

---

## Running the Current Prototype Daemon (`gaovmd`)

Start the daemon from the repository root or project directory:

```bash
cd daemon/gaovmd
dart run bin/gaovmd.dart \
  --state-dir ../../state \
  --socket-path ../../state/run/daemon.sock \
  --driver-bin ../../drivers/vz_macos/.build/debug/gaovm-driver-vz
```

### Daemon Options

| Option | Default | Description |
|---|---|---|
| `--socket-path PATH` | `<state-dir>/run/daemon.sock` | Unix domain socket path for incoming client connections |
| `--state-dir PATH` | `./state` | Directory storing configs, state files, and logs |
| `--driver-bin PATH` | `$GAOVM_DRIVER_BIN` or relative build path | Absolute or relative path to the `gaovm-driver-vz` binary |

### Legacy Prototype State & Logs

The prototype organizes its state directory as follows. M1 migrates these inputs once into SQLite; they must not remain an active source of truth in v2:

- `state/config/vm.json`: Current VM specification
- `state/config/pending_config.json`: Staged configuration changes pending VM restart
- `state/state/desired_state.json`: Desired state (`running` / `stopped`)
- `state/state/runtime_state.json`: Last known runtime status
- `state/logs/gaovmd.log`: Rotating daemon log (rotates at 10MB, preserves 3 backups)
- `state/logs/gaovm-driver-vz.log`: Rotating driver log

---

## Using the Current Prototype CLI (`gaovm_cli`)

The CLI communicates with `gaovmd` over the Unix socket.

```bash
cd clients/gaovm_cli
dart run bin/gaovm_cli.dart [options] <command>
```

### Options

- `--socket-path PATH`: Specify socket path (default: `state/run/daemon.sock`)
- `-v`, `--verbose`: Enable verbose debug output
- `-h`, `--help`: Show usage and command list

### Available Commands

| Command | Arguments | Description |
|---|---|---|
| `ping` | — | Ping the daemon to test connectivity |
| `status` | — | Query VM desired and runtime status |
| `list` | — | List managed virtual machines |
| `start` | — | Start the VM according to current configuration |
| `stop` | — | Gracefully stop the VM |
| `open-display` | — | Open the AppKit VM display window |
| `close-display` | — | Close the VM display window (VM continues running) |
| `events` | — | Stream real-time events from the daemon |
| `doctor` | — | Run environment and capability diagnostics |
| `config-get` | — | Output current VM configuration JSON |
| `config-set` | `--json '<JSON>'` | Set complete VM configuration |
| `config-patch` | `--json '<JSON>'` | Partially update VM configuration fields |
| `driver-exec` | `--method <M> [--params-json '<JSON>']` | Legacy debug passthrough; forbidden in the v2 public API |

### Examples

#### Check Daemon Health
```bash
dart run bin/gaovm_cli.dart ping
dart run bin/gaovm_cli.dart doctor
```

#### Set VM Configuration
```bash
dart run bin/gaovm_cli.dart config-set --json '{
  "cpu": 2,
  "memory": 2147483648,
  "boot": {
    "loader": "linux",
    "kernelPath": "/path/to/vmlinuz",
    "initrdPath": "/path/to/initrd",
    "commandLine": "console=hvc0 root=/dev/vda rw"
  },
  "disk": {
    "path": "/path/to/disk.img",
    "sizeMiB": 8192
  },
  "network": {
    "mode": "shared"
  },
  "graphics": {
    "enabled": true,
    "width": 1280,
    "height": 800
  }
}'
```

#### Manage VM Lifecycle & Display
```bash
# Start VM
dart run bin/gaovm_cli.dart start

# Check status
dart run bin/gaovm_cli.dart status

# Open display window
dart run bin/gaovm_cli.dart open-display

# Close display window (VM keeps running headless)
dart run bin/gaovm_cli.dart close-display

# Reopen display window anytime
dart run bin/gaovm_cli.dart open-display

# Stop VM
dart run bin/gaovm_cli.dart stop
```

#### Subscribe to Live Events
```bash
dart run bin/gaovm_cli.dart events
```

---

## VM Configuration Specification

| Field | Type | Description |
|---|---|---|
| `cpu` | Integer | Number of virtual CPUs assigned to guest |
| `memory` | Integer | Guest RAM in bytes (e.g. `2147483648` for 2 GiB) |
| `boot.loader` | String | Bootloader type (`"linux"`) |
| `boot.kernelPath` | String | Path to uncompressed ARM64 Linux kernel image |
| `boot.initrdPath` | String / null | Optional path to initial RAM disk |
| `boot.commandLine` | String | Kernel arguments (e.g. `"console=hvc0 root=/dev/vda rw"`) |
| `disk.path` | String | Path to guest disk image (sparse file created automatically if missing) |
| `disk.sizeMiB` | Integer | Disk size in MiB when creating sparse file |
| `network.mode` | String | Networking mode (`"shared"` via NAT, or `"none"`) |
| `graphics.enabled` | Boolean | Enable or disable graphical display |
| `graphics.width` | Integer | Virtual display width in pixels (e.g. `1280`) |
| `graphics.height` | Integer | Virtual display height in pixels (e.g. `800`) |

---

## Running Tests

All unit tests and integration tests can be run across the modules:

### RPC Library Tests
```bash
cd libs/gaovm_rpc
dart test
```

### Daemon Tests (99+ unit and integration tests)
```bash
cd daemon/gaovmd
dart test
```

### Swift Driver Tests
```bash
cd drivers/vz_macos
swift test
```

---

## End-to-End Automated Run

An automated end-to-end verification script is provided at [`scripts/e2e_macos14_happy_path.sh`](scripts/e2e_macos14_happy_path.sh). It executes a full build, runs the daemon in a temporary state directory, configures the VM, tests starting, display opening/closing, and stopping.

### Running the E2E Script

```bash
KERNEL_PATH=/path/to/vmlinuz \
INITRD_PATH=/path/to/initrd \
DISK_PATH=$HOME/gaovm/demo.img \
bash scripts/e2e_macos14_happy_path.sh
```

---

## License

See project repository for license details.
