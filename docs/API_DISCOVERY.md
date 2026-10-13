# Public API discovery

This implements the schema-discovery boundary in Architecture §11.7 and
contributes to `API-003`, `API-012`, `CLI-007`, and `CLI-008` under M4/M7. It is
not evidence that all documented endpoints, guest capabilities, or MVP release
gates are operational.

## Fetch the document

With a running daemon, use its private public API socket:

```sh
cd clients/gaovm_cli
dart run bin/gaovm_cli.dart --socket-path /absolute/state/run/api.sock \
  schema --timeout-seconds 10 --json
```

The equivalent HTTP request is:

```sh
curl --noproxy '*' --unix-socket /absolute/state/run/api.sock \
  http://localhost/v1/openapi.json
```

The result is the full OpenAPI document, including `components.schemas`.
All `$ref` values in the canonical served document resolve within that document;
clients do not need a repository checkout or a second schema download. The HTTP
response retains `X-Request-ID` and the existing private UDS permissions.

The CLI checks the OpenAPI 3.1 envelope, not the entire OpenAPI specification.
It accepts compatible 3.1 patch versions, supports compact `--json` and pretty
JSON, and uses the ordinary local request deadline (30 seconds by default).
Malformed responses return exit `4`, API Problems `1`, invalid command options
`2`, unavailable transports `3`, and deadlines `124`. Read-only discovery sends
no mutation body, idempotency key, or revision header.

## Query public capabilities

The CLI also supports the frozen capabilities contract:

```sh
dart run bin/gaovm_cli.dart --socket-path /absolute/state/run/api.sock \
  capabilities --timeout-seconds 10 --json
```

It sends only `GET /v1/system/capabilities` and validates HTTP `200` and the
complete `Capabilities` shape: `api_version: v1`, public backend/guest arrays,
and the three positive integer limits. Unknown fields, private driver capability
names, duplicate guest capabilities, and invalid limits return exit `4`.
Compact/pretty JSON, option validation, API Problems, transport failures, and
local deadlines use the same exits as `schema` above. No mutation/target/wait/list
options are accepted, and no driver IPC or repository-local defaults are used.

Advertisements are not host, VM, or guest readiness. Empty guest capabilities
remain empty; implemented guest handlers alone do not establish native acceptance.

The daemon registers this read-only endpoint and advertises the accepted catalog
limit of 128 non-deleted VM definitions. Creation checks the limit in the same
SQLite transaction as acceptance, including TestRun provisioning. Deleting VMs
still occupy a slot until their tombstone commits; idempotent create retries replay
their original acceptance even when the catalog is full. A new create at capacity
returns `409 HOST_RESOURCE_EXHAUSTED` with `max_defined_vms` in Problem details.
The running/boot limits come from the daemon's scheduler policy (defaults 8/2).
Capabilities do not perform a host census or imply that a VM can currently start.
The native guest transport remains disabled, so the guest advertisement is empty.
Bodies and query parameters are rejected. No public schema field was added.

## Canonical source and distribution

`gaovmd` loads the operator's `--openapi-path` once at startup. The repository
source is [gaovm-v1.yaml](../schemas/openapi/gaovm-v1.yaml), which retains its
canonical references to [VmSpec v1alpha1](../schemas/vm-spec/v1alpha1.schema.json).
The startup loader reads that known sibling VmSpec file only when it is referenced.
For distribution, keep the `openapi/` and `vm-spec/` sibling layout, or supply an
already self-contained JSON document through `--openapi-path`.

The loader copies all VmSpec definitions into the namespaced
`VmSpecV1Alpha1Definitions` component and rewrites their reference locations;
canonical validation constraints and annotations remain unchanged. It does not
copy the original resource's `$id` into the anonymous linked definitions:
[$id changes the base URI of schema references](https://spec.openapis.org/oas/v3.1.0.html#relative-references-in-uris).
This is a specialized linker for the frozen GaoVM sources, not a general-purpose
schema bundler. Unknown external references, missing JSON-pointer targets,
non-string references, embedded reference scopes/anchors/dynamic references, and
generated-component collisions fail startup rather than being silently rewritten.
No arbitrary reference path or URL is fetched. Each input file and the final
encoded document must fit the API client's existing 1 MiB JSON budget.

## Verification and limits

From the repository root:

```sh
cd daemon/gaovmd
mise exec dart@3.9 -- dart test test/openapi_document_test.dart
cd ../../clients/gaovm_cli
mise exec dart@3.9 -- dart test test/schema_cli_test.dart test/capabilities_cli_test.dart test/public_api_cli_test.dart
```

The tests fetch the linked document over the real public HTTP/UDS server, compare
every canonical VmSpec definition with its published constraints, and exercise a
real CLI process from a non-repository working directory. They also check malformed
inputs, missing references, scope/collision rejection, byte budgets, stable JSON
errors, and request deadlines. Fixtures explicitly own private socket directories
and close borrowed listeners; no production security check is bypassed.

These are schema/transport checks, not installed-daemon startup, Apple Silicon
VZ, GaoOS Guest Agent/TestRun, packaging, signing, or launchd acceptance.
Capabilities checks additionally exercise strict public DTO validation, preserved
empty guest advertisements, read-only request headers, and a real CLI process
outside the checkout. The daemon's real system handler also reports 128/8/2 over
UDS without native probes. SQLite creation tests cover the 129th definition,
concurrent last-slot requests, full-catalog idempotency replay and tombstones.
These checks are not native guest readiness or installed-daemon/VZ acceptance.
