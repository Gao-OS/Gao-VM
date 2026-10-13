//! Session-scoped binary grants. Native peer authentication remains the
//! acceptor's responsibility; wire IDs alone cannot construct a control epoch.

use crate::artifact::{ArtifactCollector, ArtifactInfo};
use crate::binary::{
    BinaryArtifact, BinaryHeader, BinarySource, ExecOutput, OpenHeader, ReadyHeader, encode_header,
};
use crate::binary_io::{read_header, write_body, write_header};
use crate::control::FrameWriter;
use crate::exec::{ExecResult, ExecState, Executor, OutputReference, OutputStream};
use crate::protocol::{ErrorCode, PROTOCOL_VERSION, ProtocolError, validate_message};
use crate::session::{ControlEpoch, Session};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::io;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::Semaphore;
use tokio::time::{Duration, Instant, timeout_at};

// Descriptor bound for the existing default engines: 16 collections * 256
// paths + 32 executions * 2 outputs. This is not an aggregate spool-byte quota.
const MAX_GRANTS: usize = 16 * 256 + 32 * 2;
const MAX_ACTIVE_TRANSFERS: usize = 2;

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct GrantKey {
    operation_id: String,
    artifact_id: String,
    source: GrantSource,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum GrantSource {
    Collection,
    Stdout,
    Stderr,
}

impl From<&BinarySource> for GrantSource {
    fn from(source: &BinarySource) -> Self {
        match source {
            BinarySource::Collection { .. } => Self::Collection,
            BinarySource::ExecOutput {
                output: ExecOutput::Stdout,
            } => Self::Stdout,
            BinarySource::ExecOutput {
                output: ExecOutput::Stderr,
            } => Self::Stderr,
        }
    }
}

struct GrantEntry {
    artifact: BinaryArtifact,
    expires: Instant,
    phase: GrantPhase,
}

struct ExecStatusMetadata {
    infos: Vec<(GrantSource, ArtifactInfo)>,
    message: Value,
}

enum GrantPhase {
    Pending(Arc<()>),
    Ready,
    Active(Arc<()>),
    Retired,
}

#[derive(Clone)]
pub struct GrantRegistry {
    epoch: ControlEpoch,
    entries: Arc<Mutex<BTreeMap<GrantKey, GrantEntry>>>,
    entropy: Arc<Semaphore>,
}

pub(crate) struct GrantOpenFailure {
    pub(crate) error: ProtocolError,
    // Present only after matching a live published full binding/selector.
    pub(crate) verified_until: Option<Instant>,
}

impl GrantOpenFailure {
    fn silent(code: ErrorCode) -> Self {
        Self {
            error: error(code),
            verified_until: None,
        }
    }

    fn verified(code: ErrorCode, expires: Instant) -> Self {
        Self {
            error: error(code),
            verified_until: Some(expires),
        }
    }
}

impl GrantRegistry {
    pub fn new(epoch: ControlEpoch) -> Result<Self, ProtocolError> {
        Self::with_blocking_worker(epoch, Arc::new(Semaphore::new(1)))
    }

    pub(crate) fn with_blocking_worker(
        epoch: ControlEpoch,
        entropy: Arc<Semaphore>,
    ) -> Result<Self, ProtocolError> {
        if !epoch.is_guest() || !epoch.claim_grant_registry() {
            return Err(error(ErrorCode::InvalidRequest));
        }
        Ok(Self {
            epoch,
            entries: Arc::new(Mutex::new(BTreeMap::new())),
            entropy,
        })
    }

    /// Capture/replay through the authorized collector, then reserve grants.
    /// Dropping this reply does not release retained spools or execute again.
    pub async fn prepare_collection(
        &self,
        session: &Session,
        collector: &mut ArtifactCollector,
        request: &Value,
        expires: Instant,
    ) -> Result<PreparedReply, ProtocolError> {
        self.authorize(session, request, "artifact.collect")?;
        if Instant::now() >= expires {
            return Err(error(ErrorCode::ArtifactNotFound));
        }
        let snapshot = timeout_at(expires, collector.collect(session, request))
            .await
            .map_err(|_| error(ErrorCode::ArtifactNotFound))??;
        let message = json!({"protocol_version": PROTOCOL_VERSION, "kind": "response", "id": request["id"],
            "method": "artifact.collect", "vm_id": snapshot.vm_id, "driver_generation": snapshot.driver_generation,
            "operation_id": snapshot.operation_id, "result": {"artifacts": []}});
        self.prepare_metadata(
            snapshot
                .artifacts
                .into_iter()
                .map(|info| (GrantSource::Collection, info))
                .collect(),
            message,
            expires,
        )
        .await
    }

    /// Read one authoritative wire snapshot. Only terminal artifact references
    /// in that exact response can publish grants, never start/cancel or running
    /// output, even if execution completes while the response is being prepared.
    pub fn prepare_exec_status(
        &self,
        session: &Session,
        executor: &mut Executor,
        request: &Value,
        expires: Instant,
    ) -> impl std::future::Future<Output = Result<PreparedReply, ProtocolError>> + Send + use<>
    {
        // Capture the authoritative response synchronously. The returned future
        // owns it and borrows no executor/session/request across entropy I/O,
        // so a composing service can release its execution lock before awaiting.
        let metadata = self.exec_status_metadata(session, executor, request, expires);
        let registry = self.clone();
        async move {
            let metadata = metadata?;
            registry
                .prepare_metadata(metadata.infos, metadata.message, expires)
                .await
        }
    }

    fn exec_status_metadata(
        &self,
        session: &Session,
        executor: &mut Executor,
        request: &Value,
        expires: Instant,
    ) -> Result<ExecStatusMetadata, ProtocolError> {
        self.authorize(session, request, "exec.status")?;
        if Instant::now() >= expires {
            return Err(error(ErrorCode::ArtifactNotFound));
        }
        let message = executor.handle(session, request)?;
        let payload = match message["kind"].as_str() {
            Some("response") => Some(&message["result"]),
            Some("error") => message["error"]["details"].get("result"),
            _ => None,
        };
        let mut infos = Vec::new();
        if let Some(payload) = payload {
            let result: ExecResult = serde_json::from_value(payload.clone())
                .map_err(|_| error(ErrorCode::GuestInternalError))?;
            if result.state != ExecState::Running {
                for (reference, source, output) in [
                    (&result.stdout, GrantSource::Stdout, OutputStream::Stdout),
                    (&result.stderr, GrantSource::Stderr, OutputStream::Stderr),
                ] {
                    if let OutputReference::Artifact {
                        artifact_id,
                        size_bytes,
                    } = reference
                    {
                        let info = executor
                            .output_artifact(session, request, output)?
                            .ok_or_else(|| error(ErrorCode::GuestInternalError))?;
                        if info.artifact_id != *artifact_id || info.size_bytes != *size_bytes {
                            return Err(error(ErrorCode::GuestInternalError));
                        }
                        infos.push((source, info));
                    }
                }
            }
        }
        Ok(ExecStatusMetadata { infos, message })
    }

    async fn prepare_metadata(
        &self,
        infos: Vec<(GrantSource, ArtifactInfo)>,
        mut message: Value,
        expires: Instant,
    ) -> Result<PreparedReply, ProtocolError> {
        let handles = self.handles(infos.len(), expires).await?;
        let operation_id = message["operation_id"]
            .as_str()
            .ok_or_else(|| error(ErrorCode::InvalidRequest))?
            .to_owned();
        let token = Arc::new(());
        let mut prepared = PreparedReply {
            registry: self.clone(),
            keys: Vec::new(),
            token,
            message: Value::Null,
            expires,
            flushing: false,
            published: false,
        };
        let message = self
            .epoch
            .while_active(|| {
                let mut entries = self
                    .entries
                    .lock()
                    .map_err(|_| error(ErrorCode::GuestInternalError))?;
                let now = Instant::now();
                if now >= expires {
                    return Err(error(ErrorCode::ArtifactNotFound));
                }
                entries.retain(|_, entry| {
                    entry.expires > now || matches!(entry.phase, GrantPhase::Active(_))
                });
                let mut additions = Vec::new();
                let mut artifacts = Vec::new();
                for ((source, info), handle) in infos.iter().zip(handles) {
                    let key = GrantKey {
                        operation_id: operation_id.clone(),
                        artifact_id: info.artifact_id.clone(),
                        source: *source,
                    };
                    let mut artifact = descriptor(info, handle);
                    let mut reserve = true;
                    if let Some(entry) = entries.get(&key) {
                        if entry.expires <= now && matches!(entry.phase, GrantPhase::Active(_)) {
                            return Err(error(ErrorCode::ArtifactLimitExceeded));
                        }
                        if !same_metadata(&entry.artifact, &artifact)
                            || matches!(entry.phase, GrantPhase::Pending(_))
                        {
                            return Err(error(ErrorCode::InvalidRequest));
                        }
                        if !matches!(entry.phase, GrantPhase::Retired) {
                            artifact = entry.artifact.clone();
                            prepared.expires = prepared.expires.min(entry.expires);
                            reserve = false;
                        }
                    }
                    if reserve {
                        encode_header(&BinaryHeader::Ready(ReadyHeader {
                            protocol_version: "gaovm.binary.v1".to_owned(),
                            vm_id: self.epoch.vm_id().to_owned(),
                            driver_generation: self.epoch.driver_generation(),
                            operation_id: key.operation_id.clone(),
                            artifact: artifact.clone(),
                        }))
                        .map_err(|_| error(ErrorCode::ArtifactLimitExceeded))?;
                        additions.push((key, artifact.clone()));
                    }
                    artifacts.push(artifact);
                }
                if entries.len()
                    + additions
                        .iter()
                        .filter(|(key, _)| !entries.contains_key(key))
                        .count()
                    > MAX_GRANTS
                {
                    return Err(error(ErrorCode::ArtifactLimitExceeded));
                }
                if message["method"] == "artifact.collect" {
                    message["result"]["artifacts"] = json!(artifacts);
                }
                validate_message(&message)?;
                for (key, artifact) in additions {
                    entries.insert(
                        key.clone(),
                        GrantEntry {
                            artifact,
                            expires,
                            phase: GrantPhase::Pending(prepared.token.clone()),
                        },
                    );
                    prepared.keys.push(key);
                }
                Ok(message)
            })
            .ok_or_else(|| error(ErrorCode::InvalidRequest))??;
        prepared.message = message;
        Ok(prepared)
    }

    /// This does not authenticate a native binary peer. The service must check
    /// native host CID/private bridge ownership before parsing or calling here.
    pub fn try_open(
        &self,
        epoch: &ControlEpoch,
        open: &OpenHeader,
    ) -> Result<TransferLease, ProtocolError> {
        self.try_open_classified(epoch, open)
            .map_err(|failure| failure.error)
    }

    pub(crate) fn try_open_classified(
        &self,
        epoch: &ControlEpoch,
        open: &OpenHeader,
    ) -> Result<TransferLease, GrantOpenFailure> {
        if !self.epoch.same(epoch)
            || open.vm_id != self.epoch.vm_id()
            || open.driver_generation != self.epoch.driver_generation()
        {
            return Err(GrantOpenFailure::silent(ErrorCode::InvalidRequest));
        }
        encode_header(&BinaryHeader::Open(open.clone()))
            .map_err(|_| GrantOpenFailure::silent(ErrorCode::InvalidRequest))?;
        self.epoch.while_active(|| {
            let mut entries = self.entries.lock().map_err(|_| GrantOpenFailure::silent(ErrorCode::GuestInternalError))?;
            let key = GrantKey { operation_id: open.operation_id.clone(), artifact_id: open.artifact_id.clone(), source: GrantSource::from(&open.source) };
            let entry = entries.get(&key).ok_or_else(|| GrantOpenFailure::silent(ErrorCode::ArtifactNotFound))?;
            if entry.expires <= Instant::now() || !matches!(entry.phase, GrantPhase::Ready | GrantPhase::Active(_))
                || matches!(&open.source, BinarySource::Collection { stream_id } if *stream_id != entry.artifact.stream_id) {
                return Err(GrantOpenFailure::silent(ErrorCode::ArtifactNotFound));
            }
            let expires = entry.expires;
            let ready = matches!(entry.phase, GrantPhase::Ready);
            // Capacity is not authorization. Unknown/pending/expired/retired
            // bindings above stay silent even while this pool is exhausted.
            if entries.values().filter(|entry| matches!(entry.phase, GrantPhase::Active(_))).count() >= MAX_ACTIVE_TRANSFERS {
                return Err(GrantOpenFailure::verified(ErrorCode::ArtifactLimitExceeded, expires));
            }
            if !ready {
                return Err(GrantOpenFailure::verified(ErrorCode::ArtifactNotFound, expires));
            }
            let entry = entries.get_mut(&key).expect("binding verified under the same registry lock");
            let token = Arc::new(());
            entry.phase = GrantPhase::Active(token.clone());
            Ok(TransferLease { registry: self.clone(), key, token, artifact: entry.artifact.clone(), expires: entry.expires })
        }).ok_or_else(|| GrantOpenFailure::silent(ErrorCode::InvalidRequest))?
    }

    fn authorize(
        &self,
        session: &Session,
        request: &Value,
        method: &str,
    ) -> Result<(), ProtocolError> {
        if !session.belongs_to(&self.epoch) {
            return Err(error(ErrorCode::InvalidRequest));
        }
        session.authorize_request(request)?;
        if request["method"] != method {
            return Err(error(ErrorCode::InvalidRequest));
        }
        Ok(())
    }

    async fn handles(&self, count: usize, expires: Instant) -> Result<Vec<String>, ProtocolError> {
        if count == 0 {
            return Ok(Vec::new());
        }
        if count > 256 {
            return Err(error(ErrorCode::ArtifactLimitExceeded));
        }
        let permit = self
            .entropy
            .clone()
            .try_acquire_owned()
            .map_err(|_| error(ErrorCode::ArtifactLimitExceeded))?;
        // getrandom can block at early boot. Keep it off the control executor;
        // cancellation retains the one permit until the owned worker finishes.
        // The worker cannot mutate grants or activate a stale epoch.
        timeout_at(
            expires,
            tokio::task::spawn_blocking(move || {
                let _permit = permit;
                (0..count)
                    .map(|_| {
                        let mut bytes = [0; 32];
                        getrandom::fill(&mut bytes)
                            .map_err(|_| error(ErrorCode::GuestInternalError))?;
                        Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
                    })
                    .collect()
            }),
        )
        .await
        .map_err(|_| error(ErrorCode::ArtifactNotFound))?
        .map_err(|_| error(ErrorCode::GuestInternalError))?
    }
}

/// Immutable control envelope with an owned unpublished reservation. Activation
/// cannot be called independently of the real control frame's successful flush.
pub struct PreparedReply {
    registry: GrantRegistry,
    keys: Vec<GrantKey>,
    token: Arc<()>,
    message: Value,
    expires: Instant,
    flushing: bool,
    published: bool,
}

impl PreparedReply {
    pub fn message(&self) -> &Value {
        &self.message
    }

    pub async fn flush<W: AsyncWrite + Unpin>(
        mut self,
        writer: &mut FrameWriter<W>,
        deadline: Instant,
    ) -> io::Result<()> {
        if !self.registry.epoch.is_active() || Instant::now() >= self.expires {
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        self.flushing = true;
        tokio::select! {
            biased;
            () = self.registry.epoch.invalidated() => return Err(io::ErrorKind::BrokenPipe.into()),
            result = writer.write_object(&self.message, deadline.min(self.expires)) => result?,
        }
        self.registry.epoch.while_active(|| {
            let mut entries = self.registry.entries.lock().map_err(|_| io::ErrorKind::BrokenPipe)?;
            if self.keys.iter().any(|key| !entries.get(key).is_some_and(|entry| {
                entry.expires > Instant::now() && matches!(&entry.phase, GrantPhase::Pending(token) if Arc::ptr_eq(token, &self.token))
            })) { return Err(io::Error::from(io::ErrorKind::BrokenPipe)); }
            for key in &self.keys { entries.get_mut(key).expect("checked reservation").phase = GrantPhase::Ready; }
            Ok(())
        }).ok_or(io::ErrorKind::BrokenPipe)??;
        self.published = true;
        Ok(())
    }
}

impl Drop for PreparedReply {
    fn drop(&mut self) {
        if self.published {
            return;
        }
        if self.flushing {
            self.registry.epoch.invalidate();
        }
        if let Ok(mut entries) = self.registry.entries.lock() {
            for key in &self.keys {
                if entries.get(key).is_some_and(|entry| matches!(&entry.phase, GrantPhase::Pending(token) if Arc::ptr_eq(token, &self.token))) {
                    entries.remove(key);
                }
            }
        }
    }
}

/// Owns one reader slot. A failed/cancelled transfer drops this lease and may be
/// retried from byte zero; it never releases the collector's entire operation.
pub struct TransferLease {
    registry: GrantRegistry,
    key: GrantKey,
    token: Arc<()>,
    artifact: BinaryArtifact,
    expires: Instant,
}

impl TransferLease {
    pub fn artifact(&self) -> &BinaryArtifact {
        &self.artifact
    }

    pub(crate) fn expires(&self) -> Instant {
        self.expires
    }

    /// Send an owned, newly opened sealed reader from this grant's trusted
    /// source provider. All I/O remains owned by this future: cancellation,
    /// expiry, revocation and mismatched ACKs close it, without retiring spools.
    /// `open_deadline` is the original accept/open deadline, not a fresh budget.
    pub async fn serve<S: AsyncRead + AsyncWrite + Unpin, R: AsyncRead + Unpin>(
        self,
        stream: S,
        source: R,
        open_deadline: Instant,
        operation_deadline: Instant,
    ) -> io::Result<CompletedGrant> {
        if !self.registry.epoch.is_active() || Instant::now() >= self.expires {
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        let ready = BinaryHeader::Ready(ReadyHeader {
            protocol_version: "gaovm.binary.v1".to_owned(),
            vm_id: self.registry.epoch.vm_id().to_owned(),
            driver_generation: self.registry.epoch.driver_generation(),
            operation_id: self.key.operation_id.clone(),
            artifact: self.artifact.clone(),
        });
        let ack = tokio::select! {
            biased;
            () = self.registry.epoch.invalidated() => return Err(io::ErrorKind::ConnectionAborted.into()),
            result = timeout_at(self.expires, async {
                let stream = write_header(stream, &ready, open_deadline.min(operation_deadline).min(self.expires)).await?;
                let body_deadline = (Instant::now() + Duration::from_secs(30)).min(operation_deadline).min(self.expires);
                let stream = write_body(stream, source, &self.artifact, body_deadline).await?;
                let ack_deadline = (Instant::now() + Duration::from_secs(30)).min(operation_deadline).min(self.expires);
                let (ack, stream) = read_header(stream, ack_deadline).await?;
                drop(stream);
                Ok::<_, io::Error>(ack)
            }) => result.map_err(|_| io::ErrorKind::TimedOut)??,
        };
        let BinaryHeader::Committed(ack) = ack else {
            return Err(io::ErrorKind::InvalidData.into());
        };
        if ack.vm_id != self.registry.epoch.vm_id()
            || ack.driver_generation != self.registry.epoch.driver_generation()
            || ack.operation_id != self.key.operation_id
            || ack.artifact_id != self.artifact.artifact_id
            || ack.stream_id != self.artifact.stream_id
            || ack.size_bytes != self.artifact.size_bytes
            || ack.digest != self.artifact.digest
        {
            return Err(io::ErrorKind::InvalidData.into());
        }
        self.registry.epoch.while_active(|| {
            let mut entries = self.registry.entries.lock().map_err(|_| io::ErrorKind::BrokenPipe)?;
            let entry = entries.get_mut(&self.key).ok_or(io::ErrorKind::BrokenPipe)?;
            if entry.expires <= Instant::now() || !matches!(&entry.phase, GrantPhase::Active(token) if Arc::ptr_eq(token, &self.token)) {
                return Err(io::Error::from(io::ErrorKind::BrokenPipe));
            }
            entry.phase = GrantPhase::Retired;
            Ok(CompletedGrant { artifact_id: self.artifact.artifact_id.clone() })
        }).ok_or(io::ErrorKind::ConnectionAborted)?
    }
}

/// A fully correlated commit ACK was received in the active epoch. This does
/// not itself verify the remote host's filesystem or release an entire job.
pub struct CompletedGrant {
    artifact_id: String,
}

impl CompletedGrant {
    pub fn artifact_id(&self) -> &str {
        &self.artifact_id
    }
}

impl Drop for TransferLease {
    fn drop(&mut self) {
        if let Ok(mut entries) = self.registry.entries.lock()
            && let Some(entry) = entries.get_mut(&self.key)
            && matches!(&entry.phase, GrantPhase::Active(token) if Arc::ptr_eq(token, &self.token))
        {
            entry.phase = GrantPhase::Ready;
        }
    }
}

fn descriptor(info: &ArtifactInfo, stream_id: String) -> BinaryArtifact {
    BinaryArtifact {
        artifact_id: info.artifact_id.clone(),
        kind: info.kind.clone(),
        content_type: info.content_type.clone(),
        size_bytes: info.size_bytes,
        digest: info.digest.clone(),
        stream_id,
    }
}

fn same_metadata(left: &BinaryArtifact, right: &BinaryArtifact) -> bool {
    left.artifact_id == right.artifact_id
        && left.kind == right.kind
        && left.content_type == right.content_type
        && left.size_bytes == right.size_bytes
        && left.digest == right.digest
}

fn error(code: ErrorCode) -> ProtocolError {
    ProtocolError {
        code,
        message: "binary grant unavailable",
    }
}
