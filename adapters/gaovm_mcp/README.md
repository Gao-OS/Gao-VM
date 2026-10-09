# GaoVM MCP adapter foundations

This package starts the B1.1 adapter from `docs/DEVELOPMENT_PLAN.md`. It is a
library checkpoint, not yet a runnable `gaovm-mcp` executable or completed Beta
deliverable. It does not block MVP packaging.

## Implemented boundary

`GaoVmMcpServer.serve` reads newline-delimited JSON requests and emits one
serialized JSON response per callback. A future process entrypoint must add the
output newline and reserve stdout for protocol messages.

Production imports only the shared public API client and models. Tools use fixed
HTTP `/v1` routes over the configured Unix socket; they never access the catalog,
driver socket, or Virtualization.framework directly. The 16 tool names come from
the frozen plan. Their input schemas are generated from the canonical OpenAPI
and linked VmSpec schemas, not maintained as a second domain contract. Daemon
and CLI dependencies are development-only, for generation and integration tests.

The current dispatcher implements the modern
[2026-07-28 discovery contract](https://modelcontextprotocol.io/specification/2026-07-28/server/discover):
`server/discover`, `tools/list`, and `tools/call`, with per-request protocol version
and client capabilities. Invalid JSON/envelopes, unsupported versions, and unknown
methods/tools return protocol errors; notifications receive no response.

Tool results retain the public JSON body as both `structuredContent` and serialized
text, including resource/Operation IDs and API Problems. Request IDs, HTTP status,
and ETags are response metadata. Local validation, unavailable transport, deadline,
and protocol failures return structured `MCP_*` tool errors without fabricating a
daemon Problem or terminating the dispatcher.

Mutation tools require caller-supplied `idempotency_key`; there are no automatic
retries. `request_timeout_seconds` bounds the local HTTP request, defaults to 30
seconds, and must be greater than zero and at most 86400. A VM wait defaults to
its valid body timeout plus five seconds. A local timeout does not cancel an
accepted durable Operation; retry mutations with the same key or use the explicit
`operation_cancel` tool.

## Validation

From this package directory:

```sh
mise exec dart@3.9 -- dart pub get --enforce-lockfile
mise exec dart@3.9 -- dart format --output=none --set-exit-if-changed lib test tool
mise exec dart@3.9 -- dart analyze
mise exec dart@3.9 -- dart test
mise exec dart@3.9 -- dart run tool/generate_contract.dart | cmp - lib/src/generated_contract.dart
```

Tests use real HTTP Unix sockets. SQLite-backed handlers demonstrate catalog/get
agreement with the CLI and a create retry shared between MCP and CLI returning
the same durable acceptance. These checks do not prove VM provisioning or boot.

## Remaining B1 work

- Standalone entrypoint and compatibility with initialization-era clients.
- Concurrent request dispatch, cancellation, prompt EOF cleanup, bounded byte
  framing, and output backpressure.
- Native process shutdown checks and installed-daemon interoperability.
- Service-level acceptance for every tool, full TestRun execution, and the
  CLI/MCP/UI cross-client Beta matrix.

The `vm_clone` schema and route are declared by OpenAPI, but the daemon does not
yet register that endpoint. The adapter must preserve its unsupported API error,
not synthesize clone success. Tool discovery alone does not establish endpoint
implementation or any native VM/packaging/release acceptance.
