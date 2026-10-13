//! Process-lifetime, bounded same-port routing. Native peer authentication must
//! precede `accept`; generic owned streams are available for Unix fixtures only,
//! not a native transport fallback. Deployment and durable host ACKs are separate.

use crate::binary_io::{Demultiplexed, accept_preface};
use crate::control::{FrameReader, FrameWriter, NegotiationError};
use crate::dispatcher::GuestResources;
use crate::guest_connection::ControlSlot;
use crate::service::{GuestControl, GuestSessionHandle};
use std::io;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{OwnedSemaphorePermit, watch};
use tokio::task::JoinSet;
use tokio::time::{Duration, Instant};

// One established control owner plus the listener's eight pending openings.
const MAX_OWNED_CONNECTIONS: usize = 9;

struct ActiveSession {
    owner: Arc<()>,
    handle: GuestSessionHandle,
}

struct Shared {
    active: Mutex<Option<ActiveSession>>,
    stopped: watch::Sender<bool>,
}

impl Shared {
    fn stop(&self) {
        self.stopped.send_replace(true);
        // Recover only for fencing/cleanup; poisoned state never admits work.
        let mut active = match self.active.lock() {
            Ok(active) => active,
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Some(session) = active.take() {
            session.handle.stop();
        }
    }
}

pub struct GuestAcceptor {
    resources: GuestResources,
    slot: ControlSlot,
    shared: Arc<Shared>,
    budget: Duration,
    jobs: JoinSet<io::Result<()>>,
    failed: bool,
}

impl GuestAcceptor {
    pub fn new(resources: GuestResources, budget: Duration) -> io::Result<Self> {
        if budget.is_zero() || Instant::now().checked_add(budget).is_none() {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let (stopped, _) = watch::channel(false);
        Ok(Self {
            resources,
            slot: ControlSlot::new(),
            shared: Arc::new(Shared {
                active: Mutex::new(None),
                stopped,
            }),
            budget,
            jobs: JoinSet::new(),
            failed: false,
        })
    }

    /// Called only after native peer admission. Own the stream, listener's
    /// opening permit and original deadline; never refresh them after demux.
    pub fn accept<S: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
        &mut self,
        stream: S,
        opening: OwnedSemaphorePermit,
        open_deadline: Instant,
        operation_deadline: Instant,
    ) -> io::Result<()> {
        while let Some(result) = self.jobs.try_join_next() {
            self.observe(result);
        }
        if self.failed || *self.shared.stopped.borrow() {
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        if self.jobs.len() >= MAX_OWNED_CONNECTIONS {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let runtime =
            tokio::runtime::Handle::try_current().map_err(|_| io::ErrorKind::NotConnected)?;
        let resources = self.resources.clone();
        let slot = self.slot.clone();
        let shared = self.shared.clone();
        let budget = self.budget;
        let mut stop = shared.stopped.subscribe();
        self.jobs.spawn_on(async move {
            let deadline = open_deadline.min(operation_deadline);
            let framed = tokio::select! {
                biased;
                _ = stopped(&mut stop) => return Ok(()),
                framed = accept_preface(stream, deadline) => framed?,
            };
            match framed {
                Demultiplexed::Control { length_prefix, stream } => {
                    let (read, write) = tokio::io::split(stream);
                    let control = tokio::select! {
                        biased;
                        _ = stopped(&mut stop) => return Ok(()),
                        control = GuestControl::bootstrap(&resources, &slot,
                            FrameReader::from_length_prefix(read, length_prefix, deadline),
                            FrameWriter::new(write), deadline) => control.map_err(negotiation_error)?,
                    };
                    drop(opening);
                    let owner = Arc::new(());
                    {
                        let mut active = shared.active.lock().map_err(|_| io::ErrorKind::Other)?;
                        if *shared.stopped.borrow() {
                            control.handle().stop();
                        } else {
                            *active = Some(ActiveSession { owner: owner.clone(), handle: control.handle() });
                        }
                    }
                    // Stop requests the owned coordinator's graceful barrier;
                    // never cancel its run future as ordinary service shutdown.
                    let result = control.run(budget).await;
                    let mut active = shared.active.lock().map_err(|_| io::ErrorKind::Other)?;
                    if active.as_ref().is_some_and(|session| Arc::ptr_eq(&session.owner, &owner)) {
                        active.take();
                    }
                    result
                }
                Demultiplexed::Binary { stream } => {
                    let handle = shared.active.lock().map_err(|_| io::ErrorKind::Other)?
                        .as_ref().map(|session| session.handle.clone()).ok_or(io::ErrorKind::NotConnected)?;
                    handle.accept_prefaced_binary(stream, opening, deadline, operation_deadline)
                }
            }
        }, &runtime);
        Ok(())
    }

    fn observe(&mut self, result: Result<io::Result<()>, tokio::task::JoinError>) {
        let failed = match result {
            Err(_) => true,
            Ok(Err(error)) => error.kind() == io::ErrorKind::Other,
            Ok(Ok(())) => false,
        };
        if failed {
            self.failed = true;
            self.shared.stop();
        }
    }

    /// Supervise finished owners even when no new peer arrives. Cancelling this
    /// wait does not cancel or detach a connection's owned work.
    pub async fn completed(&mut self) -> io::Result<()> {
        if self.failed {
            return Err(io::ErrorKind::Other.into());
        }
        let Some(result) = self.jobs.join_next().await else {
            return std::future::pending().await;
        };
        self.observe(result);
        if self.failed {
            return Err(io::ErrorKind::Other.into());
        }
        Ok(())
    }

    /// Permanently close admission, join every opening/control owner, then
    /// confirm actual filesystem-worker cleanup. This instance cannot restart.
    pub async fn shutdown(mut self) -> io::Result<()> {
        self.shared.stop();
        while let Some(result) = self.jobs.join_next().await {
            self.observe(result);
        }
        self.resources
            .quiesce()
            .await
            .map_err(|_| io::ErrorKind::Other)?;
        if self.failed {
            return Err(io::ErrorKind::Other.into());
        }
        Ok(())
    }
}

impl Drop for GuestAcceptor {
    fn drop(&mut self) {
        self.shared.stop();
        self.jobs.abort_all();
        // Abandonment fences ownership, but does not claim joined cleanup.
    }
}

async fn stopped(stop: &mut watch::Receiver<bool>) {
    loop {
        if *stop.borrow_and_update() || stop.changed().await.is_err() {
            return;
        }
    }
}

fn negotiation_error(error: NegotiationError) -> io::Error {
    match error {
        NegotiationError::Io(error) => error,
        NegotiationError::Protocol(error)
            if error.code == crate::protocol::ErrorCode::GuestInternalError =>
        {
            io::ErrorKind::Other.into()
        }
        NegotiationError::Protocol(_) => io::ErrorKind::InvalidData.into(),
    }
}
