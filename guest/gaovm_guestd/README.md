# GaoVM guest protocol and service foundations

This crate develops plan package 023 and supplies a library plus a Linux-only
`gaovm-guestd` entrypoint. It is not yet an installed or native-accepted GaoOS
service. Tests execute real Unix subprocesses and routing fixtures, but do not
establish GaoOS readiness, VZ/vsock execution or TestRun acceptance. Native gates,
least-privilege installation, retirement and recovery remain incomplete; do not
treat the development executable as deployment acceptance.

## Implemented control contract

The authoritative message grammar is
[`schemas/guest-protocol/v1.schema.json`](../../schemas/guest-protocol/v1.schema.json).
The library embeds that schema and compiles a reusable validator, including
date-time format checks. HTTP/file schema resolution is disabled; runtime
messages cannot supply a different schema. Errors do not echo request contents.

Control frames use a four-byte unsigned big-endian payload length followed by
one UTF-8 JSON object. Payloads must be nonempty and at most 16 MiB. Batches,
scalars, malformed UTF-8/JSON, duplicate keys (including escaped/nested keys),
and incomplete frames fail closed. Clean EOF is
allowed only between frames. An outbound size/type error writes no frame bytes.
Framing errors are fatal to the channel; callers must close it, not retry from
an uncertain byte offset. A transport must set bounded read/write deadlines.

`control::FrameReader` and `FrameWriter` provide asynchronous framing with absolute
deadlines. Cancelling a read preserves its buffered header/payload and original
deadline; resuming cannot extend that deadline. A framing error or timeout makes
the reader unusable. Cancelling a polled write, or any write/flush failure, makes
the writer unusable because a partial frame may already be on the connection.
Outbound validation is bounded and happens before any frame bytes are written.
These wrappers do not perform wire negotiation, dispatch RPCs, authenticate a
peer, or close the underlying transport; the composition layer still owns those
responsibilities.

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

`control::negotiate` drives a fresh `Session` over the asynchronous framing halves
under one absolute handshake deadline. It returns only after both hellos and
acknowledgements agree and every outbound message has been flushed. A protocol or
I/O error, timeout, or cancellation of a polled negotiation permanently invalidates
the session and both halves, even if the raw protocol state became ready before
the final acknowledgement flush. Unlike a standalone frame read, an interrupted
handshake cannot be resumed. Callers must close a failed transport and establish
a new connection/session; host-peer authentication is still required separately.

Successful negotiation now returns an opaque `ControlEpoch`. It cannot be
reconstructed from wire IDs and is not available from `Session::is_ready()`.
Dropping the session or explicitly invalidating its epoch fences authorization
before notifying active transfers. The standalone framing helpers do not
automatically supervise a connection after hello.

`guest_connection::ControlSlot` serializes guest control ownership across opening,
active and cleanup states. A generic guest adopts its binding only from the first
valid host hello, flushes that hello's acknowledgement before sending its own,
and completes negotiation under the original absolute deadline. It embeds no
VM ID or default generation. Failed/cancelled bootstrap poisons both framing
halves; the caller closes the owned transport.

`ActiveControl::read_message` fences its epoch before returning EOF, a framing
failure or timeout; revocation wakes a pending read. Application authorization
remains with `Session`/handlers so stale requests cannot rebind or invalidate a
healthy session. `begin_close` fences before service-owned transfer/process/spool
cleanup. Only the consumed cleanup owner's explicit `finish` reopens the slot;
dropping active/cleanup ownership leaves it closed. The service must confirm all
owned work/I/O has stopped before finishing. These ownership helpers are not an
installed dispatcher or native transport authentication.

The six `CORE_CAPABILITIES` are the frozen P0 contract. The library dispatcher
below now composes their handlers and sealed-file transfer sources. Guest hello
validation requires all six; an executable must initialize its handlers and
resource owners before advertising them and complete native transport/service
composition. P1 file transfer/service control/power operations are not part of
this implementation.

## Linux transport admission

The Linux-only `vsock::HostListener` uses native AF_VSOCK with nonblocking,
close-on-exec owned descriptors and no TCP/Unix fallback. Each accepted descriptor
passes an actual kernel `getpeername` check for AF_VSOCK and host CID 2 before
any preface or JSON is read. Claimed VM IDs, generations and CIDs do not construct
an authenticated `HostStream`.

One long-lived listener owns eight pending-opening permits, retained across
control epochs. Excess accepted openings close immediately instead of waiting
in an unbounded task queue. `AcceptedHost::into_parts` transfers the owned stream,
permit and original five-second deadline to the coordinator; it must retain the
permit through control hello or binary grant admission and must not refresh the
deadline after reading the preface. `local_port` reports the actual kernel-bound
port, not a wildcard placeholder. This component requires a Tokio I/O runtime.

ARM64 Linux checks compile this code and its Linux-only rejection tests. They do
not execute a native accept, measure quotas, or establish GaoOS/VZ peer identity.
The entrypoint below now wires the authenticated native listener, demux and OS
signals to owned control/binary work. Its Linux path is compile/lint-checked, not
native-executed; these components do not establish installed-service acceptance.

## Resident entrypoint and same-port routing

`src/bin/gaovm-guestd.rs` creates one process-lifetime `HostListener`,
`acceptor::GuestAcceptor` and shared `GuestResources`. Native streams enter the
router only through the listener's actual peer-CID check. The router restores a
consumed control length prefix with the original deadline, or hands an already
recognized GAB1 stream to the current control owner's binary admission without
reading its magic twice. It owns at most nine connection tasks (one control owner
plus the listener's eight openings). A second control opening cannot overwrite
opening/active/closing ownership. Opaque owner identity prevents an old task from
clearing a replacement's handle. `completed` supervises finished owners without
waiting for another connection; protocol/peer failures do not replace a healthy
binding, while unconfirmed cleanup/internal ownership failure stops admission.

`--help` is available without starting a listener. Runtime configuration requires
absolute `--artifact-root` and `--spool-parent` paths and a finite, positive
`--io-budget-seconds` policy. `--port` defaults to the accepted 10777; no VM identity,
storage-root or I/O-budget default is inferred. The explicit budget bounds control
frames/requests and the native caller's binary outer deadline; original opening
and grant/phase deadlines can only shorten it. This is not a new wire heartbeat
requirement. System metadata comes from the running guest's `/` root. Invalid CLI
input returns exit 2 without echoing arguments; non-Linux runtime invocation
returns failure without TCP/Unix or storage fallback.

SIGTERM/SIGINT closes the listener, permanently stops admission, joins every
opening/control owner and passes actual filesystem-worker quiescence. A cancelled
bootstrap can still own a queued initializer/result; shutdown waits for that
actual cleanup instead of declaring success at caller cancellation. An active
control owner receives its trusted local stop and completes its own barrier; the
resident loop does not abort that run future as graceful shutdown. Unix fixtures
verify these paths and replacement after confirmed EOF/partial-hello timeout.
They do not execute the resident entrypoint's native vsock/signal/prctl path.

The Linux entrypoint enables inherited `PR_SET_NO_NEW_PRIVS` and uses the invoking
UID/GID. That does not remove existing privileges, install a dedicated account,
contain descendants that escape a process group, or prove a least-privilege
service/cgroup policy. Linux PORT_ANY also remains distinct from a fixed driver
endpoint; reporting the kernel-bound port does not solve the frozen VmSpec's
wildcard-value compatibility question.

Authorized binary-open errors now send one bounded correlated header and close
without a body. Error eligibility requires a live, published, fully matched
epoch/VM/generation/operation/artifact/selector binding; matching runs before quota
checks. Unknown, malformed, pending, expired or retired bindings remain silent,
including while the transfer pool is full. Error codes alone do not establish
authorization. Busy/quota failures do not admit a reader; source-open failures
release their attempted lease without retiring the grant. Diagnostics are fixed,
and only transfer-limit replies advertise possible retry (not automatic retry).
Error writes obey the original opening/operation/grant deadline and epoch
revocation. Since an error has no active transfer lease, its opening permit stays
charged through error flush/transport close; stalled replies cannot turn into
uncharged sockets. Real Unix fixtures verify no body, inode restoration/retry,
foreign-binding silence under full quota and backpressure/deadline/EOF cleanup.
Errors after ready/body start still close the failed connection, not append an
error frame. Result/group retirement, crash recovery, least-privilege image
integration and native acceptance remain unfinished. Driver/daemon sessions and
[durable host publication](../../docs/GUEST_ARTIFACT_PUBLICATION.md) now have
implementations and Unix component checks, including a real Rust-to-Dart peer.

## Owned control coordinator

`service::GuestControl::bootstrap` owns both framing halves. After validating the
authenticated peer's first host hello, `GuestResources::bootstrap` initializes
the core engines, trusted roots, healthy spool budget and entropy source before
sending either a guest hello or a host hello acknowledgement. Initialization runs
on a counted owned filesystem worker under the original handshake deadline.
Failure emits no readiness bytes. A cancelled attempt is one-shot, poisons its
framing halves and retains cleanup ownership until the actual worker and any
discarded engine result finish; supplying fresh halves cannot resume that attempt.
Normal bootstrap failure closes both halves and passes the resource barrier.
Abandoning bootstrap instead leaves the slot closed, not reusable.

`run` takes an explicit finite, nonzero frame/request budget from its caller; it
does not define a new wire heartbeat requirement or an installed-service default.
It reads control frames concurrently with at most eight owned request tasks and
serializes replies through one writer. Overload fences the channel instead of
queueing without a bound. Invalid/foreign application requests are not reflected
and do not invalidate a healthy binding. The session handle accepts owned binary
streams and the native listener's original opening permits/deadlines; it retains
at most ten jobs (eight openings plus two admitted transfers). Native peer
authentication must occur before either coordinator entry point.

EOF, framing/deadline/write failure or `GuestSessionHandle::stop` fences the epoch
first, aborts and joins owned request/binary tasks, reaps executions, closes both
control halves, drops the dispatcher and passes the final resource barrier before
reopening admission. `stop` is a trusted local-service action, not a guest power
RPC, and cannot hide cleanup failure. Handles are weak and cannot retain the
dispatcher or authorize work on a replacement epoch. Abandoning `run` keeps its
slot closed. Unix fixtures cover readiness failure/cancellation, real process
shutdown, sibling transfers, health under binary backpressure and drop-time
cleanup quarantine; their ACKs do not prove durable host publication.

## Per-epoch guest dispatcher

`dispatcher::GuestResources` supplies trusted source/spool/system roots, one shared
spool budget and a metadata/system-query worker slot. Reuse this resource owner
across replacement control epochs. `bootstrap` creates one `GuestDispatcher` with
pre-advertisement initialization. The legacy library/test `bind` creates it after
hello and does not establish service readiness. Both compose the existing exec,
collection, system and grant engines.
It handles `capabilities.get`, `health`, `system.info`, `exec.start/status/cancel`
and `artifact.collect` without changing the frozen response shapes.

Authorization precedes dispatch. Authorized component faults become correlated
error replies with fixed diagnostics; malformed, unnegotiated or foreign-binding
requests are not reflected. Engine locks use immediate admission rather than an
unbounded wait queue. Terminal exec metadata is snapshotted synchronously, then
the execution lock is released before awaiting entropy, so health/cancel do not
wait behind that worker. Entropy and system-info reads share one owned blocking
permit; cancellation cannot free it before the actual worker finishes.

Replies are immutable, and grants activate only after a successful control flush.
Revocation interrupts an already-stalled plain reply as well as grant replies;
a cancelled partial frame cannot be followed by another frame on that writer.
The dispatcher itself does not own the request loop, bounded scheduling or
framing halves; `GuestControl` supplies that library composition.

`open_transfer` admits the exact epoch/binding/source grant before resolving its
sealed file. Collection lookup uses the original authorized request; exec lookup
selects the already-sealed stdout or stderr and checks its retained metadata.
No incoming binary path is accepted, no filesystem scan guesses an artifact, and
transfer/retry never reexecutes the command. The raw sealed reader lets the body
writer detect appended/corrupted bytes instead of silently truncating them.
The returned transfer owns its reader and transport; an ACK retires only that
grant, not sibling outputs or the whole retained result.

`shutdown` fences the epoch before cancelling/reaping executions and waiting for
capture/metadata workers. The coordinator must also join capture/transfer tasks,
close both control halves, drop the dispatcher and pass `GuestResources::quiesce`
before finishing the cleanup slot. A failed final barrier must leave that slot
closed; constructing a fresh budget would hide quarantined storage. Group/result
retirement, crash recovery and least-privilege installation are not implemented.
The Linux entrypoint already joins this shutdown path on SIGTERM/SIGINT; its
native signal/vsock execution remains unverified. Native service composition uses
pre-advertisement initialization and cannot infer readiness from protocol-only `bind`.

## Shared spool and actual I/O ownership

The dispatcher shares one default 256 MiB `spool::SpoolBudget` across exec and
collection engines and across replacement epochs. Standalone engines can accept
the same owner through `with_spool_budget`; independently constructed owners do
not establish a service-wide quota. Exec reserves its maximum combined capture
allowance before spawning, so quota rejection has no command side effect. A
collection reserves at most the remaining shared capacity before copying. Unused
capacity returns only after capture is sealed and its writers have finished.
This conservative admission can reject a command before its eventual output size
is known; it avoids starting a command whose capture budget cannot be guaranteed.

Retained metadata is path-only, not one open descriptor per artifact. Readers
reopen only the original regular, single-link inode with no-follow/nonblocking
flags and an actual read-only descriptor. `SpoolReader` and its async wrapper keep
the file, directory and reservation together; neither exposes an uncharged raw
descriptor. Releasing a catalog entry or dropping an engine cannot free a group's
charge while any sibling file, reader or I/O worker still owns it. Charges are
conservatively retained for the whole collection or stdout/stderr group until
its last owner closes, including readers from a previous generation.

Collection copies, capture write/sync/inline reads and binary source reads use
counted owned blocking jobs. Eleven shared I/O slots cover four executions with
two capture streams each, one collection and two transfers; excess work is
rejected, not queued without a bound. This pool is separate from the one shared
entropy/system-query slot. Cancelling a caller does not cancel an already-queued
or running filesystem syscall: the actual job retains its file and quota until
it completes. Discarded job results close their files before returning the worker
permit, so quiescence cannot race that cleanup. Copy cancellation is cooperative
between source opens/chunks, not a guarantee that a stalled syscall can be stopped.

Missing/substituted spool objects or failed removal permanently quarantine the
budget, preserve suspect private spool directories and make quiescence fail.
New captures then fail closed instead of recycling uncertain capacity. Inline-file
cleanup failure also prevents quota sealing from reporting clean completion.
There is no recovery scanner or durable quota reconstruction after a process crash yet.
Legacy `bind`, source-open/metadata checks and final unlink/drop still include
synchronous filesystem calls; full filesystem-latency and installed shutdown
policy remain composition work. Guest retirement does not define host artifact retention.

## Unix execution engine

`exec::Executor` implements the process lifecycle used by the guest library
dispatcher. It binds explicitly to one VM and driver generation. Every start,
status, cancel, wait, output read, and release requires a ready `Session`, the
appropriate negotiated capability, and matching request correlation. Completion
snapshots retain VM ID, generation, and operation ID; they are not wire envelopes.
The frozen `ExecResult` payload and error codes remain unchanged.

`Executor::handle` dispatches `exec.start`, `exec.status`, and `exec.cancel` into
schema-validated response/error envelopes. Request ID, method, VM, generation and
operation correlation are preserved. Malformed, unnegotiated, unsupported-capability,
or foreign-binding requests return a protocol error before execution admission;
they are not reflected as authorized wire replies. Bound execution/admission errors
return correlated `kind: error` replies without echoing argv, cwd, or environment.
Timeout/output-limit errors retain the terminal `ExecResult` in `error.details.result`.
A normal nonzero command exit instead returns a response with `state: failed`.
Cancellation acknowledges intent, not exit; cleanup faults remain error replies.

This dispatcher does not negotiate a connection, authenticate a peer, run a
listener, advertise implemented capabilities, or deliver a message. The caller
still owns framing and write deadlines. Artifact-mode output names a retained
local spool, not a completed binary transfer or host artifact publication.

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

Capture also hashes the retained bytes incrementally through the existing 8 KiB
buffer. After file flush/sync, artifact-mode output retains its original SHA-256.
`Executor::output_artifact` returns local `ArtifactInfo` under the same ready-session,
capability, VM/generation, and operation checks as `exec.status`. Stdout and stderr
have independent IDs, sizes, and digests; running output has no descriptor, and
inline/empty/disabled output returns none. Failed, timed-out, cancelled, or
output-limited executions may retain diagnostic output, without changing their
terminal outcome. Overflow metadata describes only the retained prefix.

This metadata does not change the frozen `OutputReference` or control response,
establish a stream/grant, or prove transport or host publication. It is retained
from capture, not recomputed from a later spool read. Corrupting or removing a
local file cannot redefine its original digest; a future receiver must verify the
actual transferred bytes against it. Identical retained replays preserve metadata;
internal release retires it while already-open bounded readers remain caller-owned.

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
bounded-size queries run under the dispatcher's shared blocking worker permit.
The service still needs a complete filesystem-worker/shutdown policy; byte bounds
do not establish filesystem latency bounds.

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
collection and clean up partial spools. Dropping the collection future asks its
owned copy worker to cancel; partial output and quota remain owned until the
actual worker finishes, and uncertain removal quarantines the shared budget.
Size/timestamp checks detect observed mutations, not
an atomic filesystem snapshot of concurrently written sources. The SHA-256 and
declared size describe the copied bytes, not a later read of the source path.

Retained identical replays reuse their original artifacts even if sources change;
conflicting inputs are rejected. Readers are read-only and capped at the sealed
byte count. Retaining a sealed artifact does not keep its file descriptor open.
Internal `release` retires a collection after consumption, reclaiming catalog
retention capacity; its bytes remain charged while an already-open reader or
worker owns the group. The
future transport must bound reader lifetimes and concurrency. There is no durable
guest journal, release tombstone, installed crash-spool recovery, or host DB commit.

`ArtifactInfo` is deliberately **not** a wire `artifactDescriptor`: it has no
`stream_id` because no binary channel has been established. The collector alone
does not implement an `artifact.collect` RPC response or transfer protocol; the
dispatcher/grant layer binds its descriptors and sources to separate binary
streams. The host must verify streamed bytes before durable artifact publication.
Frozen schemas remain unchanged; local descriptors are not evidence of completed
transfers.

## Binary framing library

The accepted [binary contract](../../docs/proposals/GUEST_BINARY_STREAMS_V1.md)
has an independent grammar and golden header examples in
[`schemas/guest-binary/v1.schema.json`](../../schemas/guest-binary/v1.schema.json).
[`schemas/guest-bridge/v1.schema.json`](../../schemas/guest-bridge/v1.schema.json)
separately defines the future private driver bridge opening. Neither changes
the frozen control schemas. JSON Schema does not enforce raw duplicate keys,
UTF-8 byte limits, authentication, or runtime admission by itself.

`binary` provides typed open/ready/committed/error headers. Decoding requires
1..4096 encoded bytes, strict schema validation, and direct typed deserialization
of raw keys so duplicate, escaped-duplicate, and nested duplicate fields cannot
be collapsed into a map. Error-message UTF-8 bytes are bounded separately.
Encoding uses a fixed 4096-byte buffer and validates before transport output.

`binary_io::accept_preface` recognizes only `GAB1` or a valid control length.
Control results retain the original four-byte prefix for the control decoder;
unknown magic never falls back to a raw/control stream. Header reads/writes take
the caller's original absolute open/ACK deadline, and writes include a successful
flush. Pass owned transports: an opening/send failure or cancellation drops them
rather than returning a partially consumed connection for retry.

`BodyReader` and `write_body` use chunks up to 8 KiB, a 256 MiB hard ceiling, exact
declared size, capture-time SHA-256, and an explicit end marker without waiting
for socket EOF. Body progress cannot extend its one absolute phase deadline.
A polled/cancelled or failed body read is permanently fenced. Sending rejects
short, overlong, or changed sealed sources before emitting end. Verified receive
chunks belong in a private stage; neither `finish` nor successful sending means
durable host publication or a committed ACK.

The framing layer alone does not authenticate peers, authorize operations or
publish host artifacts. The session/grant layer below adds logical authorization,
not native Linux listening, driver bridging, daemon sessions or host persistence.

## Session-scoped binary grants

`grants::GrantRegistry` requires the guest epoch issued by successful, flushed
wire negotiation. Only one registry may be constructed in an epoch; workers clone
its shared state instead of creating independent quotas. Registry keys bind the
epoch, VM, generation, operation, artifact and collection/stdout/stderr source.
Collection opens additionally require the exact published `stream_id`.

`prepare_collection` captures/replays through the authorized collector;
`prepare_exec_status` reads one authoritative execution response and grants only
its terminal artifact references, including diagnostic error details. Running,
inline, start and cancel replies cannot create output grants. Exec control results
remain unchanged; ready metadata retains the original sealed digest. Handles use
32 OS CSPRNG bytes, never ULIDs or a fallback PRNG. Entropy work runs off the async
control executor with an owned worker permit retained across cancellation. A
standalone registry owns its own slot; the dispatcher instead shares one slot
with system queries through `GuestResources`, including replacement epochs.
Capture/copy/source-read I/O uses the separate shared spool worker pool above;
complete process-wide filesystem latency and cleanup policy remain service work.

An immutable `PreparedReply` owns unpublished reservations. Only its successful
control-frame flush activates them. Dropping an unwritten reply rolls back its
reservations but preserves sealed captures; failed/cancelled writes revoke the
epoch, including older grants. Expired or retired grants need fresh authorized
metadata and a successful flush; replay cannot extend an existing grant's expiry.
Metadata cannot replace an expired active reader
until its owned lease is closed.

One grant has at most one reader, and a registry permits two active transfers.
Its descriptor count is bounded to 4,160, derived from the current default engine
limits; this count is separate from the shared 256 MiB `SpoolBudget`. The
native listener's separate pending-open bound must be retained by the composed
service. A `TransferLease::serve` owns its binary transport and a new
sealed reader supplied by the trusted source provider. It sends fixed-buffer
bytes under the original open deadline and absolute 30-second body/ACK budgets,
each limited by the outer deadline and grant expiry. Revocation, timeout, cancel,
body mismatch and bad/missing ACK close owned I/O and return the lease for bounded
byte-zero retry without executing a command again.

Only a fully matching committed ACK retires the corresponding grant. It never
calls whole-job/collection release or removes sibling spools. `CompletedGrant`
records receipt of a correlated ACK, not peer authentication or independent
verification of a host filesystem. The implemented native acceptor and private
bridge require native host-CID/authentication acceptance before installing or
advertising the complete guest service. Group/result retirement remains pending;
host publication is implemented separately and tested with a real Rust peer.

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
Async framing tests include real Unix sockets, partial-read/write cancellation,
retained deadlines, malformed input, EOF, and stalled writes. These socket tests
are not native virtio-vsock acceptance.
Negotiation tests include a real Unix-socket hello/health round trip, both hello
orderings, capability intersection, identity/version failures, malformed/EOF
frames, silence, and cancellation/failure/deadline during the final buffered flush.
Guest-owner checks cover host-first adoption/order, escaped duplicate binding
keys, invalid first messages, first-ACK flush failure, cancelled bootstrap,
EOF/deadline/revocation fencing, abandoned cleanup, and identical-binding
replacement. A real control EOF test revokes a published grant and joins its
owned binary I/O before replacement; a late old-epoch callback cannot fence it.
Exec dispatch tests cover real command completion, correlated failures, cancellation,
replay/conflicting inputs, admission fences, bounded/spilled output, and a real Unix
frame round trip with health while an execution is running. Its test-only request
loop does not establish a production dispatcher service or native vsock acceptance.
Exec metadata tests cover independent stdout/stderr, non-UTF-8 and 2 MiB output,
session/capability/binding rejection, pre-seal and non-artifact output, original
digests after spool corruption/removal, overflow prefixes, timeout/cancellation,
replay, and release with an already-open reader. They execute real Unix subprocesses
and files, not a native guest binary transfer.
Binary tests use real Unix sockets with independent header/body fixtures for
demux, fragmented/coalesced opening, chunk/end/digest failures, raw empty/non-UTF-8
data, cancellation, retained deadlines, source corruption, and backpressured
buffered flushes. Fixture ACKs are not durable publication or native acceptance.
Grant checks exercise real Unix control and binary sockets, post-flush admission,
failed/cancelled publication, exact epoch/binding/source checks, terminal spill and
error diagnostics, reader/quota/expiry ownership, correlated ACK retirement,
byte-zero retries, binary-only cancellation and revocation during stalled I/O.
Control health remains responsive in the stalled-transfer fixture; this is not a
native vsock latency or process-wide service quota measurement.
Dispatcher checks use actual Unix control/binary sockets, subprocesses and sealed
files for inline/spilled/timeout results, lossless collection, independent sibling
ACKs and byte-zero reuse. They reproduce execution-lock starvation behind queued
entropy, verify cancellation keeps the shared worker reserved, and interrupt a
revoked stalled reply. Shutdown fences new work and reaps a real running child.
Control EOF interrupts an owned, backpressured sealed-file transfer, and the
fixture joins it before allowing an identical-binding replacement control owner.
Shared-spool checks combine real exec/collection admission, cross-generation
open readers and cancelled queued read/write workers. A substituted spool object
is preserved, cannot recycle quota and fails the post-drop resource barrier;
the control slot remains closed on that failure.
These checks do not establish the native coordinator, installed service or host
SQLite publication.

The optional [real Rust-to-Dart checks](../../docs/GUEST_ARTIFACT_PUBLICATION.md#real-rust-guest-to-dart-host)
build `examples/host_publication_fixture.rs` and set `GAOVM_GUEST_FIXTURE` for the
host tests. They run the actual coordinator/engines/grants over a test-only private
Unix adapter, verify SQLite commit before ACK and actual grant retirement without
losing a sibling, download exact public bytes, and join a running Unix execution
before unknown recovery without replay. The normal CI Rust job runs all three;
they remain distinct from native CID, GaoOS installation and full TestRun E2E.

## Remaining package and MVP work

- Native Linux/GaoOS virtio-vsock listener and host-CID acceptance beyond the
  implemented transport component and cross-compilation checks.
- Installed acceptance for the implemented coordinator, executable, signal
  shutdown and original-owner cleanup; least-privilege image/service integration,
  group/result retirement and crash-spool recovery are still required.
- Native acceptance of the implemented binary acceptor/demux and sealed-source
  provider with the
  [accepted binary wire contract](../../docs/proposals/GUEST_BINARY_STREAMS_V1.md)
  and [driver bridge contract](../../docs/proposals/GUEST_DRIVER_BRIDGE_V1.md).
  Acceptance on 2026-10-10 does not establish implementation or interoperability.
  Do not send base64 artifact bodies in control messages or silently treat file
  references as completed transfers.
- Native validation of the implemented driver-owned bridge, per-VM daemon guest
  sessions/readiness, durable operations, public API/CLI and TestRun orchestration.
- Real GaoOS and Apple Silicon VZ end-to-end validation and release gates.
