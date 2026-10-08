# GaoVM guest protocol foundation

This crate starts development-plan package 023. It is a **library**, not yet an
installable `gaovm-guestd` service. Do not deploy it or treat its tests as GaoOS
guest readiness, command execution, or TestRun acceptance.

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
- Real health/system-info/exec/status/cancel/artifact handlers, least-privilege
  service installation, graceful shutdown, and bounded subprocess/output lifetime.
- Separate bounded binary artifact streams; their wire/channel binding still
  needs an explicit interoperability decision. Do not send base64 artifact bodies
  in control messages or silently treat file references as completed transfers.
- Driver-owned vsock bridge, daemon per-VM guest sessions/reconnect/readiness,
  durable guest operations, public API/CLI, and TestRun orchestration.
- Real GaoOS and Apple Silicon VZ end-to-end validation and release gates.
