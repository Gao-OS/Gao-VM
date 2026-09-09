# VM provisioning foundations (PR021)

This document records the implemented plan, disk primitives, durable create
acceptance, bundle store, and provisioning worker for M5.3/M5.4. They do **not
yet** constitute the installed daemon's public VM-create workflow. Daemon
startup composition remains integration work. Runtime asset binding now supports
completed provisioning and later specs that retain the original asset sources.
Production create and provisioning-cancellation acceptors can now be composed
through the public application services and are tested over real HTTP/UDS.
The accepted architecture and PRD remain authoritative.

## Pinned plan v1

`SqliteVmProvisioningPlanner.plan` reads a retained spec generation, a matching
pending/running `vm.create` operation, and its images in one SQLite transaction.
It can join the enclosing acceptance transaction; it performs no filesystem IO.

The immutable plan contains `plan_version: 1`, `vm_id`, `operation_id`,
`spec_generation`, `spec_digest`, `disks`, `kernel`, and `initrd`. The spec digest
is SHA-256 of the canonical serialized typed spec, using the image manifest's
canonical JSON encoding. Kernel/initrd are explicit nulls when absent.

Each disk retains its ID and writable flag. An external source retains its path
without moving, opening, canonicalizing, or assuming ownership of the file.
A managed source pins image ID/digest plus object name/digest/size and its role.
Standalone image types must match the requested role. GaoOS bundle references
resolve the manifest's `kernel`, `initrd`, and `root_disk` object names.
Plans validate their wire fields, digests, roles, and 1–32 unique disk IDs.
Terminal jobs must replay their stored plan, not regenerate it from newer specs.

## Disk materialization

`ManagedDiskMaterializer` creates one new child in a caller-owned, private staging
directory. The caller must serialize that namespace and keep its owned source and
directory handles open until completion. Both clone and fallback copy are bound
to descriptors; pathname replacement cannot substitute the source or destination.

On macOS, `fclonefileat` is attempted first, off the controller isolate. Only
unsupported/cross-volume errors select copy fallback. Permission, existing-file,
and space errors remain failures. New outputs are private files; source modes and
bytes are unchanged. Fallback IO is streamed, with cancellation/progress checks.
The resulting bytes must match the pinned size and SHA-256 before success.
Files and directory entries are flushed. Failure removes only this attempt's
new child; cleanup failures propagate rather than claiming successful cleanup.

Available space is measured against the held destination descriptor. Preflight
requires the logical disk size plus 1 MiB headroom. This is **not** a concurrent
reservation: the bundle worker still needs admission/reservation coordination.
Successful materialization is not bundle publication or Operation completion.

## Durable create acceptance

`SqliteVmCreateAcceptance.accept` owns its commit boundary and performs no
filesystem IO. One transaction creates the VM/spec, pending `vm.create`
Operation, pinned provisioning job, durable events, dedicated work outbox row,
and immutable idempotency response. Missing/invalid images roll back the entire
acceptance. Identical request retries return the acceptance-time snapshot even
after the operation becomes terminal; changed bytes conflict within retention.

Schema v5 adds `vm_provisioning`, keyed by VM and uniquely linked to the create
operation and retained spec generation. Work uses outbox topic `vm.provisioning`,
not lifecycle `vm.commands`; acceptance leaves lifecycle intent checkpoints at
zero. The VM remains desired=`stopped`, phase=`provisioning`, until the
worker publishes its bundle and commits completion. `requestCancellation`
durably records intent and emits one event without terminalizing the operation:
it does not claim that owned-file cleanup has already happened.

Registry startup skips provisioning VMs, and lazy activation rejects them before
operation recovery can mistake `vm.create` for an orphan. Lifecycle acceptance
and metadata/spec writes reject provisioning with `VM_OPERATION_CONFLICT`
(HTTP 409 at the resource API boundary). Legacy `defined` VMs remain supported.

## Bundle publication and worker recovery

`VmBundleManifest` v1 contains the pinned plan and a canonical digest of its
origin. Managed disk paths are derived as `disks/<disk-id>.raw`; arbitrary
relative paths are not accepted. The manifest is not a second active spec.

`VmBundleStore.withBundle` holds a descriptor-bound per-VM `flock` through its
callback, including the worker's terminal database commit. Roots must be private,
owned directories whose descriptors remain open. Session methods are used
serially and awaited within that callback. Filesystem calls reject an active
caller transaction. Different VMs may proceed concurrently.

Publication creates `.staging-<vm-id>-<operation-id>` with the origin manifest,
isolated disks, and logs/artifacts/runtime/nvram directories. It validates boot
objects against pinned sizes/digests and resolves external paths to owned,
nonempty regular files without taking ownership. Files and directories are
flushed before an atomic **no-replace** rename to `<vm-id>.gaovm` and parent
fsync. A mismatching or unknown publication is never overwritten or removed.

After a crash, incomplete staging is cleaned using only the known job layout;
unknown entries and symlinks fail closed. A published-but-uncommitted bundle
must match the origin and initial disk hashes before completion. Cleanup first
moves a verified publication back into staging, so a crash after removing its
manifest remains recoverable. External files are never part of cleanup.

Work claims use exact token/attempt/expiry fencing and periodic single-in-flight
renewal, including while waiting for the filesystem lock. Lost claims defer
without terminal database writes. Cancellation is checked before completion;
cleanup errors leave work retryable rather than falsely reporting completion.

Schema v6 adds immutable terminal proof (kind, manifest digest on success, and
completion time). Success atomically commits the proof, stopped VM, succeeded
operation, events, and work ACK. Failure/cancellation atomically tombstone the
provisional VM after owned-file cleanup while retaining diagnostics and foreign
key references. There is no standalone work ACK. The observed spec generation
remains zero until a later runtime actually applies it.

Completed work is not re-provisioned or verified against mutable disk hashes:
guest writes after boot are legitimate. Stored proof remains readable after
restart and is independent of the current image catalog or mutable disk bytes.

## Remaining integration contract

- Keep provisioning jobs separate from lifecycle `vm.commands` and its applied
  intent checkpoint; create/patch are not lifecycle adoption commands.
- Install the composed application services and daemon startup dispatch to the
  worker. Acceptance alone cannot finish create. The installed entrypoint still
  uses the legacy supervisor/RPC server.
- Install durable patch notification/adoption/recovery and the lifecycle
  acceptor described below alongside create/cancel. Do not replace missing paths
  with direct driver calls or in-memory-only notifications.
- Implement generation-specific bindings for changed boot/disk sources. The
  runtime resolver below supports original bindings and CPU-only changes, but
  rejects changed sources until their new durable bindings exist.
- Integrate admission/reservation coordination for concurrent provisioning and
  install the managed deletion adapter without touching external disks.

The focused tests cover plan pinning/validation, APFS clone isolation, exclusive
output creation, descriptor/path swaps, copy verification, cancellation, capacity,
and existing-file preservation. Apple Silicon and Linux runtime execution remain
separate platform gates; compilation alone does not prove native behavior there.

Database-only tests additionally verify job/acceptance durability, rollback,
idempotent replay/conflicts, cancellation intent, and provisioning readiness
gates. These contribute evidence for `VM-002`, `VM-009`, `API-005`/`API-006`,
`OP-002`/`OP-004`/`OP-007`, and `IMG-005`/`IMG-006`; none of those requirements is
declared end-to-end complete by this foundation.

Real child-process tests exit after staging, after publication, and during
cleanup after the manifest is removed. Worker integration tests cover durable
outcomes, lease loss/renewal, cancellation, low space, commit failure/retry,
unknown-file preservation, and completed mutable disks across database reopen.

## Runtime asset binding

`SqliteVmRuntimeAssets.withAssets` resolves the requested retained spec generation
from SQLite and verifies successful provisioning proof against the bundle origin.
It rejects provisional, deleting, deleted, and stale-driver-generation targets.
Kernel and initrd use their distinct pinned object roles even when both reference
one GaoOS image. Immutable boot objects are size/hash verified; managed writable
disks are checked as nonempty owned regular files, not rehashed against the base
image after guest writes. External paths resolve to owned nonempty regular files
without becoming managed files.

`VmRuntimeConfigurationResolver.withConfiguration` maps that single typed asset
snapshot into driver configuration. `RuntimeDriverEffectAdapter.scopedConfiguration`
keeps the resolver scope open until the configure RPC finishes, including failure.
The scope holds the same per-VM filesystem lock used by provisioning and retains
owned descriptors. Private bundle directories, existing log/rotation leaves, and
managed EFI variable stores are validated; pathname bindings are rechecked before
handoff. These are point-in-time checks plus cooperative daemon namespace locking,
not protection against subsequent malicious changes by another same-user process.

CPU-only spec generations reuse the existing writable disks. Changes to boot or
disk source identities fail closed with `VM_SPEC_INVALID` until generation-specific
asset materialization is implemented. This resolver neither regenerates disks nor
claims that public durable patch or installed daemon startup is complete.

Focused tests cover the public composition from completed provisioning through
the real asset resolver and configuration mapper into a fake driver, role-specific
boot bytes, retained generations, guest-mutated disks, scope release, unsafe path
rejection, and stale/deleting targets. Real Apple Silicon VZ configuration and
Linux native filesystem execution remain separate platform gates.

## Public create and provisioning cancellation

`VmApplicationService.composed` accepts independent create, patch, and lifecycle
acceptors; the existing combined adapter constructor remains compatible.
`SqliteVmCreateAcceptance` implements the create boundary directly. Missing
referenced images produce `422 VM_SPEC_INVALID` without retaining a provisional
VM, operation, or idempotency response.

`SqliteVmProvisioningCancellation` implements cancellation for active provisioning
jobs only. It rejects other operation kinds rather than directly terminalizing
work whose cleanup it does not own. A future operation router must dispatch
other cancellable kinds to their responsible services.

Schema v7 links each non-cancellable `operation.cancel` action to its target
provisioning operation with foreign keys and immutable linkage. Acceptance
atomically records the intent, pending action, link, events, and idempotent
response. The target remains pending/running. The existing provisioning worker
is the only cleanup consumer; it completes all linked cancellation actions in
the same fenced transaction as target cancellation, VM tombstone, completion
proof, events, and work ACK. Cleanup or commit failure leaves both operations
nonterminal for recovery. Legacy internal cancellation without an action still
works. Same-key retries replay the original acceptance even after completion;
new cancellation requests after target completion return
`409 OPERATION_NOT_CANCELLABLE`.

HTTP/UDS tests exercise create/restart/replay, invalid-image rollback, two Linux
image creates through isolated managed-disk publication, and distinct target
and cancellation-action GET/wait results before and after worker cleanup. These
tests compose the public services explicitly; they do not establish installed
daemon startup, runtime boot, patch, lifecycle, or CLI completeness.

## Lifecycle acceptance composition

`SqliteVmLifecycleAcceptor` composes the existing controller-gated lifecycle
transaction into `VmApplicationService.composed`. It checks a read-only durable
idempotency replay before registry activation, allowing retries even after a
successful delete has tombstoned the VM. A lookup miss does not reserve a key:
the actual acceptance transaction checks it again under the controller's
durable-write gate. If concurrent completion removes or retires the target
between lookup and acceptance, the adapter rechecks the committed replay before
returning the missing/closed-target error. Unknown targets and conflicting
request bytes do not create another intent.

`SqliteIdempotencyRepository.lookup` shares exact-byte hashing, conflict,
unfinished-reservation, and expiry semantics with `execute`, but never reserves,
deletes, or extends a key. Expired completed responses are misses; unfinished
reservations remain protected regardless of age.

Lifecycle acceptance creates durable operation/command/event state only; it
neither dispatches nor waits for runtime effects. Registry construction must use
the same SQLite catalog and its durable intent recovery repository. The daemon
entrypoint still needs to install the dispatch loop described below.

Focused lifecycle tests include real HTTP/UDS acceptance for all five actions,
same-key concurrency, cold-catalog delete replay, a delete finishing between
replay and registry lookup, rejected caller transactions, and invalid replay
correlation. Durable deletion fixtures test acceptance semantics only; they do
not claim runtime stop or managed-file deletion coverage.

## Patch acceptance and condition waits

`SqliteVmPatchAcceptor` commits OCC metadata/spec changes, image-reference
existence, manifest, architecture, and boot/disk role checks, a non-cancellable
patch operation, and the FIFO command/event
outbox atomically under the controller acceptance gate. Idempotency includes
`If-Match` as well as request bytes; committed responses replay without activating
a controller. Delivery waits behind an unfinished lifecycle, adopts the spec
without driver IO, and completes the patch operation without replacing the
lifecycle operation. Recovery validates that retained lifecycle against the last
applied non-patch intent. Tests cover transaction rollback, competing revisions,
replay, deferred dependency recovery, and durable adoption/redelivery.

`SqliteVmConditionWaiter` reads committed VM state and uses durable events only
as wakeups. Runtime and guest-agent waits use one end-to-end timeout budget,
including the application service's initial lookup; stopped VMs cannot satisfy
agent readiness. Missing/deleted resources, feed errors, rollback visibility,
cursor/read deadlines, and subscription cleanup have focused coverage.
`guest_service_ready` is explicitly unsupported until persisted service status
exists. Changed boot/disk source materialization and installed-daemon composition
remain open; these adapters alone do
not establish all PATCH/readiness requirements.

## Managed deletion

`SqliteVmManagedFileEffectAdapter` requires a stopped, lease-free durable delete
checkpoint and successful provisioning origin proof. Under the per-VM bundle
lock it validates known content, moves the bundle into a stable private deletion
quarantine, and removes only proven managed disks, logs, and managed EFI state.
Mutable guest disk bytes are not compared with the original image hash. Retries
can resume partial cleanup, including under a later delete operation.

External paths and base images remain untouched. Unknown content, linked
artifacts, and missing successful provisioning proof fail closed. Artifact
retention and deletion of unbound legacy bundles remain integration work. The
adapter does not establish driver exit: runtime composition must confirm exit
before releasing leases and invoking this effect. Thirteen focused tests cover
proof, leases, symlinks, unknown content, mutable disks, EFI, and retry behavior.

## Daemon dispatch and admission prerequisites

`VmProvisioningDispatchLoop` consumes bounded provisioning batches automatically
(100 jobs per pass, 250 ms between completed passes by default). It prevents
overlapping passes, reports job outcomes and claim failures, and retries failed
claims. Close cancels the next timer and waits for publication and terminal commit
to finish; owned roots and SQLite must remain open until that drain completes.
Tests use real managed-image creates, a one-job batch limit, injected claim failure,
and a held terminal transaction to verify automatic progress and shutdown drainage.

`VmCommandDispatchLoop` repeatedly runs bounded lifecycle claim passes (100 heads
per pass, 250 ms between completed passes by default). It never overlaps passes,
retains per-VM delivery outcomes for logging, and reports infrastructure failures
before retrying. Startup is idempotent; close cancels the next timer and awaits
in-flight adoption/ACK. Initiate loop close before registry shutdown, then await
both while SQLite remains open: a pending adoption may need controller
cancellation to unblock, and its claim release still needs the database.
SQLite integration tests cover FIFO continuation, failed-delivery retry, claim
failure/recovery, production timers, and shutdown during a claimed delivery.

Registry shutdown starts controller cancellation before draining an existing
reconciliation. A queued reconciliation rejected by closure is expected; actual
controller cleanup failures remain errors, retain controllers, and allow retry.
Regression tests cover a blocked effect, a rejected queued reconcile, and a failed
lease cleanup followed by successful shutdown retry.

This lifecycle loop does not run provisioning or reconciliation. The installed
daemon must compose those responsibilities and report their failures independently.

`VmRegistry.reconcileTick` scans the catalog, excludes provisioning VMs, and
includes active controllers omitted from the catalog so completed deletions can
be retired. It starts at most one reconciliation job per VM without waiting for
runtime completion. `reconcileVm` exposes the same coalesced job for callers that
need to await a particular VM. Each job waits for that controller to become idle
before comparing its execution state against the durable recovery checkpoint.
If state changes during the asynchronous guard, a later tick retries; a stable
checkpoint error remains observable. Unacknowledged lifecycle backlog keeps its
existing recovery precedence. Shutdown cancels controllers and drains both catalog
scans and per-VM jobs before SQLite may close.

Tests cover slow-VM isolation, repeated-tick coalescing, provisioning exclusion,
per-VM activation failure, deletion retirement, shutdown during catalog IO,
transient versus stable checkpoint mismatches, and resumption after backlog ACK.

`VmReconcileLoop` drives these scans immediately at startup and every five seconds
after each completed scan. It coalesces scans, not VM runtime work, and routes
catalog failures separately from correlated per-VM errors. Start is idempotent;
close cancels the next timer and drains only its current scan. Initiate loop close
and registry shutdown before awaiting both so pending controller work is cancelled
and drained while the catalog is still open. The timer adapter is not yet wired
into the installed daemon entrypoint.

`SqliteHostCapacityCatalog` resolves CPU/memory/disk accounting from the requested
retained spec, rather than relabeling current catalog quantities with an older
generation. Scheduler acquire and explicit admission pass the execution generation;
lost-lease cleanup uses the active generation when available. Recovery accounts
for the durable execution checkpoint, not a newer unadopted intent. The simpler
repository-only catalog rejects unavailable generations. Native host metrics and
disk reservation calculation still need production composition.

`MacOsHostMetricsSource` samples host CPU count, `hw.memsize`, and Mach VM page
statistics without shell commands; native memory calls run off the controller
isolate. Available memory is an estimate of free plus inactive pages, capped by
physical RAM. Mach already includes speculative pages in its free count, so they
are not added again. Inactive pages are not guaranteed immediately reclaimable;
configured memory budgets and admission headroom remain necessary.

Filesystem capacity uses the held owned storage directory's descriptor. The caller
must supply an unmanaged-driver inventory counter; no zero-count fallback is
assumed. Sampling failures, invalid negative inventory counts, closed storage,
and a five-second sampling deadline produce typed retryable
`HOST_RESOURCE_EXHAUSTED` failures rather than fabricated capacity. The inventory
callback must be read-only: a timeout discards its result, not its underlying work.
Live tests on the Intel macOS host compare native total RAM with `sysctl` and check
CPU/disk sampling and failure paths. Apple Silicon execution, inventory wiring,
and installed daemon composition remain separate gates.

Host lease recovery must run once before controllers become active: it replaces
stale host leases and must not be called on the periodic reconcile tick. These
prerequisites do not yet replace the legacy executable or prove end-to-end startup.
The focused admission and dispatch tests contribute to `SCH-001`, `SCH-004`,
`RUN-004`, and `OP-002`/`OP-007`; the corresponding full release gates remain open.

`MacOsDriverInventory` provides read-only same-effective-user process snapshots
and exact-PID inspection using macOS libproc off the controller isolate. Matching
requires the full caller-canonicalized executable path, not a basename. Identity
includes PID, UID, executable path, and kernel start time at microsecond precision;
managed-process exclusion compares that entire identity, so PID reuse alone cannot
exclude a new process from accounting. Inspection brackets path lookup with BSD
identity reads. Exited/zombie processes are absent; inspection errors are not.

Snapshots retain unresolved PIDs and refuse capacity counting while any remain.
This is deliberately conservative: a live process with an unavailable executable
path (observed on this host after application updates) cannot safely be assumed
unrelated. Enumeration overflow and a five-second deadline also fail closed.
Snapshots are observations, not atomic reservations or authorization to signal a
PID later. This layer never reads process arguments or sends signals. Live tests
exercise the current process and an owned child through confirmed exit; portable
tests cover full-identity exclusion and unresolved-count rejection. Startup
teardown, unknown-process policy, and production admission wiring remain
unfinished; Apple Silicon execution is still required.

On macOS, `DriverProcessManager` now canonicalizes the executable before launch
and captures its kernel identity after installing the owned process session and
output drainage. Missing/mismatched identity or inspection failure fails spawn
through the existing confirmed-exit compensation path. Runtime metadata v1 gains
an additive `process_identity` object containing PID, UID, executable path, and
kernel birth time; `created_at` remains diagnostic wall-clock time, not identity.
The manager exposes an immutable set of full identities for live owned sessions
and excludes exited sessions even while runtime-file cleanup is pending.

Real subprocess tests compare recorded identity against a fresh native lookup,
exercise two independent drivers, confirm exclusion after exit, and reject an
interpreter wrapper whose actual executable differs from the requested binary.
Non-macOS fake-runtime paths retain metadata without native identity. Legacy
records likewise lack this evidence and must not authorize PID-only signaling.
`DriverRuntimeMetadata` validates the version, resource IDs, positive generation
and bounded PID/UID values, absolute paths, timestamp, and agreement between the
outer record and nested process identity. Legacy records without identity remain
readable; an explicit malformed/null identity is rejected instead of downgraded.
The writer uses the same validator before publishing metadata.

Recovery callers can load through an owned, private generation-directory handle.
Loading uses a no-follow owned regular-file descriptor with a 64 KiB streaming
bound, checks VM/generation and expected executable/bundle/socket bindings, and
rechecks descriptor/path bindings after reading. Missing metadata returns unknown;
neither successful decoding nor a missing file proves that a live process may be
signaled or that a former process exited. Tests cover malformed/contradictory
records, legacy records, binding mismatches, oversize and symlink rejection, and
metadata emitted by a real process-manager launch. Identity-checked teardown
remains unfinished.

`DriverRuntimeDiscovery` now scans a caller-owned private runtime root and obtains
expected generation ceilings, executable paths, and bundle paths from a catalog
resolver. It returns validated records separately from missing metadata, missing
catalog bindings, unknown entries, and invalid metadata. Future/noncanonical
generation names and symlinked VM directories are not accepted. VM-level owner
marker names are ignored only when they identify owned, private, empty directories;
the reserved `api.sock` root name is left to API socket ownership checks.

Directory-name enumeration is capped at 4096 entries per directory and bracketed
by held-descriptor/path checks; each metadata file is then opened through owned
directory handles. Enumeration is not an atomic filesystem snapshot. The caller
must provide exclusive startup ownership and keep the root open for the scan;
this scanner does not acquire the daemon owner lock itself. Catalog failures abort
discovery instead of becoming an empty result. No scan deletes files, signals
processes, releases leases, or proves that a runtime is stopped. Tests cover
unknown-file preservation, missing bindings/metadata, future generations,
symlink and fake-marker rejection, and two real process-manager generations.
Installed startup composition and handling of unresolved discovery remain open.

`DaemonOwnership` provides a nonblocking exclusive OS file lock on the persistent
`.gaovmd.lock` file in the private state root, separate from the runtime root.
Only contention returns no owner; open, ownership, and lock failures propagate.
The shared filesystem lock primitive retains its blocking mode for image/bundle
stores and adds a nonblocking mode for daemon admission. Lock descriptors are
close-on-exec; release closes the descriptor but never unlinks the lock file.

Ownership verification checks that the state directory remains private and that
the root and lock pathname still reference the held inodes. These point-in-time
checks complement cooperative exclusive ownership; they cannot prevent a later
malicious same-user namespace change. Callers keep the root and ownership open
through startup recovery, runtime work, and complete shutdown. Tests cover
contention, release/reacquisition, lock-path replacement, permission changes, and
kernel release after an owning subprocess is killed. The HTTP runtime fixture
now holds ownership before lease recovery until after shutdown. The installed
daemon entrypoint still needs this ownership and recovery composition.

Driver metadata now uses `AtomicJsonFile.durable`: file flush and atomic rename
are followed by required parent-directory sync. Open/sync failure is propagated,
even if the new bytes are already visible; it does not imply rollback to the old
file. Legacy `AtomicJsonFile` callers retain their existing best-effort behavior.
Fault-injection tests verify the uncertain-publication result and that process
manager spawn compensation confirms child exit and removes its runtime directory
before a later generation can start. A native successful sync is exercised too.
This closes the metadata-file parent-sync gap, not the entire startup durability
contract: runtime-directory ancestor publication and crash-before-metadata still
need recovery coverage, and missing metadata remains an unknown process outcome.

Native process identity now also captures the kernel PID version, bracketing
executable/BSD identity inspection with version reads. Metadata persists this as
optional `process_identity.pid_version`; older records remain readable without
inventing a version. Full-identity equality includes this value. The ABI is taken
from [Apple's process-identity definitions](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h)
and checked by live tests on this macOS host.

`MacOsDriverSignaler` requires a versioned identity and permits only TERM/KILL.
It first rechecks the full identity, then uses `proc_signal_with_audittoken`, not
PID-only `kill`. The [Apple kernel implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c)
resolves and retains the audit-token target when signaling; the wrapper reports
errno directly as its return value. A stale target returns false; permission and
inspection failures remain errors. No timeout abandons this mutating native work.
The caller must establish generation ownership and keep it until the call settles.
Tests signal only owned child processes and verify stale-version rejection and
real TERM delivery. This primitive does not confirm exit, clean runtime files,
release leases, or implement startup escalation. Missing native APIs fail rather
than falling back to PID-only signaling; minimum-macOS/Apple Silicon release
verification and full startup recovery remain open.

`MacOsDriverExit.waitForExit` adds bounded, event-based exit observation using
`kqueue`/`kevent64` with `EVFILT_PROC` and `NOTE_EXIT`, off the controller isolate.
It registers the process event, checks the registered PID against the expected
full versioned identity, and distinguishes confirmed exit, timeout, and identity
change. Native registration reporting an absent PID and an already-queued exit
event cover exit-before/during-registration races. An identity mismatch is not
promoted to exit. Interrupted waits retain the original monotonic deadline, and
the queue and native buffers are closed before the future completes.

Live child-process tests cover timeout while still running, stale-version
rejection, main-isolate timer progress, TERM followed by confirmed exit, and a
process already reaped before observation begins. The observer neither signals
nor releases resources. Non-child/orphan execution on the minimum supported
macOS and Apple Silicon remains a release gate. The startup components below
build on this primitive; installed lease-recovery composition remains open.

`DriverStartupTeardown.terminateRecorded` now composes ownership verification,
native versioned signaling, and exit observation for catalog-bound discovery
records. Before starting any process work it rejects unresolved discovery,
missing PID versions, and duplicate PID claims. Each recorded process gets an
initial 20-second orphan-exit window, then TERM with five seconds to exit, then
KILL with five seconds for confirmation. Tests use shorter explicit deadlines.
Identity change is an error, not permission to signal a replacement process.

Ownership is verified before work and each signal. Different records proceed
concurrently; an error does not return until every already-started teardown has
settled, so callers cannot release ownership while another signal is in flight.
The coordinator neither deletes runtime files nor resets leases. Completion
proves exit only for the supplied records, not absence of unrecorded processes.
Live tests cover unresolved/legacy/duplicate preflight rejection without killing
a child, TERM completion, ignored-TERM KILL escalation, and failure drainage
while another VM finishes cleanup. Installed startup must still compose full
inventory, owned runtime cleanup, and lease recovery in the required order.

`DriverStartupRecovery.recover` now provides that pre-lease barrier for canonical,
catalog-bound generation directories. It verifies that daemon ownership covers
the same state root, reads private empty ownership markers, and requires a
complete process inventory with no unresolved or unrecorded drivers. After
confirmed teardown it rechecks inventory, metadata, and ownership tokens before
serialized filesystem cleanup, then checks discovery and inventory again. It
does not modify leases; callers must await success before `HostScheduler.recover`
or controller activation, keeping daemon ownership held throughout.

Generation cleanup removes only recognized metadata/temp files, the driver
socket, and empty ownership markers. Unknown content is preserved in quarantine;
VM-parent markers are never recursively deleted, and symlink quarantine paths
are rejected. Retained cleanup tokens allow retry after the last marker was
removed but the empty quarantine remains. Native-child tests cover exit before
cleanup, unresolved inventory before/after exit, and changed metadata preventing
cleanup. The inventory boundary in these tests is scoped to the test child;
they do not establish complete host census or daemon-restart acceptance.

The installed entrypoint still uses the legacy supervisor. Crash-before-metadata,
discovery of partially cleaned quarantines after daemon restart, unrecorded
process resolution, and the complete AC-04 two-VM restart gate remain open.

Lease-loss callbacks now support asynchronous acceptance: the scheduler retains
the notification until the receiver completes, retries rejection, and fences late
completion against replacement leases. Shutdown cancels retries and drains active
receivers under its existing timeout, so their dependencies must remain open until
the drain finishes. Receivers still need to fence their own already-running work;
replacement of a lease cannot cancel a callback already executing.

The controller distinguishes a completed start from a proposed completion skipped
because host-lease promotion failed. A late running-lease failure preserves terminal
operations while requesting generation-correlated driver cleanup; an uncommitted
start still fails. Focused tests cover both cases, asynchronous rejection/retry,
shutdown drainage, and stale success/failure after a replacement acquisition.

Runtime acquisitions bind loss notifications to the generation allocated by the
controller, retaining that identity across renewals and retries. Direct/recovery
reservations carry no runtime generation and cannot authorize killing a driver.
`VmRegistry.handleHostLeaseLost` only submits to an already-active controller;
the `HostLeaseLost` reducer command fences both active driver and spec generations.
Startup/recovery operations fail, completed operations remain immutable, and active
stop/kill/delete operations continue their cleanup. Lease release remains a later
termination effect, not an effect of the loss notification itself. A failed durable
batch does not prevent driver kill, and its proposed operation failure is retried.

Runtime lease payloads persist an optional positive `driver_generation`. Legacy
unbound payloads remain readable. A bound lease continues to count against host
capacity after TTL expiry, including across SQLite reopen and before its renewal
timer observes the loss. Admission cannot resurrect or replace an expired bound
lease; a different runtime generation also cannot replace its ownership. Unbound
reservations retain their expiry behavior.

Loss delivery first retains a generation-fenced cleanup reservation, then calls
the receiver. Retention failures retry while the expired runtime allocation still
counts against capacity. Cleanup reservations cannot be promoted back to running.
Confirmed release cancels loss retries and drains any retention write already in
flight before deleting the lease, preventing late hold resurrection. It does not
wait for the loss receiver, which can itself cause release. Tests cover the TTL
window, reopen, stale generations, retention failure/retry, and concurrent release.

The HTTP fixture composes this callback, but installed startup wiring remains open.
Startup must confirm previous-owner driver teardown before replacing reservations
through `recover`; that repository method does not itself inspect processes.

The runtime adapter releases the owned driver process and runtime files before
dispatching either `DriverExited` or `DriverChannelClosed` to the controller.
The factory release contract requires confirmed process exit; channel EOF alone
cannot authorize capacity release. Cleanup failures retain adapter ownership,
report a correlated `DriverProcessRelease` effect failure, and surface through
event drainage. A later kill/reconcile retries cleanup and only then reports the
saved terminal observation. Adapter close likewise retains failed work for retry.
If a newer stop/kill takes ownership during cleanup, terminal delivery uses that
operation while retaining the original driver generation fence.
Tests hold process release while checking that no terminal command is delivered,
allow another VM's events to progress, and exercise failed cleanup and shutdown
retries. Real process-manager tests verify confirmed exit and runtime-file cleanup;
the HTTP lease-loss scenario remains covered with the reordered boundary.

## Public runtime integration evidence

`sqlite_vm_runtime_http_test.dart` composes the public HTTP/UDS server, durable
create/lifecycle/patch acceptors, provisioning/command/reconciliation loops, SQLite host
leases, runtime asset resolver, effect runner, registry, and process manager.
Through HTTP it creates two managed-disk VMs, waits for durable create and start
operations, queries running state, replays an idempotent start, and stops one VM.
The two drivers are real separate subprocesses with distinct PIDs. Injecting
SIGKILL into VM-A's owned driver causes automatic recovery to generation 2 while
VM-B retains its original PID, generation, and running state. Managed disk paths
remain separate and contain the expected source bytes.
It also waits for `runtime_running` over HTTP and patches VM-B's CPU count while
running: the new spec generation is persisted, observed/driver generations remain
unchanged, and `restart_required` is true without restarting VM-B.
Removing VM-A's recovered lease through the real repository triggers its fenced
loss handler and stops its driver without restarting it or changing its original
successful start operation. VM-B retains its PID/generation. The test awaits both
the durable cleanup event and adapter cleanup drainage before counting processes.
Crash recovery is observed through public SSE with `Last-Event-ID`. Deleting the
remaining running VM stops its driver, removes its managed bundle, emits
`vm.deleted`, and replays the original delete acceptance while preserving its
peer's bundle and the base image.

The subprocess fixture substitutes for Virtualization.framework, and host metrics
are synthetic. Images are imported directly during setup; guest-service readiness
has no persisted implementation.
This evidence contributes to the first vertical slice and `RUN-001`/`RUN-002`/
`RUN-003`, `API-005`/`API-006`, and `IMG-005`. It does not prove installed daemon
startup, daemon-process restart, CLI migration, public image operations, native
admission metrics, full lease-loss safety, or actual Apple Silicon VZ boot.
