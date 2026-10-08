//! Bounded guest-side artifact snapshots. No binary wire or host registration.

use crate::protocol::{ErrorCode, PROTOCOL_VERSION, ProtocolError, validate_message};
use crate::session::Session;
use nix::fcntl::{OFlag, openat};
use nix::sys::stat::Mode;
use nix::unistd::Uid;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{File, Metadata, Permissions};
use std::io::{Read, Take};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use tempfile::{NamedTempFile, TempDir, TempPath};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

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

#[derive(Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct CollectParams {
    paths: Vec<CollectPath>,
    max_total_bytes: u64,
    #[serde(default)]
    follow_symlinks: bool,
}

#[derive(Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct CollectPath {
    path: String,
    kind: String,
    content_type: Option<String>,
}

struct StoredArtifact {
    info: ArtifactInfo,
    file: TempPath,
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
    spool: TempDir,
    limits: ArtifactLimits,
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
            spool,
            limits,
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
        let mut remaining = params
            .max_total_bytes
            .min(self.limits.max_collection_bytes)
            .min(self.limits.max_stored_bytes - stored);
        let mut artifacts = Vec::new();
        for path in &params.paths {
            let file = self.open_source(&path.path)?;
            let before = file
                .metadata()
                .map_err(|_| error(ErrorCode::GuestInternalError))?;
            if before.len() > remaining {
                return Err(error(ErrorCode::ArtifactLimitExceeded));
            }
            let mut source = tokio::fs::File::from_std(file);
            let spool = NamedTempFile::new_in(self.spool.path())
                .map_err(|_| error(ErrorCode::GuestInternalError))?;
            let mut output = tokio::fs::File::from_std(
                spool
                    .reopen()
                    .map_err(|_| error(ErrorCode::GuestInternalError))?,
            );
            let mut hash = Sha256::new();
            let mut size = 0;
            let mut buffer = [0; 8192];
            loop {
                let count = source
                    .read(&mut buffer)
                    .await
                    .map_err(|_| error(ErrorCode::GuestInternalError))?;
                if count == 0 {
                    break;
                }
                if count as u64 > remaining {
                    return Err(error(ErrorCode::ArtifactLimitExceeded));
                }
                output
                    .write_all(&buffer[..count])
                    .await
                    .map_err(|_| error(ErrorCode::GuestInternalError))?;
                hash.update(&buffer[..count]);
                size += count as u64;
                remaining -= count as u64;
            }
            let after = source
                .metadata()
                .await
                .map_err(|_| error(ErrorCode::GuestInternalError))?;
            if !unchanged(&before, &after) || size != before.len() {
                return Err(error(ErrorCode::GuestInternalError));
            }
            output
                .flush()
                .await
                .map_err(|_| error(ErrorCode::GuestInternalError))?;
            output
                .sync_all()
                .await
                .map_err(|_| error(ErrorCode::GuestInternalError))?;
            artifacts.push(StoredArtifact {
                info: ArtifactInfo {
                    artifact_id: format!("art_{}", ulid::Ulid::generate()),
                    kind: path.kind.clone(),
                    content_type: path
                        .content_type
                        .clone()
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
                file: spool.into_temp_path(),
            });
        }
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
    ) -> Result<Take<File>, ProtocolError> {
        let collection = self.collection(session, request)?;
        let artifact = collection
            .artifacts
            .iter()
            .find(|artifact| artifact.info.artifact_id == artifact_id)
            .ok_or_else(|| error(ErrorCode::ArtifactNotFound))?;
        File::open(&artifact.file)
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

    fn open_source(&self, path: &str) -> Result<File, ProtocolError> {
        if !owned(
            &self
                .root
                .metadata()
                .map_err(|_| error(ErrorCode::GuestInternalError))?,
        ) {
            return Err(error(ErrorCode::ArtifactNotFound));
        }
        let components: Vec<_> = path.split('/').collect();
        if components.iter().any(|component| {
            component.is_empty()
                || *component == "."
                || *component == ".."
                || component.contains('\0')
        }) {
            return Err(error(ErrorCode::InvalidRequest));
        }
        let mut directory = self
            .root
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
