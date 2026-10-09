# Bounded Swift driver logging

The Swift driver's `RotatingLogger` addresses the text-log part of PRD `EVT-006`:
filesystem opens, directory creation, formatting, writes and rotation run on a
private serial writer queue, not on the calling VZ runtime or RPC queue. Each
logger instance has its own queue and admission budget; there is no global sink.
This is distinct from the read-only [VM log-reference API](VM_LOGS.md).

## Structured records and correlation

New file records are JSON Lines with the nine fields from architecture section
19.1, including the applicable correlation fields from PRD `EVT-004`. Shown
expanded for readability; the file contains one physical line per new record:

```json
{
  "timestamp": "2026-10-09T00:00:00Z",
  "level": "info",
  "component": "gaovm-driver-vz",
  "vm_id": "vm_01J00000000000000000000000",
  "operation_id": "op_01J00000000000000000000000",
  "driver_generation": 7,
  "request_id": null,
  "event_type": "runtime.configured",
  "message": "vm configured"
}
```

The v2 launch factory binds an immutable VM ID and driver generation to the
logger without retaining or serializing the authentication token. Operation IDs
are captured at admission on the VZ runtime queue, or taken from a command's
captured correlation and an event's captured envelope. A delayed write therefore
cannot pick up a later operation's context. Unscoped records have a null operation
ID; the legacy launch adapter has null VM/generation fields rather than an
invented default VM.

The frozen driver protocol does not carry public `req_` IDs, so driver records
explicitly have `request_id: null`. JSON-RPC IDs are not substituted for public
request IDs. No handshake, command or event schema is extended by this change.
Event types identify bootstrap/authentication, command replies/failures, runtime
observations, control loss and logging loss. `driver.command.succeeded` records a
sent command response, not completion of a durable daemon Operation or VM boot.
Generic adapter messages use `driver.log`.

Message newlines, quotes and control characters are escaped inside the JSON
string. Existing historical text records are not rewritten or truncated; old
current files can contain text followed by new JSON records until normal rotation.
Collectors must preserve those historical bytes, not assume every old line is
JSON. Early/fallback stderr diagnostics and the daemon's separate log format are
not converted here; this is not a claim of complete project-wide `EVT-004` coverage.

## Admission and loss

`log(level, message)` performs a bounded UTF-8 copy and takes a short admission
lock. The lock only protects counters and ordered queue submission; it is never
held during filesystem I/O. Accepted records retain admission order.

The fixed per-logger limits are:

- 256 pending records, including the record currently being written.
- 1 MiB of reserved pending data: each record reserves its payload size plus
  1 KiB for structured metadata and a loss notice. This is not a total-process RSS
  cap, including JSON escaping and transient writer allocations.
- 16 KiB of UTF-8 message bytes per record.

If a limit is exceeded, the entire record is dropped, not truncated, so an
accepted Unicode message is not split mid-codepoint. `log` returns `true` for
admission and `false` for rejection; admission is not proof of persistence.
Rejections increment a saturating counter. After a successful write, the writer
attempts a `warn` record summarizing accumulated queue/record-limit losses.
That notice is best effort and requires a subsequent successful write.
I/O failures are reported to stderr on the writer queue and release the record's
reservation; they do not poison admission for later records.

Before an append, a current file of at least 10 MiB is rotated, preserving `.1`,
`.2` and `.3`.
An append may exceed the threshold by one bounded record before the next append
rotates it. This change does not implement a log stream or alter the separate
serial-byte sink. Aggregated loss notices retain the logger's VM/generation but
have no operation ID: losses can span multiple operations.

## Teardown

`flush(timeout:)` waits for submitted writer jobs, with a default one-second
deadline. It is only used off the VZ and writer queues at teardown: terminal v2
exit, v2 control loss/watchdog exit, legacy adapter exit, and bootstrap/fatal
application exit. It does not block normal logging calls or lifecycle callbacks.

Callers must quiesce producers before treating a drain as their final boundary.
A successful drain means queued jobs finished, not that every write succeeded or
that the filesystem was fsynced. A timeout leaves the writer running until
process exit; queued records may be lost. The deadline deliberately bounds this
logging wait, not the driver's existing VM/serial shutdown waits.

## Verification scope

```sh
cd drivers/vz_macos
swift test --filter RotatingLoggerTests
swift test --filter RuntimeLoggingTests
swift test --filter DriverProcessLoggingTests
swift test
swift build
swift build -c release
```

Tests use owned temporary files and FIFOs, not a fake writer. They cover a stalled
open without blocking the caller, drain timeout and ordered completion, both
pending-record and byte budgets, recovery after draining, Unicode size limits,
loss notices, and the default 10 MiB/three-history rotation. FIFO readers release
every intentionally stalled writer before fixture cleanup.

Correlation tests cover concurrent independent loggers and real runtime command
dispatch while the log writer is stalled. A compiled-driver child test exercises
bidirectional authenticated hello, configure/event and invalid-configuration
responses over a real private UDS, then verifies structured file records after
control EOF. It uses no VM boot, disk creation or native guest execution, and
cleans up only its own exited child and temporary files.

These component checks do not prove installed-daemon or Apple Silicon VZ/GaoOS
E2E acceptance. The native executable census, Guest transport and release gates
remain required; no startup safety gate is bypassed by this logging change.
