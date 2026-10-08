//! Deadline-bound control framing; not a listener or transport authentication.

use crate::frame::{MAX_FRAME_BYTES, decode_object, encode_object};
use serde_json::Value;
use std::io;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::time::{Instant, timeout_at};

pub struct FrameReader<R> {
    reader: R,
    header: [u8; 4],
    header_read: usize,
    payload: Vec<u8>,
    payload_read: usize,
    deadline: Option<Instant>,
    state: ReadState,
}

enum ReadState {
    Open,
    Eof,
    Failed,
}

impl<R: AsyncRead + Unpin> FrameReader<R> {
    pub fn new(reader: R) -> Self {
        Self {
            reader,
            header: [0; 4],
            header_read: 0,
            payload: Vec::new(),
            payload_read: 0,
            deadline: None,
            state: ReadState::Open,
        }
    }

    pub async fn read_object(&mut self, deadline: Instant) -> io::Result<Option<Value>> {
        match self.state {
            ReadState::Eof => return Ok(None),
            ReadState::Failed => return Err(io::ErrorKind::BrokenPipe.into()),
            ReadState::Open => {}
        }
        let deadline = self
            .deadline
            .map_or(deadline, |previous| previous.min(deadline));
        self.deadline = Some(deadline);
        if Instant::now() >= deadline {
            self.invalidate();
            return Err(io::ErrorKind::TimedOut.into());
        }
        let result = timeout_at(deadline, self.read_next()).await;
        if Instant::now() >= deadline {
            self.invalidate();
            return Err(io::ErrorKind::TimedOut.into());
        }
        match result {
            Ok(Ok(value)) => {
                if value.is_none() {
                    self.state = ReadState::Eof;
                }
                self.deadline = None;
                Ok(value)
            }
            Ok(Err(error)) => {
                self.invalidate();
                Err(error)
            }
            Err(_) => {
                self.invalidate();
                Err(io::ErrorKind::TimedOut.into())
            }
        }
    }

    fn invalidate(&mut self) {
        self.state = ReadState::Failed;
        self.payload = Vec::new();
    }

    async fn read_next(&mut self) -> io::Result<Option<Value>> {
        while self.header_read < self.header.len() {
            match self.reader.read(&mut self.header[self.header_read..]).await {
                Ok(0) if self.header_read == 0 => return Ok(None),
                Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
                Ok(count) => self.header_read += count,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        if self.payload.is_empty() {
            let length = u32::from_be_bytes(self.header) as usize;
            if length == 0 || length > MAX_FRAME_BYTES {
                return Err(io::ErrorKind::InvalidData.into());
            }
            self.payload.resize(length, 0);
        }
        while self.payload_read < self.payload.len() {
            match self
                .reader
                .read(&mut self.payload[self.payload_read..])
                .await
            {
                Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
                Ok(count) => self.payload_read += count,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        let value = decode_object(&self.payload)?;
        self.payload = Vec::new();
        self.header_read = 0;
        self.payload_read = 0;
        Ok(Some(value))
    }
}

pub struct FrameWriter<W> {
    writer: W,
    state: WriteState,
}

#[derive(PartialEq)]
enum WriteState {
    Ready,
    Writing,
    Failed,
}

impl<W: AsyncWrite + Unpin> FrameWriter<W> {
    pub fn new(writer: W) -> Self {
        Self {
            writer,
            state: WriteState::Ready,
        }
    }

    pub async fn write_object(&mut self, value: &Value, deadline: Instant) -> io::Result<()> {
        if self.state != WriteState::Ready {
            self.state = WriteState::Failed;
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        let payload = encode_object(value)?;
        if Instant::now() >= deadline {
            self.state = WriteState::Failed;
            return Err(io::ErrorKind::TimedOut.into());
        }
        // Cancellation leaves Writing in place; a possibly partial frame cannot
        // be retried or followed by another message on this connection.
        self.state = WriteState::Writing;
        let result = timeout_at(deadline, async {
            self.writer
                .write_all(&(payload.len() as u32).to_be_bytes())
                .await?;
            self.writer.write_all(&payload).await?;
            self.writer.flush().await
        })
        .await;
        if Instant::now() >= deadline {
            self.state = WriteState::Failed;
            return Err(io::ErrorKind::TimedOut.into());
        }
        match result {
            Ok(Ok(())) => {
                self.state = WriteState::Ready;
                Ok(())
            }
            Ok(Err(error)) => {
                self.state = WriteState::Failed;
                Err(error)
            }
            Err(_) => {
                self.state = WriteState::Failed;
                Err(io::ErrorKind::TimedOut.into())
            }
        }
    }
}
