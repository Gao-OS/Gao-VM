---
project: GaoVM
title: Private guest driver bridge v1 contract
document: protocol-contract
status: accepted
accepted: true
accepted_on: 2026-10-10
target_work_packages: ["024", "025"]
updated: 2026-10-10
---

# Private guest driver bridge v1 contract

The user accepted this contract and [the binary-stream contract](GUEST_BINARY_STREAMS_V1.md)
on 2026-10-10. Acceptance fixes the wire and trust boundaries below; it does not
prove implemented transport or native acceptance. Keep the existing driver-v2
and public API schemas unchanged while implementing this separate bridge.

## Boundary and verified starting point

The daemon owns application services and durable guest operations; the Swift
driver alone owns VZ devices. The existing driver-v2 control socket, bidirectional
hello, generation token, watchdog, and JSON-RPC framing stay unchanged. No public
driver passthrough, guest socket path, stream handle, or token is added to `/v1`.

At `main` 210e6eb, `DriverSessionV2` advertises only runtime capabilities.
The frozen schema already contains optional `guest.status` and
`guest.channel_ready`, but neither establishes a byte channel or guest health.
`DriverRuntimeLayout` already owns a private per-VM/per-generation directory.
This contract adds a separate authenticated byte bridge there, not a new JSON-RPC
method, multiplexing on the driver control socket, or VZ access from Dart.

## Endpoint and availability

- Endpoint: `guest.sock` beside that generation's `driver.sock`, derived from
  `DriverRuntimePaths.directory`; never supplied by a public request or the guest.
- Generation and VM directories remain owned `0700`; the new socket is `0600`.
  Both peers verify the expected UID; filesystem access alone does not authorize
  a connection. Unknown existing nodes are rejected, not unlinked or rebound.
- The listener accepts only while the original driver-v2 bidirectional handshake
  is authenticated. Each additional bridge connection authenticates separately.
- The driver negotiates the existing optional `guest.status` capability only
  after implementing this bridge. Its result `data` is exactly
  `{"bridge_protocol_version":"gaovm.bridge.v1","available":true,"vsock_port":10777}`,
  with the configured port (`null` before configuration) and actual runtime
  availability substituted.
  `available` means a native channel can be attempted, not that the agent is ready.
  Missing capability or a different bridge version fails closed, without fallback.

This contract defines the `guest.status` result shape,
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
guest RPCs or binary payloads. A binary stream uses the separate accepted `GAB1`
preface; it never shares the guest control connection.

Malformed, unauthorized, or wrong-binding openings close without echoing input.
An authenticated but unavailable/busy native connection may return the same
version/correlation/stream-kind fields with `kind: error` and a `code` field:
`GUEST_CHANNEL_UNAVAILABLE` or `CHANNEL_LIMIT_EXCEEDED`. It includes no free-form
message, token, endpoint, or path. A response error ends that connection.

## Lifetime, ownership, and bounds

- Per-driver limits: eight pending openings, one active control stream,
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

These are accepted bounds, not measurements or evidence of implemented safeguards.

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

## Implementation and native acceptance gates

1. Freeze independent opening fixtures and reject cases before adding the Swift
   listener/Dart connector. The independent
   [bridge schema and golden headers](../../schemas/guest-bridge/v1.schema.json)
   define shapes, not runtime authentication or admission. Keep driver-v2 and
   public schemas unchanged.
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

Accepted decision: the per-generation private UDS bridge, per-connection token/UID
authentication, fixed-port forwarding, opening shapes, resource limits, and same-UID
trust boundary above. Changes to those boundaries require a new explicit decision.
Implementation and native E2E remain separate, unproven gates.

## Current local implementation boundary

`GuestBridgeProtocolCodec` now implements the separate typed opening/ready/error
headers in the Swift driver. It checks the original flat-object keys before JSON
normalization, including escaped duplicate names, and validates required/null
fields, canonical resource IDs, version, stream kind, exact generation and encoded
header/token byte limits. Generation validation uses the original number token:
Foundation integer conversion reproduced rounding a fractional near-limit value,
and dictionary parsing rejected a valid exponent with leading zero digits. The
codec keeps legal exact integer decimal/exponent forms without accepting rounded
fractions. Diagnostics and opening descriptions do not reflect the token.

`GuestBridgeFrameIO` bounds the length before allocating the payload, retains the
caller's one original deadline through prefix/payload/validation and closes the
owned socket on a failure. Its client-side response reader checks every opening
correlation field before exposing subsequent bytes; a matched error also closes
the socket. Real Unix fixtures cover fragmented prefixes, coalesced guest bytes,
oversized lengths, silent failure, slow opening and mismatched/error responses.
Encoding returns a bounded frame; this helper is synchronous I/O for a bounded
owned socket worker, not work to run on the VZ queue.

`GuestBridgeRelay` now provides the separate raw-descriptor pump. It consumes
owned descriptors (never the borrowed VZ descriptor), uses two fixed 8 KiB buffers
on its own serial I/O queue, and stops reading a direction while that buffer is
pending. Each pending write has one five-second deadline; partial progress does
not renew it. EOF/error/cancel/drop closes both directions. Every Dispatch source
first passes its cancellation handler, including resumed suspended sources,
before raw descriptors close and the asynchronous native-release callback runs.
Completion waits for that callback; the connection/slot owner must retain
the VZ connection until actual runtime-queue close/release and acknowledge only
then. A reproduced idle-relay abandonment leak required separating the owning
handle from the self-retained cleanup worker. Unix fixtures verify forwarding,
backpressure, partial-progress timeout, drop/setup failure and delayed/duplicate
cleanup completion. Their native cleanup callback is a fixture, not a VZ close.

`GuestNativeConnector` now retains one control and two binary reservations through
connecting, prepared, relaying and actual cleanup. An opening timeout/cancellation
reports the failed decision promptly, but its `closed` callback remains pending
while an uncancellable native connect is live. A late success closes on the runtime
queue before releasing that slot, after the caller acknowledges actual raw-client
cleanup. Prepared-channel cancellation uses that same acknowledgement; merely
scheduling a listener cancellation is not a native-release barrier. Duplicate
acknowledgements cannot release a native object or slot twice. Native connection/descriptor access and release
stay on that queue; only an owned close-on-exec duplicate reaches the relay. The
original opening deadline includes the prepared channel until the caller confirms
ready output by starting the relay; established relay lifetime is independent of
that completed opening budget. Dropping an unresolved opening or channel cancels
its own work, and connector shutdown permanently fences its admission.

`VzRuntime.openGuestChannel` invokes the actual asynchronous VZ API using only the
port captured from the VM's applied configuration, not a later pending spec. Its
adapter retains the original VZ connection and VM through late completion and
runtime-queue close/release. Stop, kill, shutdown and runtime-generation release
fence the old connector before lifecycle teardown. Unix fixtures in
`GuestNativeConnectorTests.swift` verify slot retention, three simultaneous byte
streams, deadline/abandonment cleanup and independent connector isolation; the
external VZ boundary is substituted. The real SDK path compiles but native
connection establishment, teardown and two-VM isolation are not proved.

`GuestBridgeListener` now owns the generation's `0600` endpoint in real owned
`0700` VM/generation directories. Kernel peer-UID checks precede framed input;
strict opening validation, VM/generation/token checks and the original authenticated
session predicate precede native admission. Invalid/unauthorized peers close
silently; only authorized native unavailability/limit failures receive bounded
correlated errors. Eight pending permits remain charged through failure output,
raw-source cancellation and actual factory/native cleanup. Accept-time framing,
native connection and complete ready output share one five-second deadline. Only
after ready flush and all framing sources drain does the relay receive the raw FD.
The listener and each bounded native factory have separate queues. A suspended
reader preserves early guest bytes; periodic nonblocking `poll(POLLIN)` detects
peer hangup without consuming them or renewing the original deadline. On the
tested Darwin kernel, polling with no requested events missed queued-byte hangup.

`DriverSessionV2` creates this listener only after both directions of its original
hello succeed. Original-session EOF, fatal error, watchdog or terminal exit fences
the listener before teardown; bridge traffic never refreshes the control-RPC
watchdog. Compiled-driver fixtures exercise mutual-hello gating, unconfigured
runtime rejection, responsive ping, EOF cleanup and watchdog isolation. Standalone
Unix listener fixtures additionally exercise silent rejection, original deadlines,
pending permits, slow/late factories, actual raw-client cleanup, owner abandonment
and preservation of unknown/replaced endpoints. Their native connection boundary
is a fixture, not an established VZ guest connection.

`DriverRuntimePaths.guestSocketPath` derives the private sibling endpoint. The
daemon's existing owned-generation quarantine recognizes exactly `guest.sock` of
Unix-socket type alongside `driver.sock`. POSIX residue fixtures validate cleanup;
socket-shaped files, symlinks and unknown socket names preserve the quarantine and
its metadata instead of causing partial removal. Callers still require confirmed
driver exit (or a never-spawned generation); the new leaf is not process authority.

`GuestBridgeClient` now consumes the derived private endpoint inside its original
`ProcessRuntimeDriverSession`, without exposing the generation token. Negotiated
`guest.status`, its exact availability shape/version and the original channel's
identity must pass before connection; kernel peer UID is checked before token
output. A status RPC occupies one of eight opening permits until the actual RPC
settles, even after its caller deadline expires. Late results cannot reopen the
channel. Framing, status, connection and response share the original bounded
monotonic budget. The flat response decoder rejects decoded duplicate keys and
validates generation from its exact decimal coefficient/exponent before checking
every correlation field. A matched ready exposes only subsequent raw bytes, with
serialized bounded 8 KiB reads/writes and non-renewing pending-write deadlines.
Original control EOF, heartbeat failure, process exit, release and terminal commands
fence guest admission; session close joins actual owned guest closure before runtime
layout release. Guest-channel close alone does not dispatch VM lifecycle commands.
Real Unix and child-driver fixtures validate these paths, status failures, permit
retention, backpressure and two-VM isolation. Peer mismatch fixtures use the current
OS user's socket and a deliberately different expected UID; they do not prove an
actual foreign-user or native-vsock connection. Linux credential code is unexecuted.

The compiled-driver regression also reproduced terminal kill selecting `137` while
its local control-reader EOF/I/O error exited with `0`/`1`. Terminal cleanup now
commits the expected exit code before interrupting the original socket; that
reader recognizes the committed close rather than initiating another exit policy.
Repeated unconfigured-driver generations test the actual process/socket path,
not a configured VZ VM.

`HostGuestSession` now owns one control connection per original process session
and VM/generation. It sends the host-first guest hello, requires matching capability
sets in both directions and successfully writes the final acknowledgement before
an authenticated, correlated health result can establish local readiness. Typed
health and system-info requests share a bounded eight-request pool, serialized
writes and exact request/method/operation binding. Recursive raw-key validation
rejects decoded duplicates before maps are built; generation validation preserves
exact integer-valued JSON numbers. Malformed replies, partial-frame deadlines and
EOF fence the epoch and settle its pending requests. Unsent deadline/limit rejection
does not close a healthy epoch; valid guest errors retain their wire code and
retryability without reflecting free-form diagnostics.

The idle reader waits for one byte without an idle heartbeat deadline, then keeps
one explicit library frame budget across prefix, body and validation. Degraded
health refreshes the existing live epoch; reconnect waits for actual old-channel,
reader and writer closure before creating a new one. Concurrent connect callers
share one opening. Process close/exit/heartbeat/terminal fencing closes the guest
owner before runtime-layout release; closing guest alone still does not stop the
VM. Real Unix and two-child-driver fixtures exercise these paths and show that
guest health traffic cannot refresh the original driver heartbeat.

The optional guest owner now reports ordered local health/closure observations to
the per-VM controller. Runtime `running` starts one owned, bounded hello/health
probe outside the lifecycle effect lane; guest-disabled or unsupported drivers
still run without it. `guest.channel_ready` remains bridge admission only. The
controller rejects other VM/generation and stale same-generation observations.
Its reducer stays pure; live observation validity is checked by the controller and
again through the SQLite commit boundary, so closure/replacement while a write
waits cannot publish a queued ready result.

`SqliteVmStateEffectAdapter` publishes guest ready/unavailable, a durable event and
its outbox row atomically. It binds the current driver, applied spec and execution
checkpoint, and respects already-accepted stop/deletion fences. Readiness uses the
applied guest setting, not a newer unapplied spec. Lifecycle transitions and ownerless
startup recovery clear old readiness. Publication failure rolls back, is surfaced
separately and does not release a healthy driver or enter the VM failure/retry policy.
Real child-driver/Unix and SQLite fixtures verify committed condition waits, guest
close with responsive driver ping, unavailable/disabled support, a stalled health
probe with joined shutdown, stale observations and revocation during publication.
They do not establish native guest readiness or installed-service acceptance.

Automatic health/reconnect and observation retry, [durable guest execution](../GUEST_EXEC_DURABILITY.md)
and [host publication before ACK](../GUEST_ARTIFACT_PUBLICATION.md) are now composed
in the daemon, including [TestRun diagnostics](../TEST_RUN_ARTIFACTS.md). An initial
probe or local readiness observation is not native-service acceptance. `DriverSessionV2` still
offers only runtime capabilities: do not advertise `guest.status` based on Unix
fixture success. No native forwarding, peer CID, guest readiness, durable host
artifact publication through the native stack or installed-service acceptance is proved by these tests.
