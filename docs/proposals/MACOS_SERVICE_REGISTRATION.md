---
project: GaoVM
title: Bundle-owned macOS launch-agent registration
status: accepted
updated: 2026-10-11
---

# Bundle-owned macOS launch-agent registration

The component is now implemented in `services/macos_service` and integrated with
the assembler; see [usage and verification boundaries](../MACOS_SERVICE.md).
This does not mark M8 or installed-service acceptance complete.

The user approved this scoped M8.2 component on 2026-10-11 with "approve them all",
covering the pending service-registration and public-display proposals. This is
implementation approval, not an installed-service acceptance report or permission
to register/unregister a real service as part of component tests. The existing
assembler in
[`MACOS_PACKAGING.md`](../MACOS_PACKAGING.md) signs a bundle-local launch-agent
descriptor but has no registration command. Implementing this proposal does not
complete install/update/uninstall, native VM recovery, or the MVP release gate.

## Accepted interface

Add a native Swift executable at:

```text
GaoVM.app/Contents/MacOS/gaovm-service
```

Its interface is:

```text
gaovm-service --help
gaovm-service status
gaovm-service register
gaovm-service unregister
```

The assembler gains a required `--service PATH` input for a prebuilt thin ARM64
Mach-O executable. This intentionally changes its build-time invocation; update
its tests and documented callers together. It does not change the public API,
CLI resource commands, frozen driver/guest schemas, or existing VM data.

The helper manages only the existing `gaovmd.plist` inside its own app through
[`SMAppService.agent(plistName:)`](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)).
It accepts no alternate bundle, job label, plist, executable, user, state, socket,
or driver path. Help requires no bundle, home directory, or Service Management
access. Other commands verify the actual executable's owning bundle, fixed
descriptor binding, and code signature before accessing the service. App
renaming and a resolved executable symlink must preserve that ownership check.
There is no `launchctl` fallback, shared LaunchAgents copy, root escalation,
automatic Settings launch, VM action, catalog edit, or data deletion.

## Results and native boundaries

Commands emit one JSON result describing the action, bundle identifier, fixed
plist name, and observed Service Management authorization state. Keep
`notRegistered`, `enabled`, `requiresApproval`, `notFound`, and future unknown
values distinct. Native errors use stable helper error codes; do not emit native
userinfo, tokens, or unbounded localized diagnostics.

- `status` is read-only. Exit `0` means the authorization snapshot was read, not
  that the daemon, API, driver, guest, or VM is healthy.
- `register` is idempotent when the current service is already `enabled`.
  `requiresApproval` returns an actionable consent result without trying to
  override the user's choice. Otherwise attempt the native registration once
  after bundle validation, including when a fresh valid bundle reports
  `notFound`. Only a confirmed `enabled` snapshot can report enabled registration.
- `unregister` is idempotent for `notRegistered`. Other states use the native
  asynchronous unregister completion before reporting the resulting state.
  `notFound` must not be silently converted to `notRegistered` or proof of exit.
- Exit `2` denotes invalid invocation or bundle configuration; `1` denotes native
  failure or an unconfirmed action outcome; `3` denotes required user approval.
  A failed native action is not automatically retried or reported as success
  merely because a later state query looks favorable.

Apple's installed `SMAppService.h` distinguishes the two unregister variants:
synchronous unregister does not wait for service reaping; asynchronous completion
arrives after the running service has been killed and permits re-registration.
Neither callback nor `notRegistered` proves that all independently supervised
drivers exited, VZ shutdown completed, or files are safe to remove. Preserve the
existing census/EOF/watchdog boundaries. Upgrading, rolling back, removing the
app, or deleting VM data is outside this helper component and needs separate
verified ownership and native acceptance.

## Signing and packaging

Copy and sign the helper before signing the outer app. Give it a bundle-derived
service code identifier, enable hardened runtime, and add no entitlement
exception. The accepted executable-memory entitlement remains scoped to the
Dart daemon and CLI; virtualization remains scoped to the Swift driver. Verify
all embedded code and the final bundle strictly, then retain the assembler's
existing fsync/no-replace publication and input-preservation rules.

## Required component verification

1. Exercise command results through a registration boundary fixture: read-only
   status, enabled/not-registered no-ops, consent, native faults, unexpected
   post-action state, and delayed asynchronous unregister completion.
2. Execute the real compiled helper only for help, invalid invocations, rejected
   bundle/configuration/signature paths, and read-only status in uniquely named
   signed fixtures. Confirm child exit before fixture removal. No test in this
   component calls real register/unregister or starts a launch agent.
3. Extend real ARM64 assembly/signature tests for the required helper input,
   wrong architecture, unchanged source binaries, exact entitlements, hardened
   runtime, relocation, tampering, and atomic publication failure.
4. Add macOS build/test coverage for the helper. Keep installed registration,
   consent, launchd restart, update/rollback/uninstall, Apple Silicon VZ/GaoOS,
   and distribution gates explicitly pending until authorized native tests run.

## Read-only feasibility evidence

On Intel macOS 15.8.1, a temporary native Swift probe was placed beside `gaovmd`
in a renamed app whose `CFBundleExecutable` remained `gaovmd`. The secondary
executable resolved `Bundle.main` to that app and its bundle identifier. After
inside-out ad-hoc hardened-runtime signing with no entitlement exception,
`codesign --verify --deep --strict` passed and the probe exited `0`. Its sole
Service Management operation was reading `agent(plistName: "gaovmd.plist").status`,
which returned native value `3` (`notFound`). No register/unregister was called.
This supports bundle discovery and read-only probing only; it does not prove
that the helper can register, that a service ran, or that ARM64/native
acceptance passed.
