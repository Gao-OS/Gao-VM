# One-cycle legacy CLI adapter

The user accepted this PR015 compatibility boundary on 2026-10-15. Prototype
command spellings are supported for the 0.1.x release cycle and removed in 0.2.0.
This is an input adapter in the existing public HTTP/Unix client, not a second
runtime, raw RPC client, filesystem configuration store or public driver API.

## Explicit VM binding

First obtain the real server-generated VM ID from `gaovm vm list` (including the
migrated VM, if applicable), and explicitly bind the intended target:

```sh
export GAOVM_LEGACY_VM_ID='vm_00000000000000000000000001'
gaovm status
gaovm start --idempotency-key start-once
gaovm stop --vm-id default --idempotency-key stop-once
```

The example ID is a placeholder, not a special VM. `--vm-id vm_…` overrides the
environment binding. Missing, invalid or unbound `default` is a local usage
error, even if the catalog contains one VM or a VM named `default` or
`migrated-default`. The server never receives `default`. Modern `vm` commands
still require real IDs and ignore the legacy binding. An empty invocation is
legacy `status` and therefore also requires an explicit binding.

Use the public `api.sock`, not the removed `daemon.sock` RPC endpoint. Normal
source/packaged socket resolution and `--socket-path` overrides remain unchanged.

| Legacy spelling | Public API behavior |
| --- | --- |
| `ping` | GET `/v1/system/live`; daemon liveness, not VM readiness |
| `list` | `vm list`, including existing filter/pagination options |
| `status`, empty invocation, `config-get` | `vm get` for the explicitly bound ID |
| `start`, `stop`, `open-display`, `close-display` | Corresponding `vm` action; returns a durable Operation |
| `config-set`, `config-patch` | Validated input translation to revision-checked `vm patch` |
| `events`, `doctor` | Existing public SSE and doctor commands; no old RPC transport |
| `driver-exec` | Always rejected; use a supported public operation instead |

Output is the **public** JSON resource/page, Operation acceptance or structured
Problem, not the prototype RPC envelope. `config-get` returns the complete VM,
including revision, desired spec, observed generation and restart-required state;
it does not invent the former `current`/`pending` config snapshots. A successful
action exit reports acceptance, not a completed VM boot, shutdown or display
change. Use `operation wait` with an explicit deadline to observe completion.
Display close never stops the VM. Existing JSON exit codes and public failures
remain unchanged. `--verbose`/`-v` are accepted only with legacy spellings (and
the unchanged `events`/`doctor`); they do not enable private RPC tracing.

## Configuration writes

Read the current VM/revision first. Both deprecated write commands require
`--json OBJECT` **and** `--if-match REVISION`. This deliberately does not preserve
the prototype's unguarded overwrite semantics. Supply an idempotency key and
retain the exact input/revision for retries; conflicts are returned unchanged,
without automatic re-read/retry or force overwrite.

```sh
gaovm config-get
gaovm config-patch --json '{"cpu":4,"memory":536870912}' \
  --if-match 7 --idempotency-key tune-once
```

`config-set` requires all six prototype fields; `config-patch` accepts a nonempty
subset, including nonempty nested subsets. Unknown fields are rejected. Nested
updates read and validate the same VM through the public API, preserve device
IDs and unmentioned fields, and share one local read/write deadline. The server
still owns spec validation, image resolution, restart-required behavior, durable
Operation/event/outbox transitions and the revision check.

| Prototype input | Typed spec translation / safety boundary |
| --- | --- |
| `cpu`, `memory` | `cpu`, `memory_bytes`; frozen CPU/memory limits apply |
| `boot.loader` | `linux`/`auto` only, on an existing Linux-kernel VM |
| `boot.kernelPath`, `boot.initrdPath` | Public `img_` IDs, not filesystem paths; first `image import` and wait for its Operation. Nullable initrd removes it |
| `boot.commandLine` | `boot.command_line`; null means empty string |
| `disk.path` | Explicit absolute external path, exactly one disk; device ID/writability preserved |
| `disk.sizeMiB` | Must be null; resizing an existing disk is not an MVP action |
| `network.mode` | `shared`/`none`, exactly one interface; ID and applicable MAC preserved |
| `graphics` | `enabled`/`width`/`height`; unmentioned density/settings preserved |

Unmentioned modern fields (Guest settings, serial capture, restart policy, labels,
autostart, etc.) are not reset. EFI, multiple disks/interfaces and modern spec
edits use `vm patch --body-json`, not guessed legacy projections. The adapter
does not read a local kernel/disk, import a path implicitly, edit SQLite, stop a
VM, resize a disk or weaken generation/authentication checks.

The [old-data migration](LEGACY_VM_MIGRATION.md) remains a separate startup
transaction. CLI component checks do not prove installed startup, native VM
boot/display, launchd upgrade or Apple Silicon/GaoOS acceptance.
