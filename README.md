# GaoVM

GaoVM is a macOS-native, multi-VM manager for ARM64 Linux guests built on Apple's `Virtualization.framework`. GaoOS is its first Guest Profile and automated-test target, while the VM core remains guest-independent.

## Project Status

The checked-in code is a working single-VM prototype being migrated to the accepted multi-VM v2 contract. The canonical documents are:

- [Product requirements](docs/PRD.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Development plan](docs/DEVELOPMENT_PLAN.md)
- [Non-negotiable implementation rules](AGENTS.md)

Those documents are frozen for M0. Legacy prototype commands and JSON state paths documented below are historical references, not alternatives to the SQLite/public-API target. The current CLI migration checkpoint is described below.

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

## Public API CLI (`gaovm_cli`)

The CLI now uses `gaovm_api_client` for HTTP/1.1 over the daemon's public Unix socket (`state/run/api.sock` relative to the CLI's working directory by default). It has no driver RPC or daemon business-logic path. Use `--socket-path` explicitly when running from another directory.

Implemented commands at this checkpoint:

- `vm create --body-json JSON`, `vm list`, `vm get VM_ID`
- `vm patch VM_ID --body-json JSON --if-match REVISION`
- `vm delete VM_ID`
- `vm start/stop/restart/kill VM_ID`
- `vm wait VM_ID --condition CONDITION --timeout-seconds N` (add `--service-name NAME` for `guest_service_ready`)
- `image import --body-json JSON`, `image list`, `image get IMG_ID`, `image delete IMG_ID`
- `operation get/cancel OP_ID`, `operation wait OP_ID --timeout-seconds N`
- `operation list`
- `test run --body-json JSON`, `test get/cancel/artifacts TR_ID`
- `events [--after-sequence N] [--vm-id VM_ID] [--operation-id OP_ID] [--test-run-id TR_ID]`
- `doctor [--timeout-seconds N]`
- `schema [--timeout-seconds N]`

`vm list` accepts `--label-selector`, `--sort`, `--limit`, and `--cursor`.
`image list` accepts `--label-selector`, `--limit`, and `--cursor`.
`operation list` accepts `--resource-type`, `--resource-id`, `--state`, `--limit`,
and `--cursor`. `test artifacts` accepts `--limit` and `--cursor` and lists artifact
metadata with public download URLs, not artifact bytes. Page sizes are 1–200;
pass the returned `next_cursor` unchanged
with the same filters and sort to resume. Filtering and cursor validation remain
owned by the public API.

Targets must be real server-generated `vm_`/`img_`/`op_`/`tr_` ULIDs. There is no implicit or name-based `default` VM. Create accepts the public `api_version`, `kind`, `metadata`, and `spec` object; patch accepts the public metadata/spec patch object, not the legacy config format below.

Image import accepts the public `source_path`, `type`, and `architecture` (`arm64`) object, with optional image metadata and labels. The source path must be readable by the daemon. Import and deletion return durable Operations; use `operation get/wait/cancel` to track them. `image get` searches the paginated public catalog because the frozen API has no image-by-ID GET endpoint. Its local deadline covers the whole catalog walk; a missing image returns exit `1` with `IMAGE_NOT_FOUND`, and malformed pages or repeated cursors return exit `4`.

All output is JSON; `--json` selects compact output for ordinary results and diagnostics. Events always use one compact Event JSON object per line, with SSE comments omitted. Successful results go to stdout and Problems/local diagnostics to stderr. Exit codes are `0` for success or accepted work, `1` for API failure or a failed/cancelled waited Operation, `2` for usage errors, `3` for transport failure, `4` for invalid server responses, `124` for a deadline or `WAIT_TIMEOUT`, `130` for event-stream SIGINT, and `143` for event-stream SIGTERM.

Requests default to a 30-second local deadline; waits require an explicit `--timeout-seconds` and allow five additional seconds for transport. Mutations return accepted Operations without waiting for completion. Use `--idempotency-key KEY` and reuse it for explicit retries; the client does not automatically retry writes. Patch also requires an explicit revision/ETag through `--if-match`.

`schema` reads `GET /v1/openapi.json` and prints the complete OpenAPI 3.1 JSON,
including resource schemas. The daemon links canonical VmSpec definitions into
local references; the CLI never reads repository schema files. Invalid envelopes
return exit `4`; the ordinary API/transport/deadline exits still apply. Schema
discovery describes the contract, not runtime or guest readiness. See
[API discovery](docs/API_DISCOVERY.md) for source layout, limits, and verification.

`test run` takes the public `TestRunCreateRequest`: image source, readiness wait,
ordered steps, cleanup policy, and `retain_on_failure`, with optional VM overrides
and overall `timeout_seconds`. Its acceptance is not a successful guest test.
`test cancel` sends a bodyless cancellation request and returns its durable pending
Operation; collection and cleanup finish asynchronously. Track accepted work with
`operation get/wait` and `test get`. The CLI's `--timeout-seconds` bounds the local
request, not the TestRun's execution budget, and a local timeout does not cancel it.

`doctor` calls the non-mutating `GET /v1/system/doctor` endpoint. The complete
report goes to stdout: exit `0` means no error checks, and exit `1` means unhealthy;
warnings do not fail host readiness. Malformed or contradictory reports use exit
`4`. The daemon bounds its scan to eight seconds and coalesces unfinished probes.
It checks the platform, static ARM64 driver signature/entitlement, catalog,
directory bindings/permissions, images, capacity estimates, and runtime namespace.
Image manifests/sizes are required checks; content hashing has a shared 64 MiB
budget, and skipped digests are explicitly warned about. A no-follow image-root
scan warns about unregistered digest directories, staging, and unknown entries.
These can be in-flight publications/cleanup, not confirmed orphan ownership;
exceeding its 4096-entry budget is an incomplete-check error. Guest session/exec
readiness remains unverified. Doctor does not repair files, release leases, signal
processes, start a VM, or prove native VM/TestRun or release acceptance. It requires
a running daemon and cannot bypass a pre-listener startup census failure.

The event deadline bounds the entire subscription, including heartbeats. On a
disconnect (`3`), timeout (`124`), or interruption (`130`/`143`), resume explicitly
with `--after-sequence` set to the last consumed Event's `sequence` and the same
filters. Filters are combined with AND. There is no automatic reconnect.
Interrupting the stream cancels its subscription, not any VM or Operation.

```bash
cd clients/gaovm_cli
dart pub get --enforce-lockfile
dart run bin/gaovm_cli.dart --help --json
dart run bin/gaovm_cli.dart --socket-path /absolute/state/run/api.sock vm list --json
dart run bin/gaovm_cli.dart --socket-path /absolute/state/run/api.sock doctor --timeout-seconds 10 --json
dart run bin/gaovm_cli.dart --socket-path /absolute/state/run/api.sock events --after-sequence 42 --timeout-seconds 30 --json
dart test
```

Coverage includes real public-socket requests, VM/image deletion contracts, SQLite-backed filtered/paginated catalog queries, image lookup across pages, create/import/replay/query/cancellation with durable Operation waits, and resumable/live event streaming. TestRun tests exercise cross-client acceptance/query/cancellation, retry conflicts, isolated artifact pages, and the CLI executable querying a collected pre-allocation cancellation with a downloadable result. Doctor tests cover healthy/unhealthy reports, protocol validation, and local deadlines; daemon tests use real SQLite/filesystem/socket state, plus native static-signing fixtures that are never executed. Executable signal tests verify idle subscription cleanup and stable JSON/exit codes. This is a partial M7 checkpoint: guest exec and the legacy alias adapter remain pending. It does not establish installed-daemon, native guest execution, or Apple Silicon VM boot/display acceptance.

## Legacy Prototype CLI Reference (Not Supported)

The commands and examples in this section describe the removed prototype RPC CLI. They are not supported by the current public-API client.

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

## Legacy Prototype VM Configuration Specification

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

Run permission-sensitive tests as a non-root user. Fixtures that supply an
existing state directory or public socket parent explicitly set mode `0700`;
do not rely on temporary-directory permissions being identical across platforms.
Socket fixtures use `/private/tmp` only on macOS and `Directory.systemTemp` on
Linux, and POSIX test helpers select the platform's C library. Production
permission, ownership, and inode-replacement checks remain enforced.

Linux control-plane/fake-driver results do not establish installed-daemon,
Apple Silicon VZ, signing, launchd, or GaoOS Guest Agent/TestRun acceptance.

### RPC Library Tests
```bash
cd libs/gaovm_rpc
dart test
```

### Daemon Tests
```bash
cd daemon/gaovmd
dart test
```

### Swift Driver Tests
```bash
cd drivers/vz_macos
swift test
```

### Guest Protocol Foundation (Rust)

```bash
cd guest/gaovm_guestd
cargo test --locked
```

This tests framed control, bidirectional negotiation, real Unix subprocess
execution, system queries, and bounded local artifact collection in the test host
OS, not an installed guest daemon or native vsock execution. See the
[guest package scope](guest/gaovm_guestd/README.md) before using it.

---

## End-to-End Automated Run

The historical [`scripts/e2e_macos14_happy_path.sh`](scripts/e2e_macos14_happy_path.sh) still invokes the removed prototype CLI and socket contract. It must be migrated before use and is not v2 end-to-end acceptance evidence.

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
