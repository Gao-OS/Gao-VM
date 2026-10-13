//! Per-control-epoch P0 composition. Not a listener, native peer authenticator,
//! installed service, or durable host operation/artifact repository.

use crate::artifact::{ArtifactCollector, ArtifactLimits};
use crate::binary::{
    BinaryArtifact, BinaryErrorCode, BinaryFailure, BinaryHeader, BinarySource, ErrorHeader,
    ExecOutput, OpenHeader,
};
use crate::binary_io::write_header;
use crate::control::{FrameReader, FrameWriter, NegotiationError};
use crate::exec::{ExecLimits, Executor, OutputStream};
use crate::grants::{CompletedGrant, GrantRegistry, PreparedReply, TransferLease};
use crate::guest_connection::{ActiveControl, OpeningControl};
use crate::protocol::{ErrorCode, PROTOCOL_VERSION, ProtocolError, validate_message};
use crate::session::{CORE_CAPABILITIES, ControlEpoch, Session};
use crate::spool::{AsyncSpoolReader, SpoolBudget};
use crate::system::SystemQueries;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore};
use tokio::time::{Instant, timeout_at};

/// One process-lifetime resource owner, reused for replacement control epochs.
#[derive(Clone)]
pub struct GuestResources {
    artifact_root: PathBuf,
    spool_parent: PathBuf,
    system_root: PathBuf,
    blocking: Arc<Semaphore>,
    spool_budget: SpoolBudget,
}

impl GuestResources {
    pub fn new(artifact_root: &Path, spool_parent: &Path, system_root: &Path) -> Self {
        Self::with_spool_budget(
            artifact_root,
            spool_parent,
            system_root,
            SpoolBudget::default(),
        )
    }

    pub fn with_spool_budget(
        artifact_root: &Path,
        spool_parent: &Path,
        system_root: &Path,
        spool_budget: SpoolBudget,
    ) -> Self {
        Self {
            artifact_root: artifact_root.to_owned(),
            spool_parent: spool_parent.to_owned(),
            system_root: system_root.to_owned(),
            blocking: Arc::new(Semaphore::new(1)),
            spool_budget,
        }
    }

    pub fn bind(&self, control: &ActiveControl) -> Result<GuestDispatcher, ProtocolError> {
        let epoch = control.epoch().clone();
        if !epoch.is_active() {
            return Err(fault(ErrorCode::InvalidRequest));
        }
        let initialized = self.initialize(epoch.vm_id(), epoch.driver_generation())?;
        self.attach(control, initialized)
    }

    /// The caller authenticates the native peer before this entry point. Local
    /// handlers/storage initialize before either guest hello or host hello ACK.
    /// On error/cancel, close the transport and quiesce before finishing the
    /// retained opening's cleanup owner. Dropping it instead leaves admission shut.
    pub async fn bootstrap<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(
        &self,
        opening: &mut OpeningControl,
        reader: &mut FrameReader<R>,
        writer: &mut FrameWriter<W>,
        deadline: Instant,
    ) -> Result<(ActiveControl, GuestDispatcher), NegotiationError> {
        let resources = self.clone();
        let budget = self.spool_budget.clone();
        let (control, initialized) = opening
            .bootstrap_initialized(reader, writer, deadline, move |vm, generation| async move {
                budget
                    .spawn(move || resources.initialize(&vm, generation))
                    .map_err(|_| fault(ErrorCode::GuestInternalError))?
                    .await
                    .map_err(|_| fault(ErrorCode::GuestInternalError))?
                    .finish()
            })
            .await?;
        let dispatcher = self
            .attach(&control, initialized)
            .map_err(NegotiationError::Protocol)?;
        Ok((control, dispatcher))
    }

    fn initialize(
        &self,
        vm: &str,
        generation: u64,
    ) -> Result<InitializedDispatcher, ProtocolError> {
        let _healthy = self
            .spool_budget
            .try_reserve(0)
            .ok_or_else(|| fault(ErrorCode::GuestInternalError))?;
        // Availability, not a reusable grant: every published handle still gets
        // fresh CSPRNG bytes through its owned metadata worker.
        getrandom::fill(&mut [0; 32]).map_err(|_| fault(ErrorCode::GuestInternalError))?;
        let system = SystemQueries::new(vm, generation, &self.system_root)?;
        let executor = Executor::with_spool_budget(
            vm,
            generation,
            &self.spool_parent,
            ExecLimits::default(),
            self.spool_budget.clone(),
        )?;
        let collector = ArtifactCollector::with_spool_budget(
            vm,
            generation,
            &self.artifact_root,
            &self.spool_parent,
            ArtifactLimits::default(),
            self.spool_budget.clone(),
        )?;
        Ok(InitializedDispatcher {
            system,
            executor,
            collector,
        })
    }

    fn attach(
        &self,
        control: &ActiveControl,
        initialized: InitializedDispatcher,
    ) -> Result<GuestDispatcher, ProtocolError> {
        let epoch = control.epoch().clone();
        let grants = GrantRegistry::with_blocking_worker(epoch.clone(), self.blocking.clone())?;
        Ok(GuestDispatcher {
            session: control.shared_session(),
            epoch,
            system: Arc::new(initialized.system),
            blocking: self.blocking.clone(),
            spool_budget: self.spool_budget.clone(),
            executor: Mutex::new(initialized.executor),
            collections: Mutex::new(Collections {
                collector: initialized.collector,
                requests: BTreeMap::new(),
            }),
            grants,
        })
    }

    /// After fencing an epoch, join its tasks and drop its dispatcher before
    /// this final barrier. Failed cleanup must keep the closing slot fenced;
    /// replacing this resource owner would hide the quarantined spool charge.
    pub async fn quiesce(&self) -> Result<(), ProtocolError> {
        self.spool_budget
            .quiesce()
            .await
            .map_err(|_| fault(ErrorCode::GuestInternalError))?;
        let _worker = self
            .blocking
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| fault(ErrorCode::GuestInternalError))?;
        Ok(())
    }
}

struct InitializedDispatcher {
    system: SystemQueries,
    executor: Executor,
    collector: ArtifactCollector,
}

pub struct GuestDispatcher {
    session: Arc<Session>,
    epoch: ControlEpoch,
    system: Arc<SystemQueries>,
    blocking: Arc<Semaphore>,
    spool_budget: SpoolBudget,
    executor: Mutex<Executor>,
    collections: Mutex<Collections>,
    grants: GrantRegistry,
}

struct Collections {
    collector: ArtifactCollector,
    requests: BTreeMap<String, Value>,
}

impl GuestDispatcher {
    /// Fence first, reap owned executions and wait for the shared blocking
    /// worker. The coordinator also joins capture/transfer futures, closes both
    /// control halves, drops this context and passes GuestResources::quiesce
    /// before finishing its cleanup slot.
    pub async fn shutdown(&self) -> Result<(), ProtocolError> {
        self.epoch.invalidate();
        self.executor.lock().await.shutdown().await?;
        let _captures = self.collections.lock().await;
        let _worker = self
            .blocking
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| fault(ErrorCode::GuestInternalError))?;
        self.spool_budget
            .quiesce()
            .await
            .map_err(|_| fault(ErrorCode::GuestInternalError))?;
        Ok(())
    }

    pub async fn prepare_request(
        &self,
        request: &Value,
        expires: Instant,
    ) -> Result<GuestReply, ProtocolError> {
        self.session.authorize_request(request)?;
        if Instant::now() >= expires {
            return Err(fault(ErrorCode::InvalidRequest));
        }
        let outcome = self.prepare_authorized(request, expires).await;
        if !self.epoch.is_active() {
            return Err(fault(ErrorCode::InvalidRequest));
        }
        match outcome {
            Ok(reply) => Ok(reply),
            Err(error) => {
                let message = json!({"protocol_version": PROTOCOL_VERSION, "kind": "error", "id": request["id"],
                    "method": request["method"], "vm_id": self.epoch.vm_id(), "driver_generation": self.epoch.driver_generation(),
                    "operation_id": request["operation_id"],
                    "error": {"code": error.code, "message": error.message, "retryable": false}});
                validate_message(&message).map_err(|_| fault(ErrorCode::GuestInternalError))?;
                Ok(GuestReply {
                    epoch: self.epoch.clone(),
                    body: ReplyBody::Plain(message),
                })
            }
        }
    }

    async fn prepare_authorized(
        &self,
        request: &Value,
        expires: Instant,
    ) -> Result<GuestReply, ProtocolError> {
        if request["method"] == "artifact.collect" {
            // Do not queue unbounded capture futures behind a held collector.
            let mut collections = self
                .collections
                .try_lock()
                .map_err(|_| fault(ErrorCode::GuestInternalError))?;
            let reply = self
                .grants
                .prepare_collection(&self.session, &mut collections.collector, request, expires)
                .await?;
            collections.requests.insert(
                request["operation_id"]
                    .as_str()
                    .expect("authorized collection operation")
                    .to_owned(),
                request.clone(),
            );
            return Ok(GuestReply {
                epoch: self.epoch.clone(),
                body: ReplyBody::Grants(reply),
            });
        }
        if request["method"] == "exec.status" {
            let pending = {
                let mut executor = self
                    .executor
                    .try_lock()
                    .map_err(|_| fault(ErrorCode::GuestInternalError))?;
                self.grants
                    .prepare_exec_status(&self.session, &mut executor, request, expires)
            };
            let reply = pending.await?;
            return Ok(GuestReply {
                epoch: self.epoch.clone(),
                body: ReplyBody::Grants(reply),
            });
        }
        let message = match request["method"].as_str() {
            Some("capabilities.get") => {
                json!({"protocol_version": PROTOCOL_VERSION, "kind": "response", "id": request["id"],
                "method": "capabilities.get", "vm_id": self.epoch.vm_id(), "driver_generation": self.epoch.driver_generation(),
                "operation_id": request["operation_id"], "result": {"capabilities": CORE_CAPABILITIES}})
            }
            Some("health") => self.system.handle(&self.session, request)?,
            Some("system.info") => self.system_info(request, expires).await?,
            Some("exec.start" | "exec.cancel") => self
                .executor
                .try_lock()
                .map_err(|_| fault(ErrorCode::GuestInternalError))?
                .handle(&self.session, request)?,
            _ => return Err(fault(ErrorCode::CapabilityNotSupported)),
        };
        validate_message(&message).map_err(|_| fault(ErrorCode::GuestInternalError))?;
        Ok(GuestReply {
            epoch: self.epoch.clone(),
            body: ReplyBody::Plain(message),
        })
    }

    async fn system_info(&self, request: &Value, expires: Instant) -> Result<Value, ProtocolError> {
        let permit = self
            .blocking
            .clone()
            .try_acquire_owned()
            .map_err(|_| fault(ErrorCode::GuestInternalError))?;
        let system = self.system.clone();
        let session = self.session.clone();
        let request = request.clone();
        let worker = tokio::task::spawn_blocking(move || {
            // The permit stays in the worker, even when its caller is cancelled.
            let _permit = permit;
            system.handle(&session, &request)
        });
        tokio::select! {
            biased;
            () = self.epoch.invalidated() => Err(fault(ErrorCode::InvalidRequest)),
            result = timeout_at(expires, worker) => result.map_err(|_| fault(ErrorCode::GuestInternalError))?
                .map_err(|_| fault(ErrorCode::GuestInternalError))?,
        }
    }

    /// The native coordinator must authenticate before parsing/calling here.
    /// Grant admission precedes file lookup; no path comes from the binary peer.
    pub async fn open_transfer(&self, open: &OpenHeader) -> Result<GuestTransfer, ProtocolError> {
        let lease = self.grants.try_open(&self.epoch, open)?;
        let source = self.transfer_source(open, &lease)?;
        Ok(GuestTransfer { lease, source })
    }

    pub(crate) async fn prepare_open(&self, open: &OpenHeader) -> Result<GuestOpen, ProtocolError> {
        // Error codes are not authorization. Only a live matched published
        // binding can authorize a quota/busy reply before source lookup.
        let lease = match self.grants.try_open_classified(&self.epoch, open) {
            Ok(lease) => lease,
            Err(failure) => {
                return match failure.verified_until {
                    Some(expires) => Ok(GuestOpen::Error(GuestOpenError::new(
                        self.epoch.clone(),
                        open,
                        failure.error.code,
                        expires,
                    ))),
                    None => Err(failure.error),
                };
            }
        };
        match self.transfer_source(open, &lease) {
            Ok(source) => Ok(GuestOpen::Transfer(GuestTransfer { lease, source })),
            Err(error) => Ok(GuestOpen::Error(GuestOpenError::new(
                self.epoch.clone(),
                open,
                error.code,
                lease.expires(),
            ))),
        }
    }

    fn transfer_source(
        &self,
        open: &OpenHeader,
        lease: &TransferLease,
    ) -> Result<AsyncSpoolReader, ProtocolError> {
        let file = match &open.source {
            BinarySource::Collection { .. } => {
                let collections = self
                    .collections
                    .try_lock()
                    .map_err(|_| fault(ErrorCode::GuestInternalError))?;
                let request = collections
                    .requests
                    .get(&open.operation_id)
                    .ok_or_else(|| fault(ErrorCode::ArtifactNotFound))?;
                collections
                    .collector
                    .open_artifact(&self.session, request, &open.artifact_id)?
                    .into_inner()
            }
            BinarySource::ExecOutput { output } => {
                let executor = self
                    .executor
                    .try_lock()
                    .map_err(|_| fault(ErrorCode::GuestInternalError))?;
                let request = json!({"protocol_version": PROTOCOL_VERSION, "kind": "request", "id": "binary-source",
                    "method": "exec.status", "vm_id": self.epoch.vm_id(), "driver_generation": self.epoch.driver_generation(),
                    "operation_id": open.operation_id, "params": {}});
                let output = match output {
                    ExecOutput::Stdout => OutputStream::Stdout,
                    ExecOutput::Stderr => OutputStream::Stderr,
                };
                let metadata = executor
                    .output_artifact(&self.session, &request, output)?
                    .ok_or_else(|| fault(ErrorCode::ArtifactNotFound))?;
                let expected = lease.artifact();
                if metadata.artifact_id != expected.artifact_id
                    || metadata.size_bytes != expected.size_bytes
                    || metadata.digest != expected.digest
                    || metadata.kind != expected.kind
                    || metadata.content_type != expected.content_type
                {
                    return Err(fault(ErrorCode::ArtifactNotFound));
                }
                executor
                    .open_output(&self.session, &request, output)?
                    .ok_or_else(|| fault(ErrorCode::ArtifactNotFound))?
                    .into_inner()
            }
        };
        // Preserve the raw reader rather than its Take limit: the body writer
        // must detect an overlong/mutated retained file, not silently truncate it.
        Ok(file.into_async())
    }
}

impl Drop for GuestDispatcher {
    fn drop(&mut self) {
        self.epoch.invalidate();
    }
}

pub(crate) enum GuestOpen {
    Transfer(GuestTransfer),
    Error(GuestOpenError),
}

impl GuestOpen {
    pub(crate) async fn serve<S: AsyncRead + AsyncWrite + Unpin>(
        self,
        stream: S,
        open_deadline: Instant,
        operation_deadline: Instant,
        opening: OwnedSemaphorePermit,
    ) -> io::Result<()> {
        match self {
            Self::Transfer(transfer) => {
                drop(opening);
                transfer
                    .serve(stream, open_deadline, operation_deadline)
                    .await
                    .map(|_| ())
            }
            Self::Error(error) => {
                // An error has no active transfer lease. Keep the opening
                // charged until its error flush/owned transport closes.
                let result = error
                    .serve(stream, open_deadline.min(operation_deadline))
                    .await;
                drop(opening);
                result
            }
        }
    }
}

pub(crate) struct GuestOpenError {
    epoch: ControlEpoch,
    header: BinaryHeader,
    expires: Instant,
}

impl GuestOpenError {
    fn new(epoch: ControlEpoch, open: &OpenHeader, code: ErrorCode, expires: Instant) -> Self {
        let code = match code {
            ErrorCode::ArtifactNotFound => BinaryErrorCode::ArtifactNotFound,
            ErrorCode::ArtifactLimitExceeded => BinaryErrorCode::ArtifactLimitExceeded,
            ErrorCode::InvalidRequest => BinaryErrorCode::InvalidRequest,
            _ => BinaryErrorCode::GuestInternalError,
        };
        Self {
            header: BinaryHeader::Error(ErrorHeader {
                protocol_version: "gaovm.binary.v1".to_owned(),
                vm_id: epoch.vm_id().to_owned(),
                driver_generation: epoch.driver_generation(),
                operation_id: open.operation_id.clone(),
                artifact_id: open.artifact_id.clone(),
                error: BinaryFailure {
                    code,
                    message: if code == BinaryErrorCode::ArtifactLimitExceeded {
                        "binary transfer limit reached"
                    } else {
                        "binary source unavailable"
                    }
                    .to_owned(),
                    retryable: code == BinaryErrorCode::ArtifactLimitExceeded,
                },
            }),
            epoch,
            expires,
        }
    }

    async fn serve<S: AsyncRead + AsyncWrite + Unpin>(
        self,
        stream: S,
        deadline: Instant,
    ) -> io::Result<()> {
        let deadline = deadline.min(self.expires);
        if !self.epoch.is_active() {
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        tokio::select! {
            biased;
            () = self.epoch.invalidated() => Err(io::ErrorKind::ConnectionAborted.into()),
            result = write_header(stream, &self.header, deadline) => result.map(|_| ()),
        }
    }
}

pub struct GuestReply {
    epoch: ControlEpoch,
    body: ReplyBody,
}

enum ReplyBody {
    Plain(Value),
    Grants(PreparedReply),
}

impl GuestReply {
    pub fn message(&self) -> &Value {
        match &self.body {
            ReplyBody::Plain(message) => message,
            ReplyBody::Grants(reply) => reply.message(),
        }
    }

    pub async fn flush<W: AsyncWrite + Unpin>(
        self,
        writer: &mut FrameWriter<W>,
        deadline: Instant,
    ) -> io::Result<()> {
        if !self.epoch.is_active() {
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        match self.body {
            ReplyBody::Grants(reply) => reply.flush(writer, deadline).await,
            ReplyBody::Plain(message) => {
                let mut pending = PendingReply {
                    epoch: self.epoch,
                    complete: false,
                };
                tokio::select! {
                    biased;
                    () = pending.epoch.invalidated() => return Err(io::ErrorKind::ConnectionAborted.into()),
                    result = writer.write_object(&message, deadline) => result?,
                }
                pending.complete = true;
                Ok(())
            }
        }
    }
}

pub struct GuestTransfer {
    lease: TransferLease,
    source: AsyncSpoolReader,
}

impl GuestTransfer {
    pub fn artifact(&self) -> &BinaryArtifact {
        self.lease.artifact()
    }

    pub async fn serve<S: AsyncRead + AsyncWrite + Unpin>(
        self,
        stream: S,
        open_deadline: Instant,
        operation_deadline: Instant,
    ) -> io::Result<CompletedGrant> {
        self.lease
            .serve(stream, self.source, open_deadline, operation_deadline)
            .await
    }
}

struct PendingReply {
    epoch: ControlEpoch,
    complete: bool,
}

impl Drop for PendingReply {
    fn drop(&mut self) {
        if !self.complete {
            self.epoch.invalidate();
        }
    }
}

fn fault(code: ErrorCode) -> ProtocolError {
    ProtocolError {
        code,
        message: "guest work unavailable",
    }
}
