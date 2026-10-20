# GaoVM

GaoVM is a macOS-native, multi-VM manager for ARM64 Linux guests built on Apple's `Virtualization.framework`. Alpine ARM64 is the default first-release test OS; GaoOS remains a planned Guest Profile, while the VM core remains guest-independent.

## Project Status

The project began as a single-VM prototype. The current source implements the
multi-VM daemon composition, durable public API, guest-exec and TestRun workers,
and CLI; native Alpine ARM64 Guest/TestRun and installed-service release acceptance
are still pending. Component tests do not establish MVP completion.

**2026-10-19 approved scope:** Alpine ARM64 supplies the native first-release
Guest readiness, exec and TestRun E2E evidence; GaoOS-specific profile/version
integration is deferred. See the [approved PRD amendment](docs/PRD.md#2026-10-19-首版范围修订用户已批准)
and [current acceptance checkpoint](docs/FIRST_RELEASE_ACCEPTANCE.md). Prepared
images do not establish native acceptance. The canonical documents are:

- [Product requirements](docs/PRD.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Development plan](docs/DEVELOPMENT_PLAN.md)
- [Non-negotiable implementation rules](AGENTS.md)

Those documents define the frozen M0 contract with the dated approved scope amendment above. Legacy prototype commands and JSON state paths documented below are historical references, not alternatives to the SQLite/public-API target. The current CLI migration checkpoint is described below.

The public API now lists current per-VM log metadata through
`GET /v1/vms/{vm_id}/logs`, with an optional driver/serial/guest kind filter.
This read-only endpoint returns no log bytes or host paths and does not create
artifact snapshots. See [VM log references](docs/VM_LOGS.md) for ownership checks,
artifact boundaries, and verification limits.
The Swift driver also uses a [bounded asynchronous text-log writer](docs/DRIVER_LOGGING.md)
with structured VM/generation/operation correlation, so filesystem I/O and rotation
do not run on its VZ/control caller.
Its [v2 control-session watchdog](docs/DRIVER_SESSION_LIFETIME.md) also bounds
bootstrap, incomplete frames and backpressured writes; native VM shutdown and
launchd acceptance remain separate gates.
The daemon uses [bounded JSON Lines logging](docs/DAEMON_LOGGING.md) with
server-owned request IDs and typed resource correlation, without awaiting log I/O
in API or background callbacks.
The public [display API and CLI](docs/PUBLIC_VM_DISPLAY.md) use durable Operations
without taking ownership of VM lifecycle callbacks or process termination.

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

## Building Source Components

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

## macOS Bundle Assembly (Partial M8)

The [macOS packaging tool](docs/MACOS_PACKAGING.md) assembles and signs prebuilt
ARM64 daemon, CLI, driver, and service-helper binaries with the canonical schemas.
It never installs or registers the app. The separate [service helper](docs/MACOS_SERVICE.md)
implements bundle-owned status/register/unregister commands, without establishing
installed-service acceptance. Packaged executables resolve assets from their app
bundle and use `~/Library/Application Support/GaoVM` for state.
The accepted Dart hardened-runtime signing policy passes the documented Intel
compiled-launch checks; Apple Silicon execution, installed startup,
installation/update/uninstall, notarization, and native VM release acceptance
remain pending.

## Running the Source Public-API Daemon (`gaovmd`)

Start the daemon from the repository root or project directory:

```bash
cd daemon/gaovmd
mise exec dart@3.9.0 -- dart run bin/gaovmd.dart \
  --state-dir ../../state \
  --socket-path ../../state/run/api.sock \
  --driver-bin ../../drivers/vz_macos/.build/debug/gaovm-driver-vz
```

### Daemon Options

| Option | Default | Description |
|---|---|---|
| `--socket-path PATH` | `<state-dir>/run/api.sock` | Private public API socket, inside the state's `run` directory |
| `--state-dir PATH` | `./state` | Private SQLite catalog, managed images/VM bundles, runtime namespace, and logs |
| `--driver-bin PATH` | `$GAOVM_DRIVER_BIN` or relative build path | Absolute or relative path to the `gaovm-driver-vz` binary |
| `--openapi-path PATH` | `../../schemas/openapi/gaovm-v1.yaml` | Canonical public schema; packaged defaults are bundle-relative |
| `--max-running-vms N` | `8` | Host admission limit |
| `--max-concurrent-boots N` | `2` | Concurrent boot admission limit |

### Legacy Prototype State & Logs

The old prototype organized its state directory as follows; these paths are not
the active v2 catalog. See [legacy migration](docs/LEGACY_VM_MIGRATION.md) for the
supported importer and its backup/compatibility limits. Do not edit historical
JSON files to change current desired state:

- `state/config/vm.json`: Current VM specification
- `state/config/pending_config.json`: Staged configuration changes pending VM restart
- `state/state/desired_state.json`: Desired state (`running` / `stopped`)
- `state/state/runtime_state.json`: Last known runtime status
- `state/logs/gaovmd.log`: Rotating daemon log (rotates at 10MB, preserves 3 backups)
- `state/logs/gaovm-driver-vz.log`: Rotating driver log

---

## Public API CLI (`gaovm_cli`)

The CLI now uses `gaovm_api_client` for HTTP/1.1 over the daemon's public Unix
socket. Source runs default to `state/run/api.sock` relative to the CLI's working
directory; the compiled app-bundle CLI defaults to
`~/Library/Application Support/GaoVM/run/api.sock`. It has no driver RPC or daemon
business-logic path. Use `--socket-path` explicitly for a custom daemon socket or
when running from another source directory.

Implemented commands at this checkpoint:

- `vm create --body-json JSON`, `vm list`, `vm get VM_ID`
- `vm patch VM_ID --body-json JSON --if-match REVISION`
- `vm delete VM_ID`
- `vm start/stop/restart/kill VM_ID`
- `vm open-display/close-display VM_ID`, `vm display VM_ID`
- `vm logs VM_ID [--kind driver|serial|guest]`
- `vm artifacts VM_ID`, `vm download VM_ID ART_ID --output-dir DIRECTORY`
- `vm wait VM_ID --condition CONDITION --timeout-seconds N` (add `--service-name NAME` for `guest_service_ready`)
- `image import --body-json JSON`, `image list`, `image get IMG_ID`, `image delete IMG_ID`
- `operation get/cancel OP_ID`, `operation wait OP_ID --timeout-seconds N`
- `operation list`
- `guest exec VM_ID --body-json JSON` (durable acceptance; native Guest execution acceptance pending)
- `test run --body-json JSON`, `test get/cancel/artifacts TR_ID`
- `test download TR_ID ART_ID --output-dir DIRECTORY`
- `events [--after-sequence N] [--vm-id VM_ID] [--operation-id OP_ID] [--test-run-id TR_ID]`
- `doctor [--timeout-seconds N]`
- `schema [--timeout-seconds N]`
- `capabilities [--timeout-seconds N]` (public backend/guest advertisements and enforced catalog/runtime limits)

`vm list` accepts `--label-selector`, `--sort`, `--limit`, and `--cursor`.
`image list` accepts `--label-selector`, `--limit`, and `--cursor`.
`operation list` accepts `--resource-type`, `--resource-id`, `--state`, `--limit`,
and `--cursor`. `vm artifacts` and `test artifacts` accept `--limit` and
`--cursor` and list artifact metadata with public download URLs, not artifact
bytes. Page sizes are 1–200;
pass the returned `next_cursor` unchanged
with the same filters and sort to resume. Filtering and cursor validation remain
owned by the public API.

`test download` resolves an artifact through its TestRun's public metadata pages
and streams verified bytes into a fresh private child of the explicitly selected,
existing local output directory. Its JSON receipt contains the artifact metadata,
payload request ID, verified flag, and completed local path. Existing files are
not replaced, failed reads clean up their owned staging, and the full payload is
not buffered in memory. One local deadline covers paging and download; SIGINT or
SIGTERM releases the local read without changing a TestRun or VM. The shared SDK's
64 KiB preview cap remains unchanged. See [Artifact downloads](docs/ARTIFACTS.md)
for integrity, local I/O errors, cleanup limits, and remaining native acceptance.
The [desktop TestRun pane](clients/gaovm_ui/README.md#testrun-and-artifacts) also
offers a separate Download artifact action with native directory selection and
local-only cancellation. It uses the same verified streaming reader.

Targets must be real server-generated `vm_`/`img_`/`op_`/`tr_`/`art_` ULIDs. There is no implicit or name-based `default` VM. Create accepts the public `api_version`, `kind`, `metadata`, and `spec` object; patch accepts the public metadata/spec patch object, not the legacy config format below.

Image import accepts the public `source_path`, `type`, and `architecture` (`arm64`) object, with optional image metadata and labels. The source path must be readable by the daemon. Import and deletion return durable Operations; use `operation get/wait/cancel` to track them. `image get` searches the paginated public catalog because the frozen API has no image-by-ID GET endpoint. Its local deadline covers the whole catalog walk; a missing image returns exit `1` with `IMAGE_NOT_FOUND`, and malformed pages or repeated cursors return exit `4`.

All output is JSON; `--json` selects compact output for ordinary results and diagnostics. Events always use one compact Event JSON object per line, with SSE comments omitted. Successful results go to stdout and Problems/local diagnostics to stderr. Exit codes are `0` for success or accepted work, `1` for API/local-output failure or a failed/cancelled waited Operation, `2` for usage errors, `3` for transport failure, `4` for invalid server responses, `124` for a deadline or `WAIT_TIMEOUT`, `130` for event-stream/download SIGINT, and `143` for event-stream/download SIGTERM.

Requests default to a 30-second local deadline; waits require an explicit `--timeout-seconds` and allow five additional seconds for transport. Mutations return accepted Operations without waiting for completion. Use `--idempotency-key KEY` and reuse it for explicit retries; the client does not automatically retry writes. Patch also requires an explicit revision/ETag through `--if-match`.

Committed idempotency acceptance responses have a one-day replay window, measured
from acceptance completion; replay does not extend it. After startup recovery,
the daemon removes up to 100 expired response envelopes per minute. Unfinished
reservations are never made repeatable by age or removed by this collector.
Expiry ends the replay guarantee, not the durable Operation or resource lifetime.

See [event streaming and recovery](docs/EVENTS.md) for numeric cursor handling,
slow-subscriber isolation, and reconnection after a partial frame or deadline.

`guest exec` sends the frozen public `GuestExecRequest` to
`POST /v1/vms/{vm_id}/guest/exec`, preserving argv, cwd, environment, capture, and
the Guest execution timeout. It never runs the command on the host. Exit `0`
requires a valid `202` Operation acceptance for the requested VM; it is not the
Guest command's exit code. The daemon composition registers durable acceptance,
guest-session tracking and exec workers; fixture coverage does not establish
installed GaoOS/vsock execution. Track the accepted Operation separately. See
[Guest exec CLI](docs/GUEST_EXEC_CLI.md) and [durable host execution](docs/GUEST_EXEC_DURABILITY.md)
for timeouts, retries, failure behavior and native M6 limits.

`vm logs` reads only `GET /v1/vms/{vm_id}/logs`, with an optional `--kind` filter.
It prints current file metadata, not bytes or host paths, and does not create an
artifact or probe a driver. Empty results remain empty; every returned reference
must match the requested VM/kind and the frozen schema. Use `--json` for compact
output and `--timeout-seconds` for the local deadline (30 seconds by default).
Malformed replies return exit `4`; invalid options `2`, API Problems `1`, missing
transports `3`, and deadlines `124`. See [VM log references](docs/VM_LOGS.md).
Tail/stream remains P1, and live metadata is not an immutable log snapshot.

`vm artifacts` lists committed artifact metadata, including retained diagnostics
after VM tombstoning. `vm download` walks only that VM's public artifact pages
and streams the selected ID through the shared verified downloader; no TestRun
is required. VM- and TestRun-associated artifacts are both valid when their
`vm_id` matches. Listing and downloading validate the entire page, its owner,
IDs, canonical URLs, cursor, and requested page bound before accepting it.
Downloads create a private child of an existing output directory and never
overwrite or execute existing files. One deadline covers metadata and bytes;
SIGINT/SIGTERM clean this transfer without changing VM/Operation/TestRun state.
See [artifact reads and downloads](docs/ARTIFACTS.md) for limits and stable exits.

`schema` reads `GET /v1/openapi.json` and prints the complete OpenAPI 3.1 JSON,
including resource schemas. The daemon links canonical VmSpec definitions into
local references; the CLI never reads repository schema files. Invalid envelopes
return exit `4`; the ordinary API/transport/deadline exits still apply. Schema
discovery describes the contract, not runtime or guest readiness. See
[API discovery](docs/API_DISCOVERY.md) for source layout, limits, and verification.

`capabilities` reads the frozen `GET /v1/system/capabilities` contract and prints
the daemon's public backend/guest advertisements and limits. It validates the
complete response and preserves empty guest capabilities; it neither queries a
driver nor proves host/VM/guest readiness. The daemon registers this endpoint and
enforces `max_defined_vms: 128` atomically with VM creation acceptance. Deleting
VMs still occupy a slot until their tombstone commits. Running/boot limits come
from the host scheduler; the guest advertisement remains empty while native
Guest transport is disabled by default. Explicit
[Guest development opt-in](docs/GUEST_DEVELOPMENT_ACCEPTANCE.md) advertises the four
supported P0 capabilities without claiming native acceptance. The CLI does not
invent local defaults or infer guest capabilities from implemented handlers.

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
exceeding its 4096-entry budget is an incomplete-check error. Native Guest session/exec
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

Coverage includes real public-socket requests, VM/image deletion contracts, SQLite-backed filtered/paginated catalog queries, image lookup across pages, create/import/replay/query/cancellation with durable Operation waits, and resumable/live event streaming. TestRun tests exercise cross-client acceptance/query/cancellation, retry conflicts, isolated artifact pages, and the CLI executable querying a collected pre-allocation cancellation with a downloadable result. Doctor tests cover healthy/unhealthy reports, protocol validation, and local deadlines; daemon tests use real SQLite/filesystem/socket state, plus native static-signing fixtures that are never executed. Executable signal tests verify idle subscription cleanup and stable JSON/exit codes. Guest-exec and display composition now have component coverage. The [one-cycle legacy adapter](docs/LEGACY_CLI.md) accepts safe command spellings with explicit real-ID binding and revision-checked configuration translation. These checks do not establish installed-daemon, native guest execution, or Apple Silicon VM boot/display acceptance.

## Legacy Prototype CLI Reference (Not Supported)

The commands and examples in this section describe the removed prototype RPC CLI.
They are historical wire/config references, not current invocation instructions.
For the accepted one-cycle public-API input adapter, explicit binding, changed
JSON output and safety restrictions, use [Legacy CLI](docs/LEGACY_CLI.md).

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

### Swift Formatting and Lint

Both Swift packages use the repository's `.swift-format` configuration and
Xcode 26.3's built-in `swift format` version 6.2.3. CI pins that toolchain on
`macos-15` for the style check; the packages' minimum deployment target remains
macOS 14. From either `drivers/vz_macos` or `services/macos_service`, run:

```bash
swift format --version  # must be 6.2.3
swift format lint --strict --recursive Package.swift Sources Tests
```

To apply the same formatting locally, use
`swift format format --in-place --recursive Package.swift Sources Tests`.
Strict lint exits nonzero for both formatting and lint findings. This gate is
separate from build/test jobs and does not establish native VM or installed
service acceptance.

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

## Native VM Smoke Recipe (Not MVP Release Acceptance)

[`scripts/e2e_macos14_happy_path.sh`](scripts/e2e_macos14_happy_path.sh) now uses
the public CLI/API and explicit server-generated resource IDs. It imports kernel,
optional initrd and an existing raw disk, creates a VM with a managed writable
disk, waits for durable start/display/stop Operations, checks display state and
unchanged VM generation, then confirms its owned daemon exits. It does not use
prototype RPC commands, fixed startup sleeps, an implicit VM, or launchd.
With `--multi-vm`, it instead creates three VMs, starts two concurrently and
checks independent stop behavior plus distinct native PID/socket bindings and
final zero-driver cleanup. The third VM must remain never started.
Run it only on Apple Silicon macOS 14+ with prepared, quiescent ARM64 inputs;
the source images and original driver are not modified. Fresh private run state
is retained, including on failure. See [native smoke setup and limits](docs/NATIVE_VM_SMOKE.md).

### Running the E2E Script

```bash
KERNEL_PATH=/path/to/vmlinuz \
INITRD_PATH=/path/to/initrd \
DISK_PATH=/absolute/images/root.raw \
mise exec dart@3.9.0 -- bash scripts/e2e_macos14_happy_path.sh
```

The public-API recipe, owned-process handling, help and unsupported-host guard
have fixture coverage, including the multi-VM scenario with an injected native
inventory. The actual build/sign/boot/display or multi-VM branch has not been
run on this Intel host. Framebuffer/input, GaoOS guest survival/exec/TestRun,
multi-VM fault isolation, installed service, upgrade and distribution remain
separate required gates.
For the complete P0 traceability index, known implementation gaps and release
gate evidence boundaries, see [the MVP acceptance ledger](docs/MVP_ACCEPTANCE.md).

---

## Data Backup and Restore

For cold managed-state backup, same-path restore and public diagnostic export,
see [data backup and restore](docs/DATA_BACKUP.md). This requires confirmed
daemon/driver shutdown and separate external-disk backups; it is not an online
snapshot, portable VM import, or installed upgrade/rollback acceptance.

---

## License

See project repository for license details.
