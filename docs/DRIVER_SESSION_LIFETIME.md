# Driver v2 control-session lifetime

`DriverSessionV2` enforces the 15-second authenticated-daemon-RPC rule from
`AGENTS.md`. This is the driver-side control-loss component of M3.9 and M8 chaos
hardening, supporting PRD `RUN-009`; it does not establish complete unhealthy
recovery or native release acceptance.

## Deadline and I/O

The monotonic deadline starts when the v2 session runs, before accepting a daemon
connection. Connecting late does not grant another 15 seconds. A hello result
alone does not authenticate the daemon or refresh the deadline: both directions
of the version/capability/token handshake must complete. Subsequent authenticated,
correlation-checked RPCs renew the deadline.

The same watchdog covers waiting for a connection, incomplete frame headers and
payloads, and response writes under backpressure. Partial byte progress and
interrupted system calls do not renew it. A frame's header and payload share one
read deadline. Writers consult the current authenticated-RPC deadline, including
renewals while another thread is sending an event or response.

The v2 accepted socket is marked `O_NONBLOCK`; readiness polling alone is not
enough to bound a large blocking write. Partial transfers and `EAGAIN`/
`EWOULDBLOCK` retry against the deadline rather than becoming fatal protocol
errors. This follows Apple's
[nonblocking descriptor contract](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html).
The framing, frame-size limit, JSON-RPC schema, token checks and public API are
unchanged. The transitional v1.2 adapter retains its existing default I/O policy.

## Termination

An expired control deadline closes the connection, records `driver.control_lost`,
and enters the existing runtime-shutdown path with exit code `12`. Frame-boundary
control EOF uses exit code `0`; truncated frames remain fatal protocol errors.
The listener removes only the socket inode it bound. VM
shutdown remains on the explicit serial VZ runtime queue; these changes do not
alter the existing graceful/force-stop durations or wait on the VZ queue.

## Verification boundary

From `drivers/vz_macos`:

```sh
swift test --filter DriverSessionLifetimeTests
swift test
swift build -c release
```

On an Intel build host, check the macOS 14 ARM64 target without executing it:

```sh
swift build -c release --triple arm64-apple-macosx14.0
```

The lifetime suite launches the real compiled Swift driver with a private UDS and
the production 15-second timeout. It checks an absent daemon, a late connection,
partial header/payload, an unauthenticated hello result, authenticated ping
renewal, configured-session timeout, EOF, and unread-response backpressure.
Every owned child must confirm exit before its temporary files are removed.

These are control-session component checks. Configure stores a normalized spec;
the tests never issue `runtime.start`, boot a VZ VM, or run GaoOS. They do not
prove running-VM graceful/force shutdown, installed-daemon restart recovery,
launchd process-group behavior, signing/notarization, or Apple Silicon E2E.
Running-VM cleanup after a fatal truncated-frame EOF is also not established by
these checks. Those M3/M8 acceptance gates remain required.
