# Bounded daemon logging

The Dart daemon writes new `logs/gaovmd.log` records as JSON Lines with the nine
fields from architecture section 19.1: `timestamp`, `level`, `component`, `vm_id`,
`operation_id`, `driver_generation`, `request_id`, `event_type`, and `message`.
Unknown correlation values are null. `test_run_id` and `error_type` are optional
additional fields. This is separate from [Swift driver logging](DRIVER_LOGGING.md)
and the read-only [VM log-reference API](VM_LOGS.md).

## Correlation and privacy

Each write captures an immutable typed `LogContext`; there is no ambient current
VM or request. The installed daemon supplies its logger to the public API server.
API records use the server-generated request ID returned in `X-Request-ID`,
including the canonical emergency ID if request-ID generation fails. A client or
handler cannot replace it. An idempotent replay retains the original operation
ID but logs the new HTTP request ID.

VM, operation, image-import, TestRun, and artifact-download handlers attach known
correlation from typed service results through internal-only response metadata.
VM reads include the observed driver generation. This metadata changes neither
response JSON nor public schemas and requires no extra catalog lookup. Canonical
IDs from matched VM/operation/TestRun routes provide a fallback; a routed ID is
not proof that the resource exists. Malformed IDs are omitted, not copied as text.
An unknown generation is not inferred from another VM or a historical operation.

Ordinary responses produce `api.request.completed`; streamed responses produce
`api.request.streaming` once, when the response is selected, before waiting for
its source. This makes a long-lived SSE request visible without delaying its
bounded cancellation. These records describe response selection/status, not
client delivery, stream completion, durable Operation completion, or VM boot.
API messages contain only the status code, not raw URIs, query strings, headers,
bodies, or exception messages.

Background failures use `background.failed`, the correlation already carried by
the worker result, and the error's runtime type rather than its message. Some
workers do not yet carry every request/generation field, so those fields remain
null. Early/fallback stderr and remaining unscoped legacy callers are not a claim
of complete project-wide PRD `EVT-004` coverage.

## Admission, rotation, and shutdown

Admission performs bounded UTF-8 encoding; filesystem I/O and rotation are
serialized through asynchronous writes. API and background callbacks do not
await that writer. Each logger admits at most:

- 256 pending records, including the active write.
- 1 MiB of reserved pending data, counting message bytes plus 1 KiB per record.
- 16 KiB of UTF-8 message bytes per record.
- 64 UTF-16 code units each for component, event type, and optional error type.

The pending-data reservation is not an exact JSON-size or process-RSS cap. A
limit violation drops the whole record without truncating accepted Unicode.
The existing `Future<void>` interface is preserved: filtered/rejected calls
complete without throwing or providing an admission receipt. After a successful
write, the writer attempts a best-effort `daemon.log_dropped` warning for
accumulated rejections. Its correlation is null because losses can span requests
and VMs. A later successful write is required to emit the notice. I/O errors
still reach the individual write's future; they release its reservation and do
not poison later writes. API/background callers contain those errors.

Before an append, a file of at least 10 MiB rotates through `.1`, `.2`, and `.3`.
One bounded record may overshoot that threshold. Historical plaintext is not
rewritten: an existing current file can contain old text followed by JSON until
normal rotation. Message newlines and control characters are JSON-escaped.

`flush()` drains submitted jobs, not successful persistence of every record.
Daemon shutdown quiesces producers and drains logging before releasing state
ownership. This ownership drain has no timeout that could release the catalog or
filesystem roots while a writer is still active; it is not a bound on shutdown
time when the filesystem stalls.

## Verification boundary

Logger and Unix HTTP tests exercise real temporary files/FIFOs, record and byte
budgets, loss notices, Unicode limits, correlation/privacy, streaming cleanup,
and requests/listener shutdown while log I/O is genuinely stalled. Every FIFO
writer is released before fixture cleanup. SQLite-backed HTTP tests exercise
typed VM/operation/generation correlation with owned fake driver processes, not
native VM boot.

Installed-daemon logging assertions are included in `daemon_application_test`.
On the Intel macOS development host (2026-10-09), that test stops at the native
inventory safety gate with
`process inventory contains unresolved executables`, before API activation.
The gate is not bypassed. These component checks do not establish installed
daemon, Apple Silicon VZ/GaoOS, Guest transport, or release acceptance.
