# Current VM log references

This implements the frozen M4 `GET /v1/vms/{vm_id}/logs` contract from
[OpenAPI](../schemas/openapi/gaovm-v1.yaml) and architecture section 11.2.
It supports the HTTP/UDS, versioned-route, request-correlation and structured-error
boundaries of PRD `API-001`, `API-002`, `API-004` and `API-008`, and per-VM log
discovery for `EVT-005`. It does not complete those requirements' native/release
acceptance or prove log-writer rotation/non-blocking behavior (`EVT-006`).

## Public behavior

Use the VM ID returned by the catalog; replace `VM_ID` below with that exact ID:

```sh
curl --http1.1 --max-time 10 --unix-socket /absolute/state/run/api.sock \
  'http://localhost/v1/vms/VM_ID/logs?kind=serial'
```

The response is `200 application/json` with an `X-Request-ID` header and exactly
an `items` array. Each item has the frozen `LogReference` fields:

```json
{
  "kind": "serial",
  "vm_id": "vm_01J00000000000000000000000",
  "size_bytes": 4096,
  "updated_at": "2026-10-09T01:02:03.000Z",
  "artifact_id": null
}
```

Without a filter, existing current files are returned in driver, serial, guest
order, at most three items. `kind` accepts only `driver`, `serial`, or `guest` and
may appear once. Unknown query keys, malformed IDs and GET bodies produce
`400 INVALID_REQUEST`; no pagination, host paths or caller filenames are accepted.
A missing/tombstoned VM produces `404 VM_NOT_FOUND`.

The fixed names are `driver.log`, `serial.log`, and `guest.log` under that VM's
owned bundle. An unproduced bundle/log directory/file is an empty result, not a
request to create it. Loss of a successfully committed bundle is instead a
redacted `500 INTERNAL_ERROR`. An absent guest log does not prove anything about
Guest Agent readiness.

`size_bytes` and `updated_at` are fresh metadata from the same held file descriptor
stat; the timestamp is the file's modification time in UTC, not the query time.
The view is not an atomic snapshot across concurrent writers. Rotation may leave
the current basename temporarily absent or invalidate a path-binding check; a
subsequent read can observe the new file.

## Storage and artifact boundary

SQLite determines VM existence and the immutable provisioning plan. The service
checks the bounded, digest-validated bundle manifest against that pinned plan,
not a newer staged VM spec. A spec revision therefore does not relabel or discard
logs from the existing bundle.

The configured bundle-root descriptor must retain its pathname binding and mode
`0700`. Child directories/files must be owned by the daemon UID, must not be
symlinks or group/world writable, and opened files must have exactly one hard
link. Descriptor-relative, non-blocking opens reject special files without
reading them. Mismatched manifests, replaced roots and unsafe paths produce
redacted server Problems rather than exposing filesystem error strings. GET does
not repair permissions, follow replacements, remove files or change VM state.

Live references always have `artifact_id: null`: the changing file has not become
an immutable artifact. No stale snapshot ID is attached to a fresh file size/time.
Use `GET /v1/vms/{vm_id}/artifacts` to discover already captured logs and
`GET /v1/artifacts/{artifact_id}` to download those immutable bytes. Rotations
(`.1` through `.3`) remain part of host collection rather than this current-file
metadata view. See [artifact publication and downloads](ARTIFACTS.md).

No driver RPC, controller action, content hashing, log-byte reads, directory scan,
artifact publication, Operation or event/outbox mutation occurs during listing.
Only the fixed files and a manifest of at most 1 MiB are inspected. Log tail/stream
(`EVT-007`) remains P1 and is not implemented by this endpoint.

## Implementation and checks

- `libs/gaovm_models/lib/src/log_reference.dart`: typed kind/reference and strict
  serialization. The shared timestamp helper also rejects impossible calendar,
  clock and offset values rather than silently normalizing overflow.
- `daemon/gaovmd/lib/src/image_filesystem.dart`: fresh descriptor metadata; existing
  open-time image sizes retain their previous meaning.
- `daemon/gaovmd/lib/src/vm_log_application_service.dart`: read-only owned-bundle
  discovery. `vm_log_api_handlers.dart` validates client inputs separately from
  stored metadata failures; `daemon_application.dart` registers it.
- Model/API/filesystem tests cover the frozen fields, VM isolation, filters,
  growth/rotation, pinned origins across spec changes, malformed requests,
  missing/corrupt manifests, links, unsafe permissions, FIFO rejection,
  descriptor replacement and unchanged durable work/files.

```sh
cd libs/gaovm_models
mise exec dart@3.9 -- dart test
cd ../../daemon/gaovmd
mise exec dart@3.9 -- dart test test/vm_log_api_handlers_test.dart test/vm_bundle_filesystem_test.dart
mise exec dart@3.9 -- dart test test/daemon_application_test.dart --name 'installed daemon serves the VM catalog over HTTP UDS'
```

The portable API tests use real SQLite, managed image/bundle publication and HTTP
over a private UDS. They are not installed-daemon or Apple Silicon VZ/GaoOS E2E
evidence. Native startup still requires a complete executable census; this route
does not bypass that gate. Full M6 Guest execution, TestRun E2E and M8 installation,
signing/launchd/release acceptance remain separate dependencies.

Native layout references: [Darwin stat64](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/stat.h)
and [Linux statx UAPI](https://github.com/torvalds/linux/blob/v6.12/include/uapi/linux/stat.h).
Tests compare actual write metadata before pinning a whole-second timestamp:
[Dart 3.9 macOS `SetLastModified`](https://github.com/dart-lang/sdk/blob/3.9.0/runtime/bin/file_macos.cc)
uses `utime`, which discards the requested milliseconds.
