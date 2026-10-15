# Read-only macOS release inspection

The accepted [cold upgrade design](proposals/MACOS_UPGRADE_ROLLBACK.md) requires
independent executable evidence before replacement. The maintenance entry point
below implements the Developer ID Application inspection path. It does **not**
install, snapshot, migrate, replace, register, activate, commit or roll back
anything. It is separate from the public-API-only `gaovm` client and its existing
`doctor` command.

```sh
cd daemon/gaovmd
mise exec dart@3.9.0 -- dart run tool/inspect_macos_release.dart \
  --app /absolute/path/GaoVM.app \
  --bundle-id org.example.GaoVM \
  --version 0.1.0 \
  --team-id YOURTEAMID \
  --catalog-schema 21
```

Supply the expected identity/version from a trusted release source, not by
copying them from the candidate under inspection. `--catalog-schema` is an
explicit compatibility requirement; it is **not** a database observation. The
inspector never opens an installed catalog or contacts a running daemon/driver.
The source can also be compiled to a standalone maintenance executable. Keep
that executable outside any tree a later transaction may rename.

## Checks and order

1. Require an explicit canonical owned `.app` directory. Capture every regular
   file and empty directory, including unknown resources, with permissions,
   size and SHA-256. Reject symlinks, hardlinks, special files, set-ID or
   group/other-writable entries. Bound traversal to 16,384 entries/32 levels;
   plists to 64 KiB and contract documents to 1 MiB. A held root descriptor and
   no-follow child descriptors detect observed path substitution.
2. Verify the outer bundle recursively and all four code signatures strictly,
   before executing any candidate component. Require the caller's exact bundle
   IDs, Apple-issued Developer ID Application certificate chain and Team ID.
   The requirement uses Apple's [documented Developer ID certificate OIDs and
   Team ID field](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
   Each executable must be thin ARM64 Mach-O and use hardened runtime.
3. Inspect actual signed entitlements, not just the bundled plist. Daemon/CLI
   may have only the already-approved executable-memory entitlement; driver
   only virtualization; service helper none. Verify the exact owning bundle
   and six-field launch-agent layout, with no hidden arguments/environment.
   The entitlement resource files must agree. Check public/VmSpec/driver schema
   version declarations and resolve the public document's local references.
   This is not a replacement for the repository's full schema validation gate.
4. Recheck the complete tree before running the actual four
   [`--component-info` probes](COMPONENT_PROBES.md), with no inherited HOME/auth
   environment. Bind their reported roles/contracts to observed executable
   digests; require expected implementation/public/driver/VmSpec/catalog
   compatibility. Recheck the whole tree afterward, including unknown resources.

The command does not weaken the normal bidirectional hello, per-generation
authentication, process census or runtime capability negotiation. Its observed
byte/path checks are not a defence against an arbitrarily malicious same-UID
process that can rewrite both private inputs and evidence.

## Results and limits

Success exits 0 and emits one `gaovm.release-inspection.v1` JSON object containing
`compatibility: compatible`, expected identity/version, actual component evidence
and the full tree/digest. `applied_catalog_schema` is null and
`negotiated_runtime` is `unobserved`; static declarations must not be presented
as those runtime observations.

Failure emits the same format identifier with `status`, `stage` and `reason`:

- Exit 2, `incompatible`: malformed inputs, wrong identity/layout, failed native
  signature checks, changed inputs or incompatible role/contract evidence.
- Exit 3, `unverified`: unavailable native evidence or incomplete observation.
  This entry point conservatively refuses component execution from an
  Intel/Rosetta maintenance process; run maintenance natively as ARM64. It never
  falls back to filenames, C signature fixtures or guessed compatibility.
- A bounded child failure also reports its PID and confirmed-exit flag. An
  unconfirmed exit requires retaining every input; do not unlink a live image
  or restart a timed-out probe. Only the inspector's own child is terminated.

The command always retains its inputs. It performs no service action, VZ boot,
state cleanup, installed migration or release publication. It does not assess
notarization/Gatekeeper policy or prove installed lifecycle readiness. A trusted
native ARM64 run of genuine product components is still required; the local
positive policy test replaces only the external native boundary and is not
signed-release evidence. The native ad-hoc fixture is used only to prove refusal
before candidate execution, never as a GaoVM role.

The general cold-upgrade policy for explicitly pinned ad-hoc development packages
is a separate pending user choice. This entry point currently implements only
the formal-signature path common to both proposed policies; existing explicit
ad-hoc assembly tests remain valid build fixtures, not upgrade authority.
Complete cold acquisition, durable paired snapshots, writer fencing, publication,
validation/commit, rollback/recovery and uninstall are still separate M8 work.

## Cold-state preparation library

The internal [`MacOsColdStateHost`](../daemon/gaovmd/lib/src/macos_cold_state_host.dart)
performs a fresh release inspection and holds its app tree. Before and after
running only that app's `gaovm-service status`, it verifies the inspected bytes
again. Imported JSON receipts cannot grant trust to an arbitrary helper.
The native process observations match the exact canonical daemon and driver
paths; unresolved executable identities remain failures, not proof of exit.

[`ColdStateLease`](../daemon/gaovmd/lib/src/cold_state_lease.dart) holds the
existing daemon ownership mechanism throughout preparation. It refuses broad
roots, app/state overlap, noncanonical or nonprivate state, an existing owner,
anything except the exact owning helper's `notRegistered` observation, live or
unresolved daemon/driver processes, and other same-user processes referencing
the state tree. Service status is checked again after the process/reference
observations. Revalidation failure retains an acquired lock until explicit
close; rejected acquisition releases its own lock. The persistent
`.gaovmd.lock` may be created but is never unlinked; catalog/data are not opened
or changed. The host's app handle and the state lease have explicit lifetimes.

The targeted native open-reference reader requests only PID/file-descriptor
fields, restricted to the current UID and the specified canonical directory or
file. It treats readers, working directories and mappings as occupied too. It
does not inspect command lines or act on an observed PID. The bounded command
runner must confirm its own observer exited; only that observer is omitted.
The lease additionally permits its own maintenance process's references.
Warnings, malformed/truncated records, unsupported descriptor records, output
overflow and unavailable evidence refuse progress. A native search can return
1 while reporting occupied files; those PIDs must be retained, as documented in
the [lsof project's exit-status FAQ](https://github.com/lsof-org/lsof/blob/master/docs/faq.md#why-does-the-lsof-exit-code-report-it-didnt-find-open-files).
This same-user observation is not protection against privileged or malicious
writers, nor a lasting fence against uncooperative new processes.

This is a preparation prerequisite, **not a complete cold-boundary certificate**
or an installed maintenance command. It does not yet check catalog work/leases,
external disks/EFI, copy a complete durable app/state snapshot, or provide
startup fencing across state-directory replacement. It must not justify omitting
`run/`, moving installed trees, or declaring M8 complete. Normal daemon startup
and public API behavior remain unchanged. Real service registration/unregistration
and native ARM64 product acceptance remain outside this component's tests.
