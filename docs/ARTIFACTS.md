# Artifact storage and public API

This implements the artifact catalog, managed payload store, and frozen read API
for the M6.7 / PR-025 work package. It supports PRD API-001/002/004/008/009,
GST-006, TST-006/007/008, and retention in section 11. It does not by itself
complete guest output spill, automatic collection, TestRun orchestration, or the
real GaoOS acceptance scenarios AC-06/07.

The TestRun host collection and completion boundaries are documented separately
in [TEST_RUNS.md](TEST_RUNS.md).

## Public reads

- `GET /v1/vms/{vm_id}/artifacts`
- `GET /v1/test-runs/{test_run_id}/artifacts`
- `GET /v1/artifacts/{artifact_id}`

List responses contain exactly `items` and nullable `next_cursor`, with frozen
Artifact DTOs. The default page size is 50, with a range of 1–200. Opaque cursors
are limited to 512 characters, bound to the VM or TestRun, and advance by stable
`(created_at, id)` keyset order. Neither artifact route accepts a request body;
lists accept only one each of `cursor` and `limit`, and downloads accept no query.
Artifact lists remain available for retained VM tombstones; normal VM GET still
hides deleted VMs.

Downloads stream `application/octet-stream`, not JSON or base64 payloads, with an
exact `Content-Length`, a server-generated `X-Request-ID`, and
`Digest: sha-256=<base64 of the 32 digest bytes>`. The Digest encoding follows
[RFC 5843 section 2.2](https://www.rfc-editor.org/rfc/rfc5843.html#section-2.2),
as required by the existing frozen header name. The metadata DTO keeps its
`sha256:<hex>` digest and original `content_type`; its `download_url` is stable.

Missing owners and artifact IDs return typed 404 problems. Invalid IDs, pagination,
query keys and bodies return `INVALID_REQUEST` / 400. An existing artifact whose
payload is unbacked, unavailable, linked, or fails integrity checks returns
`INTERNAL_ERROR` / 500 before streaming; problem details do not disclose host paths.
Corrupt stored metadata also returns a server error, not a client validation error.
The handler calls only the application service, never a driver or SQLite directly.
Once streaming headers have been sent, a later integrity, file or transport failure
aborts the stream; it cannot be replaced with a JSON problem. Clients should
validate the advertised length and digest before treating a download as complete.

## SDK, CLI and desktop downloads

The shared Dart client provides two distinct reads through the same frozen
`GET /v1/artifacts/{artifact_id}` route:

- `readArtifact`: a complete immutable in-memory preview, limited to 64 KiB by
  default. This remains the Flutter preview boundary.
- `downloadArtifact`: streamed disk I/O in a new private child of an existing,
  caller-selected directory. The default admission budget is 256 MiB, matching
  the current managed store maximum; the SDK caller can choose a smaller budget.

Both require the canonical URL for the selected ID, HTTP 200, octet-stream type,
identity/no content encoding, exact Content-Length, one valid request ID, matching
Digest, and matching actual length/SHA-256. They do not follow redirects, send
Range requests, retry automatically, execute content, or access daemon files.
The disk reader hashes incrementally and awaits each file write before accepting
another chunk. It does not enlarge the preview budget or buffer the complete file.

Disk bytes stay in an owned staging directory until verification, file flush and
close finish. The file is then renamed to its artifact ID within that directory;
only the successful result exposes its path. The private child avoids overwriting
existing caller files. Ordinary failures close the connection/file and remove this
download's staging before returning. Cleanup I/O failures are surfaced, not called
successful downloads. Abrupt host/process crashes can leave staging; this client
does not infer orphan ownership or run garbage collection. File flush plus rename
is not a claim of parent-directory fsync or power-loss durability. Successful files
belong to the caller, outside the managed daemon artifact store.

The CLI workflow is explicit:

```sh
gaovm --socket-path /absolute/state/run/api.sock test download TR_ID ART_ID \
  --output-dir /absolute/existing/output --timeout-seconds 120 --json
```

Use server-generated TestRun and Artifact IDs. The CLI walks that TestRun's public
artifact pages, validates each complete page and its owner/ID/URL associations, then
downloads only the selected artifact. There is no invented artifact-metadata GET
or all-artifact list. Successful JSON contains `artifact`, `request_id`,
`output_path`, and `verified: true`; verification describes that byte read, not
Guest execution. Missing artifacts return `1` / `ARTIFACT_NOT_FOUND`; local output
errors return `1` / `CLI_LOCAL_IO`, and oversized metadata returns `1` /
`CLI_ARTIFACT_LIMIT`. Protocol, transport, structured Problem and deadline exits
retain their existing meanings. SIGINT/SIGTERM return `130`/`143` after releasing
the owned read, without cancelling a TestRun/Operation or changing VM state.

One local deadline covers the metadata walk and byte transfer; progress cannot
extend it. Cancellation/deadline closes HTTP and fences late publication, then
awaits file close/cleanup. In-flight OS filesystem calls cannot themselves be
aborted, so local cleanup can add latency.

The desktop TestRun pane has a separate Download artifact action. It selects an
existing directory through the native `file_selector` chooser, then uses the same
SDK disk reader with a 256 MiB admission limit and a 30-second transfer deadline.
Time spent awaiting a directory choice is not a network transfer. Verified output
shows its completed local path and payload request ID; it is never automatically
executed or opened. Cancel download releases only the local transfer and awaits
partial-file cleanup. Selection changes, catalog reload, navigation, reconnect,
and close cancel incomplete output; late chooser results cannot start new reads.
Completed files remain caller-owned even when their local UI receipt is cleared.
The 64 KiB preview remains independent. See the
[desktop client boundary](../clients/gaovm_ui/README.md#testrun-and-artifacts)
for file access and native gates.

Integration checks use real Unix-socket HTTP and files, including progressive
writes before withheld EOF, altered/truncated payloads, malformed headers/pages,
deadline/cancellation EOF, preservation of existing files, the SQLite-backed
artifact service, and source CLI SIGINT/SIGTERM:

```sh
cd libs/gaovm_api_client
mise exec dart@3.9 -- dart test
cd ../../clients/gaovm_cli
mise exec dart@3.9 -- dart test test/public_api_cli_test.dart test/test_run_cli_test.dart
cd ../gaovm_ui
flutter test --no-pub
```

These are client/public-artifact checks, not installed-daemon, native Guest binary
transport, native directory-chooser/sandbox, full GaoOS TestRun, or packaging acceptance.

## Ownership and publication

SQLite owns artifact metadata, VM/operation/TestRun associations, and retention.
Schema v10 adds `artifact_payloads`: a version-1 attestation is written only after
the store has published sealed bytes. Schema v11 adds owner/time/ID indexes for
bounded list queries without changing the published v10 migration. Existing
legacy metadata and TestRun references are preserved, not silently adopted.

Managed payloads live under `<state>/artifacts/<artifact-id>/`, independently of
the VM bundle. Each directory has a matching `owner.json`, a diagnostic
`manifest.json`, and `payload`. Manifests are ownership/integrity evidence, not
an independently writable catalog. The root is private (`0700`), and sealed
files are read-only (`0400`) and synced through held descriptors.

Internal publication requires a per-artifact output budget, capped at 256 MiB.
It streams and hashes bytes with bounded reads/writes, validates any advertised
size/hash, stages and syncs owned files, then exclusively renames the directory
before committing metadata, managed ownership, TestRun references, durable event,
and outbox in one transaction. Commit failure compensates only proven owned files.
Caller-owned transactions are rejected before consuming input. The store never
treats a diagnostic observer failure after commit as a failed publication.

Recovery skips live writers using per-artifact locks. It removes only proven,
unregistered publication/staging data, resumes interrupted cleanup, and preserves
unknown, linked, or malformed content. Registered damaged payloads are reported,
not deleted. Cleanup itself has durable events. Download preflight verifies size,
mode, manifest identity and SHA-256; lazy streams revalidate their own held inode
and close it on completion or cancellation. An unconsumed response holds no file
descriptor. Root and pathname replacement cannot redirect reads to another inode.

## VM deletion and retention

VM cleanup permits independently managed artifacts while preserving their rows,
TestRun references and payloads. Legacy/unbacked references still block cleanup,
and unknown bundle `artifacts/` content is never erased. This supports deleting
temporary VMs without deleting their diagnostic results.

Publication can persist a supplied `retention_until`. Outcome-based default
retention (7 days for successful ephemeral TestRuns, 30 days for failures) and
retention-aware garbage collection still belong to the TestRun/retention workflow;
they are not inferred or implemented by these GET routes. There is no new public
artifact upload or delete endpoint.

## Daemon composition and evidence

The daemon owns the private artifact root, reconciles it before opening the public
listener, registers all three read routes, and closes active HTTP streams before
closing its database and filesystem roots. Startup readiness reports an unhealthy
artifact store when recovery finds damaged registered payloads or retained
unidentifiable entries. No driver census, authentication or startup safety gate
is bypassed.

Relevant tests use real SQLite, owned filesystem descriptors, process exits and
HTTP over Unix sockets:

```sh
cd daemon/gaovmd
mise exec dart@3.9 -- dart test test/artifact_repository_test.dart \
  test/artifact_application_service_test.dart test/artifact_api_handlers_test.dart \
  test/sqlite_database_test.dart test/sqlite_vm_managed_file_effect_adapter_test.dart
```

They cover immutable replay, rollback/outbox consistency, migrations, streaming
budgets, integrity and symlink rejection, crash checkpoints, interrupted cleanup,
live-writer isolation, cursor isolation, typed errors, and downloads after actual
bundle cleanup, VM tombstoning and catalog reopen. Daemon tests additionally cover
linked-root rejection. These checks do not establish installed-daemon startup,
Apple Silicon VZ, native guest binary transport, automatic artifact collection,
TestRun execution, or full GaoOS E2E completion.
