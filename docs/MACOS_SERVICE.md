# Bundle-owned macOS service helper

`services/macos_service` implements the scoped
[accepted service-registration interface](proposals/MACOS_SERVICE_REGISTRATION.md)
for M8.2. It does not complete installed launchd recovery, update/uninstall,
Apple Silicon VZ/GaoOS, or release acceptance.

The assembler requires a prebuilt thin ARM64 `--service` input and installs the
signed copy as `GaoVM.app/Contents/MacOS/gaovm-service`. It manages only the owning
app's `Contents/Library/LaunchAgents/gaovmd.plist` through
[SMAppService.agent](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)).
There are no alternate bundle, job, plist, executable, user, state, socket, or
driver selectors; no launchctl/root fallback; and no catalog or VM-data mutation.

## Commands and results

```text
gaovm-service --help
gaovm-service status
gaovm-service register
gaovm-service unregister
```

Invoke the helper inside the intended signed app. `--help` needs neither an app
nor `HOME` and never accesses Service Management. All other invocations emit
one JSON object with `action`, `bundle_identifier`, `plist_name`,
`authorization_state`, `native_status`, `outcome`, and `error_code`. Invalid
invocations/configurations have null unobserved fields; native failures use
stable helper codes without native userinfo or unbounded diagnostics.

Authorization values remain distinct: `notRegistered`, `enabled`,
`requiresApproval`, `notFound`, and `unknown` with its original native integer.
The outcome and authorization fields use the same observed snapshot. State can
change after observation; these fields are not daemon/API/driver/guest health.

| Command | Meaning of exit 0 |
| --- | --- |
| `status` | Read an authorization snapshot; no registration action. |
| `register` | Already enabled, or a successful native call followed by enabled. |
| `unregister` | Already not registered, or native async completion followed by not registered. |

Exit `2` means invalid invocation, bundle configuration, or signature; `1` means
native failure, canonical-launch/output failure, or an unconfirmed action;
`3` means required user approval. Consent results include
`next_action: approve_in_system_settings`; the helper does not open Settings or
override consent. A failed native call remains failed even if its later state
looks favorable. Actions are attempted once, without automatic retries.

`register` can immediately start the daemon and is an operator action, not a
read-only probe. For unregister, the helper awaits the native asynchronous
completion rather than the synchronous API. Completion or `notRegistered` does
not prove that independent driver children exited, native VM shutdown finished,
or files can safely be deleted. Preserve census, EOF/watchdog, and cleanup gates.

## Owning bundle and signing

The actual executable is resolved through dyld, not a command-line path selector.
The helper verifies the exact app layout, regular files/directories, bounded
property lists, app identity and fixed descriptor fields. Security framework
checks cover the app and nested code, helper code identifier `<bundle-id>.service`,
the actual running code, hardened runtime, and absence of helper entitlements.
The Dart executable-memory exception is not applied to this Swift executable.

On Intel macOS 15.8.1, direct execution from a signed renamed app resolved
`Bundle.main` correctly, but an external executable symlink bound it to the link's
directory. A verified symlink invocation now re-executes only the validated
canonical helper, which must pass owning-bundle validation again before any
Service Management access. It does not relax the ownership check or introduce
an alternate service target. These read-only probes do not prove registration.

## Component verification

From `services/macos_service`:

```sh
swift format lint --strict --recursive Package.swift Sources Tests
swift test
swift build -c release
swift build -c release --triple arm64-apple-macosx14.0
```

Tests exercise real compiled help/invalid invocations and read-only status in
uniquely identified, ad-hoc signed app fixtures, including rename/symlink,
descriptor/code-ID mismatch, tampering, missing hardening, and entitlement
rejection. Fixture cleanup requires confirmed child exit. Action tests replace
only the external Service Management boundary and cover no-ops, consent,
not-found/unknown states, native faults, snapshot consistency, and delayed
unregister completion. No component test invokes real register/unregister or
starts a launch agent. [Packaging checks](MACOS_PACKAGING.md) cover real ARM64
assembly/signatures, source preservation, and atomic publication.

CI now builds/tests this helper and builds the ARM64 assembly input. Local checks
are not evidence of a GitHub run. ARM64 cross-compilation is not native execution;
registration/consent, installed daemon restart, update/rollback/uninstall,
Apple Silicon VZ/GaoOS, and signed distribution still need separate acceptance.
