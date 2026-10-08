# Legacy VM migration checkpoint (PR015 / M1.6)

`LegacyVmMigration` is a startup-only adapter from the former singleton files
to the SQLite catalog. This checkpoint does not complete PR015's transitional
CLI adapter or establish the real macOS upgrade acceptance gate.

## State and startup boundary

The installed `DaemonApplication` invokes migration only after native driver
census and previous-owner teardown succeed, before scheduler recovery, workers,
controllers, or the public listener become active. Legacy PIDs and observed
state never authorize process signaling or lease release.

The adapter preserves `config.json`, `pending_config.json`,
`desired_state.json`, and `daemon_state.json` byte-for-byte. Before accepting a
VM, it publishes `legacy-v1-backup` through private staging, file/directory
fsync, and an atomic no-replace rename. Its manifest pins JSON digests plus
canonical kernel/initrd paths, sizes, and SHA-256 digests. Changed inputs before
catalog acceptance fail closed; the adapter does not overwrite the backup or
delete old data to retry. Unknown staging entries and nonempty unmarked staging
directories are preserved.

Pending configuration wins over the applied legacy configuration. Configured
Linux/auto kernel boot, shared/disconnected networking, and an external writable
root disk map to a typed spec. Kernel/initrd enter the immutable image store;
the external disk remains at its canonical path and is never moved or deleted.
Missing/empty assets, relative paths, unsupported boot/network modes, and invalid
typed specs stop migration without deleting the source data. Guest Agent is
disabled and the frozen bounded on-failure restart policy applies.

Schema v8 adds `legacy_vm_migrations`. One acceptance transaction creates a real
`vm_` ULID named `migrated-default`, its create Operation, pinned provisioning
work, events/outbox rows, and immutable migration identity. Only that Operation
is claimed by startup migration. A process crash reuses the same identity and
published bundle. Completion atomically applies the pinned desired state,
records the completion marker, and emits `vm.legacy_migrated` through the outbox.
After completion, retained legacy files are not an active state source; an empty
new state directory never creates an implicit default VM. No public API schema
or driver IPC change is introduced.

Changed implementation/test files are under `daemon/gaovmd`: the new migration
adapter and crash fixture, daemon startup/export wiring, schema v8, an optional
Operation filter on provisioning claims, and migration/schema regression tests.

## Verification

Run from `daemon/gaovmd` with Dart 3.9:

```sh
mise exec dart@3.9 -- dart pub get --enforce-lockfile
mise exec dart@3.9 -- dart format --output=none --set-exit-if-changed bin lib test
mise exec dart@3.9 -- dart analyze
mise exec dart@3.9 -- dart test test/legacy_vm_migration_test.dart test/sqlite_database_test.dart test/vm_provisioning_work_repository_test.dart
mise exec dart@3.9 -- dart test
```

Focused coverage includes idempotent migration across database reopen; real
process exit after backup publication, asset import, catalog acceptance, bundle
publication, and completion; transactional completion rollback; equal-size
kernel mutation; lost recovery inputs; pending configuration; external-disk
preservation; unknown staging preservation; and native census rejection before
legacy backup/catalog mutation or old lease replacement.

Validated on Intel macOS 15.8.1 on 2026-10-08: 48 focused tests passed; frozen
dependency resolution, formatting, analysis, AOT compilation, and executable
`--help` passed. The full daemon suite had 848 passed, 1 skipped, and 2 failed:
installed startup rejected unresolved native executables, and the untouched
legacy supervisor's fifth-retry test timed out. That exact retry test passed
alone with its original timeout; the full suite is not reported as green.

This evidence contributes to `VM-001`, `VM-005`, `VM-009`, and `SPEC-002` only
within the migration boundary. It does not declare those PRD requirements
end-to-end complete.

## Remaining dependencies and limits

- Finish the transitional public-API CLI adapter: `default` may be a temporary
  alias, never an internal VM ID, and is removed after one release cycle.
- Resolve legacy runtime/socket remnants through proven native ownership; this
  adapter does not blindly unlink old sockets or trust historical PID files.
- Validate installed startup and migration on a host with a complete native
  process inventory. On the current Intel macOS host, unresolved executables
  prevent the positive installed-daemon test; this guard has not been bypassed.
- Run the real Apple Silicon VM boot/upgrade, Swift/VZ, signing, launchd, and
  release gates. Component/crash fixtures and AOT compilation do not replace them.

PR015 therefore remains a partial work package. CLI integration and a clean-host
native upgrade test are the next dependencies, not optional MVP exclusions.
