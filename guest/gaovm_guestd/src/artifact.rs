//! Bounded guest-side artifact snapshots. No binary wire or host registration.

use crate::protocol::{ErrorCode, PROTOCOL_VERSION, ProtocolError, validate_message};
use crate::session::Session;
use crate::spool::{Reservation, RetainedFile, SpoolBudget, SpoolDirectory, SpoolReader};
use nix::fcntl::{OFlag, openat};
use nix::sys::stat::Mode;
use nix::unistd::Uid;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{File, Metadata, Permissions};
use std::io::{Read, Take, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use tempfile::NamedTempFile;

#[derive(Clone, Copy)]
pub struct ArtifactLimits {
    pub max_collection_bytes: u64,
    pub max_stored_bytes: u64,
    pub max_retained: usize,
}

impl Default for ArtifactLimits {
    fn default() -> Self {
        Self {
            max_collection_bytes: 16 * 1024 * 1024,
            max_stored_bytes: 256 * 1024 * 1024,
            max_retained: 16,
        }
    }
}

/// Local metadata, deliberately not a wire descriptor: no stream exists yet.
#[derive(Clone, Debug, Serialize)]
pub struct ArtifactInfo {
    pub artifact_id: String,
    pub kind: String,
    pub content_type: String,
    pub size_bytes: u64,
    pub digest: String,
}

#[derive(Clone, Debug)]
pub struct CollectionSnapshot {
    pub vm_id: String,
    pub driver_generation: u64,
    pub operation_id: String,
    pub artifacts: Vec<ArtifactInfo>,
}

#[derive(Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct CollectParams {
    paths: Vec<CollectPath>,
    max_total_bytes: u64,
    #[serde(default)]
    follow_symlinks: bool,
}

#[derive(Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct CollectPath {
    path: String,
    kind: String,
    content_type: Option<String>,
}

struct StoredArtifact {
    info: ArtifactInfo,
    file: Arc<RetainedFile>,
}

struct Collection {
    params: CollectParams,
    snapshot: CollectionSnapshot,
    artifacts: Vec<StoredArtifact>,
}

pub struct ArtifactCollector {
    vm_id: String,
    generation: u64,
    root: File,
    spool: Arc<SpoolDirectory>,
    limits: ArtifactLimits,
    budget: SpoolBudget,
    collections: HashMap<String, Collection>,
}

impl ArtifactCollector {
    pub fn new(
        vm_id: &str,
        generation: u64,
        source_root: &Path,
        spool_parent: &Path,
        limits: ArtifactLimits,
    ) -> Result<Self, ProtocolError> {
        Self::with_spool_budget(
            vm_id,
            generation,
            source_root,
            spool_parent,
            limits,
            SpoolBudget::new(limits.max_stored_bytes),
        )
    }

    pub fn with_spool_budget(
        vm_id: &str,
        generation: u64,
        source_root: &Path,
        spool_parent: &Path,
        limits: ArtifactLimits,
        budget: SpoolBudget,
    ) -> Result<Self, ProtocolError> {
        validate_message(
            &json!({"protocol_version": PROTOCOL_VERSION, "kind": "request", "id": "artifact-binding",
            "method": "health", "vm_id": vm_id, "driver_generation": generation, "operation_id": null, "params": {}}),
        )?;
        if limits.max_collection_bytes > 256 * 1024 * 1024
            || limits.max_stored_bytes < limits.max_collection_bytes
            || limits.max_stored_bytes > 1024 * 1024 * 1024
            || limits.max_retained == 0
        {
            return Err(error(ErrorCode::InvalidRequest));
        }
        let root = private_directory(source_root)?;
        private_directory(spool_parent)?;
        let spool = tempfile::Builder::new()
            .prefix("gaovm-artifacts-")
            .permissions(Permissions::from_mode(0o700))
            .tempdir_in(
                spool_parent
                    .canonicalize()
                    .map_err(|_| error(ErrorCode::GuestInternalError))?,
            )
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        Ok(Self {
            vm_id: vm_id.to_owned(),
            generation,
            root,
            spool: SpoolDirectory::new(spool, budget.clone())
                .map_err(|_| error(ErrorCode::GuestInternalError))?,
            limits,
            budget,
            collections: HashMap::new(),
        })
    }

    pub async fn collect(
        &mut self,
        session: &Session,
        request: &Value,
    ) -> Result<CollectionSnapshot, ProtocolError> {
        let operation = self.authorize(session, request)?.to_owned();
        let params = params(request)?;
        if let Some(collection) = self.collections.get(&operation) {
            return if collection.params == params {
                Ok(collection.snapshot.clone())
            } else {
                Err(error(ErrorCode::InvalidRequest))
            };
        }
        if self.collections.len() >= self.limits.max_retained {
            return Err(error(ErrorCode::ArtifactLimitExceeded));
        }
        let stored: u64 = self
            .collections
            .values()
            .flat_map(|collection| &collection.artifacts)
            .map(|artifact| artifact.info.size_bytes)
            .sum();
        let remaining = params
            .max_total_bytes
            .min(self.limits.max_collection_bytes)
            .min(self.limits.max_stored_bytes - stored);
        let reservation = self
            .budget
            .reserve_up_to(remaining)
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        let root = self
            .root
            .try_clone()
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        let spool = self.spool.clone();
        let paths = params.paths.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let _cancel_on_drop = CancelCapture(cancel.clone());
        let worker = self
            .budget
            .spawn(move || capture_collection(root, spool, paths, reservation, cancel))
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        let artifacts = worker
            .await
            .map_err(|_| error(ErrorCode::GuestInternalError))?
            .finish()?;
        let snapshot = CollectionSnapshot {
            vm_id: self.vm_id.clone(),
            driver_generation: self.generation,
            operation_id: operation.clone(),
            artifacts: artifacts
                .iter()
                .map(|artifact| artifact.info.clone())
                .collect(),
        };
        self.collections.insert(
            operation,
            Collection {
                params,
                snapshot: snapshot.clone(),
                artifacts,
            },
        );
        Ok(snapshot)
    }

    pub fn open_artifact(
        &self,
        session: &Session,
        request: &Value,
        artifact_id: &str,
    ) -> Result<Take<SpoolReader>, ProtocolError> {
        let collection = self.collection(session, request)?;
        let artifact = collection
            .artifacts
            .iter()
            .find(|artifact| artifact.info.artifact_id == artifact_id)
            .ok_or_else(|| error(ErrorCode::ArtifactNotFound))?;
        artifact
            .file
            .reader()
            .map(|file| file.take(artifact.info.size_bytes))
            .map_err(|_| error(ErrorCode::GuestInternalError))
    }

    pub fn release(&mut self, session: &Session, request: &Value) -> Result<(), ProtocolError> {
        self.collection(session, request)?;
        let operation = self.authorize(session, request)?.to_owned();
        self.collections.remove(&operation);
        Ok(())
    }

    fn authorize<'a>(
        &self,
        session: &Session,
        request: &'a Value,
    ) -> Result<&'a str, ProtocolError> {
        session.authorize_request(request)?;
        if request["method"] != "artifact.collect"
            || request["vm_id"] != self.vm_id
            || request["driver_generation"] != self.generation
        {
            return Err(error(ErrorCode::InvalidRequest));
        }
        request["operation_id"]
            .as_str()
            .ok_or_else(|| error(ErrorCode::InvalidRequest))
    }

    fn collection(&self, session: &Session, request: &Value) -> Result<&Collection, ProtocolError> {
        let operation = self.authorize(session, request)?;
        let collection = self
            .collections
            .get(operation)
            .ok_or_else(|| error(ErrorCode::ArtifactNotFound))?;
        if collection.params != params(request)? {
            return Err(error(ErrorCode::InvalidRequest));
        }
        Ok(collection)
    }
}

struct CancelCapture(Arc<AtomicBool>);

impl Drop for CancelCapture {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

fn capture_collection(
    root: File,
    spool: Arc<SpoolDirectory>,
    paths: Vec<CollectPath>,
    reservation: Arc<Reservation>,
    cancel: Arc<AtomicBool>,
) -> Result<Vec<StoredArtifact>, ProtocolError> {
    let mut remaining = reservation.bytes();
    let mut artifacts = Vec::new();
    let check_cancel = || {
        if cancel.load(Ordering::Acquire) {
            Err(error(ErrorCode::GuestInternalError))
        } else {
            Ok(())
        }
    };
    for path in paths {
        check_cancel()?;
        let mut source = open_source(&root, &path.path)?;
        let before = source
            .metadata()
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        if before.len() > remaining {
            return Err(error(ErrorCode::ArtifactLimitExceeded));
        }
        let file = NamedTempFile::new_in(spool.path())
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        let retained = RetainedFile::new(file, spool.clone(), reservation.clone())
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        let mut file = retained
            .owned_writer()
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        let mut buffer = [0; 8192];
        let mut hash = Sha256::new();
        let mut size = 0;
        loop {
            check_cancel()?;
            let count = source
                .read(&mut buffer)
                .map_err(|_| error(ErrorCode::GuestInternalError))?;
            if count == 0 {
                break;
            }
            if count as u64 > remaining {
                return Err(error(ErrorCode::ArtifactLimitExceeded));
            }
            check_cancel()?;
            file.write_all(&buffer[..count])
                .map_err(|_| error(ErrorCode::GuestInternalError))?;
            hash.update(&buffer[..count]);
            size += count as u64;
            remaining -= count as u64;
        }
        let after = source
            .metadata()
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        if !unchanged(&before, &after) || size != before.len() {
            return Err(error(ErrorCode::GuestInternalError));
        }
        file.flush()
            .and_then(|()| file.sync())
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        check_cancel()?;
        drop(file);
        artifacts.push(StoredArtifact {
            info: ArtifactInfo {
                artifact_id: format!("art_{}", ulid::Ulid::generate()),
                kind: path.kind,
                content_type: path
                    .content_type
                    .unwrap_or_else(|| "application/octet-stream".to_owned()),
                size_bytes: size,
                digest: format!(
                    "sha256:{}",
                    hash.finalize()
                        .iter()
                        .map(|byte| format!("{byte:02x}"))
                        .collect::<String>()
                ),
            },
            file: retained,
        });
    }
    check_cancel()?;
    reservation
        .seal(
            artifacts
                .iter()
                .map(|artifact| artifact.info.size_bytes)
                .sum(),
        )
        .map_err(|_| error(ErrorCode::GuestInternalError))?;
    Ok(artifacts)
}

fn open_source(root: &File, path: &str) -> Result<File, ProtocolError> {
    if !owned(
        &root
            .metadata()
            .map_err(|_| error(ErrorCode::GuestInternalError))?,
    ) {
        return Err(error(ErrorCode::ArtifactNotFound));
    }
    let components: Vec<_> = path.split('/').collect();
    if components.iter().any(|component| {
        component.is_empty() || *component == "." || *component == ".." || component.contains('\0')
    }) {
        return Err(error(ErrorCode::InvalidRequest));
    }
    let mut directory = root
        .try_clone()
        .map_err(|_| error(ErrorCode::GuestInternalError))?;
    for (index, component) in components.iter().enumerate() {
        let last = index + 1 == components.len();
        let flags = OFlag::O_RDONLY
            | OFlag::O_CLOEXEC
            | OFlag::O_NOFOLLOW
            | OFlag::O_NONBLOCK
            | if last {
                OFlag::empty()
            } else {
                OFlag::O_DIRECTORY
            };
        let file = File::from(
            openat(&directory, *component, flags, Mode::empty())
                .map_err(|_| error(ErrorCode::ArtifactNotFound))?,
        );
        let metadata = file
            .metadata()
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        if !owned(&metadata)
            || if last {
                !metadata.is_file() || metadata.nlink() != 1
            } else {
                !metadata.is_dir()
            }
        {
            return Err(error(ErrorCode::ArtifactNotFound));
        }
        directory = file;
    }
    Ok(directory)
}

fn params(request: &Value) -> Result<CollectParams, ProtocolError> {
    serde_json::from_value(request["params"].clone()).map_err(|_| error(ErrorCode::InvalidRequest))
}

fn owned(metadata: &Metadata) -> bool {
    metadata.uid() == Uid::effective().as_raw() && metadata.mode() & 0o022 == 0
}

fn private_directory(path: &Path) -> Result<File, ProtocolError> {
    let file = File::open(
        path.canonicalize()
            .map_err(|_| error(ErrorCode::GuestInternalError))?,
    )
    .map_err(|_| error(ErrorCode::GuestInternalError))?;
    let metadata = file
        .metadata()
        .map_err(|_| error(ErrorCode::GuestInternalError))?;
    if !metadata.is_dir() || !owned(&metadata) {
        return Err(error(ErrorCode::InvalidRequest));
    }
    Ok(file)
}

fn unchanged(before: &Metadata, after: &Metadata) -> bool {
    owned(after)
        && after.nlink() == 1
        && before.dev() == after.dev()
        && before.ino() == after.ino()
        && before.len() == after.len()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
}

fn error(code: ErrorCode) -> ProtocolError {
    ProtocolError {
        code,
        message: "guest artifact collection failed",
    }
}
