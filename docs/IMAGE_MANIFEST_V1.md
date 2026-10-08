# Image manifest v1

This document specifies the immutable `Image.manifest` object used by PR020.
It refines M5.1/M5.2/M5.5/M5.6 without changing the public `/v1` request or
resource schemas. `architecture` is `arm64`, matching the frozen MVP schema.

The store supports `linux-kernel`, `initrd`, `raw-disk`, and `gaoos-bundle`.
A standalone file produces one object named `payload`. A GaoOS bundle is a
directory containing `manifest.json` and an `objects/` directory. Archive
extraction and `.gaovm` VM bundle import are outside this format.

## Manifest fields

Required fields are `manifest_version` (integer `1`), `digest`, `architecture`,
`type`, and `objects`. Optional string fields are `guest_profile`, `version`,
`build_id`, and `channel`. Unknown fields are rejected. Optional fields are
omitted, rather than encoded as null. Metadata strings contain 1–1024 characters.

`objects` maps 1–64 names to objects with exactly two fields:

- `digest`: SHA-256 of the object's bytes, formatted as `sha256:` plus 64 lowercase hex digits.
- `size_bytes`: positive integer byte count.

Names match `[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}` and identify files directly within
`objects/`. Names never contain paths. Source objects must be regular files
owned by the daemon user; bundle object symlinks and symlinked object directories
are rejected. Standalone source paths are resolved to an owned regular file.
Sources are opened with no-follow and nonblocking flags, then regular-file type
and daemon ownership are verified on the held descriptor. Bundle children are
opened relative to held directory descriptors. Copying uses asynchronous IO from
that descriptor, so later pathname replacement cannot substitute unchecked bytes.
Manifests are read with a 1 MiB streaming bound before decoding, including when
the file grows after its initial size check.

`gaoos-bundle` additionally requires `guest_profile: "gaoos"`, `version`,
`build_id`, `channel`, and a `gaoos` object with exactly these fields:

- `kernel`, `initrd`, `root_disk`: three distinct names present in `objects`.
- `default_command_line`: string, which may be empty.
- `guest_agent_expected`: boolean.

The three names describe boot roles; their objects remain part of the bundle's
single immutable image resource. PR021 provisioning resolves these roles when
creating isolated VM disks. Import checks hashes and declared byte sizes; it
does not attempt to boot or certify an operating system.
If an import request supplies bundle metadata, it must match the source manifest;
the importer never silently ignores or rewrites immutable build metadata.

## Identity and canonical encoding

The image digest hashes the UTF-8 canonical JSON manifest **excluding its
`digest` member**. Object keys are sorted recursively in ascending string order,
JSON has no insignificant whitespace, and scalar encoding uses Dart JSON
encoding. Object byte digests, type, architecture, and immutable metadata are
therefore included in image identity. The digest is not necessarily the digest
of a standalone source file. `ImageManifest.create` constructs this encoding;
`ImageManifest.fromJson` verifies it. The standalone import service's optional
`expectedObjectDigest` checks the original file's byte digest.

Deduplication is by the complete image digest. Reimporting an identical manifest
returns the original image ID, creation time, and labels. Labels are catalog
metadata, excluded from content identity, and are not changed by a duplicate
import. No stored manifest can be updated independently of its image resource.

## Publication and recovery

Each image root belongs to one SQLite catalog. All mutations use a store lock
and an in-process queue; different processes cooperate through an OS file lock.
Imports use streaming I/O with cancellation checks, progress callbacks, and a
capacity check that reserves the input size plus 1 MiB of metadata headroom.
An actual write error still fails safely if capacity changes during the copy.

1. Create a private staging directory below the image root and copy its objects.
2. Check object sizes/digests, write the immutable manifest, flush files and directories.
3. Rename staging to `images/sha256-<hex>/` and flush the image root directory.
4. Commit the image catalog row, `image.imported` event, and event outbox atomically.
   For a durable import, the same transaction completes its Operation and
   acknowledges the fenced image-work outbox delivery.

The root has mode 0700 and published files have mode 0400. Failed imports remove
their staging directories. Catalog insert or final SQLite commit failure removes
the publication while retaining the filesystem lock.
A process crash before catalog commit may leave staging or an unregistered
complete directory; these are invisible to catalog clients. `reconcile()` removes
them. A crash after commit preserves the image and its complete objects.

Filesystem mutations (including import, delete, reconciliation, and unpublished
operation completion)
reject calls made inside an active caller transaction on the same SQLite catalog,
including a second connection to that catalog, before changing the filesystem.
A nested savepoint is not a durable commit and therefore cannot authorize file
removal. Application acceptance commits its database-only operation/outbox first;
the worker invokes the store after that transaction has ended.

Deletion checks actual retained `vm_specs` for every VM without a deletion
tombstone, including pending and applied generations. This is deliberately
conservative: historical generations retained for a live VM still protect their
images. An in-use image raises `ImageInUse`. Catalog deletion and `image.deleted`
event/outbox commit before removing the directory. A crash during cleanup leaves
an orphan for reconciliation. External source files and VM disks are never
deleted by this store.

Reconciliation preserves registered images, verifies their manifests and object
hashes, and reports damaged image IDs for doctor/repair rather than deleting
referenced content. It removes only recognized unregistered image directories
and staging directories, then emits `image.store_cleaned`. Unknown entries and
symlinks are preserved. The application service must validate image existence
in the same database transaction that adds a VM reference; PR020 supplies the
reference query and deletion side. VM provisioning supplies reference creation
validation in its own application transaction.

## Durable public operations

`ImageApplicationService` and `ImageApiHandlers` expose the frozen import, list,
and delete routes over the public Unix HTTP socket. Acceptance is database-only
and returns `202` with a pending Operation and Location. Import acceptance reserves
an image ID. Deduplication resolves the completed Operation's resource ID and
`result.image_id` to the original image; idempotency retries preserve the exact
original acceptance response, including its reserved ID and pending state.

The daemon owns a recoverable image-work loop with expiring, renewed claims.
Publication and terminal Operation commits verify the claim token and expiry;
an old worker cannot overwrite a replacement's result. Cancellation is accepted
through the Operation API and completes only after the store lock is acquired and
unpublished staging/orphans are cleaned, including files from a previous worker.
Image deletion rechecks references and atomically commits catalog deletion, its
Operation, events, and work acknowledgement before removing managed files.
Shutdown drains in-flight image work before closing SQLite.

## Verification and scope

`image_store_test.dart` exercises real files, SQLite, event/outbox persistence,
concurrent deduplication in both one isolate and simultaneous child processes,
cancellation, capacity rejection, reference protection,
rollback, caller-transaction rejection, descriptor ownership across pathname
replacement, bounded manifest growth, and child-process exit at all three
publication checkpoints. Application, public HTTP, work-loop, and operation
recovery tests additionally cover durable acceptance/replay, cancellation across
lease replacement, final-commit rollback, reference races, pagination, metadata
validation, and process exits before and after the terminal Operation commit.
`image_manifest_test.dart` verifies canonicalization, immutability, and malformed
manifest rejection. POSIX durability and ownership behavior is exercised on
macOS; Linux uses descriptor `statx`, procfs descriptor IO, and its corresponding
`stat`/`df` interfaces and needs Linux CI. Missing descriptor-validation interfaces
fail closed.

The public composition uses a concrete fenced `ImageOperationCommit`, not an
arbitrary future transaction callback. These checks do not establish CLI image
command coverage, installed daemon startup, native VM boot, or full MVP completion.
