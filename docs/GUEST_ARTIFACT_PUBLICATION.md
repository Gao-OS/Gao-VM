# Host guest-output publication boundary

`HostGuestArtifactService` composes the accepted
[binary contract](proposals/GUEST_BINARY_STREAMS_V1.md), original authenticated
guest connection, SQLite and the managed artifact store for **exec stdout/stderr
and explicitly requested guest collections**.
This is library coverage for M6 / PRD GST-006, not installed-daemon, complete
TestRun or native GaoOS acceptance. The
[guest-exec worker and public route](GUEST_EXEC_DURABILITY.md) now use this boundary
in daemon composition; native capability advertisement and installed acceptance
remain gated. No frozen public, driver or guest
control schema changes are introduced.

Migration 20 adds diagnostic one-shot markers and collection receipt uniqueness.
`artifact.collect` and `system.info` commit authorization before guest IO; another
owner cannot replay them. Collection binary metadata must exactly equal its
durable control descriptor, unlike exec metadata supplied by the binary lookup.
Unrecognized guest kinds map to public `file`, preserving the original private
label. Complete collection projection requires every sibling mapping and exposes
only host Artifact DTOs. See [TestRun collection](TEST_RUN_ARTIFACTS.md) for the
system-info checkpoint, per-step outputs and positive retirement recovery.

## Original attempt and terminal receipt

The worker must capture the original ready `GuestControlConnection` before
`GuestExecApplicationService.beginAttempt`, passing its local `epochId` as
`controlEpochId` alongside the attempt ID and current-owner predicate. Migration
18 adds this immutable start-marker binding and guest receipt/mapping tables;
migrations 1–17 are unchanged. A previously started v17 job has no recorded epoch:
it stays uncertain and cannot be rebound to a fresh connection or authorize guest
work. An unstarted historical job can still receive its first explicit claim.
The local epoch ID is ownership evidence, not authentication or a wire secret.
New exec admission still requires readiness. After the start marker, a degraded
health reply does not revoke the original authenticated connection's ownership:
status capture and output receive require that epoch to remain active, not healthy.
Control closure or loss of the original authenticated driver generation fences
publication, including before its asynchronous close reader has settled.

One service owns one original exec attempt. `captureExecStatus` sends only
`exec.status`, never `exec.start`. It verifies the running job's VM/generation,
attempt, original control epoch and durable request/capture bound. Only a
validated terminal reply creates a receipt. The complete immutable result,
including **both** sibling output references, commits before any binary receive
can acknowledge guest retirement. Refresh cannot change that result, replace the
connection or extend the service's original monotonic deadline.

`readExecSnapshot` is an internal recovery read that retains private guest IDs;
it is not a public Operation result. `readExecResult` returns null while any
artifact output lacks a committed mapping, otherwise rewrites every artifact
reference to a host-generated public ID. Inline fields remain unchanged. These
reads do not complete an Operation, confirm process-group cleanup or authorize a
replayed command. Recovery can inspect known outcomes without a live guest.

## Bounded receive and commit

Inject a single process-owned `GuestArtifactBudget` into all attempt services.
The caller must choose its global transfer/byte policy explicitly. The library
limits a VM to two transfers, one active reader per sealed source, and reserves
the requested maximum bytes before bridge opening; excess admission fails without
an unbounded queue. The hard per-artifact maximum stays 256 MiB and does not
enlarge the guest's default capture limit or choose a host retention policy.

`receiveOutput` opens through the control connection's **original** driver
provider. The runtime provider uses `GuestBridgeClient.openAndJoin`: failure joins
its actual original opening/status worker and descriptor cleanup before releasing
composed admission. Driver UID/token admission and guest native peer admission
are separate trust boundaries; a stream handle is not authentication.

The host sends `GAB1` and a length-prefixed strict `gaovm.binary.v1` open header.
The ready/error header is at most 4096 encoded bytes. The shared strict JSON
decoder rejects recursively duplicated decoded keys, malformed UTF-8/Unicode and
fractional raw numbers that would otherwise round into integers. Ready must match
VM/generation/operation, private artifact ID, stdout/stderr selector and original
status size; binary-side metadata supplies MIME, sealed digest and stream handle.
Authorized pre-body errors stay typed and do not close the healthy control epoch.

Body reads are serialized, at most 8192 bytes, and fed into the managed store's
streaming writer/hash. A zero prefix ends the body without waiting for EOF;
trailers are neither parsed nor published. Early end, overlong/truncated chunks,
checksum mismatch and ownership loss cannot publish partial bytes. Opening/body/
commit-ACK phases use original 5/30/30-second absolute limits, capped by the
attempt deadline. Chunk progress or metadata refresh cannot reset those budgets.

After exact size/digest verification, the existing managed store seals and fsyncs
its owned private stage and atomically publishes a host-generated `art_` identity.
Its `commitReferences` callback writes only internal SQL references in the same
transaction as the artifact, managed-payload attestation, TestRun reference if
supplied, event and outbox. It rechecks the original live epoch/job/generation
before commit. The durable mapping includes VM/generation/operation, guest ID,
source selector and immutable metadata; guest IDs are not global public identities.
The previously committed complete terminal snapshot remains available throughout.

Only after this commit does the host write the correlated `committed` ACK using
the **guest** ID, current stream handle, exact size and digest. `acknowledged`
means the complete ACK was written locally, not that the guest observed it. Lost
ACK or control closure after commit returns the durable artifact with
`acknowledged: false`; it never rolls back committed bytes or re-executes a command.

A retry within the original epoch/deadline checks the durable mapping, rejects
changed metadata, and verifies the complete transfer again from byte zero. It
reuses the host artifact and emits no duplicate resource/event. It verifies the
original publication retention receipt but returns the current SQLite retention
deadline without rewriting the sealed manifest or restoring an obsolete policy.
Default retention anchors and GC remain a separate policy decision.

Closing a service aborts its sockets and joins actual publication/cleanup work
before returning transfer admission. Unconfirmed stage cleanup retains the byte
reservation in the shared budget and throws `ArtifactPublicationFailure` at the
close barrier. A new service must not replace that budget to hide unknown disk
ownership. Filesystem calls cannot themselves be aborted, so cleanup may outlast
the caller's network deadline. Crash reconciliation continues to use the existing
managed-store ownership proofs; this is not a new destructive cleanup policy.

## Verification and remaining work

From `daemon/gaovmd`:

```sh
mise exec dart@3.9.0 -- dart test \
  test/host_guest_artifacts_test.dart test/guest_bridge_client_test.dart \
  test/host_guest_session_test.dart test/guest_exec_application_service_test.dart \
  test/sqlite_database_test.dart test/artifact_application_service_test.dart \
  test/artifact_api_handlers_test.dart
```

Tests use authenticated real Unix sockets, real files and SQLite transactions /
catalog reopen. A separate connection observes the snapshot/mapping/resource at
ACK; the public Unix HTTP artifact route downloads committed host bytes after
guest control closure and rejects the private guest ID. The matrix includes
fragmented metadata, coalesced/full-size chunks, empty/non-UTF-8 bytes, strict
bindings/numbers, checksum/partial-body failures, publication rollback, epoch and
generation fences, ACK loss, idempotent replay, sibling reference completion,
two-VM private-ID reuse, responsive/degraded health, shared admission and cleanup
failure.

The worker/HTTP fixture matrix additionally covers known-result Operation
completion, cancellation during stalled status, the original committed deadline,
two-VM dispatch independence, original-owner recovery and corrupted output.
The [ordered TestRun coordinator](TEST_RUN_STEPS.md) uses the same worker and
associates child output artifacts with their parent run.

### Real Rust guest to Dart host

The optional cross-language checks start the real Rust `GuestAcceptor`,
dispatcher, execution/collection engines and grant registry through
`guest/gaovm_guestd/examples/host_publication_fixture.rs`. Its test-only private
Unix bridge verifies the peer UID and fixture token; it is not the shipped
`gaovm-guestd` transport or proof of native host CID.

From the repository root:

```sh
(cd guest/gaovm_guestd && cargo +1.96.1 build --locked --example host_publication_fixture)
export GAOVM_GUEST_FIXTURE="$PWD/guest/gaovm_guestd/target/debug/examples/host_publication_fixture"
(cd daemon/gaovmd && mise exec dart@3.9.0 -- dart test \
  test/host_guest_artifacts_test.dart --name 'real Rust guest' --concurrency=1)
```

Without the environment variable, these three checks are explicitly skipped;
a configured invalid executable fails instead. The normal CI Rust job builds the
example and sets this variable, so that gate cannot silently skip the real peer.
The checks cover non-UTF-8 spilled stdout and an independent stderr, a multichunk
collection with an empty sibling, complete durable host mappings observed through
a separate SQLite connection before ACK, and exact public HTTP downloads after
control closure. A new binary opening without refreshing metadata confirms that
the real Rust registry consumed the stdout ACK while stderr remains available.
Disconnect recovery joins the actual guest process and its ordinary Unix child
before settling the original host attempt as unknown, with no command replay.
This does not establish containment of escaped descendants or native driver
retirement. The public `acknowledged` flag still means local write completion,
not independently confirmed guest receipt on every production transfer.

The three real-peer checks have run successfully on Intel macOS and an isolated
Linux x86_64 container with Rust 1.96.1 / Dart 3.9.0. The fixture explicitly gives
its owned API socket parent mode `0700`; it does not rely on platform-specific
temporary-directory defaults or weaken the public server's permission check.
This is local/container evidence, not a completed GitHub Actions run.
The full daemon suite also passed as an unprivileged Linux test user on
2026-10-11: 1,339 passed and 50 platform-specific checks skipped. Linux component
success does not clear the Intel macOS installed-startup census gate.

Still required: native lifecycle and restart acceptance with positive original-owner
retirement, end-to-end guest group/result retirement and crash recovery, GaoOS
least-privilege image/service integration, and native Apple Silicon VZ/GaoOS
exec/timeout/cancel/spill/restart/public-download acceptance. Fixture tests do not
prove native CID, installed daemon startup or release gates.
