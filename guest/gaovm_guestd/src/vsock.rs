//! Native Linux vsock admission. Authenticate the actual peer address before
//! exposing a stream; JSON bindings and a binary preface are never credentials.
//! This is transport, not the composed guest service or a native acceptance test.

use nix::libc;
use nix::sys::socket::{
    AddressFamily, Backlog, MsgFlags, Shutdown, SockFlag, SockType, VsockAddr, accept4, bind,
    getpeername, getsockname, listen, recv, send, shutdown, socket,
};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll, ready};
use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::{Duration, Instant};

const MAX_PENDING_OPENINGS: usize = 8;
const OPEN_TIMEOUT: Duration = Duration::from_secs(5);

/// A long-lived listener keeps the pending-open limit across control epochs.
/// Requires a Tokio runtime with I/O enabled. There is no TCP/Unix fallback.
pub struct HostListener {
    socket: AsyncFd<OwnedFd>,
    pending: Arc<Semaphore>,
    port: u32,
}

impl HostListener {
    pub fn bind(port: u32) -> io::Result<Self> {
        if port < 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid vsock port",
            ));
        }
        tokio::runtime::Handle::try_current().map_err(|_| {
            io::Error::new(io::ErrorKind::NotConnected, "vsock requires an I/O runtime")
        })?;
        let socket = socket(
            AddressFamily::Vsock,
            SockType::Stream,
            SockFlag::SOCK_NONBLOCK | SockFlag::SOCK_CLOEXEC,
            None,
        )?;
        bind(
            socket.as_raw_fd(),
            &VsockAddr::new(libc::VMADDR_CID_ANY, port),
        )?;
        listen(&socket, Backlog::new(MAX_PENDING_OPENINGS as i32)?)?;
        let port = getsockname::<VsockAddr>(socket.as_raw_fd())?.port();
        Ok(Self {
            socket: AsyncFd::new(socket)?,
            pending: Arc::new(Semaphore::new(MAX_PENDING_OPENINGS)),
            port,
        })
    }

    /// Report the actual bound port, including an OS-assigned wildcard port.
    /// Fixed bridge endpoint configuration must not confuse it with PORT_ANY.
    pub fn local_port(&self) -> u32 {
        self.port
    }

    /// The caller retains the opening permit through preface/hello or binary
    /// grant admission and uses the original deadline for the entire opening.
    /// Excess peers are closed immediately, not queued as unbounded futures.
    pub async fn accept(&self) -> io::Result<AcceptedHost> {
        loop {
            let mut ready = self.socket.readable().await?;
            let result = ready.try_io(|socket| {
                accept4(
                    socket.get_ref().as_raw_fd(),
                    SockFlag::SOCK_NONBLOCK | SockFlag::SOCK_CLOEXEC,
                )
                .map_err(io::Error::from)
            });
            let socket = match result {
                Ok(Ok(fd)) => {
                    // SAFETY: accept4 succeeded with a new, uniquely owned fd.
                    unsafe { OwnedFd::from_raw_fd(fd) }
                }
                Ok(Err(error)) if error.kind() == io::ErrorKind::Interrupted => continue,
                Ok(Err(error)) => return Err(error),
                Err(_) => continue,
            };
            let deadline = Instant::now() + OPEN_TIMEOUT;
            authenticate_host(&socket)?;
            let opening = self.pending.clone().try_acquire_owned().map_err(|_| {
                io::Error::new(
                    io::ErrorKind::ConnectionRefused,
                    "guest opening limit reached",
                )
            })?;
            return Ok(AcceptedHost {
                stream: HostStream {
                    socket: AsyncFd::new(socket)?,
                },
                opening,
                deadline,
            });
        }
    }
}

/// Cannot be constructed from a claimed CID or arbitrary fd outside this module.
pub struct AcceptedHost {
    stream: HostStream,
    opening: OwnedSemaphorePermit,
    deadline: Instant,
}

impl AcceptedHost {
    pub fn into_parts(self) -> (HostStream, OwnedSemaphorePermit, Instant) {
        (self.stream, self.opening, self.deadline)
    }
}

fn authenticate_host(socket: &OwnedFd) -> io::Result<()> {
    // Nix rejects a non-AF_VSOCK family or wrong sockaddr size. No read occurs
    // before the kernel-provided address has passed this check.
    let peer = getpeername::<VsockAddr>(socket.as_raw_fd())?;
    if peer.cid() != libc::VMADDR_CID_HOST {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "vsock host peer required",
        ));
    }
    Ok(())
}

pub struct HostStream {
    socket: AsyncFd<OwnedFd>,
}

impl AsyncRead for HostStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if buf.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        loop {
            let mut ready = ready!(self.socket.poll_read_ready(cx))?;
            match ready.try_io(|socket| {
                recv(
                    socket.get_ref().as_raw_fd(),
                    buf.initialize_unfilled(),
                    MsgFlags::MSG_DONTWAIT,
                )
                .map_err(io::Error::from)
            }) {
                Ok(Ok(count)) => {
                    buf.advance(count);
                    return Poll::Ready(Ok(()));
                }
                Ok(Err(error)) if error.kind() == io::ErrorKind::Interrupted => continue,
                Ok(Err(error)) => return Poll::Ready(Err(error)),
                Err(_) => continue,
            }
        }
    }
}

impl AsyncWrite for HostStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        if buf.is_empty() {
            return Poll::Ready(Ok(0));
        }
        loop {
            let mut ready = ready!(self.socket.poll_write_ready(cx))?;
            match ready.try_io(|socket| {
                send(
                    socket.get_ref().as_raw_fd(),
                    buf,
                    MsgFlags::MSG_DONTWAIT | MsgFlags::MSG_NOSIGNAL,
                )
                .map_err(io::Error::from)
            }) {
                Ok(Err(error)) if error.kind() == io::ErrorKind::Interrupted => continue,
                Ok(result) => return Poll::Ready(result),
                Err(_) => continue,
            }
        }
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        // Like a Unix/TCP socket, there is no userspace write buffer to flush.
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(
            shutdown(self.socket.get_ref().as_raw_fd(), Shutdown::Write).map_err(io::Error::from),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use nix::sys::socket::socketpair;

    #[test]
    fn a_real_non_vsock_peer_with_forged_preface_never_passes_native_admission() {
        let (peer, accepted) = socketpair(
            AddressFamily::Unix,
            SockType::Stream,
            None,
            SockFlag::empty(),
        )
        .unwrap();
        send(
            peer.as_raw_fd(),
            b"GAB1{\"vm_id\":\"forged\",\"cid\":2}",
            MsgFlags::MSG_NOSIGNAL,
        )
        .unwrap();
        assert!(authenticate_host(&accepted).is_err());
        drop(accepted);
        let mut reply = [0; 1];
        match recv(peer.as_raw_fd(), &mut reply, MsgFlags::empty()) {
            Ok(count) => assert_eq!(count, 0),
            Err(error) => assert_eq!(error, nix::errno::Errno::ECONNRESET),
        }
    }
}
