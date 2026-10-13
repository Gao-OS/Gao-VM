# Native VM public-API smoke recipe

`scripts/e2e_macos14_happy_path.sh` replaces the prototype RPC happy path with
`clients/gaovm_cli/tool/e2e_macos.dart`. It contributes a source-run smoke recipe
for UC-01/UC-03 and M3/M4/M5/M7/M8 verification; it is not the full PRD release
gate or installed-service acceptance.

## Prepare and run

Use Apple Silicon macOS 14+ with Xcode command-line tools and Dart 3.9.0. Prepare
existing, nonempty, absolute paths to an ARM64 Linux kernel, optional initrd and
raw root disk. Keep the inputs quiescent during import; do not use a disk attached
to another running VM. `DISK_PATH` is an import source, not an external writable
test disk, and a missing disk is not silently created. The resulting test VM
owns a separate managed writable copy.

Resolve the pinned dependencies first, from the repository root:

```sh
(cd daemon/gaovmd && mise exec dart@3.9.0 -- dart pub get --enforce-lockfile)
(cd clients/gaovm_cli && mise exec dart@3.9.0 -- dart pub get --enforce-lockfile)
mise exec dart@3.9.0 -- bash scripts/e2e_macos14_happy_path.sh --help

KERNEL_PATH=/absolute/images/kernel \
INITRD_PATH=/absolute/images/initrd \
DISK_PATH=/absolute/images/root.raw \
mise exec dart@3.9.0 -- bash scripts/e2e_macos14_happy_path.sh
```

Omit `INITRD_PATH` when the kernel boots without one. Optional inputs are:

- `DRIVER_BIN`: existing absolute Swift-driver path; otherwise build the driver
  with `swift build`. Only a fresh private copy is re-signed with the repository's
  virtualization entitlement and hardened runtime. Originals are unchanged.
- `STATE_DIR`: absolute new directory whose parent exists. Existing state,
  including symlinks, is rejected. Default: a new system temporary directory.
- `SOCK_PATH`: absolute path inside that canonical state directory's `run`
  child. Default: `run/api.sock`; it is never an existing daemon's socket.
- `TIMEOUT_SECONDS`: 1–86400, default 120, per CLI request/Operation wait rather
  than an overall run deadline.
- `DART_BIN`: explicit Dart executable for the shell wrapper when needed.

Help works without host inputs, `HOME`, or native execution. An unsupported
host exits `2` before creating run state or building/signing anything. Other
input/usage errors use `2`, run/native failures `1`, SIGINT `130`, and SIGTERM
`143`. Run state is printed as JSON as soon as it is created and always retained.

## What it does

The harness starts exactly its own daemon using the resolved Dart executable
and daemon package configuration, with explicit state/socket/driver/OpenAPI
paths. Readiness follows the daemon's listening notification, raced against
actual process exit and a 30-second deadline; no fixed startup sleep substitutes
for readiness. It never registers a service or signals another daemon.

All VM/image work goes through the real public CLI and HTTP-over-UDS client:

1. Import the kernel, optional initrd and raw disk; wait for each import Operation.
2. Create the VM from the returned image IDs, using the frozen typed VM spec.
3. Start it, wait for the exact Operation and `runtime_running` condition, and
   capture its driver generation.
4. Open, close, reopen and close its display. Wait for each durable Operation;
   require a committed display snapshot and unchanged running VM generation.
5. Stop only the created VM and verify its stopped desired/observed state.
6. Terminate only the owned daemon and require its confirmed, zero-code exit
   before reporting successful flow completion. Forced/nonzero shutdown cannot
   produce a passing receipt.

Acceptance and completion must agree on Operation ID, resource type/ID and action
type. Every mutation has an explicit fresh idempotency key; failures are not
automatically retried. Display status alone is not runtime or guest readiness.

After VM allocation, failures still attempt a public stop of that VM. If cleanup
also fails, retain both errors. Daemon cleanup first requests TERM, then KILL after
10 seconds, allowing a further 5 seconds for exit. Failed signal delivery or a
deadline is not retirement; an unconfirmed exit is an error with its PID. No run
tree, input, executable or VM resource is deleted automatically. A stopped daemon
alone does not prove every driver or guest retired after an unsuccessful VM stop.
Do not rerun after failed cleanup until the original VM/driver retirement is
established; a new state directory is not proof that the old runtime stopped.

## Evidence and remaining acceptance

Component tests run the recipe through a real public Unix socket and CLI with an
external API fixture, and use actual owned subprocesses for readiness/exit and
pre-listener failure. They verify image-ID specs, durable waits, display/lifetime
checks, failure diagnostics, shell help and unsupported-host rejection. They do
not boot a guest, render a framebuffer, sign/run an ARM64 driver or install a
service. From `clients/gaovm_cli`:

```sh
mise exec dart@3.9.0 -- dart test test/public_api_cli_test.dart \
  --name '(native |E2E shell)' --reporter expanded
mise exec dart@3.9.0 -- dart analyze
mise exec dart@3.9.0 -- dart format --output=none --set-exit-if-changed bin lib test tool
```

The actual native branch remains unrun on the Intel development host. Even a
passing native smoke receipt only establishes its stated public runtime/display
flow: it does not prove framebuffer/input, manual-close guest survival, GaoOS
guest exec/TestRun artifacts, simultaneous VMs/windows, crash/daemon-restart
recovery, signed installed-service behavior, upgrade rollback or distribution.
Those remain separate PRD/M8 gates and require recorded native evidence.
