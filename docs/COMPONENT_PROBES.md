# Executable component evidence

M8 maintenance needs evidence from the actual executable, not only a filename,
`Info.plist`, signature or static packaging fixture. The daemon, CLI, Swift VZ
driver and macOS service helper implement the standalone read-only invocation:

```sh
/absolute/path/to/component --component-info
```

It emits one `gaovm.component.v1` JSON object and exits before HOME/path
resolution, catalog migration, process census, driver connection, logging, AppKit
runtime creation or Service Management access. It does not accept other action
arguments. It works outside an app bundle and without auth tokens. This is static
executable diagnostics, **not** a driver/public API request or an authenticated
session. Normal startup still requires all existing hello, UID/token, capability,
generation, watchdog, signing and census checks.

The format has exactly these keys: `format`, `role`, `version`, `public_api`,
`vm_spec`, `driver_protocol`, `catalog_schema`, `capabilities`, `service_actions`.
Absent contracts are explicit nulls; empty capability/action lists stay empty.
`capabilities` contains `offered`, `required` and `development_only` string lists.
`catalog_schema`, when present, contains `minimum` and `maximum` integers.
Unknown/missing keys, duplicate capabilities/actions and malformed versions fail
parsing. This diagnostic format does not modify the frozen public/IPC schemas.

| Role | Actual code declarations reported |
| --- | --- |
| `daemon` | Public API and VmSpec versions, driver codec version, supported catalog migration range, actual hello capability names/requirements |
| `cli` | Public API and VmSpec versions; no catalog writer or driver capability |
| `driver-vz` | Driver codec version and the same default/required capability arrays used by its hello; Guest remains development-only, not a default offer |
| `service` | Actual service action enum; no catalog writer, public API or driver session |

Implementation versions are compiled into the component, not read from app
metadata or environment variables. The current version is `0.1.0`. Driver and
daemon hello implementation versions share their respective probe declarations.
Future release bumps must update all components together and prove the resulting
binary/app/schema agreement. A self-report is not proof of provenance: signatures,
trusted release identity and actual executable hashes must also be checked.

## Internal maintenance checks

`probeComponentExecutable` requires a canonical, owned, regular executable with
one link and no group/other write bits. It pins parent/file descriptors, verifies
their path bindings, hashes the held bytes before and after execution, validates
the exact JSON role and returns the binary SHA-256 with the parsed declaration.
Unrecognized prototype output, stderr diagnostics, wrong roles, observed file
replacement/mutation or a failed process prevent successful evidence.

The child runner closes stdin, drains bounded stdout/stderr (16 KiB each), uses
no shell and no inherited HOME/auth environment, and applies a five-second
observation deadline. Failure terminates **only its own child**, first gracefully,
then forcibly if needed, and separately confirms exit. An unconfirmed exit is a
failure requiring all inputs to be retained, not authority to unlink a live
executable or signal an unrelated process. A timeout never restarts a probe.

`verifyReleaseCompatibility` checks all four actual role declarations against the
expected bundle version and a caller-supplied required catalog schema. It checks
the public/VmSpec/driver versions, default P0 capabilities, both sides' negotiated
required-capability intersection, service actions and role separation. A
development-only Guest capability cannot satisfy the default handshake. Missing
evidence is incompatible, not “old but probably supported”. The supplied catalog
number is not a live database observation; the cold transaction must obtain and
bind the actual database version independently.

These internal components are prerequisites, not the complete release inspector,
version doctor, cold snapshot/publication/rollback transaction or installed
lifecycle acceptance. The existing assembler still checks static architecture and
signatures; it must not treat these unit fixtures as actual component evidence.
The [accepted cold lifecycle design](proposals/MACOS_UPGRADE_ROLLBACK.md) remains
the required transaction boundary.

## Verification boundary

Local checks execute the actual daemon/CLI entry points and compiled Swift
driver/helper probes without runtime or service creation. Other tests compile an
explicit probe fixture to exercise bounded child lifetime, strict parsing and
byte binding; that fixture is not a GaoVM product role or signed release.
Contract mismatch/role/capability/schema tests cover the internal compatibility
policy. None of these are Apple Silicon/VZ boot, Guest readiness, launchd
registration, installed update or whole-state rollback acceptance.
