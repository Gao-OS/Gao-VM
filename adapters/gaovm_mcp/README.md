# GaoVM MCP adapter

This package implements the standalone B1.1 adapter from
`docs/DEVELOPMENT_PLAN.md`. It is a transport/lifecycle checkpoint, not a completed
Beta deliverable. It does not block MVP packaging.

## Run

From this package directory:

```sh
mise exec dart@3.9 -- dart run bin/gaovm_mcp.dart --socket-path /absolute/path/to/public-api.sock
```

The socket path is explicit. The adapter does not start a daemon, register a
launchd service, or change client configuration. Stdout contains only
newline-delimited JSON protocol messages; usage and diagnostics go to stderr.

## Implemented boundary

`GaoVmMcpServer.serve` reads newline-delimited UTF-8 JSON requests and emits one
serialized JSON response per callback. Output callbacks are serialized and must
not block the isolate; their futures acknowledge drain. The standalone entrypoint
uses Dart's [non-blocking stdout sink](https://api.dart.dev/dart-io/Stdout/nonBlocking.html),
adds the newline, and flushes each response before writing the next one.
Input frames are limited to 1 MiB, invalid UTF-8 and oversized frames recover at
the next newline, and an incomplete EOF frame is rejected without reaching the API.

Production imports only the shared public API client and models. Tools use fixed
HTTP `/v1` routes over the configured Unix socket; they never access the catalog,
driver socket, or Virtualization.framework directly. The 16 tool names come from
the frozen plan. Their input schemas are generated from the canonical OpenAPI
and linked VmSpec schemas, not maintained as a second domain contract. Daemon
and CLI dependencies are development-only, for generation and integration tests.

The dispatcher implements the modern
[2026-07-28 discovery contract](https://modelcontextprotocol.io/specification/2026-07-28/server/discover):
`server/discover`, `tools/list`, and `tools/call`, with per-request protocol version
and client capabilities. Invalid JSON/envelopes, unsupported versions, and unknown
methods/tools return protocol errors; notifications receive no response.
Initialization-era clients can negotiate `2025-11-25` with `initialize` followed
by `notifications/initialized`. Both modes share the same tool catalog and API
results; legacy negotiation never bypasses explicit modern metadata validation.

Requests run concurrently, so a pending HTTP tool does not block discovery or
cancellation. `notifications/cancelled` releases the matching local HTTP request
and suppresses its late response. Input EOF releases outstanding HTTP requests
and drains pending output before returning. Local cancellation does not call the
durable Operation cancellation endpoint.

## Backpressure and shutdown

At most 64 tool requests can await API/output completion. Additional valid tool
calls return the retryable structured `MCP_SERVER_BUSY` error before reaching the
API. Discovery and cancellation still work while those tool slots are occupied.
At 128 total pending requests, input consumption pauses until a slot is released,
bounding the response queue as well as HTTP concurrency.

Each output write has a five-second deadline. EOF cancels unfinished HTTP work,
then grants one five-second deadline to drain completed responses; progress does
not restart this shutdown budget for every queued response. Explicit cancellation
also suppresses responses that are queued but not yet written.

An output error or expired deadline fails the transport and releases pending API
connections. The standalone process reports the failure on stderr and exits with
code 1, including when a native stdout write remains stalled. This is not graceful
success: normal EOF still drains output and exits naturally with code 0. A failed
or unread diagnostics pipe cannot retain the failed process.

None of these local limits cancels a durable Operation already accepted by the
daemon. Retry mutations with the same idempotency key or query/cancel the Operation
explicitly through another public client.

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
mise exec dart@3.9 -- dart format --output=none --set-exit-if-changed bin lib test tool
mise exec dart@3.9 -- dart analyze
mise exec dart@3.9 -- dart test
mise exec dart@3.9 -- dart run tool/generate_contract.dart | cmp - lib/src/generated_contract.dart
```

Tests use real HTTP Unix sockets. SQLite-backed handlers demonstrate catalog/get
agreement with the CLI and a create retry shared between MCP and CLI returning
the same durable acceptance. These checks do not prove VM provisioning or boot.
Holding the response after real SQLite acceptance verifies that MCP cancellation
and EOF preserve the Operation and its CLI idempotent replay.
Owned, unhardened compiled-process fixtures check clean protocol stdout and
natural EOF exit, including peer-observed closure of a pending HTTP connection.
An unread-stdout fixture checks actual pipe backpressure, failed native exit and
HTTP closure. A library-level check separately proves HTTP release without using
process exit to close the connection.
Fixture files are removed only after confirmed child exit. These checks do not
prove production signing or installed-daemon integration.

## Remaining B1 work

- Installed-daemon interoperability and broader native transport failure checks.
- Service-level acceptance for every tool, full TestRun execution, and the
  CLI/MCP/UI cross-client Beta matrix.

The `vm_clone` schema and route are declared by OpenAPI, but the daemon does not
yet register that endpoint. The adapter must preserve its unsupported API error,
not synthesize clone success. Tool discovery alone does not establish endpoint
implementation or any native VM/packaging/release acceptance.
