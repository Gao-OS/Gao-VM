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

This lease alone is a preparation prerequisite, **not a complete cold-boundary
certificate** or an installed maintenance command. It does not itself check
catalog work/leases or external disks/EFI; the separate inspections below now
cover those component boundaries. Complete durable paired app/state snapshots
and startup fencing across state-directory replacement remain unimplemented.
These components must not justify omitting
`run/`, moving installed trees, or declaring M8 complete. Normal daemon startup
and public API behavior remain unchanged. Real service registration/unregistration
and native ARM64 product acceptance remain outside this component's tests.

## Metadata-preserving tree snapshot primitive

The internal [`MaintenanceTree.snapshotTo`](../daemon/gaovmd/lib/src/maintenance_tree.dart)
now copies one complete supported tree to a new private snapshot wrapper. It is
not an installed maintenance command or a paired app/state transaction. The
caller must still establish the full cold/external-file boundary and retain its
ownership throughout preparation; a JSON receipt grants no authority to move
its recorded paths.

The source and destination must be disjoint, canonical owned trees. Snapshot
storage must have private mode bits and no ACL grants. The primitive takes a
bounded cooperative namespace lock, refuses existing final/partial destinations,
and checks available space against logical file/xattr sizes plus conservative
per-entry overhead before copying. This is not a disk-space reservation. It
creates `.<name>.partial/payload` (`payload.app` for an app), preserves unknown
files and empty directories, and never excludes `run/` or other names. Links,
hardlinks, special files, unsafe modes and traversal/metadata bounds fail closed;
an unsupported entry must not be silently omitted to make a backup succeed.
The persistent `.gaovm-maintenance.lock` is never unlinked. Before calling the
existing lock primitive, any existing lock must be a singly linked, empty owned
regular file with mode 0600. Other contents, modes or links are refused without
changing them. The snapshot name cannot use this reserved lock name.
Copying an ownership file's bytes never transfers its kernel lock to the copy;
the held source ownership is not a startup fence for a replacement tree.

Native copying uses held descriptors and is awaited to completion, never
abandoned on a timer. Files retain bytes, UID/GID, modes, ACLs, extended attributes
(including chunked resource forks), creation/modification times and BSD flags.
Directories receive their metadata after their children. The copy call alone is
not preservation proof: checked native ownership/stat operations supplement
[`fcopyfile`](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3),
and complete source/copy manifests are compared before publication. Native
metadata errors or unsupported attributes refuse the snapshot rather than
normalizing them away. Resource forks are bounded to 4 GiB minus one byte;
other attribute values to 16 MiB, attribute-name lists and ACLs to 64 KiB each.
Read access can advance access times; they are copied as observed but excluded
from the integrity manifest, as are new inode identities and change times.

Each manifest binds file size/SHA-256 and every supported entry's permissions,
ownership, creation/modification times, flags and ACL/xattr digests. The primitive
syncs new directories, copied data/metadata, and the sealed `receipt.json`, then publishes
with an atomic no-replace directory rename and parent sync. The receipt format
is `gaovm.tree-snapshot.v1`. A failure after staging starts reports both partial
and final paths, retains originals/output, and never deletes output to retry.
A sync error may follow a successful rename: inspect both retained paths rather
than assuming nothing was published. This receipt is not a recovery journal.

Local Intel tests use real private files, native metadata/ACL/resource-fork APIs,
and a closed SQLite database with committed WAL/SHM sidecars. SQLite validation
opens only the disposable copy, never the original catalog. These snapshot tests
do not prove the separate inspections below, a paired snapshot, crash/low-disk
injection, writer fencing, upgrade, rollback, signed-product or native ARM64
lifecycle acceptance. The full M8 transaction remains unfinished.

## Source-read-only catalog and referenced-file inspections

The internal [`ColdCatalogInspection`](../daemon/gaovmd/lib/src/cold_catalog_inspection.dart)
requires an existing held `ColdStateLease` and a new empty, private inspection
directory, disjoint from both state and owning app. It copies only `gaovm.db`
and existing WAL/SHM sidecars through owned descriptors, independently checks
their bytes/native metadata, and verifies original inputs and cold observations
again. The inspection directory and remaining output are retained. Existing
output, unsafe files, unknown rollback journals and observed path substitution
refuse progress; nothing is deleted, repaired or retried in place.

**SQLite never opens the original catalog.** Only the disposable copy is opened
read/write so its WAL shared memory can initialize, with SQL `query_only` and
`trusted_schema=OFF` before inspection. This follows SQLite's
[WAL read-only constraints](https://www.sqlite.org/wal.html#read_only_databases).
Copy-side SHM creation/recovery or checkpointing is permitted. No migration runs;
the original schema is reported. This partial, SQLite-modified inspection copy
is **not a backup or restore input**.

The reader explicitly understands schemas 1–21, requires matching known tables
and a contiguous migration ledger, and checks SQLite integrity/foreign keys,
VM IDs/generations and required bounded VmSpecs. Unknown/newer layouts fail;
schema 0 is observable but blocks upgrade preparation pending a separate
initialization/legacy workflow. A future daemon migration does not automatically
extend maintenance compatibility. Nonempty WAL files must have a supported,
checksummed header, matching database page size and complete frame layout, per
the [SQLite file format](https://www.sqlite.org/fileformat.html#wal_file_format).
This checks SQLite's recovered read view, not every WAL frame independently.
Raw original sidecar hashes remain bound in the evidence.

`requireQuiescent()` refuses running intents, non-cold phases, unapplied intent
revisions, deletion in progress, nonterminal Operations/TestRuns, running steps,
unfinished provisioning/legacy migration/guest execution/diagnostic/collection/
artifact work, and **all** resource leases, including expired or unknown holds.
Unpublished `events` rows may await replay; every other unpublished outbox topic
is unfinished work. Terminal failed/cancelled history remains intact. Exact
counts accompany at most 32 sample identities per blocker. VM and reference
evidence is bounded to 16,384 entries; each decoded VmSpec to 1 MiB.

The separate [`ColdFileReferences`](../daemon/gaovmd/lib/src/cold_file_references.dart)
uses that quiescent inspection's nondeleted current, observed and execution
VmSpecs, not just the latest generation. It holds and hashes actual external
disk/EFI consumers, deduplicates shared paths while retaining their bindings,
and distinguishes paths inside state from those outside it. Canonical, owned,
nonempty regular files are required; links, unsafe write permissions and ACLs
are refused without normalization. Same-UID native reference observation cannot
account for ACL-granted writers belonging to other users. Other observed
processes, incomplete native evidence, byte/metadata changes or path replacement
also refuse progress. The native observer never acts on an observed PID.

Both objects revalidate against the original held lease; serialized JSON cannot
construct a trusted inspection. Referenced-file revalidation retains its handles
on failure until explicit close; the caller always owns the state lease lifetime.
Their JSON formats are `gaovm.cold-catalog-inspection.v1` and
`gaovm.cold-file-references.v1`. Every referenced-file record says
`backed_up: false`: no external backup/restore or lasting writer fence is supplied.
Managed assets and runtime namespaces have separate read-only inspections below.
Legacy inputs, safe `run/` exclusion, complete paired snapshots, transaction
fencing/journal, publication/validation/commit, rollback/recovery and uninstall still need the
full workflow. These internal checks do not change the public API or authorize
installed mutations, service actions, VZ boot, push or release.

## Managed images, bundle provenance and current writable bytes

The internal [`ColdManagedAssets`](../daemon/gaovmd/lib/src/cold_managed_assets.dart)
uses facts retained privately by `ColdCatalogInspection` while SQLite opens only
the inspection copy. Imported JSON cannot supply those facts. Active image rows
must agree with their immutable manifests, including type/profile/version/build/
channel. Actual published image manifests and every declared object are checked
against that catalog, including complete size and content digests.

Each nondeleted VM needs successful provisioning publication proof: the plan,
relational VM/Operation/generation IDs, terminal create Operation, completion
timestamp, retained origin spec digest and bundle manifest digest must agree.
The create request's generation, when present, must be an integer. A failed or
cancelled create tombstones its definition; a live definition with such proof
is contradictory and refused. A retained failed **TestRun** VM is different:
its earlier successful create proof, definition, current data and terminal
diagnostic history are kept, not converted into upgrade garbage.

Current, observed and execution VmSpecs must retain the completed boot/disk
source binding. Image-role pins are checked against the catalog, including the
distinct kernel/initrd/root objects in a GaoOS bundle. Unknown/older layouts
without bounded publication proof refuse asset preparation; no migration or
repair runs here. This is not a replacement for the separate legacy workflow.

**Writable VM disks are not checked against their original image seed digest.**
Their nonempty current bytes and native metadata are held and hashed, as are
existing managed EFI variables. Legitimate guest changes therefore survive the
inspection. An absent managed EFI file is permitted only before any observed
or driver generation; absence is recorded and rechecked, never initialized.
A used VM's missing EFI, an empty file, a changed path or an observed writer
refuses progress.

The required `images/` and `vms/` roots, VM bundle folders and immutable-image
folders are bound and revalidated. Private roots/bundle folders and no ACL
grants on known directories/files are required, without chmod/ACL normalization.
The existing native-metadata `MaintenanceTree` checks bind all entries beneath
required roots, including unknown regular staging/orphan data and empty
directories. Unknown data is retained; links, unsafe entries, special files or
changes refuse progress rather than trigger cleanup. Each tree retains its
existing 16,384-entry/32-level traversal bounds; managed file bindings are also
bounded to 16,384. Manifest/plan/spec JSON is capped at 1 MiB per input, image
label JSON at 64 KiB.

The result format is `gaovm.cold-managed-assets.v1`. File evidence still says
`backed_up: false`; tree content evidence is not a snapshot receipt. Revalidation
checks the original cold lease before and after tree reads, using held readers.
Failure does not release the caller's state ownership, and explicit close
releases only this inspection's readers. These checks provide neither a lasting
writer/startup fence nor a complete cold boundary. Runtime observations below
remain a separate prerequisite.
Legacy handling and state-only snapshot composition are covered below. Paired
snapshots, publication, durable transaction recovery, activation/commit,
whole-state rollback and uninstall still require the full M8 workflow.

## Runtime namespaces and retired executable observations

The internal [`ColdRuntimeInspection`](../daemon/gaovmd/lib/src/cold_runtime_inspection.dart)
starts from the original held cold lease and private-copy catalog facts. It
checks every retained generation directory, not just the current generation.
VM namespaces must match catalog identities, including tombstoned VMs; each
generation must be canonical, positive and no greater than the recorded driver
generation. Every present generation requires valid bounded diagnostic metadata
whose VM/generation, bundle and socket paths match those derived bindings.
An optional recorded process identity must have the owning UID. Metadata is
capped at 64 KiB and the whole fixed-depth namespace at 4,096 entries.

Private owned directories, empty recognized ownership markers and singly linked
regular metadata without unsafe write permissions or ACL grants are required.
Missing/invalid metadata, future generations, unbound VMs, unknown entries,
unsafe paths or nonempty ownership markers refuse preparation without cleanup.
An absent `run/` is recorded and not created; later appearance fails revalidation.
Absence alone is not evidence that historical processes exited.

Known driver/guest sockets and the public API's `api.sock`/private generation
aliases are inspected without connecting, reading socket bytes or unlinking.
The Darwin reader uses no-follow `fstatat` relative to the held parent, requires
the owning UID/private mode/no ACL, and checks inode/stat facts around the
no-follow ACL lookup and parent binding. API socket hardlinks may share an inode;
a regular file or symlink using a socket name is refused, not followed or opened.
Socket facts bind an observation, not liveness or complete restorable metadata.
They do not change the general snapshot primitive's special-file refusal.

The native census includes the inspected app's current driver and all distinct
executable paths recorded by retained generations, including retired paths.
These paths select read-only observations only: they are not independently
trusted executable identities and never authorize execution, signaling or
filesystem mutation. No metadata PID, basename, missing executable, socket or
timeout can substitute for the existing native census. Live or unresolved
processes refuse progress; unavailable native observations propagate rather
than becoming an empty inventory.

Held directory/file identities and byte/native metadata evidence are rechecked
around the census, with the original catalog and cold lease checked before and
afterward. Changed records, sockets or directory contents fail closed. Failed
revalidation retains the caller's ownership; explicit close releases only this
inspection's readers. Exported `gaovm.cold-runtime-inspection.v1` JSON is detached
diagnostic evidence, not a recovery authority, and always reports
`run_omission_authorized: false`.

This component does not establish the complete cold boundary or a lasting
startup/writer fence. The state-only snapshot consumer below composes these
observations with the other cold checks. Paired app/state snapshots, publication,
durable journal/recovery, activation/commit, whole-state rollback and uninstall
still require the composed M8 workflow.
Fixture process/service observations plus genuine local filesystem/socket/ACL
checks do not prove installed lifecycle, ARM64, VZ or GaoOS acceptance.

## Legacy inputs and migration backup provenance

The internal [`ColdLegacyInspection`](../daemon/gaovmd/lib/src/cold_legacy_inspection.dart)
reads the original held state without calling migration, creating a database,
repairing inputs or cleaning staging. A pre-catalog legacy state is supported
only while the database and all WAL/SHM/rollback-journal paths remain absent.
If any exists, the original lease's quiescent private-copy catalog inspection is
required. A new lease cannot reuse an old lease's catalog facts. Migration rows
are read only from that private SQLite copy, never the original database.

Before migration completes, `pending_config.json` wins over `config.json`.
The selected JSON identifies the current kernel, optional initrd and external
root disk. These must be canonical, owned, nonempty, singly linked regular files
without unsafe write permissions or ACL grants. Held readers bind their current
bytes/native metadata and reject other native process references or unavailable
observations. The selected JSON is capped at 1 MiB. This discovers dependencies;
it does not replace the candidate daemon's complete configuration validation.
Legacy desired state and PID/observed JSON are preserved bytes, not authority
to declare coldness, signal processes or start a VM.

A published migration backup requires its empty ownership **directory** and
the frozen v1 manifest. Raw saved-file byte digests/sizes, boot-source records
and the canonical manifest digest must match. If a catalog migration row exists,
its backup digest must also match; missing or substituted backups refuse. A
pending backup additionally pins the original root inputs and actual kernel/
initrd path, size and digest. The mutable root disk is bound at its current bytes,
not compared to an invented historical disk digest. Known saved JSON inputs and
the backup manifest retain the migration's 1 MiB limits.

After a durable completed migration, root legacy JSON is opaque retained history.
It need not remain valid JSON or equal the published backup, and deleted old
kernel/initrd paths do not become current dependencies. Current catalog external
disk/EFI references still require `ColdFileReferences`; managed images/bundles
still require `ColdManagedAssets`. An incomplete durable migration remains a
catalog blocker and cannot opt into this historical treatment.

Both the published backup and any `.legacy-v1-backup-stage` tree are captured
and revalidated with native metadata. Unknown regular files and empty directories
are retained, even in an unowned stage; their presence does not authorize cleanup
or certify candidate migration. Links, special files, unsafe permissions, ACL
grants, changed entries or newly appearing trees refuse without removing data.
Existing `MaintenanceTree` traversal bounds apply. The four root legacy inputs
and any migration lock file are also sealed and their absence/presence rechecked.

The result is `gaovm.cold-legacy-inspection.v1`, always with
`snapshot_authorized: false` and active files marked `backed_up: false`.
Verification checks the original lease/catalog around input reads and native
observations. Failure retains the caller's ownership; close releases only the
inspection's readers. Exported JSON cannot replace the held inspection object.
This is neither a migration success certificate nor a complete cold snapshot,
external writer fence or recovery authority. State-only composition is described
below; paired app/state snapshots, durable publication/recovery, activation/
commit, whole-state rollback and uninstall remain unfinished.

## Guarded persistent-state snapshots

The internal [`ColdStateSnapshot`](../daemon/gaovmd/lib/src/cold_state_snapshot.dart)
combines the original caller-owned cold lease, private-copy catalog, managed
assets, external references, legacy inputs and runtime observations. Its
`prepare`/`verify` check those held boundaries; full persistent-tree checks run
during the actual copy. No original database is opened with SQLite, no migration
is invoked, and no service, VM, original path or desired state is changed.

An existing catalog must be initialized, supported and quiescent; all earlier
WAL, durable-work, provenance and generation guards remain in force. Pre-catalog
legacy input is supported only while the database and all sidecars remain absent
and root `run/` remains absent. A pre-catalog runtime, even an empty directory,
requires independent investigation; it is not removed or presumed retired.
Absence alone still does not prove exit: the original lease's independent native
service/process/reference checks remain mandatory throughout.

`snapshotTo` copies the entire persistent state, including database/sidecars,
current writable disks/NVRAM, retained failed TestRun data and history, artifacts,
logs, legacy backups, ownership records, unknown ordinary staging and empty
directories. Only root `run/` is omitted, after and during the combined checks;
nested directories named `run` are retained. Known runtime facts remain in the
receipt and original runtime entries remain untouched. Ordinary `MaintenanceTree`
snapshots still have no exclusions and reject sockets/special files. Its new
fixed state-copy mechanism requires the coordinator's repeated boundary callback;
that low-level callback mechanism is not independently a coldness verifier.

All persistent entries require owned native metadata and safe permissions;
links/special files, extra hardlinks and ACL grants refuse. The ACL restriction
also covers unknown persistent data: same-user process observation cannot prove
absence of writers granted access to other users. Nothing is chmod/ACL-normalized
to pass. Existing traversal and metadata bounds apply.

Storage must be private and outputs unused/disjoint from state, owning app and
inspection inputs. The existing capacity check, descriptor-owned native copy,
metadata preservation, fsync and atomic no-replace publication are reused.
The payload is checked against the complete source manifest. Source/boundary
checks run again before publication and afterward; payload/native metadata and
exact receipt bytes are independently rechecked after the final callbacks, both
before and after publication. Changes or unavailable native evidence refuse;
after-publication failure retains the final output but never returns success.
Failed partial/final outputs and originals are retained for inspection, not
overwritten or cleaned on retry. Close releases readers, not the caller's lease.

The persisted format is `gaovm.cold-state-snapshot.v1`, with fixed
`omitted_paths: ["run"]`, a complete manifest/digest and the held component
observations under `boundary`. This is snapshot-storage publication, **not**
candidate app publication. External disks/EFI and active legacy dependencies
are accounted at their canonical current bytes but are **not** backed up by
this payload; back them up separately and validate them again before rollback.
The matching signed app is not part of this state-only snapshot.

The receipt explicitly reports `paired_app_snapshot: false`,
`external_files_backed_up: false`, `candidate_publication_authorized: false` and
`replacement_startup_fenced: false`. Copied lock bytes do not acquire kernel
ownership, and neither JSON nor a successful copy is a transferable cold permit.
Holding the original same-path lease does not fence a replacement tree after
rename. Paired old-app snapshots, persistent publication/startup fencing, durable
transaction recovery, activation/commit, fresh-cold whole-state rollback,
uninstall and their crash/low-disk/native installed acceptance remain unfinished.
