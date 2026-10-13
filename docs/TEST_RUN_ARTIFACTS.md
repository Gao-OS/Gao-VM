# Durable TestRun artifact collection

This is the host composition for development-plan M6.7 and PRD `TST-006`:
driver/serial logs, every available step's stdout/stderr, the result report and
system information. It follows [ordered execution](TEST_RUN_STEPS.md) and
precedes the existing cleanup worker. Unix/SQLite/file fixtures are not native
vsock, installed-service, real GaoOS, or M6/M8 release acceptance.

## Original sources and publication

The collection worker reserves driver, serial and result identities with its
immutable execution snapshot. Migration 20 adds immutable per-step output
reservations, a one-time system-info checkpoint and diagnostic RPC attempts;
migrations 1–19 are unchanged.

Inline outputs are exact UTF-8 with the TestRun application's 64 KiB threshold.
They become managed stdout/stderr artifacts, including empty outputs, under
reserved host IDs. Their source size and truncation flag remain in the report.
Invalid UTF-8 is already a binary spill at the guest, never a lossy conversion.
Existing spill artifacts are verified and reused, not recopied or re-executed:
VM, TestRun, original child operation, kind, size and managed payload must match.
Known historical inline results can be collected without manufacturing an exec
binding. Unavailable or invalid sources are reported explicitly; an unverified
artifact reference is not emitted as a published result.

Inline publication commits its per-step reference with the artifact, TestRun
association, event and outbox. Restart reuses these reserved identities and
verified bytes. All published step payloads are verified again after the final
report publication, before collection can attest completion. Damage keeps
collection unfinished rather than allowing cleanup to report success.

The `gaovm.test-result.v1` JSON artifact contains `execution`, `step_artifacts`,
`system_info` and the existing log `collection` entries. Its execution projection
references host output artifacts instead of duplicating inline payloads; SQLite
retains the original step result unchanged. This keeps the report bounded while
preserving exit status, timing and failure diagnostics. No public DTO, artifact
kind or frozen API/protocol field was added.

When a TestRun has an original VM-start generation, the report retains that
generation even if the runtime catalog now describes a replacement. Log entries
retain their own generation tags; recovery does not relabel original execution.

## System information and retirement

The worker calls `system.info` only through the already authenticated original
VM generation, under the parent TestRun operation. The original successful VM
start, accepted/applied intent and spec checkpoint must match at authorization
and receipt commit. It does not create a guest exec or connect to a replacement
controller. Parent cancellation still permits bounded diagnostic collection;
it cannot authorize another step.

A diagnostic start marker commits before RPC bytes. One original local service
coalesces duplicates under its first monotonic deadline. Another owner cannot
replay the method or renew that deadline. Validated system info commits as a
one-shot snapshot; unavailable information is recorded explicitly and does not
prevent the existing failure/cancellation cleanup policy from running.

Startup order is actual previous-owner retirement and complete native driver
census, guest-job recovery, step recovery, then diagnostic recovery, before any
current runtime, loop or public listener activates. An unfinished foreign
diagnostic blocks normal collection until this positive barrier settles it.
The final system-info checkpoint rechecks the diagnostic ledger in its own
transaction, so a foreign claim that wins after the initial lookup cannot be
mistaken for unavailable information and permit cleanup while its RPC is live.
Recovery preserves known original info or records unknown/not-started evidence;
it never resolves a connection or issues fresh guest IO. A missing local worker
is not retirement evidence. Shutdown fences new IO and joins original RPC,
publication and recovery work before releasing shared storage.

## Generic guest collection

`HostGuestArtifactService.captureCollection` implements the frozen
`artifact.collect` core method for explicitly supplied guest paths. Input is
validated before a start marker, and the complete validated descriptor group is
durable before binary receive. The binary header must exactly match all six
original descriptor fields, including stream handle, digest and MIME. Publication
uses the [shared commit-before-ACK boundary](GUEST_ARTIFACT_PUBLICATION.md).
Partial sibling mappings stay private; archival results expose only host Artifact
DTOs. Byte-zero transfer retry uses the same receipt, epoch, deadline and host ID,
never another collection RPC. Unrecognized guest kind labels map to public `file`
while their original labels remain in the private receipt/mapping.

The frozen TestRun request has no arbitrary guest-file collection paths. Automatic
TestRun collection therefore uses its existing step outputs and system info; it
does not invent guest filenames or add a configuration/public passthrough.

## Verification boundary

Terminal TestRun completion applies the accepted [artifact retention policy](ARTIFACTS.md#vm-deletion-and-retention)
in its SQLite transaction: success with temporary VM deletion gets seven days,
failure/cancellation/retention gets thirty, all anchored at `completed_at`.
Sealed publication receipts are not rewritten. Expiry does not unpin TestRun
lists, execution results or collection journals, and public GET never initiates
deletion. The daemon's bounded retention loop deletes only proven, expired,
unreferenced managed bytes and is drained before catalog/root shutdown.

```sh
cd daemon/gaovmd
mise exec dart@3.9.0 -- dart test \
  test/host_guest_artifacts_test.dart test/host_guest_session_test.dart \
  test/sqlite_database_test.dart test/test_run_collection_worker_test.dart
```

These checks cover real private Unix sockets, SQLite rollback/reopen, durable
mapping before ACK, public HTTP artifact download, exact metadata and bytes,
original-owner shutdown/recovery, sibling completion, per-step publication,
real process exits at publication/commit, and post-report payload damage.
The optional [real Rust peer checks](GUEST_ARTIFACT_PUBLICATION.md#real-rust-guest-to-dart-host)
add actual guest grants, collection bytes and ordinary Unix execution shutdown;
they do not exercise the full native TestRun composition.
Actual native process retirement and escaped-descendant
containment, installed daemon startup, least-privilege GaoOS service
integration and real-image success/failure/cancel/restart E2E remain separate gates.
