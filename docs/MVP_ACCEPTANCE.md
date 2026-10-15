# MVP acceptance ledger

Checked against [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md),
[PRD.md](PRD.md) and [ARCHITECTURE.md](ARCHITECTURE.md) on 2026-10-13.
The ordinary local matrix baseline is `b75b5a1` on local `main`, including failed-VM
retention, the `83bdc80` multi-VM smoke recipe and the independently bounded
host-guard and artifact-recovery scenarios. The Guest development entry was
accepted and updated after `c605e51` on 2026-10-14. The two interface choices were
accepted on 2026-10-15; the legacy CLI component checkpoint is recorded below.
Earlier checkpoints remain below as historical evidence, not current decisions.

**The Multi-VM Agent Testing MVP is not release-ready.** This ledger distinguishes
implementation/test entry points from proof that the product works. A file,
test name, successful fixture, cross-build or signed package is not native
acceptance. The release scope remains all P0 requirements, the PRD's
non-functional/data rules, frozen architectural invariants and M0–M8; VM clone,
Flutter UI, MCP and other P1/Beta work are not prerequisites.

The user has deferred Apple Silicon execution to their own machine. No machine
switch, Chrome integration, launchd registration, installed-app replacement,
release publication or remote push is authorized by this ledger.

## Known implementation and scope gaps

1. **M6 native Guest acceptance remains unproved.** The user accepted a
   [default-off development entry](GUEST_DEVELOPMENT_ACCEPTANCE.md) on 2026-10-14.
   Explicit opt-in now connects the daemon launch policy, optional driver
   `guest.status`, authenticated per-generation bridge and P0 public Guest
   capability advertisement. Default launches remain Guest-disabled. Local
   compiled-driver/Unix/HTTP checks are not Apple Silicon/GaoOS acceptance;
   hello, UID/token, capability, generation and census guards remain mandatory.
2. **PR015 installed migration acceptance remains unproved.** On 2026-10-15 the
   user accepted one release cycle of [public-API-only legacy input
   compatibility](LEGACY_CLI.md). The client adapter translates command spellings,
   explicit real-ID binding and revision-checked configuration writes. It does
   not restore raw RPC, implicit/name-based `default`, unrestricted filesystem
   boot inputs, disk resize or public driver passthrough. The installed startup
   and migration acceptance in [the checkpoint](LEGACY_VM_MIGRATION.md) remains
   pending; implementing the client is not evidence for that native boundary.
3. **M8 installed upgrade/rollback remains unfinished.**
   [Packaging](MACOS_PACKAGING.md) assembles a new app without replacing an
   installed one; [the helper](MACOS_SERVICE.md) provides scoped native service
   actions, not an upgrade transaction. [Cold backup/restore](DATA_BACKUP.md)
   provides a manual same-path recipe, not an installed lifecycle transaction.
   DB migrations and conservative manual recovery are not proof of the planned
   install/update/uninstall and failed-upgrade rollback workflow. The plan does
   not require automatic rollback; the user accepted the [explicit cold operator
   lifecycle](proposals/MACOS_UPGRADE_ROLLBACK.md) on 2026-10-15, not automatic
   orchestration. [Executable component probes](COMPONENT_PROBES.md) and internal
   role/contract compatibility checks now provide a tested prerequisite. A
   [read-only Developer ID inspection entry point](MACOS_RELEASE_INSPECTION.md)
   adds signed identity/layout and whole-tree checks, not applied database or
   negotiated runtime evidence. Held cold preparation, metadata-preserving tree
   copies and [catalog/referenced-file inspections](MACOS_RELEASE_INSPECTION.md#source-read-only-catalog-and-referenced-file-inspections),
   plus [managed asset checks](MACOS_RELEASE_INSPECTION.md#managed-images-bundle-provenance-and-current-writable-bytes),
   now cover separate prerequisites, not their full transaction composition.
   The development-package trust choice, complete cold boundary, writer fencing,
   whole-state rollback and native acceptance remain
   unfinished, not waived by the proposal.

These are not all interchangeable with “tests not run”. In particular, a green
native boot would not itself complete Guest/TestRun acceptance, prove installed
migration or implement installed upgrade/rollback.

## P0 traceability index

All 94 P0 IDs from PRD section 8 are represented individually below. The following
entry points locate code and relevant checks; they do **not** certify coverage,
correctness or release completion for every ID. The final column states the
observation needed to close the requirement, including native evidence where
the PRD explicitly requires it.

Entry points:

- **Domain/catalog:** [models](../libs/gaovm_models/lib/src/),
  [model tests](../libs/gaovm_models/test/),
  [VM repository](../daemon/gaovmd/lib/src/vm_repository.dart),
  [application service](../daemon/gaovmd/lib/src/vm_application_service.dart),
  [daemon tests](../daemon/gaovmd/test/), [provisioning](VM_PROVISIONING.md).
- **Runtime/spec:** [reducer](../daemon/gaovmd/lib/src/vm_controller_reducer.dart),
  [process manager](../daemon/gaovmd/lib/src/driver_process_manager.dart),
  [driver source](../drivers/vz_macos/Sources/vz_macos/),
  [driver tests](../drivers/vz_macos/Tests/vz_macosTests/),
  [native recipe](NATIVE_VM_SMOKE.md).
- **Images:** [image store](../daemon/gaovmd/lib/src/image_store.dart),
  [image manifest contract](IMAGE_MANIFEST_V1.md), [VM provisioning](VM_PROVISIONING.md).
- **API/Operation/events:** [public handlers](../daemon/gaovmd/lib/src/resource_api_handlers.dart),
  [Operation service](../daemon/gaovmd/lib/src/operation_application_service.dart),
  [OpenAPI](../schemas/openapi/gaovm-v1.yaml), [events](EVENTS.md),
  [daemon logs](DAEMON_LOGGING.md), [VM logs](VM_LOGS.md).
- **Guest/TestRun/artifacts:** [guest source](../guest/gaovm_guestd/src/),
  [guest tests](../guest/gaovm_guestd/tests/), [host exec](GUEST_EXEC_DURABILITY.md),
  [TestRun](TEST_RUNS.md), [steps](TEST_RUN_STEPS.md),
  [collection](TEST_RUN_ARTIFACTS.md), [artifact retention](ARTIFACTS.md).
- **Scheduler/CLI:** [scheduler](../daemon/gaovmd/lib/src/host_scheduler.dart),
  [scheduler tests](../daemon/gaovmd/test/host_scheduler_test.dart),
  [public CLI](../clients/gaovm_cli/lib/gaovm_cli.dart),
  [CLI tests](../clients/gaovm_cli/test/), [guest CLI](GUEST_EXEC_CLI.md).

| ID | Implementation/check entry point | Required closing evidence |
| --- | --- | --- |
| VM-001 | Domain IDs; `resource_id_test.dart`, public create tests | Every public create returns an immutable, correctly prefixed ULID |
| VM-002 | VM application/handlers; public create/lifecycle/patch tests | Create/list/get/patch/delete through the installed public API |
| VM-003 | VM repository and ID-targeted API tests | Duplicate-name policy never changes resource identity |
| VM-004 | Resource handlers; catalog-scale and CLI selector tests | Filtered pages preserve selection and ordering |
| VM-005 | Typed model, schema and provisioning tests | Persisted specs pass the frozen typed/schema contract |
| VM-006 | VM model/repository/runtime tests | Public status reflects committed desired/observed/generation/error state |
| VM-007 | Lifecycle/managed-file deletion tests | Async stop/release/delete completes without a live driver or lease |
| VM-008 | Managed-file deletion and migration tests | External-disk bytes survive actual VM deletion |
| VM-009 | Registry intent/startup recovery and migration tests | Installed daemon restart restores the full catalog; AC-04 |
| RUN-001 | Multi-VM reducer/runtime tests; `--multi-vm` recipe | Two actual VZ runtimes run concurrently; AC-01 |
| RUN-002 | Driver layout/auth/log tests; runtime inspector | Distinct PID/socket/token/logs and scoped generation bindings; AC-01 |
| RUN-003 | Fake runtime/process recovery tests | Crash A while native B continues running; AC-02 |
| RUN-004 | Controller serial queue and acceptance tests | Overlapping commands cannot run concurrently for one VM |
| RUN-005 | Registry/public lifecycle tests; multi-VM recipe | Independent VM actions overlap without shared runtime state |
| RUN-006 | Lifecycle acceptance/idempotency/conflict tests | Retry start/stop/restart/kill yields reuse or stable conflicts |
| RUN-007 | Reducer, RPC and callback-fencing tests | Old or foreign callbacks cannot update a current generation |
| RUN-008 | Driver delegate/event and reconcile tests | Native runtime transitions update committed state without a status poll |
| RUN-009 | Heartbeat/watchdog/reconcile tests | Real failed heartbeats cause bounded, per-VM recovery |
| RUN-010 | Reducer/restart policy tests | Native `never`, `on_failure`, `always` outcomes match policy |
| RUN-011 | Restart limiter/reducer/transaction tests | Exhaustion commits stopped/failed, operation failure and permanent-failure event |
| SPEC-001 | Typed boot spec; Swift configuration tests | ARM64 Linux kernel boots on Apple Silicon |
| SPEC-002 | Kernel/initrd/cmdline mapping and import tests | Native configured boot inputs are applied unchanged |
| SPEC-003 | Admission and VZ configuration validation tests | Host/VZ CPU and memory limits reject invalid configurations |
| SPEC-004 | Model and Swift VZ configuration tests | Invalid memory alignment is rejected before native start |
| SPEC-005 | Typed disk mappings; VZ configuration tests | Native guest sees all configured virtio block disks |
| SPEC-006 | Image provisioning, external-disk and deletion tests | Managed isolation and external ownership survive native lifecycle |
| SPEC-007 | Shared/none network mappings; VZ configuration tests | Native NAT and no-network behavior match the spec |
| SPEC-008 | Model/provisioning MAC validation tests | NIC MAC remains stable across runtime generations |
| SPEC-009 | Graphics mapping/display tests; both smoke modes | Native graphics enabled/disabled and display ownership work |
| SPEC-010 | Serial controller/logging tests | Actual native guest serial bytes are captured per VM |
| SPEC-011 | Patch/adoption/generation tests | Running patch stages the spec until a new generation applies it |
| SPEC-012 | Patch and disk materialization validation tests | Unsupported resize cannot be reported as an applied hot patch |
| IMG-001 | Image store/manifest/provisioning tests | Atomic kernel/initrd/raw/GaoOS import through the public API |
| IMG-002 | Immutable image manifest and verification tests | Digest/architecture/type and bytes stay bound after reopen |
| IMG-003 | GaoOS manifest/provisioning tests | Version/build/channel are retained and applied to image selection |
| IMG-004 | Image atomic-publication/crash tests | Crash/failure exposes no partial registered image |
| IMG-005 | Managed disk/provisioning tests; multi-VM recipe | Three created VMs own separate writable disk copies |
| IMG-006 | Clonefile/fallback materializer tests | APFS clone and fallback preserve bytes, capacity and ownership |
| IMG-007 | Reference/deletion transaction tests | Referenced images cannot be removed or raced into deletion |
| API-001 | OpenAPI, router and API-client tests | All advertised `/v1` paths match the live implementation |
| API-002 | Public listener/socket ownership tests | Installed API uses only private HTTP/1.1 UDS; AC-10 |
| API-003 | OpenAPI loader/endpoint tests | Served JSON includes valid, resolved VmSpec references |
| API-004 | Handler/Problem/client contract tests | Every response is correlated to its request |
| API-005 | Application acceptance and CLI tests | Long actions return a durable matching 202 before completion |
| API-006 | Idempotency repository/acceptance/retention tests | Same key/body reuses work; incompatible reuse conflicts |
| API-007 | Patch acceptor/ETag/OCC tests | Concurrent stale revision writes cannot commit |
| API-008 | Problem models/handler/CLI tests | Stable status/code/retryability/details reach clients |
| API-009 | Catalog-scale/filter/pagination tests | Pagination and label/sort semantics hold across full catalogs |
| API-010 | VM/Operation wait and deadline tests | Explicit deadlines produce typed results or WAIT_TIMEOUT |
| API-011 | Outbox/feed/SSE/client-resume tests | Reconnection resumes committed sequences without gaps; AC-09 |
| API-012 | CLI public-UDS and packaged-client tests | Production CLI uses the public API, not driver/business shortcuts |
| OP-001 | Operation model/repository transition tests | Only valid durable state transitions commit |
| OP-002 | SQLite reopen and registry recovery tests | Installed restart preserves accepted operations and query results |
| OP-003 | Typed Operation model and repository tests | Identity/request/deadline/result/error survive persistence |
| OP-004 | Operation application cancellation tests | Cancellable work stops progressing and finishes durable cleanup |
| OP-005 | Cancellation-stage/conflict tests | Irreversible stages reject with OPERATION_NOT_CANCELLABLE |
| OP-006 | Operation/event/outbox transaction tests | Completion and its durable event commit together |
| OP-007 | Controller/acceptance/dispatch tests | Conflicting per-VM work cannot race execution |
| EVT-001 | Event repository/outbox tests | Sequence is monotonic across transactions and installed restart |
| EVT-002 | Event filters/feed/API tests | Persisted VM/Operation/TestRun filters return the correct events |
| EVT-003 | SSE subscriber-lag/resume tests | Native/installed disconnect resumes from the last consumed sequence |
| EVT-004 | Daemon/driver/runtime log tests | Applicable request/VM/Operation/generation IDs reach logs without tokens |
| EVT-005 | Serial/driver per-VM logging tests | Native parallel VM output cannot mix across log files |
| EVT-006 | Rotating log/backpressure tests | 10 MB/three-rotation policy does not block VM commands |
| GST-001 | Rust guest daemon CLI/service tests | GaoOS image installs and runs the optional guest daemon |
| GST-002 | VZ socket/bridge/Rust vsock components | Enable an approved path and prove actual bidirectional native vsock |
| GST-003 | Rust system/control and host session tests | Native negotiated health/system.info reach the authenticated host |
| GST-004 | Rust exec/host durable exec/public CLI tests | Native exit/stdout/stderr/duration reach the public result |
| GST-005 | Rust/host timeout/cancel tests | Native process groups retire before terminal timeout/cancel completion |
| GST-006 | Binary/spool/publication/artifact tests | Native large output is bounded and durably downloadable |
| GST-007 | Unavailable-guest/generic runtime tests | Guest unavailability does not break native VM lifecycle; AC-08 |
| TST-001 | TestRun application/repository/API tests | Durable public TestRun acceptance survives restart |
| TST-002 | Provisioning/start worker tests | Native TestRun creates its own VM from the selected managed image |
| TST-003 | Readiness worker/deadline tests | Native guest-ready wait distinguishes VZ running; AC-05 |
| TST-004 | Ordered step worker and guest exec tests | Native steps run in order through the original authenticated session |
| TST-005 | Step repository/result/model tests | Queried native step results preserve status and structured outcomes |
| TST-006 | Collection/public artifact tests | Native stdout/stderr/serial/driver/result artifacts are downloadable |
| TST-007 | Cleanup worker/delete/retain tests | Selected native cleanup policy reaches a proven terminal result |
| TST-008 | Failure-retention/always-delete tests | Failed native VM remains inspectable with its original error; AC-07 |
| TST-009 | Cancellation/step/cleanup recovery tests | Native cancellation stops later steps and applies cleanup policy |
| TST-010 | Parallel provisioning and TestRun ownership tests | Concurrent native runs from one image own independent VMs |
| SCH-001 | Host scheduler/metrics/admission tests | Real CPU/memory/disk observations bound boot admission |
| SCH-002 | Host limits/lease and capabilities tests | Configured maximum running VMs is enforced atomically |
| SCH-003 | Boot lease/recovery tests | Concurrent native boots cannot exceed the configured limit |
| SCH-004 | Lease/startup/generation recovery tests | Old leases are fenced and revalidated before new native admission |
| SCH-005 | Admission/Problem/public action tests | Resource shortage returns a stable retryable rejection |
| CLI-001 | CLI catalog/create/patch/delete tests | Real public API arguments, JSON, revision and resource bindings |
| CLI-002 | CLI lifecycle/wait/idempotency tests | Real start/stop/restart/kill/wait and stable local deadlines |
| CLI-003 | Image import/list/pagination CLI tests | Real image operations preserve import identity and list semantics |
| CLI-004 | Operation get/wait/cancel CLI tests | Typed public Operation correlation and cancellation results |
| CLI-005 | Guest exec CLI/durability tests | CLI completes an actual native authenticated guest command |
| CLI-006 | TestRun query/artifact/download CLI tests | CLI observes actual native TestRun success/failure/artifacts |
| CLI-007 | Public CLI help/output/protocol tests | All supported commands preserve stable JSON contracts |
| CLI-008 | CLI failure/signal/deadline tests | Non-success results produce documented stable exit codes |

## Milestone and acceptance-scenario boundaries

| Plan deliverable | Current boundary | Missing proof/work |
| --- | --- | --- |
| M0 contracts, IDs, errors, AGENTS | Frozen documents, typed IDs and schema set present | Keep implementation, docs and packaged protocol versions aligned |
| M1 catalog, WAL/outbox, repositories, old-data migration | SQLite/migration/reopen/crash components and one-cycle CLI adapter present | Installed startup/migration acceptance |
| M2 registry, queue, generations, fake runtime, restart, scheduler | Controller/admission/recovery components and tests present | Real parallel, crash, heartbeat and retry exhaustion evidence |
| M3 driver split, hello/auth, VZ queue/lane, delegate/display/serial/stop | Swift runtime/protocol/log/display components present | Native VZ queue behavior, boot/display/serial and stop escalation |
| M4 API, Operations, SSE, idempotency, OCC, conditional adapter | Public HTTP/UDS/application-service path present | Full installed path; unresolved M4.7 compatibility scope |
| M5 manifests/import/bundles/clone/reference/GaoOS profile | Managed publication/provisioning components present | Real GaoOS image and native isolated writable disks |
| M6 Guest protocol/daemon/session/waits/exec/TestRun/artifacts/E2E | Host/guest workers, transport fixtures and default-off development entry present | Native development path and GaoOS AC-05/06/07 |
| M7 public CLI | Source/compiled public-client tests present | Native Guest/TestRun transactions through CLI |
| M8 CI/app/plist/signing/upgrade/chaos/docs/release | Ordinary CI workflow, assembly/helper and smoke recipes present | Apple self-hosted execution, installed upgrade/rollback and first MVP release |

| PRD scenario | Available check | Closing boundary |
| --- | --- | --- |
| AC-01 | `e2e_macos14_happy_path.sh --multi-vm`; public API/private-file/inventory fixtures | Native run pending; per-VM generation identity is `(vm_id, generation)`, not globally unique integers |
| AC-02 | Fake crash/reducer/process-generation tests | Native A crash/B survival/restart/old-callback rejection pending |
| AC-03 | SQLite acceptance/replay/controller tests | Native duplicate-start single-driver observation pending |
| AC-04 | Startup/registry/lease/outbox recovery tests | Native two-VM daemon restart and no-orphan evidence pending; current smoke does not run this scenario |
| AC-05 | Authenticated socket readiness and deadline fixtures | Native Guest composition and real GaoOS readiness pending |
| AC-06 | Provisioning/step/collection/cleanup/public-download fixtures | Full native success-to-artifact-to-VM-deletion transaction pending |
| AC-07 | Failure retention overrides always-delete; collection/download fixtures | Full native failed guest exit and retained debug environment pending |
| AC-08 | Guest-disabled native smoke recipe and unavailable-guest checks | Native generic Linux execution and explicit unavailable error pending |
| AC-09 | Real public-UDS SSE cursor/reconnect/subscriber-lag tests | Installed/restart event history observation pending |
| AC-10 | Private ownership/socket/auth/log/descriptor tests | Fresh installed native launch and token/process-argument/log inspection pending |

## Cross-cutting requirements are not waived

The numbered feature IDs do not replace PRD sections 10–11, AGENTS invariants
or development-plan section 12. Their closing evidence must also cover:

| Requirement | Required evidence beyond an available component |
| --- | --- |
| Reliability | Real daemon/driver crash recovery, no untracked orphan, recoverable image/create/delete publication, terminal Operations and no duplicate dangerous effects |
| Consistency | Per-VM write linearization, cross-VM concurrency, monotonic revisions/sequences and one SQLite transaction for state/Operation/event/outbox |
| Performance | Release-host measurements excluding actual boot time: CRUD and status/list P95 below 250 ms; driver-to-durable-event P95 below 1 s. No such benchmark is certified here |
| Catalog/resource scale | At least 100 defined stopped VMs without 100 resident drivers; enforced atomic 128-defined-VM ceiling, including deleting VMs until tombstone; actual running limit determined by host budget |
| Resource control | Bounded guest output, non-blocking slow log/event subscribers, streaming image/disk IO and no whole-large-artifact memory load, including the real Guest transport |
| Security | Private 0600 UDS/0700 state, no TCP/public listener, no token in logs/args, canonical owned external paths and no automatic execution of guest output as a host command |
| Compatibility | Independent public/driver/VmSpec versions; additive `/v1` compatibility and new API version for breaking changes; installed role/protocol compatibility and migration acceptance |
| Retention | 30-day resource/event/Operation recommendations must be assessed separately from idempotency expiry. TestRun artifact expiry starts at completed_at: successful deleted environments seven days, failed/cancelled/retained environments 30; references and ownership still prevent deletion, and cleanup emits an event |
| Data ownership | Retained VMs require explicit deletion; referenced images survive; managed publication/migration/backup preserve external disks and original data on failure |
| Runtime invariants | Independent per-VM controllers/processes/generations, EOF/watchdog retirement, bounded restart/window/backoff, late-callback fences, responsive serial VZ queue and display lifetime separate from VM lifetime |
| Logging | Applicable VM/Operation/generation/request correlation, per-VM serial/driver separation and bounded rotation. DAEMON_LOGGING.md still excludes complete project-wide EVT-004 coverage; do not infer it from selected correlated records |
| Definition of Done | Success/failure and crash/timeout/cancel checks, relevant schema/docs, no driver work in handlers or implicit singleton, version/migration explanation and actual native evidence; a future PR must identify requirements and evidence rather than claim a fixture is release acceptance |

## Verification provenance

Previously completed reports inspected directly on this host:

- The post-idempotency daemon report records 1431 passes, one platform skip and
  zero reported errors **for a filtered run**, not the complete suite. It predates
  the failed-VM retention override. Two positive installed-daemon tests were
  excluded because native census could not resolve all executables. The
  `unresolved native census rejects startup before legacy migration` case was
  also excluded due its unresolved owned-child cleanup boundary. Do not treat
  any of those three checks as passing or rerun the unsafe child case casually.
- The subsequent failure-retention report records 187 relevant passes. It
  verifies that component boundary, not all daemon tests or native Guest work.
- The earlier CLI report records 154 passes. A fresh full rerun at `83bdc80`
  instead produced 153 passes and one default-30-second host-guard timeout.
  The failing test performed two source-program launches in one test budget;
  separate display/multi-VM cases retain each original exit/no-state assertion
  and each default 30-second budget. The repaired full CLI run completed with
  155 passes, zero skips and zero errors at the `7bc19b7` source revision, using
  the default test concurrency. Formatting and analysis also passed. This
  subsequent green run does not erase the reproduced earlier failure.
- JSON Schema/OpenAPI validation was rerun successfully for this audit.
- A subsequent test-only migration cleanup checkpoint preserves fixture state
  when an owned child's exit is unconfirmed and still retires sibling children.
  Filtered migration/helper coverage passed 17 tests, helper/packaged-daemon/
  launch-configuration coverage 12, packaged CLI four and cold backup four
  (34 distinct test names). Daemon analysis and formatting passed. The actual
  native executable-unlink case remains unrun; neither positive installed case
  was recertified. See [the migration checkpoint](LEGACY_VM_MIGRATION.md#owned-child-cleanup-checkpoint-2026-10-13).

### Ordinary local matrix refresh (2026-10-13)

The refreshed checks ran on Intel macOS 15.8.1 with Dart 3.9.0, Swift 6.2.4,
swift-format 6.2.3 and Rust 1.96.1. Swift/Rust and the unchanged Dart library/CLI
sources were checked before the daemon test repairs; the final daemon matrix,
formatting, analysis and AOT compilation cover the repaired source baseline.

| Component | Passed tests | Scope |
| --- | --- | --- |
| gaovm_models | 101 | Full package suite; zero skips/errors |
| gaovm_rpc | 5 | Full package suite; zero skips/errors |
| gaovm_api_client | 87 | Full package suite; zero skips/errors |
| gaovm_cli | 155 | Full package suite, default concurrency/timeouts; zero skips/errors |
| gaovmd | 1440 | Filtered suite, default concurrency/timeouts; one Linux-only platform skip, zero errors; three checks excluded below |
| Swift driver | 142 | Local component suite; zero failures; not native VZ/GaoOS boot acceptance |
| Swift service helper | 16 | Component/signing checks; registration actions mocked, no installed registration mutation |
| Rust guest | 195 | Local macOS suite; zero failures/ignored tests; Linux-only vsock suite executes zero cases here |

All five Dart packages passed lockfile enforcement, formatting and analysis.
Daemon and CLI AOT compilation passed. Both Swift packages passed strict lint
with the pinned formatter; the service helper's ARM64 release cross-build passed.
Rust formatting, warning-as-error clippy, locked tests, all-target host build and
Linux ARM64 static target check passed. JSON Schema/OpenAPI validation passed.
Neither ARM64 cross-build/check is execution on an ARM64 machine.

The final daemon run supplied the real Rust `host_publication_fixture`; its
integration cases were not skipped for a missing executable. Its only platform
skip was `Linux reports clone fallback without creating a destination`.
The three exclusions remain **unrun, not passing**:

- `installed daemon completes a pre-cancelled TestRun without client polling`
- `installed daemon serves the VM catalog over HTTP UDS`
- `unresolved native census rejects startup before legacy migration`

The native census fence was not bypassed and the actual executable-unlink case
was not rerun. No Chrome work, machine switch, installed service/app replacement,
native Guest acceptance or release publication follows from these results.

The refresh preserves, rather than erases, the reproduced failures:

- Initial daemon run: 1432 passes, one skip and five failed Supervisor tests;
  an instrumented rerun had 1431 passes and six failures including the Guest
  heartbeat timing race. Source fixture startup exceeded the existing
  connection budget under suite load; narrow imports reduced startup cost and
  keep the same actual hello, RPC, crash and recovery implementations.
- After those two repairs: 1434 passes, one skip and three crash-child deadline
  failures. Narrowing the runtime/collection child imports retained their exact
  crash checkpoints and exit/recovery assertions. Independent checks also
  showed reduced startup cost, not a native runtime boot correction.
- The next run: 1436 passes, one skip and one failed artifact-recovery test.
  Two independent manifest variants shared a default 30-second budget; a child
  outlived teardown and then reported a missing fixture directory. The variants
  now have separate default budgets. All artifact crash children are owned and
  joined before fixture deletion; an unconfirmed exit retains both directory
  and open database. Two new receipt checks failed before this change and pass
  afterwards, including a real child exit and a controlled missing receipt.
- Guest heartbeat isolation now holds only the first probe's scheduling at the
  external timer boundary. The real authenticated original channel, healthy
  Guest replies before/during the probe, matching VM/generation/Operation event
  and descriptor closure remain asserted. Default production Timer intervals,
  ping timeouts and shutdown timers are unchanged. Focused process coverage
  passed 30 tests; final artifact coverage passed 39, both included in the
  final 1440 daemon passes rather than added again.

Retained diagnostic reports are under `/private/tmp/gaovm-mvp-matrix.sUncEh`;
`daemon-final.jsonl` has a successful terminal receipt. The earlier red reports
remain separate. These local reports are not a GitHub Actions run, native
acceptance or notarized release evidence. Before release, rerun all ordinary
gates at the release revision, without hiding required checks, and attach their
complete outputs together with the native evidence.

### 2026-10-14 Guest development entry

The user accepted only the default-off Guest development entry, preserving all
authentication and generation guards. The entry and documentation were implemented
after `c605e51`; the legacy CLI and installed lifecycle choices remain open.

Local checks passed for this slice:

- 156 Dart tests across launch configuration, public system handlers, process
  manager, bridge client, host Guest session and committed Guest readiness;
  the manager test exercised the actual compiled Swift driver with opt-in on/off.
- The full Swift driver component suite: 145 tests, zero failures, including
  mutual hello, optional-capability rejection, wrong bridge token/generation,
  original-control watchdog and endpoint teardown.
- Dart formatting (254 files unchanged), analysis and daemon AOT compilation;
  pinned Swift 6.2.3 strict formatting/lint.
- 113 local Markdown links in the changed documentation resolved successfully.

These are local component/compiled-process checks, not an unfiltered daemon
matrix, installed launchd acceptance or native VZ/GaoOS evidence. The earlier
native-census exclusions remain unrun; the development flag cannot bypass them.
Apple Silicon/native closing evidence remains the user's separate test boundary.

#### Expanded ordinary Dart regression at `ba663e1`

After committing the Guest entry, all five ordinary Dart package suites were
rerun with their default concurrency and timeouts on 2026-10-14:

| Package | Passed tests | Scope |
| --- | --- | --- |
| gaovm_models | 101 | Full package suite; no skips/errors |
| gaovm_rpc | 5 | Full package suite; no skips/errors |
| gaovm_api_client | 87 | Full package suite; no skips/errors |
| gaovm_cli | 155 | Full package suite; no skips/errors |
| gaovmd | 1445 | Filtered suite; one Linux-only skip, no errors; the same three exclusions remain unrun |

All five reports contain successful terminal receipts. The daemon run supplied
the actual Rust `host_publication_fixture`; its integration checks were not
skipped for a missing executable. The 156 targeted Guest-entry checks above are
included in the 1445 daemon passes, not additional tests.

A read-only `/bin/cat` inventory snapshot still reported incomplete census with
five unresolved records and no matching executable. No unknown process was
modified or accepted as exited. The positive daemon-startup cases and the unsafe
executable-unlink case remain excluded as documented above. Reports are retained
under `/private/tmp/gaovm-guest-regression.Cl3Cm6`. This checkpoint does not rerun
native VZ/GaoOS, installed services or release checks, and does not accept either
the legacy CLI or installed upgrade/rollback interface choice.

Repeat the earlier scoped matrix checks from the repository root:

```sh
bash scripts/validate_contracts.sh
(cd clients/gaovm_cli && mise exec dart@3.9.0 -- dart format --output=none --set-exit-if-changed bin lib test tool)
(cd clients/gaovm_cli && mise exec dart@3.9.0 -- dart analyze)
(cd clients/gaovm_cli && mise exec dart@3.9.0 -- dart test --reporter expanded)
(cd guest/gaovm_guestd && cargo +1.96.1 build --all-targets --locked)
(
  export GAOVM_GUEST_FIXTURE="$PWD/guest/gaovm_guestd/target/debug/examples/host_publication_fixture"
  cd daemon/gaovmd
  mise exec dart@3.9.0 -- dart test --reporter expanded --name '^(?!.*(?:installed daemon completes a pre-cancelled TestRun without client polling|installed daemon serves the VM catalog over HTTP UDS|unresolved native census rejects startup before legacy migration)).*$'
)
```

These commands intentionally select the same daemon subset; they do not cover
the full unfiltered daemon/Swift/Rust/native release matrix.

## Release gate checklist

All ten PRD section 13 gates remain explicit:

| Gate | Current verdict | Required evidence |
| --- | --- | --- |
| 1 All P0 complete or approved scope changes | Not proven | Close the 94 entries and remaining implementation/acceptance gaps above |
| 2 OpenAPI/implementation contract alignment | Component validation only | Complete live handler/schema contract checks at the release revision |
| 3 All Dart unit/integration tests pass | Not proven | Unfiltered green release-revision runs; excluded native/cleanup cases are not passes |
| 4 Swift driver tests pass | Local component pass | 145 tests and strict lint passed for the Guest entry; rerun at the release revision |
| 5 Apple Silicon self-hosted E2E | Not run | Authorized host/runner execution; user owns current hardware testing |
| 6 Multi-VM/crash/restart/guest/TestRun/idempotency/event scenarios | Partial component coverage | Native AC scenarios and downloadable Guest/TestRun results, not only acceptance receipts |
| 7 Driver signing and virtualization entitlement | Assembly/static component coverage | Verify the actual executed native binary and its entitlements |
| 8 launchd install/uninstall/upgrade | Incomplete/unverified | Approved installed workflow, rollback implementation and native lifecycle checks |
| 9 No public driver.exec | Architecture/source boundary retained | Recheck exported routes and clients at release; Guest exec remains an application service |
| 10 README/PRD/OpenAPI/VmSpec/driver versions agree | Needs release audit | Signed release artifact version/role compatibility and documentation/schema parity |

Do not mark M6, M8 or the overall goal complete from this ledger. The user
accepted both one-cycle public-API CLI compatibility and the explicit cold
installed lifecycle on 2026-10-15; those choices no longer block implementation.
The Guest development entry was accepted on 2026-10-14.
Installed upgrade implementation and native/release evidence remain separate
required work, not silently waived deliverables.

## 2026-10-15 legacy CLI component checkpoint

The [one-cycle adapter](LEGACY_CLI.md), tested on top of `820a5bd`, uses the existing
public HTTP/Unix client only. Explicit alias binding, real catalog IDs, typed
configuration translation, revision/idempotency propagation, wrong-target
rejection, one composite local deadline and executable environment binding have
component coverage. There is no public/raw driver passthrough or singleton VM.

The **unfiltered CLI suite passed 167 tests**, with zero failures or skips.
The report ended with `success: true` at
`/private/tmp/gaovm-legacy-cli.ybrbkB/cli.jsonl`. CLI analysis and pinned Dart
format checks passed. These checks include existing compiled CLI launch cases,
but are not a new daemon/Swift/Guest matrix or installed/native acceptance run.
The unrelated UI lockfile is unchanged. The cold upgrade transaction remains
implementation work, not a passed gate.

## 2026-10-15 executable component evidence checkpoint

On top of `52d146e`, all four product entry points implement the standalone
read-only `--component-info` probe before state/runtime/service creation. The
[diagnostic contract and limits](COMPONENT_PROBES.md) distinguish actual component
roles/versions from bundle metadata, current database state and authenticated
runtime negotiation. Bounded subprocess capture confirms its own child's exit;
owned-file probes bind the parsed role to observed executable SHA-256 bytes.
Internal compatibility checks reject missing roles, mismatched versions/contracts,
unsupported catalog versions and development-only capabilities used as default
requirements. Frozen public/driver schemas and normal authentication are unchanged.

Local verification passed:

- Models: **103** tests; CLI: **168** tests, both unfiltered with zero skips.
- Daemon: **1,468** passed, **1** platform skip, zero failures. The same three
  installed/native-process exclusions documented above remain excluded; none is
  counted as passing. The Rust host publication fixture was enabled.
- Swift driver: **146** tests; service helper: **17**, zero failures. These are
  Intel process/queue/component checks, not VZ or Service Management activation.
- Dart analysis and pinned formatting, changed Swift strict formatting, public
  JSON Schema/OpenAPI validation and `git diff --check` passed.

Dart reports and the complete driver log are under
`/private/tmp/gaovm-component-probe.soVj3m/`; all Dart reports ended with
`success: true`. The UI lockfile remains unchanged. Probe/compatibility fixtures
do not certify a signed product release, applied catalog version, installed
upgrade, whole-state rollback, Guest readiness or native lifecycle acceptance.

## 2026-10-15 read-only release inspection checkpoint

On top of `4e8c5d4`, the [Developer ID inspection tool](MACOS_RELEASE_INSPECTION.md)
checks the explicit signed identity, actual entitlement/ARM64/bundle/service
layout, shipped contract versions and actual component evidence. Complete
before/after tree manifests include unknown files and empty directories.
The general ad-hoc upgrade trust choice is still pending; only the common
formal-signature inspection path is implemented here. No installed app, catalog
or service action was performed.

The focused **49-test** inspection/probe/compatibility/tree/child suite passed.
The real native negative case creates a controlled signed ARM64 C fixture,
verifies its ordinary signature, then proves the Developer ID requirement rejects
it without execution. The positive policy case replaces the external native
boundary and is not actual signed-product/ARM64 acceptance. Native plist decoding
uses bounded stdin, not a generated file. Malformed command inputs fail without
HOME or runtime files.

The complete daemon suite passed **1,495** tests, with **1** platform skip and
the same **3** explicitly excluded installed/native-process cases, zero failures.
Rust publication coverage remained enabled. The unchanged RPC and API-client
suites were also rerun: **5** and **87** passed, zero failures/skips. Reports
under `/private/tmp/gaovm-component-probe.soVj3m/` ended with `success: true`;
the latest daemon report is `daemon-release.jsonl`.

Dart analysis, pinned formatting, scoped local Markdown links and
`git diff --check` passed. The standalone inspection tool compiled to an Intel
AOT executable and its help command exited successfully; that artifact is not a
signed product release. The unrelated UI lockfile is unchanged. No fresh Swift
or hardware matrix is claimed by this subsequent Dart-only checkpoint.
Actual applied catalog/runtime negotiation, cold acquisition, complete durable
paired snapshots, startup/writer fencing, publication, validation/commit,
whole-state rollback/recovery and uninstall remain unfinished M8 work.

## 2026-10-15 cold-state preparation checkpoint

On top of `97d0442`, the internal
[cold preparation components](MACOS_RELEASE_INSPECTION.md#cold-state-preparation-library)
bind a read-only owning-helper status query to freshly inspected app bytes,
retain actual private state ownership, and independently reject live/unresolved
daemon/driver processes or other same-user state references. Service status is
rechecked after native observations. Refused acquisition releases its own lock;
failed revalidation retains an acquired lock until explicit close. No catalog,
desired state or installed app is changed; the persistent ownership lock may be
created and is never removed by these components.

The **87-test** focused preparation/inspection/ownership suite passed with zero
failures/skips. Real isolated open-file children prove both directory/file
observations and refusal until confirmed exit. Native service/census observations
in the lease policy tests are replaced at the external boundary; they do not
prove actual Service Management or an unconstrained host census. Changed app
bytes prevent a subsequent helper execution. Incomplete native output, foreign
service identity, re-registration, lock contention and replaced state identities
refuse progress. Native partial-search status 1 retains reported occupied PIDs.

The complete daemon regression passed **1,529** tests, with **1** platform skip,
zero failures and the same **3** explicitly excluded installed/native-process
cases. The Rust host publication fixture remained enabled. Both JSON reports in
`/private/tmp/gaovm-cold-preflight.vGA4jo/` ended with `success: true`. Dart
analysis, pinned formatting (**275** files), JSON Schema/OpenAPI validation,
scoped Markdown file links and `git diff --check` passed. No new Swift/hardware,
CI or native installed-lifecycle result is claimed. The unrelated UI lockfile
retains its previous digest and is not part of this change.

This lease is only a preparation prerequisite: active catalog work/leases,
retired runtime generations, external disks/EFI, complete durable paired
snapshots, writer fencing across directory replacement, publication,
validation/commit, rollback/recovery and uninstall remain unfinished. It does
not authorize omitting `run/`, replacing installed app/state, service mutation,
push or release, and does not complete M8 or the overall goal.

## 2026-10-15 native tree snapshot component checkpoint

On top of `0678d70`, the internal
[tree snapshot primitive](MACOS_RELEASE_INSPECTION.md#metadata-preserving-tree-snapshot-primitive)
copies supported complete trees, including unknown files, empty directories and
zero-byte ownership records. Native bytes, UID/GID, modes, ACLs, xattrs/resource
forks, creation/modification times and flags are checked independently in source
and payload manifests. Directory metadata is applied after children; synced
receipts and no-replace publication retain failed staging and original inputs.
An existing namespace lock with unexpected mode, contents or hardlinks is refused
before the existing lock primitive can change its permissions. Copied lock bytes
do not transfer source ownership or fence a replacement tree.

The final **102-test** focused suite passed with **concurrency 1**, zero failures
or skips. It includes **23 new native component tests**, real retained SQLite
WAL/SHM with committed data, resource forks larger than one read chunk, ACL/flag
preservation, metadata-only change detection, descriptor lifetimes, existing
target protection, native-copy failure retention and real source/copy lock
independence. Only the disposable SQLite copy was opened for integrity checks.
The terminal report is `focused-complete.jsonl` under
`/private/tmp/gaovm-tree-snapshot.c8JJrj/`.

Broad regression **did not pass** during this change:

- The first selected daemon run passed **1,546**, skipped **1** and failed **1**
  existing daemon component-probe case at its 10-second child deadline.
- The concurrency-2 rerun passed **1,542**, skipped **1** and failed **5**:
  four existing executable-probe cases at their 5-second deadlines and the
  packaged HOME/default-state case at its 10-second child deadline.
- The same **3** installed/native-process exclusions documented above remained
  excluded, not passed. The Rust host publication fixture remained enabled.
  These broad runs preceded the final namespace-guard test additions.

Parallel focused attempts also hit probe deadlines; those failed reports are
retained alongside `daemon.jsonl` and `daemon-c2.jsonl`. The daemon component
case, packaged HOME case and final focused suite passed in isolation. Every
timed-out owned child reported confirmed exit. At one observation the host had
12 logical CPUs and load averages 187.76/141.52/112.50; this is pressure context,
not a proven cause. No production/test deadline, assertion or exclusion was
relaxed. Isolated success does not supersede the failed broad runs or satisfy
the unfiltered release gate.

Dart analysis, pinned formatting (**278** files), JSON Schema/OpenAPI validation,
scoped local Markdown file links and `git diff --check` passed. The unrelated UI
lockfile is unchanged and excluded from this component. No fresh Swift, hardware,
CI, signed-product or installed lifecycle result is claimed.

This is not complete cold acquisition or a paired app/state transaction. Active
catalog/lease checks, retired runtimes, external disks/EFI, startup/writer fencing,
crash/low-disk injection, publication/commit, whole-state rollback/recovery and
uninstall remain unfinished M8 work. No installed app/state or real service was
changed, and neither M8 nor the overall goal is complete.

## 2026-10-15 cold catalog and referenced-file checkpoint

On top of `db8499d`, the internal
[catalog and referenced-file inspections](MACOS_RELEASE_INSPECTION.md#source-read-only-catalog-and-referenced-file-inspections)
bind a private catalog copy to the original held cold lease. SQLite opens only
the copy; the source catalog is neither migrated nor checkpointed. Known schema
tables/ledger, SQLite integrity/foreign keys, VM identities/generations and
current/observed/execution VmSpecs are checked. Active durable work, unapplied
intents, all resource leases and non-event unpublished outbox rows block
preparation without deleting history or releasing unknown ownership.

Actual disk/EFI consumers have retained descriptors, native metadata/digests
and same-UID open-reference observations. Shared consumers retain every binding;
unsafe/unknown files, ACLs, observed writers and changed paths/bytes/metadata
refuse progress. These are revalidatable facts, **not external backups** or a
lasting writer fence. Neither imported JSON nor a partial SQLite inspection
copy can authorize restore or installed mutation.

The **154-test** focused suite passed with **concurrency 1**, zero failures or
skips, across 14 files. Its **52 new tests** include real native SQLite WAL-only
committed work with unchanged source DB/WAL/SHM metadata, schema 1/20/21 reads,
blocked schema-0 preparation, exact bounded blocker samples, a running execution
checkpoint despite stopped public intent, unchanged failed TestRun history,
stale catalog detection, actual disk/EFI hashing, deduplication,
ACL/hardlink/referrer refusal and file replacement/change detection. The owning
app/service/process observations are fixture boundaries, not formal ARM64 or
installed-service acceptance; the file metadata, SQLite and positive reference
reader use native local operations.

Three red cases demonstrated that SQLite could ignore damaged WAL input and
produce an older apparently idle read view. The new supported-header/checksum,
page-size and complete-frame-layout checks refuse those inputs before SQLite
opens the copy. SQLite still decides valid frame visibility; this is not an
independent forensic validation of every frame. Original bytes are retained.
The terminal report is `focused-final.jsonl` under
`/private/tmp/gaovm-cold-catalog.lseM0i/`.

Dart analysis, pinned formatting (**282** files), JSON Schema/OpenAPI validation,
scoped Markdown file links and staged `git diff --check` passed. The unrelated
UI lockfile remains unchanged and outside this component. Broad daemon
regression was not rerun here; the failed broad runs above remain unresolved,
not superseded by this focused pass. No new Swift, hardware, CI, signed-product
or installed lifecycle pass is claimed.

Retired generations/legacy boundaries, managed bundle/image validation, safe
`run/` handling, paired app/state publication, startup/writer fencing and durable
transaction recovery/commit/rollback/uninstall remain unfinished. No installed
app/state, real service, Chrome integration or remote ref was changed. M8 and
the complete PRD/development-plan goal remain open.

## 2026-10-15 managed asset checkpoint

On top of `e3cd572`, [managed asset inspection](MACOS_RELEASE_INSPECTION.md#managed-images-bundle-provenance-and-current-writable-bytes)
checks active immutable images and the completed publication provenance of live
VM bundles using facts from the private SQLite copy. Image catalog metadata,
actual manifest/object bytes, create Operation identity/completion and retained
spec generations must agree. Current writable disk/EFI bytes are bound without
comparing them to immutable image seeds or changing source files.

The checks distinguish failed/cancelled create tombstones from retained failed
TestRun VMs with successfully published assets. The latter keep their definition,
current disk/EFI and terminal history unchanged. A never-started VM may have no
managed EFI yet; the absence is recorded and revalidated without initialization.
Used-VM loss, mismatched proof, unknown bindings, unsafe paths/permissions/ACLs,
observed writers or changed bytes/metadata refuse progress. Required image/VM
trees also retain and bind unknown regular staging/orphan data, not clean it.

The **263-test** combined focused run passed with **concurrency 1**, zero
failures/skips, across **22** files. This includes **24 new tests** plus the prior
cold/metadata/component checks and existing runtime-asset, bundle/image store,
manifest and provisioning repository checks. New cases cover real unchanged
source trees, legitimate writable changes, missing/unsafe files, absent EFI and
its observation race, current/observed/execution bindings, retained failed
TestRuns, contradictory failed-create proof, unrelated Operations, typed request
generations, immutable corruption, unknown staging retention, distinct GaoOS
role objects and refusal before tree reads after the original lease is closed.
The terminal report is `focused-final.jsonl` under
`/private/tmp/gaovm-managed-assets.4H09OD/`.

Dart analysis, pinned formatting (**284** files), JSON Schema/OpenAPI validation,
scoped Markdown file links and staged `git diff --check` passed. The unrelated UI
lockfile stays unchanged and excluded. Full daemon regression was not rerun:
these focused results do not supersede the earlier failed broad regressions.
No new Swift, hardware, CI or installed lifecycle pass is claimed.
The owning service/process census is still a fixture boundary; native local
SQLite, file metadata/hash/copy and the positive reference reader do not establish
installed-service, Developer ID product, ARM64, VZ or Guest acceptance.

Full cold acquisition still needs retired runtimes/legacy boundaries and safe
`run/` handling. Paired app/state publication, persistent startup/writer fencing,
durable journal/recovery, activation/commit, whole-state rollback and uninstall
remain unfinished. No installed app/state, real service, remote ref or hardware
was changed; the full M8/PRD goal is not complete.
