# GaoVM guest protocol foundation

This crate starts development-plan package 023. It is a **library**, not yet an
installable `gaovm-guestd` service. Tests now execute real Unix subprocesses, but
do not establish installed GaoOS guest readiness, vsock execution, or TestRun
acceptance. Do not deploy this library as a guest service.

## Implemented control contract

The authoritative message grammar is
[`schemas/guest-protocol/v1.schema.json`](../../schemas/guest-protocol/v1.schema.json).
The library embeds that schema and compiles a reusable validator, including
date-time format checks. HTTP/file schema resolution is disabled; runtime
messages cannot supply a different schema. Errors do not echo request contents.

Control frames use a four-byte unsigned big-endian payload length followed by
one UTF-8 JSON object. Payloads must be nonempty and at most 16 MiB. Batches,
scalars, malformed UTF-8/JSON, and incomplete frames fail closed. Clean EOF is
allowed only between frames. An outbound size/type error writes no frame bytes.
Framing errors are fatal to the channel; callers must close it, not retry from
an uncertain byte offset. A transport must set bounded read/write deadlines.

`Session` binds one connection to a VM ID and driver generation. Both peers send
`session.hello` and acknowledge the same capability intersection; both required
sets must be satisfied. Either hello/acknowledgement ordering is supported.
Wrong identity, version, role, request ID, capability set, or renegotiation fails
the handshake permanently. Application requests require a ready session and a
negotiated capability. Stale application messages are rejected without changing
the current session binding.

Callers must send and flush values returned by `hello`/`receive_hello` before
processing another message or dispatching application work. Any write failure
terminates the connection. `is_ready()` means protocol negotiation only, not
VM runtime state, guest health, or service readiness. It is not transport
authentication: the future vsock service must verify its host peer identity.

The six `CORE_CAPABILITIES` are the frozen P0 contract, not claims that handlers
already exist. Guest hello validation requires all six; a future executable must
not advertise them until all corresponding handlers and binary transfer paths
are implemented. P1 file transfer/service control/power operations are not part
of this implementation.

## Unix execution engine

`exec::Executor` implements the process lifecycle needed by the future guest RPC
dispatcher. It binds explicitly to one VM and driver generation. Every start,
status, cancel, wait, output read, and release requires a ready `Session`, the
appropriate negotiated capability, and matching request correlation. Completion
snapshots retain VM ID, generation, and operation ID; they are not wire envelopes.
The frozen `ExecResult` payload and error codes remain unchanged.

Commands receive an argv vector, cwd, and explicit environment. No shell is added
implicitly. The parent environment is cleared, a baseline `PATH=/usr/bin:/bin`
is set, request environment entries are applied, and stdin is closed. Execution
uses the service's existing UID/GID; this does not install a least-privilege
service, elevate privileges, or sandbox a guest administrator's commands.

Deadlines start before process spawn and are never restarted by delayed worker
scheduling. A deadline already expired when first observed is a timeout, even if
the process has since exited. Cancellation and timeout send SIGTERM to the owned
process group, allow 200 ms, then escalate to SIGKILL. Leader exit also terminates
remaining group members so inherited pipes cannot keep capture open indefinitely.
Process reaping and capture cleanup each have a two-second bound. These are Unix
process-group attempts: unconfirmed exit is a failed result, not a successful
cancellation acknowledgement. The implementation does not establish containment
of descendants that deliberately escape their group; Linux service/cgroup policy
remains installation work.

Capture drains stdout/stderr independently in fixed-size chunks to private spool
files. The default combined capture cap is 16 MiB per execution, with four active
and 32 retained executions. Above the request's inline threshold, or for non-UTF-8
bytes, output remains in a lossless local artifact spool with a generated `art_`
ULID. Output readers are read-only and bounded to the sealed byte count. Overflow
stops the command and reports `OUTPUT_LIMIT_EXCEEDED`; timeout reports
`EXEC_TIMEOUT`. `ExecSnapshot.failure` must be handled by the future dispatcher,
not silently treated as success. A nonzero command exit is a failed result, not
a protocol failure. Disabled capture uses the null device and consumes no spool
budget. Running snapshots contain empty output; output is published on completion.

The configured spool parent must be owned by the effective user and not group/world
writable. Owned subdirectories are `0700`, and output files are `0600`. Sealing a
local file does **not** prove binary transfer, host artifact registration, or durable
publication. The host must still stream, verify, and commit each artifact.

Identical retained operation replays return the existing snapshot; conflicting
inputs are rejected. Admission/retention exhaustion rejects new work. `release`
is an internal acknowledgement to discard a terminal result only after the caller
has consumed its output. There is no persistent guest operation journal or replay
tombstone after release: the daemon's durable Operation remains authoritative.
`shutdown` cancels active work, closes admission, and preserves terminal records
until release/drop. Dropping the executor requests cancellation while its runtime
is alive; dropping an unpolled worker also kills its owned process group. This
does not claim cleanup after SIGKILL of the whole guest service.

## Core system queries

`system::SystemQueries` handles negotiated `health` and `system.info` requests
with schema-validated response envelopes and unchanged request/VM/generation/
operation correlation. Health reports this agent instance's monotonic uptime
and responsiveness, not application-service readiness or overall VM health.

System info uses the running kernel's `uname` identity, reads at most 64 KiB of
OS-release metadata, and optionally reads the boot ID (128-byte bound). A trusted
filesystem root is supplied by the composition layer (`/` in a guest); it cannot
be chosen by an RPC request. `/etc/os-release` takes precedence over the vendor
file, without merging. Quoted values are decoded as data, never sourced or expanded
by a shell. A missing OS name falls back to the kernel's OS name; an unspecified
OS version is `unknown`, never the kernel release or a guessed distribution version.
Missing optional identity fields are null. Malformed, oversized, or non-regular metadata
returns `GUEST_INTERNAL_ERROR` without echoing file contents. These synchronous,
bounded-size queries still need the future service's bounded blocking-I/O worker
policy; byte bounds do not establish filesystem latency bounds.

## Guest-side artifact collection

`artifact::ArtifactCollector` prepares local snapshots for `artifact.collect`.
It is explicitly bound to a VM/generation, and collection, reads, and release all
require a ready session with the negotiated capability and operation binding.
The source root and spool parent are trusted service configuration, not request
parameters, and must be owned by the effective user and not group/world writable.

Request paths are strict relative paths beneath the pinned source-root descriptor.
Absolute paths, empty/dot/parent components, symlinks in any component, hard-linked
files, and special files are rejected. Each component is opened relative to an
owned directory descriptor with no-follow/nonblocking flags and checked for type,
ownership, and unsafe write permissions. Root permissions are checked again on
each new source open; replacing its original pathname does not rebind the root.
This policy does not grant access to arbitrary guest files or elevate privileges.

Files stream through an 8 KiB buffer into private `0700`/`0600` spools. The default
limits are 16 MiB per collection, 256 MiB of retained bytes, and 16 retained
collections, further bounded by the request's combined byte limit. Zero permits
only empty files. Copy errors, overflow, or observed source changes publish no
collection and discard partial spools; dropping the collection future also
discards its partial output. Size/timestamp checks detect observed mutations, not
an atomic filesystem snapshot of concurrently written sources. The SHA-256 and
declared size describe the copied bytes, not a later read of the source path.

Retained identical replays reuse their original artifacts even if sources change;
conflicting inputs are rejected. Readers are read-only and capped at the sealed
byte count. Retaining a sealed artifact does not keep its file descriptor open.
Internal `release` retires a collection after consumption, reclaiming
retention capacity; already-open readers remain caller-owned until closed. The
future transport must bound reader lifetimes and concurrency. There is no durable
guest journal, release tombstone, installed crash-spool recovery, or host DB commit.

`ArtifactInfo` is deliberately **not** a wire `artifactDescriptor`: it has no
`stream_id` because no binary channel has been established. The collector does
not yet implement a complete `artifact.collect` RPC response or transfer protocol.
The future transport must create/bind separate binary streams and the host must
verify streamed bytes before durable artifact publication. Frozen schemas remain
unchanged; local descriptors are not evidence of completed transfers.

## Checks

Rust 1.96.1 is the CI baseline; `Cargo.lock` is authoritative.

```bash
cargo +1.96.1 fmt --all --check
cargo +1.96.1 clippy --all-targets --locked -- -D warnings
cargo +1.96.1 test --locked
```

CI also checks the library for `aarch64-unknown-linux-gnu`. That is compilation
coverage, not a native ARM64 guest/vsock test. Schema examples, fragmented and
coalesced frames, invalid lengths, pre-hello calls, capability mismatch, and
cross-VM/generation messages are exercised through the library interfaces.

## Remaining package and MVP work

- Linux virtio-vsock listener and host-peer verification.
- RPC dispatch around the execution/collection engines and system queries; an
  executable, least-privilege service installation, signal handling, crash cleanup,
  and reconnect/disconnect policy.
- Separate bounded binary artifact streams; their wire/channel binding still
  needs an explicit interoperability decision. Do not send base64 artifact bodies
  in control messages or silently treat file references as completed transfers.
- Driver-owned vsock bridge, daemon per-VM guest sessions/reconnect/readiness,
  durable guest operations, public API/CLI, and TestRun orchestration.
- Real GaoOS and Apple Silicon VZ end-to-end validation and release gates.
