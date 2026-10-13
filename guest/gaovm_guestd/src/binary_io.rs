//! Bounded async binary framing. Callers authenticate peers and current grants
//! before using it, and publish a verified private stage before a commit ACK.
//! Dropping an opening future drops its owned stream; partial openings are not
//! resumable. A cancelled/failed body reader is permanently fenced.

use crate::binary::{
    BINARY_MAGIC, BinaryArtifact, BinaryHeader, MAX_ARTIFACT_BYTES, MAX_CHUNK_BYTES,
    MAX_HEADER_BYTES, decode_header, encode_header,
};
use crate::frame::MAX_FRAME_BYTES;
use sha2::{Digest, Sha256};
use std::io;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::time::{Instant, timeout_at};

pub enum Demultiplexed<S> {
    /// These bytes belong to the control decoder and must not be discarded.
    Control {
        length_prefix: [u8; 4],
        stream: S,
    },
    Binary {
        stream: S,
    },
}

/// Framing only: a binary preface never authenticates a peer or activates a grant.
/// Use an owned stream so an error/cancel closes the connection, not a borrowed
/// transport which could accidentally be reused after a partial opening.
pub async fn accept_preface<S: AsyncRead + Unpin>(
    mut stream: S,
    deadline: Instant,
) -> io::Result<Demultiplexed<S>> {
    let mut prefix = [0; 4];
    before_deadline(deadline)?;
    timeout_at(deadline, stream.read_exact(&mut prefix))
        .await
        .map_err(|_| io::ErrorKind::TimedOut)??;
    before_deadline(deadline)?;
    if prefix == BINARY_MAGIC {
        return Ok(Demultiplexed::Binary { stream });
    }
    let length = u32::from_be_bytes(prefix) as usize;
    if length == 0 || length > MAX_FRAME_BYTES {
        return Err(invalid_body());
    }
    Ok(Demultiplexed::Control {
        length_prefix: prefix,
        stream,
    })
}

/// Read one header under the caller's original open or ACK phase deadline.
/// Length is validated before allocation. An error returns no reusable stream.
pub async fn read_header<S: AsyncRead + Unpin>(
    mut stream: S,
    deadline: Instant,
) -> io::Result<(BinaryHeader, S)> {
    before_deadline(deadline)?;
    let header = timeout_at(deadline, async {
        let mut length = [0; 4];
        stream.read_exact(&mut length).await?;
        let length = u32::from_be_bytes(length) as usize;
        if length == 0 || length > MAX_HEADER_BYTES {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let mut payload = vec![0; length];
        stream.read_exact(&mut payload).await?;
        decode_header(&payload)
    })
    .await
    .map_err(|_| io::ErrorKind::TimedOut)??;
    before_deadline(deadline)?;
    Ok((header, stream))
}

/// Open headers include GAB1; every other header has only its length prefix.
/// Validate before any output. Success requires the whole frame to be flushed
/// under the original phase deadline, not merely queued to a buffered writer.
pub async fn write_header<S: AsyncWrite + Unpin>(
    mut stream: S,
    header: &BinaryHeader,
    deadline: Instant,
) -> io::Result<S> {
    before_deadline(deadline)?;
    let payload = encode_header(header)?;
    timeout_at(deadline, async {
        if matches!(header, BinaryHeader::Open(_)) {
            stream.write_all(&BINARY_MAGIC).await?;
        }
        stream
            .write_all(&(payload.len() as u32).to_be_bytes())
            .await?;
        stream.write_all(&payload).await?;
        stream.flush().await
    })
    .await
    .map_err(|_| io::ErrorKind::TimedOut)??;
    before_deadline(deadline)?;
    Ok(stream)
}

/// Send an owned sealed-spool reader with one fixed buffer. The declared size
/// and capture-time digest must both match, including source EOF, before an end
/// marker is emitted. A failed/cancelled send drops the owned transport; callers
/// must start retries from byte zero on a new admitted connection. This neither
/// waits for a committed ACK nor retires a grant/spool.
pub async fn write_body<S: AsyncWrite + Unpin, R: AsyncRead + Unpin>(
    mut stream: S,
    mut source: R,
    artifact: &BinaryArtifact,
    deadline: Instant,
) -> io::Result<S> {
    if artifact.size_bytes > MAX_ARTIFACT_BYTES {
        return Err(invalid_body());
    }
    let expected_digest = parse_digest(&artifact.digest)?;
    before_deadline(deadline)?;
    timeout_at(deadline, async {
        let mut remaining = artifact.size_bytes;
        let mut buffer = [0; MAX_CHUNK_BYTES];
        let mut hash = Sha256::new();
        while remaining != 0 {
            let wanted = remaining.min(MAX_CHUNK_BYTES as u64) as usize;
            let count = source.read(&mut buffer[..wanted]).await?;
            if count == 0 {
                return Err(invalid_body());
            }
            hash.update(&buffer[..count]);
            remaining -= count as u64;
            stream.write_all(&(count as u32).to_be_bytes()).await?;
            stream.write_all(&buffer[..count]).await?;
        }
        // Never conceal an overlong or changed source behind the declared size.
        if source.read(&mut buffer[..1]).await? != 0
            || <[u8; 32]>::from(hash.finalize()) != expected_digest
        {
            return Err(invalid_body());
        }
        stream.write_all(&[0; 4]).await?;
        stream.flush().await
    })
    .await
    .map_err(|_| io::ErrorKind::TimedOut)??;
    before_deadline(deadline)?;
    Ok(stream)
}

/// Stream chunks into an owned private stage, never a public artifact. Success
/// requires exact size, the explicit end marker and the declared SHA-256. This
/// reader does not establish binding/grant validity or durable publication.
pub struct BodyReader<R> {
    stream: R,
    remaining: u64,
    expected_digest: [u8; 32],
    hash: Sha256,
    deadline: Instant,
    failed: bool,
    complete: bool,
}

impl<R: AsyncRead + Unpin> BodyReader<R> {
    pub fn new(stream: R, artifact: &BinaryArtifact, deadline: Instant) -> io::Result<Self> {
        if artifact.size_bytes > MAX_ARTIFACT_BYTES {
            return Err(invalid_body());
        }
        before_deadline(deadline)?;
        Ok(Self {
            stream,
            remaining: artifact.size_bytes,
            expected_digest: parse_digest(&artifact.digest)?,
            hash: Sha256::new(),
            deadline,
            failed: false,
            complete: false,
        })
    }

    /// A single absolute deadline covers every chunk and the end marker. It
    /// cannot be extended by progress or a second call after cancellation.
    pub async fn read_chunk(&mut self) -> io::Result<Option<Vec<u8>>> {
        if self.failed {
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        if self.complete {
            return Ok(None);
        }
        // If this future is dropped after polling, keep the failed fence. A
        // partially consumed length/body cannot be reinterpreted as a new frame.
        self.failed = true;
        before_deadline(self.deadline)?;
        let result = timeout_at(self.deadline, async {
            let mut length = [0; 4];
            self.stream.read_exact(&mut length).await?;
            let length = u32::from_be_bytes(length) as usize;
            if length == 0 {
                if self.remaining != 0
                    || <[u8; 32]>::from(self.hash.clone().finalize()) != self.expected_digest
                {
                    return Err(invalid_body());
                }
                self.complete = true;
                return Ok(None);
            }
            if length > MAX_CHUNK_BYTES || length as u64 > self.remaining {
                return Err(invalid_body());
            }
            let mut bytes = vec![0; length];
            self.stream.read_exact(&mut bytes).await?;
            self.hash.update(&bytes);
            self.remaining -= length as u64;
            Ok(Some(bytes))
        })
        .await
        .map_err(|_| io::ErrorKind::TimedOut)?;
        before_deadline(self.deadline)?;
        match result {
            Ok(chunk) => {
                self.failed = false;
                Ok(chunk)
            }
            Err(error) => Err(error),
        }
    }

    /// Only a verified body may hand its stream back for subsequent connection
    /// handling. This is not a commit ACK and must not trigger publication alone.
    pub fn finish(self) -> io::Result<R> {
        if self.failed || !self.complete {
            return Err(invalid_body());
        }
        Ok(self.stream)
    }
}

fn parse_digest(digest: &str) -> io::Result<[u8; 32]> {
    let hex = digest.strip_prefix("sha256:").ok_or_else(invalid_body)?;
    let bytes = hex.as_bytes();
    if bytes.len() != 64
        || !bytes
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        return Err(invalid_body());
    }
    let mut value = [0; 32];
    for (index, pair) in bytes.chunks_exact(2).enumerate() {
        let nibble = |byte| {
            if byte <= b'9' {
                byte - b'0'
            } else {
                byte - b'a' + 10
            }
        };
        value[index] = nibble(pair[0]) * 16 + nibble(pair[1]);
    }
    Ok(value)
}

fn before_deadline(deadline: Instant) -> io::Result<()> {
    if Instant::now() >= deadline {
        Err(io::ErrorKind::TimedOut.into())
    } else {
        Ok(())
    }
}

fn invalid_body() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid binary stream")
}
