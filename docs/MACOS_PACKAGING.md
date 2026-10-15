# macOS bundle assembly

`daemon/gaovmd/tool/package_macos.dart` is a partial M8.2 build-time assembler.
It does not compile inputs, install anything, start the daemon, or register a
launchd service. Compiled Dart launch checks cover the scoped signing policy on
Intel macOS; complete installed startup, installation/update/uninstall,
notarization, and Apple Silicon VM/GaoOS release acceptance remain pending. An
assembled bundle is not evidence that those gates passed.

The separate [cold operator publication command](MACOS_COLD_MAINTENANCE.md)
composes fenced preparation/retirement/publication, not installation or a
complete upgrade. It intentionally leaves ordinary startup blocked; activation,
validation/commit, rollback and uninstall remain separate unfinished work.

## Inputs and invocation

Run on macOS with Xcode Command Line Tools and the pinned Dart 3.9 SDK. Supply
four prebuilt, executable, thin ARM64 Mach-O files. Intel and universal binaries
are rejected. The assembler checks architecture and signatures, not whether an
input implements the correct GaoVM role, version, or protocol.

From `daemon/gaovmd`, with an existing user-owned output directory of mode `0700`:

```sh
mise exec dart@3.9 -- dart run tool/package_macos.dart \
  --daemon /absolute/build/gaovmd \
  --cli /absolute/build/gaovm \
  --driver /absolute/build/gaovm-driver-vz \
  --service /absolute/build/gaovm-service \
  --schemas ../../schemas \
  --driver-entitlements ../../drivers/vz_macos/Resources/entitlements.plist \
  --output-dir /absolute/private-package-output \
  --bundle-id org.example.GaoVM \
  --version 0.1.0 \
  --sign -
```

Every option is required. Use your actual reverse-DNS bundle identifier and a
numeric `X.Y.Z` version. `--sign -` explicitly selects ad-hoc development signing;
it is not a distribution certificate, notarization, or Gatekeeper acceptance.
For certificate signing, pass the intended signing identity explicitly. Signed
copies use the hardened runtime; certificate signing also requests a timestamp.
The original input binaries are never signed or modified.

On success, stdout contains the canonical path to `GaoVM.app`. Usage/input-format
errors return `2`; filesystem or native tool failures return `1` with diagnostics
on stderr. `--help` describes the invocation without assembling a package.

## Layout and validation

```text
GaoVM.app/Contents/
  Info.plist
  MacOS/gaovmd
  MacOS/gaovm
  MacOS/gaovm-service
  Helpers/gaovm-driver-vz
  Library/LaunchAgents/gaovmd.plist
  Resources/dart-runtime-entitlements.plist
  Resources/driver-entitlements.plist
  Resources/schemas/...
```

`Info.plist` declares a macOS 14 background application with `gaovmd` as its main
executable. Nested code is signed inside out: service helper, driver, CLI, then
the application.
The driver must have an enabled `com.apple.security.virtualization` entitlement
in both the supplied plist and its actual signed entitlements. The daemon and CLI
use a generated, fixed Dart policy containing only
`com.apple.security.cs.allow-unsigned-executable-memory`, accepted on 2026-10-10.
The policy does not apply to the Swift driver or service helper. The service
helper uses `<bundle-id>.service` as its code identifier and has no entitlements.
Its identifier and lack of entitlement keys are verified after signing the outer
app. Hardened runtime remains enabled;
no library-validation, JIT, or other SDK exception is added. Each binary is
verified, then the bundle is verified with `codesign --verify --deep --strict`.
`--deep` is not used for signing. The layout and signing order follow
[Apple's code-signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/).

Schema copying rejects links and special files, limits depth to 16, entries to
512, and each file to 1 MiB. The copied public OpenAPI document and its companion
VmSpec references are loaded and validated before publication.

## Bundled launch agent

The assembler generates `Contents/Library/LaunchAgents/gaovmd.plist` before
signing. The native [service helper](MACOS_SERVICE.md) in the owning app uses
[`SMAppService.agent(plistName: "gaovmd.plist")`](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)).
Apple's API requires the descriptor in that bundle-local directory. No
registration action is performed by this assembler, and `BundleProgram` is
only supported for SMAppService-installed jobs: copying this plist to a shared
LaunchAgents directory or using `launchctl bootstrap` is not an installation path.

The fixed plist basename does not impose a filename-length limit on the existing
255-character bundle-ID input contract.
The descriptor contains only:

- `Label=<bundle-id>.gaovmd`: a job identity derived from the supplied app identity.
- `BundleProgram=Contents/MacOS/gaovmd` and `ProgramArguments=[gaovmd]`: a
  bundle-relative daemon executable, with no shell, interpreter, working-directory
  dependency, fixed user identity, `HOME`, or state/socket override.
- `KeepAlive=true`: request continuous supervision; this also implies RunAtLoad.
- `Umask=63`: the decimal plist representation of `077`, restricting newly
  created files to the current user.
- `AbandonProcessGroup=true`: request that launchd leave driver children to
  shut down through control EOF/watchdog rather than killing the daemon's
  process group immediately, matching `ARCHITECTURE.md` section 17.1.

Key semantics come from the target host's `launchd.plist(5)`. Throttling and
SIGTERM-to-SIGKILL grace retain launchd defaults. No unbounded stdout/stderr file
is added; daemon logging remains separately bounded. The
[v2 driver lifetime component](DRIVER_SESSION_LIFETIME.md) is a prerequisite, not
proof of running-VM recovery. Registration/consent, installed daemon restart,
process-group behavior, and install/update/uninstall still require native tests.

## Publication and failure handling

The assembler serializes publication with an output-directory lock. It creates a
private `.gaovm-package-<random>.app` staging directory, verifies the signed tree,
syncs files and directories, and publishes with an atomic no-replace rename.
An existing `GaoVM.app`, including a link at that name, is never overwritten.
The output directory must not itself be a link. Keep the schema input tree
separate from the output directory.

Failed staging is deliberately retained for inspection rather than recursively
removed through a replaceable path. The lock file also remains. A final directory
sync can fail after the rename has already published the app: on any failure,
inspect both staging and `GaoVM.app` before retrying. Do not force-overwrite an
existing app. Remove retained staging only after verifying the exact directory
is yours and no packaging process is using it.

## Packaged runtime paths

The compiled `gaovmd` and `gaovm` recognize their `*.app/Contents/MacOS/` layout
using the actual resolved executable path, independently of the working directory.
App renaming and CLI symlinks therefore do not require rewriting paths; see
[Dart's resolved executable contract](https://api.dart.dev/dart-io/Platform/resolvedExecutable.html).
The daemon's default socket remains `<state-dir>/run/api.sock`.

| Setting | Packaged default |
| --- | --- |
| Daemon state | `$HOME/Library/Application Support/GaoVM` |
| Daemon driver | `<app>/Contents/Helpers/gaovm-driver-vz` |
| Daemon OpenAPI | `<app>/Contents/Resources/schemas/openapi/gaovm-v1.yaml` |
| CLI socket | `$HOME/Library/Application Support/GaoVM/run/api.sock` |

Existing flags override these defaults. Driver precedence remains `--driver-bin`,
then `GAOVM_DRIVER_BIN`, then the bundled helper. A custom daemon `--state-dir` or
`--socket-path` requires the matching explicit CLI `--socket-path`. The defaults
that need `HOME` require it to be nonempty and absolute; otherwise pass daemon
`--state-dir` or CLI `--socket-path`. Help does not require `HOME`. Source/Dart SDK
runs and binaries outside the app layout keep their existing development defaults.
Missing bundled resources fail startup rather than falling back to repository
assets. Path selection does not bypass startup census, ownership, signing, or VM
runtime checks.

These defaults alone do not establish that a signed executable can run. The
compiled launch checks below exercise the accepted signing policy without
entering installed daemon startup or VM recovery. This partial component does
not install a launchd service; launching it through Finder is not installation
or restart-recovery acceptance.

## Verification boundary

The assembly suite uses real cross-compiled ARM64 fixtures and macOS signing
tools, but never executes those fixtures or registers a service. It checks the
launch-agent descriptor after app renaming, the longest accepted bundle ID, and
signature rejection after descriptor tampering. It also checks exact signed
entitlement dictionaries and the hardened-runtime flag: the driver fixture has
only virtualization, daemon/CLI fixtures have only the accepted Dart bit, and
the service helper has no entitlements. The suite also assembles the actual
cross-built ARM64 Swift helper without executing it and verifies its source bytes
are unchanged. Build that input first from `services/macos_service`:

```sh
swift build -c release --triple arm64-apple-macosx14.0
```

The real-helper assembly case skips explicitly when that build is absent; CI
builds it before the suite. Signature-only C fixtures still do not prove the
daemon, CLI, or driver implements its role.
Unit tests cover packaged path selection, explicit overrides, invalid `HOME`,
and preservation of development defaults.

Separate launch suites compile the real daemon and CLI for the test host and
sign them with the same Dart policy in a renamed app layout. On Intel macOS
15.8.1 with Dart 3.9.0, all three daemon and four CLI launch cases passed. They
cover help without `HOME`, fail-closed missing paths/resources, a resolved CLI
symlink, and the compiled CLI reaching a real public HTTP-over-UDS API fixture
with an explicit socket. Daemon cases deliberately stop before census, state
creation, or driver startup. These host-architecture executables are not inputs
to the ARM64-only assembler and do not test Apple Silicon execution.

The test-process cleanup guard requires a confirmed child exit before a fixture
can be removed; successful signal delivery or an elapsed deadline is not enough.
Run from `daemon/gaovmd`:

```sh
mise exec dart@3.9.0 -- dart test \
  test/macos_app_package_test.dart test/vm_bundle_filesystem_test.dart \
  test/daemon_launch_configuration_test.dart test/owned_test_process_test.dart \
  test/packaged_daemon_launch_test.dart \
  --concurrency=1
```

From `clients/gaovm_cli`:

```sh
mise exec dart@3.9.0 -- dart test \
  test/default_socket_path_test.dart test/public_api_cli_test.dart \
  test/packaged_cli_launch_test.dart --concurrency=1
```

Passing these suites proves component assembly/signature, filesystem, path
selection, and the stated compiled launch behavior. It does not prove complete
installed daemon startup, a launchd lifecycle, native VZ boot/display, Guest
Agent/TestRun, upgrade rollback, notarized distribution, or release readiness.
Hosted macOS execution coverage and the required self-hosted Apple Silicon VM
E2E gate remain pending.

### Hardened-runtime signing finding

On Intel macOS 15.8.1 with Dart 3.9.0, compiled daemon entrypoint probes passed
before hardened-runtime re-signing. After ad-hoc re-signing with `codesign --force
--sign - --options runtime --timestamp=none` and no entitlements, the same probes
timed out, including `--help`. Three owned fixture processes remained present
after TERM and KILL; their exit was not confirmed. Sampling reached `Dart_Invoke`
and an AOT-code address.

A subsequent controlled probe copied the compiled daemon to a fresh private app
layout and added only `com.apple.security.cs.allow-unsigned-executable-memory`
while retaining hardened runtime and library validation. The signed copy reached
`--help` and exited successfully. Its embedded `__dart_app_snap` payload was
byte-identical before and after signing, the original artifact was unchanged,
and every probe child confirmed exit before the temporary fixture was removed.
This identifies the missing executable-memory exception as the launch blocker in
the tested configuration, rather than snapshot corruption during re-signing.

The pinned [Dart 3.9 AOT signing policy](https://github.com/dart-lang/sdk/blob/3.9.0/runtime/tools/entitlements/dartaotruntime_product.plist)
includes that exception. Apple warns that it
[relaxes executable-memory protection](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-unsigned-executable-memory).
The user accepted that single exception on 2026-10-10 for the compiled Dart
daemon and CLI. The assembler now applies it, and the compiled launch suites
verify the scope described above. Neither the historical help probe nor these
launch checks establish complete daemon startup, Apple Silicon compatibility,
or native VM acceptance. Do not remove live executable fixtures or treat
signature verification alone as packaged runtime acceptance.
