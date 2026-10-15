# Maintenance validation request/catalog isolation

These are internal components for the accepted
[cold upgrade workflow](proposals/MACOS_UPGRADE_ROLLBACK.md), not an activation or
commit command. Ordinary daemon admission still rejects the persistent startup
fence. No daemon/maintenance CLI option bypasses that admission, and no worker
startup policy has been changed by these components.

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

## Evidence and remaining composition

The real Artifact application service can list/download retained evidence using
this native read-only connection over the restricted HTTP UDS. Integration checks
verify original binary bytes/digest, refusal of DELETE and unchanged main-catalog
bytes. Other checks cover current/old/incomplete/missing catalogs, native write
refusal, exact request correlation, route specificity, late route registration,
body framing, stalled uploads, HEAD and false ordinary readiness.

Full activation still needs a verified candidate/publication-bound admission and
state-ownership handoff, controlled migration (including legacy inputs), disabled
and drained background writers, actual installed API/doctor/catalog identity
evidence, confirmed native-probe exit and durable explicit commit/recovery. A
component flag, static signature, read-only connection or successful diagnostic
response does not provide those guarantees. Whole-state/app rollback, first
install and native lifecycle acceptance remain separate unfinished work. Apple
Silicon/VZ/GaoOS execution remains assigned to the user.
