# GaoVM desktop console

The Flutter client for `docs/DEVELOPMENT_PLAN.md` B1.2. This is the first
VM catalog/detail, lifecycle, and linked-Operation slice, not complete Beta acceptance.

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
Connect reloads the catalog and clears the selection; selecting a row fetches
that VM's current detail. Catalog rows are explicitly labeled snapshots, not a
live event feed. Load more passes opaque continuation cursors unchanged.

## Implemented boundary

- Production dependencies are Flutter, `gaovm_api_client`, and `gaovm_models`.
- Reads use public `GET /v1/vms`, `GET /v1/vms/{vm_id}`, and
  `GET /v1/operations/{operation_id}`.
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
`flutter test` renders `build/ui-catalog-preview.png` with bundled fonts for
visual inspection. That preview uses a test HTTP server, not a running VM.

The test listener is explicitly closed separately from `HttpServer.listenOn`.
Real-I/O synchronization latches are created in `WidgetTester.runAsync`'s zone,
not the widget test's virtual-clock zone.

## Still required by the full plan

- Image catalog; create/edit/delete; independent display control.
- Full Operation catalog/history, externally created Operations, and cancellation UI.
- Resumable events, driver/serial logs, TestRun/artifacts, host status.
- Cross-client creation/takeover and consistent state against the real daemon.
- Native window-close evidence against running daemon/VMs, not just a test server.
- Native sandbox/private-socket permissions, signing, installation, and release gates.

The generated macOS App Sandbox entitlements remain unchanged. A widget test
does not establish permission to reach an installed daemon socket from the native
sandbox, and a successful debug build does not establish that runtime access.
Do not disable sandboxing or broaden entitlements just to make a probe pass.
The Flutter UI remains a Beta deliverable and is not an MVP prerequisite.
