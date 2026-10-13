# Event Streaming and Recovery

The MVP event interface is `GET /v1/events` over the private public API Unix
socket. It reads the committed SQLite journal, not driver callbacks or an
in-memory broadcast. A subscription is diagnostic/notification delivery; it
does not own a VM controller, a VM lifecycle action, or an Operation.

## Cursors and filters

`after_sequence=N` resumes strictly after the nonnegative decimal sequence `N`.
`after=N` is a compatibility spelling. If both are supplied, they must agree.
`Last-Event-ID: N` takes precedence over a valid query cursor; invalid or
conflicting query parameters remain errors even when that header is present.
An omitted cursor starts after zero.

The cursor is the Event's numeric `sequence`, **not** its prefixed `evt_` resource
ID. `vm_id`, `operation_id`, and `test_run_id` are optional, typed resource-ID
filters. Supplied filters are combined, not alternatives. Unknown/repeated query
parameters and malformed cursors/IDs return a structured `INVALID_REQUEST`.

Sequence numbers are global. A filtered stream may legitimately skip sequence
numbers belonging to other resources. Require increasing sequences and correct
resource association; do not require adjacent integers.

## Framing and consumption

The successful response has `Content-Type: text/event-stream; charset=utf-8`,
`Cache-Control: no-cache`, and an `X-Request-ID`. Each Event has one frame:

```text
id: <decimal sequence>
data: <one complete Event JSON object>

```

The blank line terminates the frame. JSON carries the same numeric `sequence`
and the Event's separate `event_id`, type, resource/correlation IDs, payload,
and timestamp. The server deliberately omits the optional SSE `event:` field:
an Event's arbitrary type is JSON data, not an SSE control field.
`: connected` and `: heartbeat` are comments, not Events or cursor updates.
Heartbeats normally occur every 15 seconds when the stream is not paused.

For a durable consumer:

1. Parse the complete frame and validate its Event/cursor and requested scope.
2. Finish handling that Event before saving its sequence as the consumed cursor.
3. On EOF, transport failure, or local deadline, reconnect with the saved cursor
   and the same filters.

Never advance from an `id:` line when its JSON/frame is incomplete. A disconnect
can leave a partial final frame; discard that incomplete frame, then resume from
the last fully validated and handled Event. An interrupted handler may receive
an Event again. Make handling retry-safe; if it triggers a public mutation,
retain that mutation's idempotency key rather than generating a new one on retry.
Read the authoritative resource/Operation when current state is needed; delivery
of a notification is not proof that a complete boot or guest test succeeded.

## Slow and disconnected clients

Each SQLite feed owns its cursor and pauses further page retrieval when its
consumer pauses. The public transport flushes one stream chunk at a time with
a per-write deadline (15 seconds by default). A blocked write closes that
subscription; it must not block another subscription or a VM controller.
The ordinary request deadline is not an absolute lifetime for a healthy SSE
response. Client disconnect and daemon shutdown separately cancel the feed and
release the owned connection/listener resources.

Closing a subscription does not delete its committed Events, cancel an Operation,
or stop a VM. Reconnection is the consumer's responsibility. This is not a
promise of indefinite journal retention or portability across catalog restores;
see [cold backup/restore boundaries](DATA_BACKUP.md) before reusing saved cursors
after restoring an older catalog.

## CLI and raw HTTP examples

Use the actual private socket, server-generated VM ID, and last consumed numeric
sequence in the following variables:

```bash
gaovm --socket-path "$GAOVM_SOCKET" --timeout-seconds 300 events \
  --after-sequence "$GAOVM_EVENT_SEQUENCE" --vm-id "$GAOVM_VM_ID"

curl --unix-socket "$GAOVM_SOCKET" --no-buffer --max-time 300 \
  -H 'Accept: text/event-stream' \
  -H "Last-Event-ID: $GAOVM_EVENT_SEQUENCE" \
  "http://localhost/v1/events?vm_id=$GAOVM_VM_ID"
```

The CLI prints one compact Event JSON object per line, omitting comments. Its
local timeout bounds the entire subscription, including idle heartbeats; the
default is 30 seconds. It does not automatically reconnect. SIGINT/SIGTERM stop
the local subscription (exit `130`/`143`), not the VM or a durable Operation.
The Dart client's decoder rejects invalid, non-increasing, mismatched, truncated,
or greater-than-1-MiB frames. Preserve the last accepted cursor when it reports
that the stream closed; do not treat a malformed/truncated frame as consumed.

## Verification boundary

`daemon/gaovmd/test/event_subscriber_lag_test.dart` exercises real SQLite,
transactional lifecycle delivery, per-VM controllers, host admission, and the
HTTP-over-UDS transport. It checks concurrent start/stop with an unread SSE
backlog, another filtered subscriber's progress, actual remote EOF, a truncated
backlog prefix, and exact replay through the Dart API client from the last
complete cursor. The fixture uses
fake host metrics and the fake driver's explicit clock/runtime, not VZ.

Related tests cover header/filter validation, bounded feed pages, listener
ownership, write deadlines, cancellation, and public lifecycle acceptance:

```bash
cd daemon/gaovmd
dart test test/event_subscriber_lag_test.dart test/event_api_handlers_test.dart \
  test/sqlite_durable_event_feed_test.dart test/public_api_stream_test.dart \
  test/public_api_listener_process_test.dart test/sqlite_vm_public_lifecycle_test.dart \
  test/vm_command_dispatcher_test.dart --concurrency=1
```

The fixture's two-second lifecycle bounds distinguish progress from its
five-second blocked-write budget; they are not the PRD's P95 performance
benchmark. This coverage does not establish installed-daemon startup, native
Apple Silicon VM/guest execution, or MVP release acceptance.
