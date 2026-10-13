# Swift driver serial capture

This implements the serial I/O ownership portion of development-plan M3.3/M3.7
and PRD SPEC-010/EVT-006. It does not establish native VZ/GaoOS or release
acceptance. No public, driver, or guest wire contract changes are required.

## I/O and runtime ownership

Each runtime owns an independent `SerialController`. `SerialController.prepare`
opens the rotating sink on a utility worker, not the VZ queue. Start waits
asynchronously for successful preparation before building its VZ configuration.
`VzConfigurationBuilder` only attaches the already prepared output handle; it
does not open or drain serial logs. VZ configuration and VM access remain on the
explicit runtime queue.

The pipe reader and rotating sink share one private serial I/O queue. Reads use
64 KiB chunks, and a chunk is written before another is read. There is no unbounded
queue of retained `Data` jobs behind stalled file writes or rotation; the kernel
pipe supplies backpressure. Logs retain the existing 10 MiB bound and last three
rotations. Sink read/write/synchronization failures are returned by cleanup;
after a write failure the pump drains and discards remaining bytes rather than
silently treating the capture as successful.

## Capture snapshots and events

The driver offers the existing frozen v2 `console.status` as an optional
capability. The required runtime-core capabilities are unchanged; runtime-only
peers authenticate normally but cannot invoke an unnegotiated console command.
`guest.status` remains unimplemented and unadvertised.

`console.status` returns `ready` and `log_path` for the currently applied serial
controller. It never opens a file or reads the staged restart-required serial
configuration. A small independently locked observation makes read/write failure
visible while a producer still holds the pipe open, without waiting for the
private I/O queue. A missing, retired, or failed capture reports `ready: false`
and `log_path: null`. This is not an acknowledgement of completed drain or cleanup.
Snapshots bypass the dispatcher's pending lifecycle lane; stalled preparation or
drain does not require a start/stop response before status can reply.

After real preparation starts its pump, `VzRuntime` emits the existing
`console.ready` event with the active log path and the explicitly captured start
operation. Session identity supplies the VM and driver generation. Queued events
from closed or poisoned runtime generations are ignored. Readiness describes a
prepared host capture pipe: it can precede VM construction and a later start
failure. It does not prove guest bytes were received, a VM booted, or the Guest
Agent is ready, and it is not a VM terminal event.

## Drain acknowledgement

Closing the controller requests writer closure without waiting on the VZ queue.
Its completion runs only after actual pipe EOF, sink synchronization, and reader
closure. An independently retained producer descriptor can postpone EOF.
Repeated close calls join the same pump. The pump retains its pipe and sink
independently of the controller so deallocation cannot discard queued bytes or
resurrect the retiring controller.

## Start, retirement, and shutdown

`VzRuntime` tracks outstanding serial preparation and retired pumps. A new
runtime generation waits for previous serial work before opening another sink;
old and new owners cannot race rotation of the same per-VM log.

The existing 30-second start deadline now covers that wait and serial preparation
as well as asynchronous VZ start. Shutdown cancels the pending start result,
but cancellation is not proof that the filesystem call returned. A late
preparation cannot install a controller or start a VM; successful late controllers
are retired and included in cleanup.

Runtime shutdown completion includes the outstanding serial work. VM stop/kill
terminal cleanup joins it off the VZ queue for at most ten seconds; cleanup failure
or deadline expiry is reported as unconfirmed and yields exit code 1. Control-loss
shutdown retains its existing bounded best-effort policy and control-loss exit
codes. Neither path cancels a blocked kernel file operation or proves that a native
VM has stopped. Other existing disk/EFI configuration I/O is outside this
serial-only change.

## Checks and native limitations

From `drivers/vz_macos`:

```sh
swift test
swift build -c release
swift build -c release --triple arm64-apple-macosx14.0
```

`SerialControllerTests` exercise real raw-file rotation, repeated close waiters,
controller deallocation with a live duplicated pipe producer, and early readiness
failure after a real rotation permission error (skipped only for root users).
`VzRuntimeQueueTests` exercise status during stalled FIFO preparation and pipe
drain, actual shutdown completion, prior-writer exclusion, cancellation, and the
real thirty-second start deadline. Console checks include staged versus applied
paths, early host-pipe readiness before a guaranteed pre-VZ disk failure, and
operation/generation fencing. Compiled-driver UDS tests and the Dart process
manager integration check negotiated console replies with no configured VM.
Every successful fixture releases and joins its owned I/O before deleting its
temporary directory. The replacement fixture
uses an intentional disk-directory failure before VZ configuration construction;
FIFO fixtures fail during serial preparation. No valid VM is started.

An earlier replacement experiment reached the native VZ configuration path and
the test process exited with signal 11 on Intel macOS 15.8.1. Debugger attachment
was denied by the host, so its root cause is unresolved; it is not evidence of a
successful native check. The bounded serial fixtures do not cover that path.

An ARM64 cross-build is compilation only. Apple Silicon acceptance still requires
real VZ/GaoOS serial output, rotation during VM control, multi-VM isolation,
descriptor lifetime through native stop/restart, and signed/installed execution.
In particular, bounded pipe buffering can throttle the producer. These fixtures
do not establish which native VZ queue writes to the
[serial attachment](https://developer.apple.com/documentation/virtualization/vzfilehandleserialportattachment)
or how native VM control responds to that backpressure; measure it on the real
VM before accepting the full EVT-006 requirement.
