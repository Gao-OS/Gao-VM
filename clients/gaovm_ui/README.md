# GaoVM desktop console

The Flutter client for `docs/DEVELOPMENT_PLAN.md` B1.2. This implements initial
VM catalog/detail, lifecycle, linked-Operation, and durable history slices,
not complete Beta acceptance. History advances PRD UI-005/UI-007 and presents
the public OP-003/OP-008 fields; it does not prove native or cross-client Beta gates.

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
Choose Virtual machines or Operations. Connect binds the explicit socket,
reloads the active catalog, and clears selection. Operations can be connected
without first loading VMs. Switching panes keeps the configured connection and
fetches the destination catalog, releasing superseded local reads. Editing the
socket field alone never retargets navigation, paging, or detail refresh.
Selecting a row fetches that resource's current detail. Rows are explicitly
labeled snapshots, not a live event feed. Load more passes opaque continuation
cursors unchanged and preserves selection. API CONFIGURED indicates a local
socket choice, not proof of daemon health; a failed read is not an empty catalog.

## Implemented boundary

- Production dependencies are Flutter, `gaovm_api_client`, and `gaovm_models`.
- Reads use public `GET /v1/vms`, `GET /v1/vms/{vm_id}`,
  `GET /v1/operations`, and `GET /v1/operations/{operation_id}`.
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
or pane changes. `flutter test` renders `build/ui-catalog-preview.png` and
`build/ui-operations-preview.png` with bundled fonts for visual inspection.
These previews use test HTTP servers, not running VMs or a native sandbox probe.

The test listener is explicitly closed separately from `HttpServer.listenOn`.
Real-I/O synchronization latches are created in `WidgetTester.runAsync`'s zone,
not the widget test's virtual-clock zone. Reads started in widget initialization
also need condition-based pumping between real-I/O turns, so the harness drains
widget-zone microtasks while awaiting peer acceptance and EOF. This does not
change production timeouts or replace the actual socket-disconnect assertion.

## Still required by the full plan

- Image catalog; create/edit/delete; independent display control.
- Operation cancellation UI and filters beyond cursor paging.
- Resumable events, driver/serial logs, TestRun/artifacts, host status.
- Cross-client creation/takeover and consistent state against the real daemon.
- Native window-close evidence against running daemon/VMs, not just a test server.
- Native sandbox/private-socket permissions, signing, installation, and release gates.

The generated macOS App Sandbox entitlements remain unchanged. A widget test
does not establish permission to reach an installed daemon socket from the native
sandbox, and a successful debug build does not establish that runtime access.
Do not disable sandboxing or broaden entitlements just to make a probe pass.
The Flutter UI remains a Beta deliverable and is not an MVP prerequisite.
