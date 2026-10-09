# GaoVM desktop console

The Flutter client for `docs/DEVELOPMENT_PLAN.md` B1.2. This implements initial
VM catalog/detail, lifecycle, linked-Operation, durable history, cancellation,
and resumable-event slices, not complete Beta acceptance.
History advances PRD UI-005/UI-007 and presents the public OP-003/OP-008 fields;
it does not prove native or cross-client Beta gates.
Cancellation exposes the existing OP-004/OP-005 public contract without changing
daemon cleanup semantics or proving native cleanup completion.
The event pane exposes the existing EVT-001/EVT-002/EVT-003 stream and advances
UI-005/UI-007 without deriving resource state from events.

## Run and check

The current client is developed with Flutter 3.47.6 (Dart 3.13.5). This does not
change the existing daemon/CLI packages' pinned Dart 3.9 toolchain.

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
flutter build macos --debug --no-pub
flutter run -d macos
```

Run these commands from `clients/gaovm_ui`. Enter an absolute path to an already
running daemon's private public-API socket and click **Connect**. There is no
automatic daemon start, service registration, driver connection, or default VM.
Choose Virtual machines, Operations, or Events. Connect binds the explicit socket
and resets the active view. VM/Operation panes fetch their catalogs; Events waits
for an explicit Start stream. Operations and Events can be connected without
first loading VMs. Switching panes keeps the configured connection, releases
superseded local reads, and fetches a destination catalog only when applicable.
Editing the socket field alone never retargets navigation, paging, or detail refresh.
Selecting a VM or Operation row fetches that resource's current detail. Those
rows are explicitly labeled snapshots, not a live event feed. Selecting an event
inspects its already consumed journal record without another request.
Load more passes opaque continuation cursors unchanged and preserves selection.
API CONFIGURED indicates a local
socket choice, not proof of daemon health; a failed read is not an empty catalog.

## Implemented boundary

- Production dependencies are Flutter, `gaovm_api_client`, and `gaovm_models`.
- Reads use public `GET /v1/vms`, `GET /v1/vms/{vm_id}`,
  `GET /v1/operations`, and `GET /v1/operations/{operation_id}`.
- Event subscriptions use only public `GET /v1/events`, not a driver connection
  or direct SQLite/filesystem access. The public API contract is unchanged.
- Operation history is independent of UI-submitted actions and VM selection.
  It accepts all public resource types, other-client keys, and null keys.
  Pages and records are typed against the shared model; invalid page shapes,
  unexpected success statuses, duplicate IDs, and looping cursors are rejected.
  Failed paging keeps the last validated rows instead of appending invalid data.
- History detail checks ID, action type, target type/ID, original request ID,
  and nullable idempotency key against the selected snapshot. State, progress,
  cancellability, timestamps, errors, and results are fetched fresh, not inferred.
  Original request/result JSON and UTC lifecycle/deadline fields remain inspectable.
  Refresh detail is an explicit GET; it never resubmits an action, selects a VM,
  or cancels an Operation. Connect is the explicit catalog-reload path.
- Cancellation is an explicit, confirmed `POST /v1/operations/{operation_id}/cancel`
  with an empty object and a fresh idempotency key. Confirmation names the target
  Operation and resource; Keep running sends no request. Fresh detail determines
  the initial button's cancellability, but the daemon decides admission and may
  return a structured `OPERATION_NOT_CANCELLABLE` problem.
- A validated cancellation acknowledgement identifies a separate `operation.cancel`
  Operation targeting the original Operation ID. Acceptance never marks the target
  cancelled or claims cleanup finished. Refresh cancellation reads that receipt,
  checking its ID, type, target, key, and the original request ID once observed.
  Only a verified terminal receipt triggers a fresh selected-target GET; the UI
  displays that target's actual state, even if it is still running.
- Lost or malformed cancellation responses remain unknown outcomes. Explicit
  Retry cancellation reuses the same socket, target, body, and key, including after
  pane changes, reconnecting to that socket, or target completion. Receipts are
  local to the application's lifetime and scoped by socket/Operation ID, not
  persisted as durable state. A new request after a verified terminal receipt
  requires fresh target eligibility, another confirmation, and a new key.
- Closing or leaving the pane releases its local submission/read sockets without
  issuing another cancel, VM action, or service command. An interrupted submission
  remains an unknown intent available for same-key replay while the app stays open.
  Read errors preserve the accepted receipt, and late replies cannot refresh a
  different selection or overwrite another socket's receipt.
- Start/Stop/Restart submit `POST /v1/vms/{vm_id}/actions/{action}` with an
  idempotency key and validate the returned `202` acceptance against the selected VM.
  Stop and Restart require confirmation identifying the VM; Cancel sends no command.
  Admission is decided by the daemon, not inferred from the snapshot's phase.
- A lost or invalid action response is an unknown outcome, not proof of failure.
  Explicit replay of the latest intent reuses the same socket, VM, payload, and key,
  including after catalog reload or selection changes. Keys are not persisted
  across application restarts. A new explicit action after a verified terminal
  Operation creates a new intent/key, not a replay of the previous failure.
- The detail pane retains the latest action receipt per socket/VM. A different
  explicit action can supersede this local pane without cancelling the old durable
  Operation; all Operations remain owned by the daemon. Repeat submission of the
  same accepted, nonterminal action is disabled, not silently replayed or polled.
- Refresh Operation displays typed state, progress, request ID, cancellability,
  error, and result. It rejects mismatched Operation ID, VM ID, action type, or
  idempotency key. A read failure keeps the accepted receipt and its identity;
  it does not submit another action. Reads are explicit snapshots, not a live feed.
- Acceptance and Operation success never imply a VM phase. A terminal Operation
  triggers a fresh public VM read only if that same VM/socket is still selected.
  Late results cannot switch selection or overwrite another VM's observed state.
- Catalog/detail show phase, metadata revision, labels, spec/applied/driver
  generations, restart-required state, and the typed specification.
- Problems retain code, request ID, retryability, and optional Operation ID.
- Superseded detail requests and widget disposal cancel local HTTP connections.
  They never cancel durable Operations, stop VMs, or own daemon processes.
- Typography is bundled offline with copyright notices and OFL licenses;
  see `assets/fonts/README.md` for pinned sources and binary hashes.

Desktop widget tests use real HTTP/Unix sockets and full schema-shaped VM replies,
not mocked internal API client/model classes. They also exercise actual peer
disconnect on teardown, stale selections, opaque pagination, identity errors,
and Start acceptance/replay after a lost response.
Lifecycle coverage includes confirmation/cancellation, correlated Operation reads,
terminal failure versus a fresh Start intent, separate observed-state refresh,
structured read problems, stale selections, and socket EOF on Operation-read teardown.
History coverage adds other-client/non-VM resources, independent connection,
connection-bound navigation/paging, fresh request/result detail, identity and
page rejection, failed-versus-empty reads, stale replies, and socket EOF on close
or pane changes. Cancellation coverage includes confirmation, fresh eligibility,
separate acceptance/completion, same-key replay after a lost response and navigation,
new intents after terminal failure, per-socket receipts, identity rejection,
structured problems, stale selection, and actual submission/read EOF on teardown.
Event coverage adds explicit connection/subscription, immutable filter scopes,
cursor/header resume after EOF, comment handling, bounded retention/selection
eviction, system/non-VM resources, strict frame rejection, structured problems,
and actual idle/pre-header socket EOF on pause, navigation, reconnect, and close.
`flutter test` renders `build/ui-catalog-preview.png`,
`build/ui-operations-preview.png`, `build/ui-cancellation-preview.png`,
and `build/ui-events-preview.png` with bundled fonts for visual inspection.
These previews use test HTTP servers, not running VMs or a native sandbox probe.

The test listener is explicitly closed separately from `HttpServer.listenOn`.
Real-I/O synchronization latches are created in `WidgetTester.runAsync`'s zone,
not the widget test's virtual-clock zone. Reads started in widget initialization
also need condition-based pumping between real-I/O turns, so the harness drains
widget-zone microtasks while awaiting peer acceptance and EOF. This does not
change production timeouts or replace the actual socket-disconnect assertion.

## Event journal

Connect selects a socket but does not start a subscription or verify daemon health.
Optional VM, Operation, and TestRun IDs are typed public IDs and combine as AND
filters. After sequence is a nonnegative 64-bit decimal cursor, initially zero.
Start stream applies these drafts as a new scope and clears this local view;
pause an active stream before starting another scope. Invalid drafts issue no
request and leave the last validated scope, cursor, records, and selection intact.

Resume stream preserves the active filters and configured socket, ignoring draft
edits. It sends the last validated cursor through both `after_sequence` and
`Last-Event-ID`. Comments/heartbeats do not advance that cursor. Invalid frames,
non-increasing sequences, records outside the active scope, and reused IDs within
the retained window interrupt the stream without consuming the offending record.
Sequence gaps are allowed; they are not evidence of lost matching events.

Each subscription retains the shared client's 30-second whole-stream deadline,
including idle heartbeats. EOF, timeout, transport, and protocol failures require
explicit resume; there is no automatic reconnect or background resource refresh.
Pause, Connect, pane changes, and window close release only the local subscription.
They do not submit commands, cancel Operations, stop VMs, or manage the daemon.

The pane retains at most 200 events and 2 MiB of encoded Event JSON, with a visible
omitted-record count. Eviction clears a selected old record but keeps the cursor.
This is a bounded display window, not a second durable journal or exact heap-size
limit. It lasts only for this pane/connection; leaving or reconnecting clears it.
Record a cursor and enter it as After sequence to resume after reopening the pane.
The daemon's SQLite journal remains the durable source. Selection exposes the
typed event's resource/correlation IDs, UTC occurrence time, and full payload;
system and non-VM events do not require VM selection. Event payloads never replace
fresh public resource reads or imply the completion of an Operation.

Log-content viewing remains unfinished. The existing VM logs API lists only file
metadata; it provides neither contents nor a tail stream. Implementing that part
requires a separately accepted bounded public API, not UI filesystem access.

## Still required by the full plan

- Image catalog; create/edit/delete; independent display control.
- Operation filters beyond cursor paging.
- Driver/serial log contents and tailing, TestRun/artifacts, host status.
- Cross-client creation/takeover and consistent state against the real daemon.
- Native window-close evidence against running daemon/VMs, not just a test server.
- Native sandbox/private-socket permissions, signing, installation, and release gates.

The generated macOS App Sandbox entitlements remain unchanged. A widget test
does not establish permission to reach an installed daemon socket from the native
sandbox, and a successful debug build does not establish that runtime access.
Do not disable sandboxing or broaden entitlements just to make a probe pass.
The Flutter UI remains a Beta deliverable and is not an MVP prerequisite.
