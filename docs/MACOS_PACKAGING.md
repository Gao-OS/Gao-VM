# macOS bundle assembly

`daemon/gaovmd/tool/package_macos.dart` is a partial M8.2 build-time assembler.
It does not compile inputs, install anything, start the daemon, or register a
launchd service. Hardened-runtime execution validation, installation/update/
uninstall, notarization, and Apple Silicon VM/GaoOS release acceptance remain
pending. An assembled bundle is not evidence that those gates passed.

## Inputs and invocation

Run on macOS with Xcode Command Line Tools and the pinned Dart 3.9 SDK. Supply
three prebuilt, executable, thin ARM64 Mach-O files. Intel and universal binaries
are rejected. The assembler checks architecture and signatures, not whether an
input implements the correct GaoVM role, version, or protocol.

From `daemon/gaovmd`, with an existing user-owned output directory of mode `0700`:

```sh
mise exec dart@3.9 -- dart run tool/package_macos.dart \
  --daemon /absolute/build/gaovmd \
  --cli /absolute/build/gaovm \
  --driver /absolute/build/gaovm-driver-vz \
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
  Helpers/gaovm-driver-vz
  Resources/driver-entitlements.plist
  Resources/schemas/...
```

`Info.plist` declares a macOS 14 background application with `gaovmd` as its main
executable. Nested code is signed inside out: driver, CLI, then the application.
The driver must have an enabled `com.apple.security.virtualization` entitlement
in both the supplied plist and its actual signed entitlements. Each binary is
verified, then the bundle is verified with `codesign --verify --deep --strict`.
`--deep` is not used for signing. The layout and signing order follow
[Apple's code-signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/).

Schema copying rejects links and special files, limits depth to 16, entries to
512, and each file to 1 MiB. The copied public OpenAPI document and its companion
VmSpec references are loaded and validated before publication.

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

These defaults do not establish that a signed executable can run. Hardened-runtime
execution remains blocked by the finding below. This partial component does not
install a launchd service; launching it through Finder is not installation or
restart-recovery acceptance.

## Verification boundary

The assembly suite uses real cross-compiled ARM64 fixtures and macOS signing
tools, but never executes those fixtures. Unit tests cover packaged path selection,
explicit overrides, invalid `HOME`, and preservation of development defaults.
The test-process cleanup guard requires a confirmed child exit before a fixture
can be removed; successful signal delivery or an elapsed deadline is not enough.
Run from `daemon/gaovmd`:

```sh
mise exec dart@3.9 -- dart test \
  test/macos_app_package_test.dart test/vm_bundle_filesystem_test.dart \
  test/daemon_launch_configuration_test.dart test/owned_test_process_test.dart \
  --concurrency=1
```

From `clients/gaovm_cli`:

```sh
mise exec dart@3.9 -- dart test \
  test/default_socket_path_test.dart test/public_api_cli_test.dart --concurrency=1
```

Passing these suites proves component assembly/signature, filesystem, and path
selection behavior, not execution of hardened packaged binaries, a launchd
lifecycle, native VZ boot/display, Guest Agent/TestRun, upgrade rollback, notarized
distribution, or release readiness. Hosted macOS execution coverage and the
required self-hosted Apple Silicon VM E2E gate remain pending.

### Known hardened-runtime blocker

On Intel macOS 15.8.1 with Dart 3.9.0, compiled daemon entrypoint probes passed
before hardened-runtime re-signing. After ad-hoc re-signing with `codesign --force
--sign - --options runtime --timestamp=none` and no entitlements, the same probes
timed out, including `--help`. Three owned fixture processes remained present
after TERM and KILL; their exit was not confirmed. Sampling reached `Dart_Invoke`
and an AOT-code address, but the root cause and required signing policy are not
yet established. Hardened CLI execution and Apple Silicon reproduction have not
been verified. Do not remove live executable fixtures or treat signature
verification alone as packaged runtime acceptance.
