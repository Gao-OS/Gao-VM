# Guest development acceptance entry

The user accepted this default-off development entry on 2026-10-14. It enables
the existing native Guest bridge for development acceptance, not a release-ready
Guest product or proof of Apple Silicon/GaoOS execution.

On 2026-10-19 the user approved Alpine ARM64 for first-release native acceptance,
with GaoOS-specific integration deferred. The [PRD amendment](PRD.md#2026-10-19-首版范围修订用户已批准)
changes the test OS; all runtime, authentication and evidence requirements below
remain in force.

## Explicit opt-in

`gaovmd --guest-development-acceptance true` enables the entry. Omission or
`false` leaves it disabled; environment variables cannot enable it. Values other
than `true`/`false`, missing values and repeated options are rejected. Packaged
service launch defaults are unchanged: this is an explicit manual daemon launch,
not permission to replace an installed app or register a service.

From a source checkout, build the driver and start a foreground daemon with a
new private state directory:

```sh
cd drivers/vz_macos
swift build
cd ../../daemon/gaovmd
gaovm_acceptance_state="$(mktemp -d /private/tmp/gaovm-guest-acceptance.XXXXXX)"
mise exec dart@3.9.0 -- dart run bin/gaovmd.dart \
  --state-dir "$gaovm_acceptance_state" \
  --guest-development-acceptance true
```

Keep that state path for a second terminal's public CLI socket selection
(`STATE_PATH/run/api.sock`). The source defaults select the checkout's built
driver and OpenAPI document; an external launch must supply their absolute paths
with `--driver-bin` and `--openapi-path`. Do not reuse installed production state.
Startup still requires complete native process inventory and normal ownership
recovery. An unresolved process is not proof of exit; this flag does not skip it.

The daemon passes the same explicit switch to each independent driver process.
The driver offers optional `guest.status` only when enabled. The public
`GET /v1/system/capabilities` response advertises only `health`, `system.info`,
`exec` and `artifact.collect`; without opt-in its Guest list stays empty. These
advertisements are support, not VM/Guest readiness. No new public fields, routes
or driver passthrough are introduced.

## Authentication and runtime boundary

Both directions of the original driver hello must authenticate and agree on
`guest.status` before `guest.sock` is created. A runtime-only peer remains valid
but cannot use this capability or open that endpoint. Kernel UID checks,
per-generation tokens, exact VM/generation correlation, bridge-version checks,
opening quotas and deadlines remain unchanged. Tokens remain in the driver's
environment, never arguments, public responses or Guest traffic.

`guest.status` reports the accepted `gaovm.bridge.v1` shape. `available` requires
an active bridge and a running, unfenced native VM with its applied Guest port
and socket device. An unconfigured VM reports `available: false` and a null port.
VZ reads stay on the explicit runtime queue. A ready bridge alone is not Guest
readiness: the host-first Guest hello, negotiated capabilities and correlated
health must still succeed before the controller commits readiness for the current
generation. Wrong token or generation closes a bridge opening without reflection.
Control EOF, watchdog expiry and driver teardown still fence the bridge; Guest
traffic cannot refresh the original control watchdog.

The VM's applied configuration must also enable `guest_agent` and use the port
on which the actual Guest service listens (normally 10777). The daemon flag does
not change VM specs, install the Guest service, infer image paths or turn on a
disabled Guest profile. Changing the daemon flag is not a live mutation of an
existing driver's negotiated session; use a fresh daemon/driver generation.

## Native acceptance remains separate

On the user's Apple Silicon machine, supply a real Alpine ARM64 image containing the
[resident Guest service](../guest/gaovm_guestd/README.md), import/provision it
through the public API, and wait for `guest_agent_ready`. Follow the existing
[Guest exec](GUEST_EXEC_CLI.md) and [TestRun](TEST_RUNS.md) workflows. Verify
terminal Operations, downloaded bytes/digests and failure retention, rather than
calling an HTTP acceptance, capability advertisement or bridge acknowledgement
an executed test.

Use a dedicated non-login service account, private service-owned artifact/spool
roots, a finite explicit I/O budget and a verified descendant-retirement policy.
The executable's inherited UID/GID and `PR_SET_NO_NEW_PRIVS` do not install that
policy. Keep the unmodified no-Agent smoke image separate, and retain image
provenance and static preparation receipts. Offline installation is not proof of
module loading, peer-CID admission, readiness, command execution or safe shutdown.

Native closing evidence still requires peer CID verification, two-VM isolation,
timeout/cancellation, output spill, daemon restart, and public artifact downloads.
Local compiled-driver/Unix/HTTP tests cover the opt-in and rejection boundaries;
they do not prove that native stack. No machine switch, launchd mutation or Chrome
integration is part of this implementation.
