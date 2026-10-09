# GaoVM desktop console

The Flutter client for `docs/DEVELOPMENT_PLAN.md` B1.2. This is the first
VM catalog/detail and Start-acceptance slice, not complete Beta acceptance.

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
- Reads use public `GET /v1/vms` and `GET /v1/vms/{vm_id}`.
- Start submits `POST /v1/vms/{vm_id}/actions/start` with an idempotency key
  and validates the returned `202` Operation acceptance against the selected VM.
  Acceptance never changes the displayed observed VM phase.
- A lost or invalid response is an unknown outcome, not proof that Start failed.
  Explicit retries reuse the same socket, VM, payload, and key within this UI
  session, including after catalog reload or selection changes. Keys are not
  persisted across application restarts. After validated acceptance, Start is
  disabled for that VM in this session; Operation progress is not implemented yet.
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
`flutter test` renders `build/ui-catalog-preview.png` with bundled fonts for
visual inspection. That preview uses a test HTTP server, not a running VM.

The test listener is explicitly closed separately from `HttpServer.listenOn`.
Real-I/O synchronization latches are created in `WidgetTester.runAsync`'s zone,
not the widget test's virtual-clock zone.

## Still required by the full plan

- Image catalog; create/edit/delete; stop/restart; independent display control.
- Full lifecycle/Operation progress and terminal-result handling beyond Start acceptance.
- Operations, resumable events, driver/serial logs, TestRun/artifacts, host status.
- Cross-client creation/takeover and consistent state against the real daemon.
- Native window-close evidence against running daemon/VMs, not just a test server.
- Native sandbox/private-socket permissions, signing, installation, and release gates.

The generated macOS App Sandbox entitlements remain unchanged. A widget test
does not establish permission to reach an installed daemon socket from the native
sandbox, and a successful debug build does not establish that runtime access.
Do not disable sandboxing or broaden entitlements just to make a probe pass.
The Flutter UI remains a Beta deliverable and is not an MVP prerequisite.
