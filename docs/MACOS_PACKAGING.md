# macOS bundle assembly

`daemon/gaovmd/tool/package_macos.dart` is a partial M8.2 build-time assembler.
It does not compile inputs, install anything, start the daemon, or register a
launchd service. Installation/update/uninstall, automatic bundle-relative launch
configuration, notarization, and Apple Silicon VM/GaoOS release acceptance remain
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

## Runtime and verification boundary

Runtime defaults still refer to the source/prototype working directory. Do not
launch this partial bundle through Finder and assume it is installed. For a
manual runtime check, invoke `Contents/MacOS/gaovmd` directly with explicit
`--state-dir`, `--socket-path`, `--driver-bin` pointing to the packaged helper,
and `--openapi-path` pointing to the packaged schema. Invoke `Contents/MacOS/gaovm`
with the same explicit `--socket-path`. These flags do not bypass startup census,
ownership, signing, or VM runtime checks.

The component suite uses real cross-compiled ARM64 fixtures and macOS signing
tools, but never executes those fixtures:

```sh
mise exec dart@3.9 -- dart test \
  test/macos_app_package_test.dart test/vm_bundle_filesystem_test.dart \
  --concurrency=1
```

Passing this suite proves assembly/signature and filesystem behavior only, not
execution of packaged GaoVM binaries, a launchd lifecycle, native VZ boot/display,
Guest Agent/TestRun, upgrade rollback, or release readiness.
