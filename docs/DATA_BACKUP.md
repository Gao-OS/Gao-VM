# Data backup, restore and diagnostic export

This is the M8.5 backup/export runbook, using the storage boundaries in
[architecture section 10](ARCHITECTURE.md#10-persistence-与目录结构).
It does not add a public backup API, automate service shutdown, or implement the
P1 portable `.gaovm` export/import feature. The cold, same-path recipe below has
isolated filesystem/SQLite coverage; installed-service backup/restore, upgrade
rollback and Apple Silicon VM/GaoOS recovery still need native acceptance.

## What must travel together

Preserve the complete private state directory, except `run/` only after the
quiescence barrier below has been established:

- `gaovm.db` and any SQLite sidecars: catalog, versioned specs, desired/observed
  state, Operations, TestRuns, Events, leases, idempotency and outbox records.
- `images/`: immutable manifests and objects, including base disks and boot files.
- `vms/`: bundle origin manifests, **current writable disks**, NVRAM, logs and
  collection staging. Recreating a disk from its base image loses guest changes.
- `artifacts/`: sealed manifests, ownership receipts and payloads. These live
  independently of VM bundles so retained TestRun results survive VM deletion.
- `logs/`, legacy migration backups/markers and other state-owned files. Do not
  discard a staging directory or ownership marker just because it looks temporary.

External disks and external EFI variable stores are separate operator-owned
files, not followed or copied by this state archive. Inventory their canonical
paths, ownership, sizes and checksums; quiesce all their writers and back them up
separately at the same boundary. Retain their original paths for this recipe.
An archive of managed state alone is not a backup of those external bytes.
The app, CLI, driver and service helper are also outside the data archive; record
and retain the matching signed release separately.

Do not copy just `gaovm.db` while it is open. Committed changes may still exist
only in its WAL; deleting or separating that WAL can lose data.
[SQLite's WAL documentation](https://www.sqlite.org/wal.html#the_wal_file)
describes this boundary. A
[SQLite online backup](https://www.sqlite.org/backup.html) snapshots the database,
not the concurrently changing managed disk, image and artifact files; it is not
a whole-GaoVM backup on its own.

## Establish a cold boundary first

1. Stop new client writes and automation. Review and settle active image imports,
   VM provisioning/deletion, guest executions and TestRuns through their public
   Operations. A cancellation acceptance is not terminal completion.
2. Stop each VM through the public API and wait for its stop Operation to finish.
   Confirm desired state is `stopped` and observed state is `stopped`; closing a
   display does not stop a VM. Do not edit desired state directly in SQLite.
3. Prevent the owning daemon from restarting. For a registered app, unregistering
   its [bundle-owned service](MACOS_SERVICE.md) is an explicit operator action.
   `notRegistered` reports registration state, not completion of daemon/driver
   shutdown. For a manually launched daemon, stop that exact owned process.
4. Confirm actual daemon and driver exits, joined workers/log writers and closed
   database handles. Use complete native process identities, not a PID basename,
   elapsed watchdog time, successful signal delivery or a missing socket.
   External disk writers must also be gone. If an executable/process is unresolved,
   preserve the original state and resolve it; do not bypass the startup census.

Only then may `run/` be omitted: it holds API/driver sockets and generation
runtime metadata, not the catalog. This exclusion must never be used to erase
unknown live-driver evidence or turn an unresolved crash into a clean shutdown.
There is no built-in online whole-state snapshot or command that proves this
barrier. Do not run this recipe against an active installation.

An internal [guarded state snapshot component](MACOS_RELEASE_INSPECTION.md#guarded-persistent-state-snapshots)
now composes the held cold checks and creates metadata-preserving state-only
copies, with a durable boundary receipt and no original mutation. It is not an
installed maintenance command, app/state pair, external-file backup or rollback
transaction. Its fixture acceptance does not authorize this operator recipe
against a live installation or replace the native lifecycle gates.

## Create and check a private archive

The following is an operator recipe for macOS. Replace both placeholders with
explicit canonical, absolute, user-owned directories. The state root must be
private (`0700`) and must not be a symlink; choose an existing private backup
parent outside that root. Keep all writers stopped until archiving finishes.
Use no `sudo`, root/home-directory target or existing output archive.

```sh
set -eu
umask 077
gaovm_state_dir='/absolute/canonical/GaoVM-state'
gaovm_backup_parent='/absolute/private-backups'
gaovm_backup_dir="$(mktemp -d "${gaovm_backup_parent}/gaovm-backup.XXXXXX")"
tar -cpf "${gaovm_backup_dir}/state.partial.tar" --exclude='./run' \
  -C "${gaovm_state_dir}" .
tar -tf "${gaovm_backup_dir}/state.partial.tar"
mv "${gaovm_backup_dir}/state.partial.tar" "${gaovm_backup_dir}/state.tar"
(cd "${gaovm_backup_dir}" && /usr/bin/shasum -a 256 state.tar > state.tar.sha256)
(cd "${gaovm_backup_dir}" && /usr/bin/shasum -a 256 -c state.tar.sha256)
```

Inspect all exit codes **and diagnostics**; an unreadable file, skipped entry,
changing-file warning, low disk or checksum failure makes the backup incomplete.
Keep partial output for inspection and retry into a new directory; do not remove
source data. The destination must remain private and have enough space for the
current writable disks as well as immutable objects. This recipe uses ordinary
archive I/O, not APFS clonefile; budget for the copied logical file sizes.

Record alongside the archive: original state path and UID, backup date, exact
app/build version, public/driver/spec versions, SQLite `user_version`, external
file inventory and checksums, and the observed cold-boundary evidence. The
checksum detects corruption, not authenticity; trust only your own archive or
an authenticated source. Protect backups like guest disks: logs, guest data and
stored request environments may be sensitive. No encryption is supplied here.
Completion and a checksum are not a power-loss durability guarantee; use durable
backup storage and retain another verified copy before replacing original data.

## Validate and restore without mixing generations

Keep the original installation cold. Never extract over an existing state tree,
merge two backups, or replace a database while any process has it open.
First inspect the trusted archive listing and verify its checksum. Extract into
a newly created private inspection directory, not `/`, a home directory or a
running state path:

```sh
gaovm_restore_parent='/absolute/private-restore-checks'
gaovm_restore_dir="$(mktemp -d "${gaovm_restore_parent}/gaovm-restore.XXXXXX")"
tar -xpf "${gaovm_backup_dir}/state.tar" -C "${gaovm_restore_dir}"
/usr/bin/sqlite3 -readonly "${gaovm_restore_dir}/gaovm.db" \
  'PRAGMA integrity_check; PRAGMA foreign_key_check; PRAGMA user_version;'
```

Expect `ok`, no foreign-key rows and the recorded schema version. Inspect the
managed files and external file inventory as well: SQLite integrity alone cannot
prove that a disk or artifact exists or that its bytes are correct. Do not alter
sealed manifests to match catalog metadata or recalculate ownership receipts.
Artifact retention is live SQLite policy; its sealed publication receipt may
legitimately contain an earlier deadline. See [artifact ownership](ARTIFACTS.md).

This recipe restores under the **same canonical state path and UID**. With all
writers still stopped, preserve any current state tree by moving that exact
directory to a separately selected, unused sibling path. Retain it until recovery
is verified. Move the verified inspection tree to the original state path on
the same filesystem, keeping its private permissions and the matching external
files available. Do not use a broad cleanup command, delete the preserved tree,
or hand-edit stored IDs, absolute paths, versions or generation counters.
Cross-machine/UID moves, relocated external files and portable VM import are not
certified by this recipe.

Restarting a daemon is a separate operator action: startup migration,
reconciliation and desired-state recovery can mutate the restored data. Use the
matching signed binaries and normal ownership/census gates. After authorized
startup, check public VM/image/Operation/TestRun lists and `doctor`, then verify
artifact downloads and a controlled VM start/stop before restoring automation.
Doctor does not fix files, and a green doctor report is not guest boot or native
service acceptance. If recovery fails, keep both trees and the original archive;
do not retry by deleting runtime evidence or weakening validation.

For a pre-upgrade rollback, restore the complete pre-upgrade data and its matching
old app, not just the old binary or database. A newer catalog is rejected by an
older daemon; lowering `user_version` is not a downgrade. Preserve post-upgrade
data separately. Restoring an older snapshot intentionally loses later writes
and rewinds event/idempotency history: clients must establish a new snapshot and
cursor and review any write retry, rather than reuse later cursors or keys blindly.
There is no automatic installed-app rollback in the current implementation.

## Export diagnostic bytes through the public API

When the daemon is healthy, export individual diagnostics without copying its
private database or treating guest output as a host command:

```sh
gaovm --socket-path /absolute/state/run/api.sock vm artifacts VM_ID \
  --limit 50 --timeout-seconds 10 --json
gaovm --socket-path /absolute/state/run/api.sock vm download VM_ID ART_ID \
  --output-dir /absolute/existing/private-output --timeout-seconds 120 --json
gaovm --socket-path /absolute/state/run/api.sock test download TR_ID ART_ID \
  --output-dir /absolute/existing/private-output --timeout-seconds 120 --json
```

Follow `next_cursor` for every owner page. Use real resource IDs; exports retain
the artifact metadata and verified byte receipt, but are not VM/catalog backups
or restorable TestRuns. The downloader creates a private child directory,
validates owner/ID/URL associations and verifies exact length and SHA-256 without
overwriting existing output. Details and limits are in [ARTIFACTS.md](ARTIFACTS.md).
`vm logs` returns live log references, not an immutable log export or tail stream.

## Verification boundary

```sh
cd daemon/gaovmd
mise exec dart@3.9.0 -- dart test test/cold_state_backup_test.dart
```

The fixture archives/restores only fresh test-owned state, at the original path,
with all component writers closed. Real SQLite repositories, image publication,
managed writable disk provisioning, a collected pre-allocation cancellation and
sealed artifacts are used. It checks catalog/Operation/TestRun/event/outbox
preservation, increasing event sequence after reopen, unchanged external bytes,
image hashes, runtime asset resolution, private permissions, omitted sockets and
artifact bytes through real HTTP over a private Unix socket. Negative checks show
loss of a committed WAL event in a live main-file-only copy, rejection of a cold
database-only copy's missing payload/runtime assets, and non-mutating rejection of
a newer schema. No VZ driver or installed daemon/service is launched, and no live
installation is backed up or replaced. Real install/upgrade/rollback/uninstall,
GaoOS boot and native process-retirement acceptance remain required.
