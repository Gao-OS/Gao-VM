//! Single-owner guest control bootstrap/lifecycle. The native acceptor must
//! authenticate its host peer before reserving a slot or reading any preface.
//! This module never authenticates a caller from JSON VM/generation strings.

use crate::control::{FrameReader, FrameWriter, NegotiationError, negotiate};
use crate::protocol::{ErrorCode, ProtocolError, validate_message};
use crate::session::{CORE_CAPABILITIES, ControlEpoch, Role, Session};
use serde_json::Value;
use std::future::Future;
use std::io;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::time::{Instant, timeout_at};

#[derive(Default)]
enum SlotState {
    #[default]
    Vacant,
    Opening(Arc<()>),
    Active(Arc<()>),
    Closing(Arc<()>),
}

/// One instance per guest service, not a daemon/global VM runtime singleton.
#[derive(Clone, Default)]
pub struct ControlSlot {
    state: Arc<Mutex<SlotState>>,
}

impl ControlSlot {
    pub fn new() -> Self {
        Self::default()
    }

    /// Reserve before consuming a first hello. Opening, active and cleanup
    /// owners all exclude a second binding; there is no implicit/default VM.
    pub fn reserve(&self) -> Result<OpeningControl, ProtocolError> {
        let mut state = self.state.lock().map_err(|_| internal())?;
        if !matches!(*state, SlotState::Vacant) {
            return Err(invalid());
        }
        let owner = Arc::new(());
        *state = SlotState::Opening(owner.clone());
        Ok(OpeningControl {
            slot: self.clone(),
            owner,
            completed: false,
            cleanup_required: false,
            started: false,
        })
    }
}

pub struct OpeningControl {
    slot: ControlSlot,
    owner: Arc<()>,
    completed: bool,
    cleanup_required: bool,
    started: bool,
}

impl OpeningControl {
    /// Adopt only a valid host-first hello, flush its acknowledgement, then
    /// complete the guest hello under the same original absolute deadline.
    /// The caller owns authenticated transport closure on failure/cancellation.
    pub async fn bootstrap<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(
        mut self,
        reader: &mut FrameReader<R>,
        writer: &mut FrameWriter<W>,
        offered: &[&str],
        required: &[&str],
        deadline: Instant,
    ) -> Result<ActiveControl, NegotiationError> {
        self.bootstrap_inner(reader, writer, offered, required, deadline, |_, _| async {
            Ok(())
        })
        .await
        .map(|(control, ())| control)
    }

    /// Initialization owns filesystem work. Keep its opening owner available
    /// on failure/cancellation so the coordinator can fence and quiesce it.
    pub(crate) async fn bootstrap_initialized<R, W, T, F, Fut>(
        &mut self,
        reader: &mut FrameReader<R>,
        writer: &mut FrameWriter<W>,
        deadline: Instant,
        initialize: F,
    ) -> Result<(ActiveControl, T), NegotiationError>
    where
        R: AsyncRead + Unpin,
        W: AsyncWrite + Unpin,
        F: FnOnce(String, u64) -> Fut,
        Fut: Future<Output = Result<T, ProtocolError>>,
    {
        self.cleanup_required = true;
        self.bootstrap_inner(
            reader,
            writer,
            &CORE_CAPABILITIES,
            &CORE_CAPABILITIES,
            deadline,
            initialize,
        )
        .await
    }

    async fn bootstrap_inner<R, W, T, F, Fut>(
        &mut self,
        reader: &mut FrameReader<R>,
        writer: &mut FrameWriter<W>,
        offered: &[&str],
        required: &[&str],
        deadline: Instant,
        initialize: F,
    ) -> Result<(ActiveControl, T), NegotiationError>
    where
        R: AsyncRead + Unpin,
        W: AsyncWrite + Unpin,
        F: FnOnce(String, u64) -> Fut,
        Fut: Future<Output = Result<T, ProtocolError>>,
    {
        let mut io = BootstrapIo {
            reader,
            writer,
            completed: false,
        };
        if self.started {
            return Err(NegotiationError::Protocol(invalid()));
        }
        self.started = true;
        {
            let state = self
                .slot
                .state
                .lock()
                .map_err(|_| NegotiationError::Protocol(internal()))?;
            if !matches!(&*state, SlotState::Opening(owner) if Arc::ptr_eq(owner, &self.owner)) {
                return Err(NegotiationError::Protocol(invalid()));
            }
        }
        let first = io
            .reader
            .read_object(deadline)
            .await
            .map_err(NegotiationError::Io)?
            .ok_or_else(|| NegotiationError::Io(io::ErrorKind::UnexpectedEof.into()))?;
        validate_message(&first).map_err(NegotiationError::Protocol)?;
        if first["kind"] != "request"
            || first["method"] != "session.hello"
            || first["params"]["peer_role"] != "host"
            || !first["operation_id"].is_null()
        {
            return Err(NegotiationError::Protocol(invalid()));
        }
        let vm = first["vm_id"]
            .as_str()
            .ok_or_else(|| NegotiationError::Protocol(invalid()))?;
        let generation = first["driver_generation"]
            .as_u64()
            .ok_or_else(|| NegotiationError::Protocol(invalid()))?;
        let mut session = Session::new(Role::Guest, vm, generation, offered, required)
            .map_err(NegotiationError::Protocol)?;
        let ack = session
            .receive_hello(&first)
            .map_err(NegotiationError::Protocol)?
            .ok_or_else(|| NegotiationError::Protocol(invalid()))?;
        let initialized = timeout_at(deadline, initialize(vm.to_owned(), generation))
            .await
            .map_err(|_| NegotiationError::Io(io::ErrorKind::TimedOut.into()))?
            .map_err(NegotiationError::Protocol)?;
        io.writer
            .write_object(&ack, deadline)
            .await
            .map_err(NegotiationError::Io)?;
        let epoch = negotiate(&mut session, io.reader, io.writer, deadline).await?;
        {
            let mut state = self
                .slot
                .state
                .lock()
                .map_err(|_| NegotiationError::Protocol(internal()))?;
            if Instant::now() >= deadline {
                return Err(NegotiationError::Io(io::ErrorKind::TimedOut.into()));
            }
            if !matches!(&*state, SlotState::Opening(owner) if Arc::ptr_eq(owner, &self.owner)) {
                return Err(NegotiationError::Protocol(invalid()));
            }
            *state = SlotState::Active(self.owner.clone());
        }
        io.completed = true;
        self.completed = true;
        Ok((
            ActiveControl {
                slot: self.slot.clone(),
                owner: self.owner.clone(),
                session: Arc::new(session),
                epoch,
            },
            initialized,
        ))
    }

    /// After closing the failed opening's transport, quiesce its resource owner
    /// before finishing this cleanup slot. An active owner cannot be closed here.
    pub fn begin_close(self) -> Result<ClosingControl, ProtocolError> {
        let mut state = self.slot.state.lock().map_err(|_| internal())?;
        if !matches!(&*state, SlotState::Opening(owner) | SlotState::Closing(owner)
            if Arc::ptr_eq(owner, &self.owner))
        {
            return Err(invalid());
        }
        *state = SlotState::Closing(self.owner.clone());
        Ok(ClosingControl {
            slot: self.slot.clone(),
            owner: self.owner.clone(),
        })
    }
}

impl Drop for OpeningControl {
    fn drop(&mut self) {
        if !self.completed
            && let Ok(mut state) = self.slot.state.lock()
            && matches!(&*state, SlotState::Opening(owner) if Arc::ptr_eq(owner, &self.owner))
        {
            *state = if self.cleanup_required {
                SlotState::Closing(self.owner.clone())
            } else {
                SlotState::Vacant
            };
        }
    }
}

struct BootstrapIo<'a, R: AsyncRead + Unpin, W: AsyncWrite + Unpin> {
    reader: &'a mut FrameReader<R>,
    writer: &'a mut FrameWriter<W>,
    completed: bool,
}

impl<R: AsyncRead + Unpin, W: AsyncWrite + Unpin> Drop for BootstrapIo<'_, R, W> {
    fn drop(&mut self) {
        if !self.completed {
            self.reader.invalidate();
            self.writer.invalidate();
        }
    }
}

pub struct ActiveControl {
    slot: ControlSlot,
    owner: Arc<()>,
    session: Arc<Session>,
    epoch: ControlEpoch,
}

impl ActiveControl {
    pub fn session(&self) -> &Session {
        &self.session
    }
    pub fn epoch(&self) -> &ControlEpoch {
        &self.epoch
    }

    pub(crate) fn shared_session(&self) -> Arc<Session> {
        self.session.clone()
    }

    /// Fence EOF/framing errors/deadlines before returning to the service.
    /// Application authorization remains with Session/handlers: rejecting a
    /// stale request must not silently rebind or invalidate a healthy session.
    /// Cancelling this borrowed read remains resumable while the owner lives;
    /// abandoning the owner instead fences it through Drop.
    pub async fn read_message<R: AsyncRead + Unpin>(
        &self,
        reader: &mut FrameReader<R>,
        deadline: Instant,
    ) -> io::Result<Option<Value>> {
        let result = tokio::select! {
            biased;
            () = self.epoch.invalidated() => Err(io::ErrorKind::ConnectionAborted.into()),
            result = reader.read_object(deadline) => result,
        };
        if !self.epoch.is_active() {
            self.fence();
            reader.invalidate();
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        if !matches!(&result, Ok(Some(_))) {
            self.fence();
            reader.invalidate();
        }
        result
    }

    /// Fence before the service aborts/joins owned transfers and shuts down
    /// executions. Admission stays closed throughout that cleanup.
    pub fn begin_close(self) -> ClosingControl {
        self.fence();
        ClosingControl {
            slot: self.slot.clone(),
            owner: self.owner.clone(),
        }
    }

    fn fence(&self) {
        self.epoch.invalidate();
        if let Ok(mut state) = self.slot.state.lock()
            && matches!(&*state, SlotState::Active(owner) if Arc::ptr_eq(owner, &self.owner))
        {
            *state = SlotState::Closing(self.owner.clone());
        }
    }
}

impl Drop for ActiveControl {
    fn drop(&mut self) {
        self.fence();
    }
}

/// Dropping a cleanup owner never reopens admission. Only the coordinating
/// service may finish after all owned I/O/process/spool cleanup is confirmed.
pub struct ClosingControl {
    slot: ControlSlot,
    owner: Arc<()>,
}

impl ClosingControl {
    pub fn finish(self) -> Result<(), ProtocolError> {
        let mut state = self.slot.state.lock().map_err(|_| internal())?;
        if !matches!(&*state, SlotState::Closing(owner) if Arc::ptr_eq(owner, &self.owner)) {
            return Err(invalid());
        }
        *state = SlotState::Vacant;
        Ok(())
    }
}

fn invalid() -> ProtocolError {
    ProtocolError {
        code: ErrorCode::InvalidRequest,
        message: "guest control ownership or hello is invalid",
    }
}
fn internal() -> ProtocolError {
    ProtocolError {
        code: ErrorCode::GuestInternalError,
        message: "guest control unavailable",
    }
}
