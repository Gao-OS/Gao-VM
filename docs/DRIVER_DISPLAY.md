# Swift driver display ownership

This implements the driver-side foundation of development-plan M3.6 using the
existing frozen `gaovm.driver.v2` commands. It is not public-API or native VZ/GaoOS
display acceptance.

## Session and commands

The driver offers `display.open`, `display.close`, and `display.status` as optional
capabilities. The five runtime-core capabilities remain required. Both hello
directions must agree on the same capability intersection before authentication
completes; an unnegotiated display command returns `CAPABILITY_NOT_NEGOTIATED`.
This preserves runtime-only daemon compatibility and the original
[authenticated-RPC watchdog](DRIVER_SESSION_LIFETIME.md).

Display open and close share `RuntimeCommandDispatcher`'s ordered lifecycle lane.
Heartbeat and status snapshots do not wait for an outstanding AppKit operation.
The transitional v1.2 `open_display`/`close_display` methods use the same owner and
asynchronous dispatcher, not another singleton or display implementation.

- Open requires an existing applied runtime with graphics in a running-class
  state. It does not create or start a VM. The view dimensions come from the
  applied start configuration, not a subsequently configured restart-required spec.
- Repeated open reuses the window/view. `activate: false` orders the window without
  calling application activation or making it key; the default is `true`.
- Close detaches the view after the AppKit close call returns and is repeatable.
  It never calls VM stop or invalidates the still-live runtime binding, so a later
  open can create another view/window for that same runtime.
- Display command result `data` includes `display_state`, `open`, `supported`, and
  `ok`. A headless status or close returns `closed` without initializing a window.

## Queue and generation boundaries

`VzRuntime` owns VZ lifecycle/property access on its explicit serial queue.
`DisplayController` owns the window and view on MainActor. Opening transfers an
opaque generation-bound view factory to MainActor; it does not read VM state or
call VZ lifecycle methods there. VZ state is checked before that transfer.

`DisplayObservation` is a small lock-protected published snapshot. Neither
runtime status nor display status synchronously calls the main queue. A stalled
AppKit main queue therefore does not stall the VZ queue to obtain window state.

Runtime retirement invalidates its binding before scheduling MainActor cleanup.
The controller rechecks that binding across view/window creation. Old window
notifications and retirement callbacks cannot clear a replacement window.
Runtime event-generation closure also fences observations still queued when the
owning VZ queue retires that generation.

The existing `display.state_changed` event carries VM/driver-generation identity
from the session and the display command's explicitly captured operation ID.
A manual window close has a null operation ID, not a later VM command's ID.
`willClose` reports `closing`; deferred completion reports `closed` after the SDK
close call has returned. Display events are not VM terminal events.

## Verification and remaining acceptance

From `drivers/vz_macos`:

```sh
swift test
swift build -c release
swift build -c release --triple arm64-apple-macosx14.0
```

`DisplayControllerTests` use real AppKit windows with non-presenting SDK window
overrides and ordinary `NSView` fixtures at the VZ view boundary. They cover
close/reopen, command/manual-close correlation, stale close callbacks, and
retirement during window creation. They do not render a VZ framebuffer or boot a
guest. Runtime-queue tests deliberately block the main run loop while real
headless status/close/error callbacks complete.

The lifetime tests use the real compiled driver/private UDS for optional capability
negotiation, inconsistent bilateral hello rejection, headless display commands,
heartbeat, and EOF. The daemon's `driver_process_manager_test.dart` also uses its
real Dart RPC/session adapter against that Swift executable before checking
stop/kill exits. These checks never issue `runtime.start`.

An ARM64 cross-build is compilation only. Apple Silicon acceptance still requires
an actual VZ VM, framebuffer/input, manual close/reopen without stopping the guest,
simultaneous VM displays, lifecycle races, and signed/installed-driver behavior.

The user approved the scoped [public display extension](proposals/PUBLIC_VM_DISPLAY.md)
on 2026-10-11. Its daemon/controller, durable operations, typed public client, and
CLI implementation are described in [Public VM display](PUBLIC_VM_DISPLAY.md).
This extends only the approved public OpenAPI routes; no public driver passthrough
is added. Driver replies alone do not prove durable public Operation completion,
and component coverage does not establish native Apple Silicon/GaoOS acceptance.
