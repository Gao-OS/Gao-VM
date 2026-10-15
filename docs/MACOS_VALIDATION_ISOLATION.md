# Maintenance validation request/catalog isolation

The internal candidate-only validation entry composes these components for the
accepted [cold upgrade workflow](proposals/MACOS_UPGRADE_ROLLBACK.md). It is not
normal activation or an upgrade commit. Ordinary daemon admission still rejects
the persistent startup fence; ordinary startup/worker policy is unchanged.

The full candidate-validation command passes against private populated schema-21
and pre-catalog legacy fixtures, including retained post-validation state and
its sealed completion record. Native identity/signature/service/ARM64 boundaries
remain fixtures; this is not installed native acceptance or a complete upgrade.
Earlier timed-out inputs remain retained. See the current
[acceptance ledger](MVP_ACCEPTANCE.md).

## HTTP request restriction

[`PublicApiServer`](../daemon/gaovmd/lib/src/public_api_server.dart) accepts the
immutable internal `PublicApiAccess.maintenanceValidation` restriction. Default
`normal` access retains the ordinary public API behavior. Restricted access
permits only empty-body GETs on these reviewed route templates:

```text
/v1/openapi.json
/v1/system/live
/v1/system/ready
/v1/system/capabilities
/v1/system/doctor
/v1/vms
/v1/vms/{vm_id}
/v1/vms/{vm_id}/logs
/v1/vms/{vm_id}/artifacts
/v1/images
/v1/operations
/v1/operations/{operation_id}
/v1/test-runs/{test_run_id}
/v1/test-runs/{test_run_id}/artifacts
/v1/artifacts/{artifact_id}
```

Routing uses the actual winning template, not a resource-prefix pattern. A newly
registered, more-specific GET does not inherit permission from an approved
resource template. The current image-item route is DELETE-only and has no
preapproved GET. Unknown routes, events, driver/display observations, waits and
all non-GET methods are refused. Non-empty Content-Length and any transfer
encoding are refused before body parsing or application-handler invocation.
Queries and IDs on admitted routes still undergo their ordinary handler checks.

Policy refusal is a correlated `403` problem using the existing `INVALID_REQUEST` code,
type `maintenance-validation-read-only`, and `retryable: false`. No frozen public
field or error enum was added. HEAD receives headers without a response body.
The owned socket writer sends the refusal without draining an attacker-controlled
request body, then closes; shutdown can cancel that same tracked writer. This
avoids Dart 3.9's implicit request-body drain before ordinary response headers.

Liveness retains its normal meaning. Ordinary readiness always returns `503`,
`ready: false`, and `checks.maintenance_validation: read_only`, even when the
injected health service would report healthy. A restricted listener is not a
normally activated daemon. There is no mutable switch to normal access; closing
and restarting the same listener does not lift the restriction.

Restricted shutdown retains both HTTP request futures and the original handler
and health futures, including work that outlives its HTTP observation deadline.
Drain runs outside the socket observation gate, so a borrowed diagnostic can
finish its own path observation. Restart is refused while the old restricted
requests are draining. Normal access does not acquire this additional drain.

## Native read-only catalog

[`GaoVmDatabase.openReadOnly`](../daemon/gaovmd/lib/src/sqlite_database.dart)
opens an existing filesystem catalog with SQLite's native `READONLY` flag. It
requires the current schema, every core table and the exact complete migration
ledger; it does not create, initialize, migrate or repair a catalog. Missing,
old, newer or incomplete input is refused. Empty/in-memory inputs are not
accepted, and SQLite receives an absolute filesystem path rather than a URI.

`transaction` refuses before invoking its callback. Main-catalog writes attempted
through `read` are rejected by SQLite itself, including after `query_only` is
turned off. The immutable `isReadOnly` property describes that connection only;
ordinary writable opens and their migration/transaction behavior are unchanged.

This is not a filesystem sandbox or a backup. SQLite may need sidecar bookkeeping;
request logging may append a diagnostic log if one is supplied. The caller must
keep the actual state kernel lease and bound directories alive, avoid additional
writable connections, and account separately for all non-catalog state/external
files. Neither this factory nor the HTTP restriction grants that lease or permits
starting a process through a maintenance fence.

## Candidate-only controlled validation

After completed cold publication, the installed candidate's `gaovmd` accepts
`--validate-upgrade` with explicit app/state/work/inspection paths, bundle/Team
IDs, old/new versions and expected source catalog schema. See the
[cold maintenance instructions](MACOS_COLD_MAINTENANCE.md#candidate-only-validation).
There is no fixture/bypass option. The ordinary daemon entry remains fenced.

Admission requires the executing binary's exact canonical installed candidate
path, the complete signed publication/preparation records and matching native
identity, a held persistent fence and the actual original-state kernel lease.
Native census permits only this exact versioned self PID; another daemon,
driver, unresolved PID or changed self identity still prevents cold admission.
The v2 durable intent binds the validation workspace inode,
publication/preparation digests and the candidate inode/manifest plus the
observed self identity. Marker files and copied locks are not ownership grants.

Under that same lease, the coordinator opens the actual catalog for controlled
schema/legacy migration, closes the writer and reopens it natively read-only.
It does not run ordinary daemon startup, controller/driver recovery, outbox
dispatch, scheduling, idempotency expiry, artifact retention or other background
workers. An idle driver manager exists solely for doctor observations; no driver
session is opened. The same resource handlers serve the restricted private UDS.
Request logging is not installed in this composition.

The one-shot session checks live/false-ready/capabilities/doctor, compares paged
VM/image/operation values against the actual catalog, reads resource diagnostics
and TestRuns, and downloads all retained artifacts with byte count and SHA-256
verification. Expired idempotency and artifact records are not cleaned. After
the original request/native work drains, a complete persistent-state manifest
(excluding only `run/`) must match the one captured at read-only admission.
Ordinary bounded doctor responses do not authorize abandoning the original
native observations; maintenance drains those same probes before releasing
directories/catalog/ownership.

Success retains a separate complete `validation/validated-state` snapshot and a
sealed `validation/completed/record.json`. The original app/state rollback pair
is not rewritten. Original non-catalog data and external inputs are rechecked;
the post-validation copy is verified again after native observations. Normal
startup remains fenced, and `committed`, `activation_authorized` and
`rollback_authorized` remain false. Any partial/unknown validation output is
retained and a blind repeat is refused, not automatically repaired or promoted.
The outside-app [sealed validation recovery](MACOS_COLD_MAINTENANCE.md#sealed-validation-recovery)
entry separately re-establishes a zero-process cold boundary. It can reverify a
complete record or atomically publish only its complete sealed completion
checkpoint; it never reruns migration/API validation or clears the fence.

## Evidence and remaining composition

The real Artifact application service can list/download retained evidence using
this native read-only connection over the restricted HTTP UDS. Integration checks
verify original binary bytes/digest, refusal of DELETE and unchanged main-catalog
bytes. Other checks cover current/old/incomplete/missing catalogs, native write
refusal, exact request correlation, route specificity, late route registration,
body framing, stalled uploads, HEAD and false ordinary readiness.

The published-candidate integration now exercises a real managed image and
provisioned stopped VM, terminal cancelled TestRun and its Operations/events,
managed binary artifact, expired idempotency/retention data and unknown private
state bytes. The actual catalog and resource reads are compared, artifacts are
downloaded through HTTP UDS, background cleanup does not run, and the startup
fence remains after sealed validation completion. Seven negative native-census
fixtures reject missing/unversioned/changed self identity, other/unresolved
daemons and live/unresolved drivers before migration or validation-intent writes.
These fixtures do not attest actual native process identity or VZ/Guest execution.

The pre-catalog fixture has no source database. Cold publication independently
reports a missing catalog, then candidate validation imports the original Linux
kernel/initrd and migrates exactly one stopped VM with the pending CPU setting.
Original JSON inputs, their legacy backups, unknown private data and external
disk bytes remain intact. The complete pre-upgrade app/state rollback pair is
unchanged and its state snapshot still has no catalog.

A real unsupported legacy network mode fails controlled migration after the
boot images have been imported. The partial catalog, validation intent, startup
fence and original rollback pair remain; no completion record or API listener
appears. A blind repeat is refused before native component execution or new
inspection output, with both persistent state and work manifests unchanged.
This is one migration-error checkpoint, not the complete crash/recovery matrix.

This candidate-only composition is not a production-ready upgrade transaction.
An independently verified outside-app launcher, cold commit, arbitrary
interrupted-validation recovery, activation and paired whole-state/app rollback
remain unfinished.
Historical nonzero-schema migration through the new composition and the complete
failure/crash/low-disk matrix still need dedicated integration evidence. A green
diagnostic report is not product readiness or VZ/Guest execution. First install
and native lifecycle acceptance remain unfinished; Apple Silicon/VZ/GaoOS
execution remains assigned to the user.
