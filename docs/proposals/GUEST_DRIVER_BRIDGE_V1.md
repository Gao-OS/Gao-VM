---
project: GaoVM
title: Private guest driver bridge v1 proposal
document: protocol-proposal
status: proposed
accepted: false
target_work_packages: ["024", "025"]
updated: 2026-10-09
---

# Private guest driver bridge v1 proposal

This is a review proposal, not a frozen contract or implemented transport.
It fills the separate bridge-contract decision required by
[the binary-stream proposal](GUEST_BINARY_STREAMS_V1.md). Neither proposal is
accepted yet. Do not change production wire behavior on the basis of this draft.

## Boundary and verified starting point

The daemon owns application services and durable guest operations; the Swift
driver alone owns VZ devices. The existing driver-v2 control socket, bidirectional
hello, generation token, watchdog, and JSON-RPC framing stay unchanged. No public
driver passthrough, guest socket path, stream handle, or token is added to `/v1`.

At `main` 210e6eb, `DriverSessionV2` advertises only runtime capabilities.
The frozen schema already contains optional `guest.status` and
`guest.channel_ready`, but neither establishes a byte channel or guest health.
`DriverRuntimeLayout` already owns a private per-VM/per-generation directory.
This draft adds a separate authenticated byte bridge there, not a new JSON-RPC
method, multiplexing on the driver control socket, or VZ access from Dart.

## Proposed endpoint and availability

- Endpoint: `guest.sock` beside that generation's `driver.sock`, derived from
  `DriverRuntimePaths.directory`; never supplied by a public request or the guest.
- Generation and VM directories remain owned `0700`; the new socket is `0600`.
  Both peers verify the expected UID; filesystem access alone does not authorize
  a connection. Unknown existing nodes are rejected, not unlinked or rebound.
- The listener accepts only while the original driver-v2 bidirectional handshake
  is authenticated. Each additional bridge connection authenticates separately.
- The driver negotiates the existing optional `guest.status` capability only
  after implementing this bridge. Its proposed result `data` is exactly
  `{"bridge_protocol_version":"gaovm.bridge.v1","available":true,"vsock_port":10777}`,
  with the configured port (`null` before configuration) and actual runtime
  availability substituted.
  `available` means a native channel can be attempted, not that the agent is ready.
  Missing capability or a different bridge version fails closed, without fallback.

Defining this `guest.status` result shape is part of the decision requested here,
even though it requires no change to the existing schema's generic `data` object.
`guest.channel_ready` must never be interpreted as authenticated guest readiness.

## Per-connection opening handshake

One `u32be length + UTF-8 JSON object` request and one response precede the raw
byte stream. Lengths are 1..4096 bytes and checked before allocation. Reject
duplicate/unknown fields, invalid UTF-8/JSON, batches, and invalid correlation.
The one opening request has exactly these fields:

```json
{
  "protocol_version": "gaovm.bridge.v1",
  "kind": "open",
  "vm_id": "vm_01J00000000000000000000000",
  "driver_generation": 8,
  "request_id": "req_01J00000000000000000000001",
  "operation_id": null,
  "stream_kind": "control",
  "auth_token": "<the existing per-generation driver token>"
}
```

`stream_kind` is `control` or `binary`. `operation_id` is nullable for control
health/negotiation and required for binary work. IDs use the frozen resource-ID
syntax, generation is a positive integer, and token comparison is constant time.
The token is a nonempty string of at most 512 UTF-8 bytes.
The token is never forwarded to the guest, logged, persisted, or returned in a
response. There is no caller-selected port, path, or guest command in this prefix.

After UID, token, generation, active-control-session, and slot checks, the driver
connects to **only** the configured guest-agent port of its own VM. Only successful
native connection establishment permits this response:

```json
{
  "protocol_version": "gaovm.bridge.v1",
  "kind": "ready",
  "vm_id": "vm_01J00000000000000000000000",
  "driver_generation": 8,
  "request_id": "req_01J00000000000000000000001",
  "operation_id": null,
  "stream_kind": "control"
}
```

The daemon checks every field before sending guest bytes. This acknowledgement
proves bridge admission/connection only, not guest hello, health, execution, or
durable artifact publication. The guest protocol still performs its own hello.
The driver strips both opening frames and pumps subsequent bytes without parsing
guest RPCs or binary payloads. A binary stream uses the separate proposed `GAB1`
preface; it never shares the guest control connection.

Malformed, unauthorized, or wrong-binding openings close without echoing input.
An authenticated but unavailable/busy native connection may return the same
version/correlation/stream-kind fields with `kind: error` and a `code` field:
`GUEST_CHANNEL_UNAVAILABLE` or `CHANNEL_LIMIT_EXCEEDED`. It includes no free-form
message, token, endpoint, or path. A response error ends that connection.

## Lifetime, ownership, and bounds

- Proposed per-driver limits: eight pending openings, one active control stream,
  and two active binary streams. Excess admission fails; it does not queue
  unbounded tasks. Connecting streams reserve their active slot until closed;
  timeout/cancellation releases the reservation exactly once.
  Open/auth/native-connect/response share one five-second
  absolute deadline, further bounded by the caller's operation deadline.
- All VZ device/property/connection operations run on the explicit runtime queue.
  The native connect is asynchronous; no semaphore or synchronous completion wait
  is allowed on that queue. A late native completion after timeout or teardown
  closes its connection on the runtime queue and cannot restore admission.
- Retain each VZ connection on the runtime queue. Its file descriptor is borrowed;
  an owned duplicate may be handed to bounded nonblocking I/O workers. Those
  workers use fixed 8 KiB directional buffers and stop reading while a buffer is
  pending. They do not close the VZ-owned descriptor or access VZ objects.
- On EOF/error/cancellation, close both bridge directions, close the owned raw
  descriptors, then close/release the VZ connection on its queue exactly once.
  No half-close behavior is required. Guest binary framing supplies its own end
  marker. A stalled write has a five-second absolute budget for the pending
  buffer; partial progress does not restart that budget.
- Driver control EOF, watchdog expiry, or runtime teardown first fences new
  openings and closes all active bridges. Bridge traffic never refreshes the
  authenticated driver-control watchdog. Late callbacks retain their original
  VM/generation and cannot attach to another driver or session.
- Closing a guest bridge alone does **not** stop the VM. The daemon marks that
  guest session unavailable and resolves outstanding operations according to
  their disconnect semantics; it must not replay a side-effecting `exec.start`
  merely because a channel disappeared.
- Runtime-file reconciliation must recognize the exact new socket leaf only
  under verified generation ownership, after confirmed process exit. Preserve
  unknown files and reject substituted links/inodes; never broaden cleanup to a
  directory glob. Public artifacts remain independent of this runtime directory.

These are proposed bounds, not measurements or implemented safeguards.

## Trust and native evidence limits

This model trusts processes running as the daemon's OS user, like the existing
driver-generation token boundary. It isolates other OS users and VM/generation
mix-ups; it does not isolate hostile processes with the same UID that can read
the daemon/driver environment or replace user-owned paths. If that threat model
is required, a stronger credential/channel-binding design must be accepted first.

The guest must separately verify native peer CID before adopting a host hello.
Linux defines host CID as 2, which identifies the host, not a particular host
process. The bridge token is not a credential to expose inside a generic image.
See [Linux UAPI](https://github.com/torvalds/linux/blob/master/include/uapi/linux/vm_sockets.h).

Apple exposes asynchronous guest-port connection establishment and a connection
file descriptor owned by the VZ connection. This was checked against the local
Xcode SDK's `VZVirtioSocketDevice.h` and `VZVirtioSocketConnection.h`; API shape is
not proof of native peer identity or successful forwarding.
See [Apple's connection API](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice/connect(toport:completionhandler:)).

## Implementation and acceptance after approval

1. Freeze independent opening fixtures and reject cases before adding the Swift
   listener/Dart connector. Keep driver-v2 and public schemas unchanged.
2. Exercise real Unix sockets: correct/wrong token, UID/version/VM/generation,
   fragmented/coalesced framing, silent/slow open, slot exhaustion, stalled
   writes, simultaneous control/binary streams, and teardown during native connect.
3. Verify the VZ-queue boundary, late completion cleanup, per-generation runtime
   cleanup, driver-control responsiveness, and VM-B isolation under VM-A failure.
4. Connect the actual host Guest Session, guest dispatcher, and approved binary
   protocol. Readiness requires negotiated guest capabilities and authenticated
   health, transactionally fenced by the current VM/generation/session.
5. Prove native Apple Silicon VZ + GaoOS peer CID, two-VM isolation, reconnect,
   guest timeout/cancel, artifact spill, daemon restart, and public API download.
   Unix-socket or fake-VZ results cannot satisfy this native gate.

Decision requested: accept the per-generation private UDS bridge, per-connection
token/UID authentication, fixed-port forwarding, opening shapes, resource limits,
and same-UID trust boundary above, or specify which boundary must change.
Approval of the binary-stream proposal alone does not approve this bridge.
