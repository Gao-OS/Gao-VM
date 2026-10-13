//! Owned per-epoch control execution. The native acceptor authenticates the
//! peer and restores any demultiplexed control prefix before this entry point.
//! This is not an installed service or a host durable artifact publisher.

use crate::binary::BinaryHeader;
use crate::binary_io::{Demultiplexed, accept_preface, read_header};
use crate::control::{FrameReader, FrameWriter, NegotiationError};
use crate::dispatcher::{GuestDispatcher, GuestResources};
use crate::guest_connection::{ActiveControl, ControlSlot};
use crate::session::ControlEpoch;
use std::io;
use std::sync::{Arc, Mutex as StateMutex, Weak};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{Mutex, OwnedSemaphorePermit};
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::{Duration, Instant, timeout_at};

const MAX_REQUESTS: usize = 8;
// Eight admitted openings plus two already-active body/ACK jobs.
const MAX_BINARY_JOBS: usize = 10;

#[derive(Clone)]
pub struct GuestSessionHandle {
    epoch: ControlEpoch,
    dispatcher: Weak<GuestDispatcher>,
    work: Arc<StateMutex<BinaryWork>>,
}

struct BinaryWork {
    closed: bool,
    stop_requested: bool,
    jobs: Vec<JoinHandle<io::Result<()>>>,
}

impl GuestSessionHandle {
    /// Request graceful shutdown of this control epoch. This is a trusted
    /// local-service action, not a guest power RPC. `run` owns the final cleanup
    /// barrier; calling this method does not itself release the control slot.
    pub fn stop(&self) {
        if let Ok(mut work) = self.work.lock() {
            work.stop_requested = true;
            work.closed = true;
        }
        self.epoch.invalidate();
    }

    /// Native authentication must precede this call. Retain the long-lived
    /// listener's opening permit and original deadline through grant admission.
    /// GAB1/JSON bindings do not authenticate a peer. Jobs own their transports;
    /// caller cancellation cannot detach them from control cleanup.
    pub fn accept_binary<S: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
        &self,
        stream: S,
        opening: OwnedSemaphorePermit,
        open_deadline: Instant,
        operation_deadline: Instant,
    ) -> io::Result<()> {
        self.enqueue_binary(stream, opening, open_deadline, operation_deadline, false)
    }

    pub(crate) fn accept_prefaced_binary<S: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
        &self,
        stream: S,
        opening: OwnedSemaphorePermit,
        open_deadline: Instant,
        operation_deadline: Instant,
    ) -> io::Result<()> {
        self.enqueue_binary(stream, opening, open_deadline, operation_deadline, true)
    }

    fn enqueue_binary<S: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
        &self,
        stream: S,
        opening: OwnedSemaphorePermit,
        open_deadline: Instant,
        operation_deadline: Instant,
        prefaced: bool,
    ) -> io::Result<()> {
        let deadline = open_deadline.min(operation_deadline);
        if !self.epoch.is_active() || Instant::now() >= deadline {
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        let runtime =
            tokio::runtime::Handle::try_current().map_err(|_| io::ErrorKind::NotConnected)?;
        let mut work = self.work.lock().map_err(|_| io::ErrorKind::Other)?;
        if work.closed {
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        work.jobs.retain(|job| !job.is_finished());
        if work.jobs.len() >= MAX_BINARY_JOBS {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let dispatcher = self
            .dispatcher
            .upgrade()
            .ok_or(io::ErrorKind::ConnectionAborted)?;
        let epoch = self.epoch.clone();
        work.jobs.push(runtime.spawn(async move {
            let _opening = opening;
            let admitted = tokio::select! {
                biased;
                () = epoch.invalidated() => return Err(io::ErrorKind::ConnectionAborted.into()),
                result = timeout_at(deadline, async {
                    let stream = if prefaced { stream } else {
                        let Demultiplexed::Binary { stream } = accept_preface(stream, deadline).await? else {
                            return Err(io::ErrorKind::InvalidData.into());
                        };
                        stream
                    };
                    let (header, stream) = read_header(stream, deadline).await?;
                    let BinaryHeader::Open(open) = header else { return Err(io::ErrorKind::InvalidData.into()); };
                    let transfer = dispatcher.prepare_open(&open).await.map_err(|_| io::ErrorKind::PermissionDenied)?;
                    Ok::<_, io::Error>((transfer, stream))
                }) => result.map_err(|_| io::ErrorKind::TimedOut)??,
            };
            admitted.0.serve(admitted.1, deadline, operation_deadline, _opening).await
        }));
        Ok(())
    }

    fn close(&self) -> (Vec<JoinHandle<io::Result<()>>>, bool, bool) {
        self.epoch.invalidate();
        let (mut work, trusted) = match self.work.lock() {
            Ok(work) => (work, true),
            // Recover only to abort/join owned jobs, never to reopen admission.
            Err(poisoned) => (poisoned.into_inner(), false),
        };
        work.closed = true;
        let jobs = std::mem::take(&mut work.jobs);
        for job in &jobs {
            job.abort();
        }
        (jobs, trusted, work.stop_requested)
    }
}

pub struct GuestControl<R, W> {
    resources: GuestResources,
    owner: Option<ActiveControl>,
    dispatcher: Option<Arc<GuestDispatcher>>,
    reader: Option<FrameReader<R>>,
    writer: Option<Arc<Mutex<FrameWriter<W>>>>,
    requests: JoinSet<io::Result<()>>,
    binaries: GuestSessionHandle,
}

impl<R, W> GuestControl<R, W>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    pub async fn bootstrap(
        resources: &GuestResources,
        slot: &ControlSlot,
        mut reader: FrameReader<R>,
        mut writer: FrameWriter<W>,
        deadline: Instant,
    ) -> Result<Self, NegotiationError> {
        let mut opening = slot.reserve().map_err(NegotiationError::Protocol)?;
        let (owner, dispatcher) = match resources
            .bootstrap(&mut opening, &mut reader, &mut writer, deadline)
            .await
        {
            Ok(ready) => ready,
            Err(error) => {
                drop(reader);
                drop(writer);
                let closing = opening.begin_close().map_err(NegotiationError::Protocol)?;
                resources
                    .quiesce()
                    .await
                    .map_err(NegotiationError::Protocol)?;
                closing.finish().map_err(NegotiationError::Protocol)?;
                return Err(error);
            }
        };
        let dispatcher = Arc::new(dispatcher);
        let binaries = GuestSessionHandle {
            epoch: owner.epoch().clone(),
            dispatcher: Arc::downgrade(&dispatcher),
            work: Arc::new(StateMutex::new(BinaryWork {
                closed: false,
                stop_requested: false,
                jobs: Vec::new(),
            })),
        };
        Ok(Self {
            resources: resources.clone(),
            owner: Some(owner),
            dispatcher: Some(dispatcher),
            reader: Some(reader),
            writer: Some(Arc::new(Mutex::new(writer))),
            requests: JoinSet::new(),
            binaries,
        })
    }

    pub fn handle(&self) -> GuestSessionHandle {
        self.binaries.clone()
    }

    /// The caller chooses a finite, nonzero frame/request budget. Each phase
    /// has one absolute deadline; a partial frame or stalled reply cannot reset
    /// it. Eight in-flight requests are allowed; overload fences the channel
    /// rather than queueing without a bound or blocking EOF behind handler work.
    pub async fn run(mut self, budget: Duration) -> io::Result<()> {
        let outcome = loop {
            let Some(read_deadline) = Instant::now().checked_add(budget) else {
                break Err(io::ErrorKind::InvalidInput.into());
            };
            if budget.is_zero() {
                break Err(io::ErrorKind::InvalidInput.into());
            }
            let owner = self.owner.as_ref().expect("active control owner");
            let reader = self.reader.as_mut().expect("owned control reader");
            tokio::select! {
                message = owner.read_message(reader, read_deadline) => match message {
                    Ok(None) => break Ok(()),
                    Err(error) => break Err(error),
                    Ok(Some(request)) => {
                        if self.requests.len() >= MAX_REQUESTS { break Err(io::ErrorKind::WouldBlock.into()); }
                        let dispatcher = self.dispatcher.as_ref().expect("active dispatcher").clone();
                        let writer = self.writer.as_ref().expect("owned control writer").clone();
                        let Some(expires) = Instant::now().checked_add(budget) else {
                            break Err(io::ErrorKind::InvalidInput.into());
                        };
                        self.requests.spawn(async move {
                            let prepared = timeout_at(expires, dispatcher.prepare_request(&request, expires)).await
                                .map_err(|_| io::ErrorKind::TimedOut)?;
                            // Invalid/foreign application input is not reflected
                            // and cannot fence the current healthy binding.
                            let Ok(reply) = prepared else { return Ok(()); };
                            let mut writer = timeout_at(expires, writer.lock()).await.map_err(|_| io::ErrorKind::TimedOut)?;
                            reply.flush(&mut writer, expires).await
                        });
                    }
                },
                completed = self.requests.join_next(), if !self.requests.is_empty() => match completed {
                    Some(Ok(Ok(()))) => {},
                    Some(Ok(Err(error))) => break Err(error),
                    Some(Err(_)) => break Err(io::ErrorKind::Other.into()),
                    None => {},
                },
            }
        };
        let closing = self
            .owner
            .take()
            .expect("active control owner")
            .begin_close();
        let (binaries, trusted, stop_requested) = self.binaries.close();
        self.requests.abort_all();
        while self.requests.join_next().await.is_some() {}
        for job in binaries {
            let _ = job.await;
        }
        let stopped = self
            .dispatcher
            .as_ref()
            .expect("active dispatcher")
            .shutdown()
            .await;
        drop(self.reader.take());
        drop(self.writer.take());
        drop(self.dispatcher.take());
        let quiescent = self.resources.quiesce().await;
        if !trusted || stopped.is_err() || quiescent.is_err() {
            return Err(io::ErrorKind::Other.into());
        }
        closing.finish().map_err(|_| io::ErrorKind::Other)?;
        if stop_requested
            && outcome
                .as_ref()
                .is_err_and(|error| error.kind() == io::ErrorKind::ConnectionAborted)
        {
            Ok(())
        } else {
            outcome
        }
    }
}

impl<R, W> Drop for GuestControl<R, W> {
    fn drop(&mut self) {
        if let Some(owner) = &self.owner {
            owner.epoch().invalidate();
        }
        self.requests.abort_all();
        drop(self.binaries.close());
        // ActiveControl's Drop keeps abandoned cleanup closed. Only run's
        // explicit, confirmed final barrier is allowed to finish that slot.
    }
}
