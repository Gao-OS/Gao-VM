//! Shared byte admission whose lifetime follows owned files and actual I/O.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::task::{Context, Poll};
use tempfile::{NamedTempFile, TempDir, TempPath};
use tokio::io::{AsyncRead, ReadBuf};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::task::JoinHandle;

pub const DEFAULT_SPOOL_BYTES: u64 = 256 * 1024 * 1024;
// Four execution captures (two streams each), one collection and two transfers.
const IO_WORKERS: u32 = 11;
const CHUNK: usize = 8192;

#[derive(Clone)]
pub struct SpoolBudget {
    inner: Arc<Budget>,
}

struct Budget {
    limit: u64,
    used: AtomicU64,
    failed_cleanup: AtomicBool,
    workers: Arc<Semaphore>,
}

impl Default for SpoolBudget {
    fn default() -> Self {
        Self::new(DEFAULT_SPOOL_BYTES)
    }
}

impl SpoolBudget {
    pub fn new(limit: u64) -> Self {
        Self {
            inner: Arc::new(Budget {
                limit,
                used: AtomicU64::new(0),
                failed_cleanup: AtomicBool::new(false),
                workers: Arc::new(Semaphore::new(IO_WORKERS as usize)),
            }),
        }
    }

    pub(crate) fn reserve_up_to(&self, maximum: u64) -> io::Result<Arc<Reservation>> {
        if self.inner.failed_cleanup.load(Ordering::Acquire) {
            return Err(io::ErrorKind::Other.into());
        }
        let previous = self
            .inner
            .used
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |used| {
                Some(used + maximum.min(self.inner.limit - used))
            })
            .expect("infallible bounded reservation");
        Ok(Arc::new(Reservation {
            budget: self.clone(),
            bytes: AtomicU64::new(maximum.min(self.inner.limit - previous)),
        }))
    }

    pub(crate) fn try_reserve(&self, bytes: u64) -> Option<Arc<Reservation>> {
        if self.inner.failed_cleanup.load(Ordering::Acquire) {
            return None;
        }
        self.inner
            .used
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |used| {
                (bytes <= self.inner.limit - used).then(|| used + bytes)
            })
            .ok()?;
        Some(Arc::new(Reservation {
            budget: self.clone(),
            bytes: AtomicU64::new(bytes),
        }))
    }

    pub(crate) fn spawn<T: Send + 'static>(
        &self,
        work: impl FnOnce() -> T + Send + 'static,
    ) -> io::Result<JoinHandle<Work<T>>> {
        tokio::runtime::Handle::try_current().map_err(|_| io::ErrorKind::Other)?;
        let permit = self
            .inner
            .workers
            .clone()
            .try_acquire_owned()
            .map_err(|_| io::ErrorKind::WouldBlock)?;
        Ok(tokio::task::spawn_blocking(move || Work {
            value: work(),
            _permit: permit,
        }))
    }

    /// Wait for actual workers, including workers whose callers were cancelled.
    /// The service must fence admission and join its other tasks first.
    pub async fn quiesce(&self) -> io::Result<()> {
        let _all = self
            .inner
            .workers
            .clone()
            .acquire_many_owned(IO_WORKERS)
            .await
            .map_err(|_| io::ErrorKind::BrokenPipe)?;
        if self.inner.failed_cleanup.load(Ordering::Acquire) {
            return Err(io::ErrorKind::Other.into());
        }
        Ok(())
    }
}

pub(crate) struct Work<T> {
    // A cancelled caller's result closes its owned files before returning the
    // worker slot. Quiescence must not race discarded-result destruction.
    value: T,
    _permit: OwnedSemaphorePermit,
}

impl<T> Work<T> {
    pub(crate) fn finish(self) -> T {
        self.value
    }
}

pub(crate) struct Reservation {
    budget: SpoolBudget,
    bytes: AtomicU64,
}

impl Reservation {
    pub(crate) fn bytes(&self) -> u64 {
        self.bytes.load(Ordering::Acquire)
    }

    /// Only after all writers are finished; never increase a live reservation.
    pub(crate) fn seal(&self, retained: u64) -> io::Result<()> {
        // Inline capture may already have dropped its file. Do not shrink its
        // charge or claim clean completion if that removal was uncertain.
        if self.budget.inner.failed_cleanup.load(Ordering::Acquire) {
            return Err(io::ErrorKind::Other.into());
        }
        let old = self
            .bytes
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |old| {
                (retained <= old).then_some(retained)
            })
            .map_err(|_| io::ErrorKind::InvalidData)?;
        self.budget
            .inner
            .used
            .fetch_sub(old - retained, Ordering::AcqRel);
        Ok(())
    }
}

impl Drop for Reservation {
    fn drop(&mut self) {
        // Quarantine charges on uncertain removal. Already-admitted work still
        // fits its original reservations; no later capture may recycle them.
        if self.budget.inner.failed_cleanup.load(Ordering::Acquire) {
            return;
        }
        self.budget
            .inner
            .used
            .fetch_sub(self.bytes.load(Ordering::Acquire), Ordering::AcqRel);
    }
}

pub(crate) struct SpoolDirectory {
    directory: Option<TempDir>,
    budget: SpoolBudget,
    identity: (u64, u64),
}

impl SpoolDirectory {
    pub(crate) fn new(directory: TempDir, budget: SpoolBudget) -> io::Result<Arc<Self>> {
        match std::fs::symlink_metadata(directory.path()) {
            Ok(metadata) if metadata.is_dir() => Ok(Arc::new(Self {
                directory: Some(directory),
                budget,
                identity: (metadata.dev(), metadata.ino()),
            })),
            _ => {
                let _ = directory.keep();
                budget.inner.failed_cleanup.store(true, Ordering::Release);
                Err(io::ErrorKind::Other.into())
            }
        }
    }

    pub(crate) fn path(&self) -> &Path {
        self.directory
            .as_ref()
            .expect("owned spool directory")
            .path()
    }
}

impl Drop for SpoolDirectory {
    fn drop(&mut self) {
        let directory = self.directory.take().expect("owned spool directory");
        let original = std::fs::symlink_metadata(directory.path()).is_ok_and(|metadata| {
            metadata.is_dir() && (metadata.dev(), metadata.ino()) == self.identity
        });
        if self.budget.inner.failed_cleanup.load(Ordering::Acquire) || !original {
            let _ = directory.keep();
            self.budget
                .inner
                .failed_cleanup
                .store(true, Ordering::Release);
        } else if directory.close().is_err() {
            self.budget
                .inner
                .failed_cleanup
                .store(true, Ordering::Release);
        }
    }
}

pub(crate) struct RetainedFile {
    // Close/unlink files before dropping their directory and quota charge.
    path: Option<TempPath>,
    _directory: Arc<SpoolDirectory>,
    reservation: Arc<Reservation>,
    identity: (u64, u64),
}

impl RetainedFile {
    pub(crate) fn new(
        file: NamedTempFile,
        directory: Arc<SpoolDirectory>,
        reservation: Arc<Reservation>,
    ) -> io::Result<Arc<Self>> {
        let metadata = file.as_file().metadata()?;
        Ok(Arc::new(Self {
            path: Some(file.into_temp_path()),
            _directory: directory,
            reservation,
            identity: (metadata.dev(), metadata.ino()),
        }))
    }

    fn open(&self, writable: bool) -> io::Result<File> {
        let file = OpenOptions::new()
            .read(true)
            .write(writable)
            .custom_flags((nix::fcntl::OFlag::O_NOFOLLOW | nix::fcntl::OFlag::O_NONBLOCK).bits())
            .open(self.path.as_ref().expect("live retained path"))?;
        let metadata = file.metadata()?;
        if !metadata.is_file()
            || metadata.nlink() != 1
            || (metadata.dev(), metadata.ino()) != self.identity
        {
            return Err(io::ErrorKind::InvalidData.into());
        }
        Ok(file)
    }

    pub(crate) fn reader(self: &Arc<Self>) -> io::Result<SpoolReader> {
        Ok(SpoolReader {
            file: self.open(false)?,
            owner: self.clone(),
        })
    }

    pub(crate) fn writer(self: &Arc<Self>) -> io::Result<SpoolWriter> {
        Ok(SpoolWriter {
            owned: Some(self.owned_writer()?),
        })
    }

    pub(crate) fn owned_writer(self: &Arc<Self>) -> io::Result<WriterFile> {
        Ok(WriterFile {
            file: self.open(true)?,
            owner: self.clone(),
        })
    }
}

impl Drop for RetainedFile {
    fn drop(&mut self) {
        let mut path = self.path.take().expect("owned retained path");
        let original = std::fs::symlink_metadata(&path).is_ok_and(|metadata| {
            metadata.is_file()
                && metadata.nlink() == 1
                && (metadata.dev(), metadata.ino()) == self.identity
        });
        if !original {
            // Do not unlink a substituted object or guess that missing means
            // deleted rather than moved. Recovery must confirm the namespace.
            path.disable_cleanup(true);
            self.reservation
                .budget
                .inner
                .failed_cleanup
                .store(true, Ordering::Release);
        } else if path.close().is_err() {
            self.reservation
                .budget
                .inner
                .failed_cleanup
                .store(true, Ordering::Release);
        }
    }
}

pub(crate) struct WriterFile {
    file: File,
    owner: Arc<RetainedFile>,
}

impl Write for WriterFile {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.file.write(bytes)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

impl WriterFile {
    pub(crate) fn sync(&self) -> io::Result<()> {
        self.file.sync_all()
    }
}

pub(crate) struct SpoolWriter {
    owned: Option<WriterFile>,
}

impl SpoolWriter {
    async fn step<T: Send + 'static>(
        &mut self,
        action: impl FnOnce(&mut File) -> io::Result<T> + Send + 'static,
    ) -> io::Result<T> {
        let budget = self
            .owned
            .as_ref()
            .ok_or(io::ErrorKind::BrokenPipe)?
            .owner
            .reservation
            .budget
            .clone();
        let mut owned = self.owned.take().expect("checked writer");
        let (owned, result) = budget
            .spawn(move || {
                let result = action(&mut owned.file);
                (owned, result)
            })?
            .await
            .map_err(|_| io::ErrorKind::Other)?
            .finish();
        self.owned = Some(owned);
        result
    }

    pub(crate) async fn write_chunk(&mut self, bytes: &[u8]) -> io::Result<()> {
        if bytes.len() > CHUNK {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let bytes = bytes.to_vec();
        self.step(move |file| file.write_all(&bytes)).await
    }

    pub(crate) async fn sync(&mut self) -> io::Result<()> {
        self.step(|file| file.sync_all()).await
    }

    pub(crate) async fn inline(&mut self, size: u64) -> io::Result<Vec<u8>> {
        if size > 1024 * 1024 {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        self.step(move |file| {
            file.seek(SeekFrom::Start(0))?;
            let mut bytes = Vec::with_capacity(size as usize);
            file.take(size).read_to_end(&mut bytes)?;
            if bytes.len() as u64 != size {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            Ok(bytes)
        })
        .await
    }
}

/// Read-only file ownership; no API can extract an uncharged raw descriptor.
pub struct SpoolReader {
    file: File,
    owner: Arc<RetainedFile>,
}

impl std::fmt::Debug for SpoolReader {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SpoolReader").finish_non_exhaustive()
    }
}

impl Read for SpoolReader {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.file.read(bytes)
    }
}

impl Write for SpoolReader {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        // The actual descriptor is O_RDONLY; the kernel rejects this operation.
        (&self.file).write(bytes)
    }

    fn flush(&mut self) -> io::Result<()> {
        (&self.file).flush()
    }
}

impl SpoolReader {
    pub fn metadata(&self) -> io::Result<std::fs::Metadata> {
        self.file.metadata()
    }

    pub fn into_async(self) -> AsyncSpoolReader {
        AsyncSpoolReader {
            reader: Some(self),
            pending: None,
            buffered: Vec::new(),
            position: 0,
            failed: false,
        }
    }
}

type ReadTask = JoinHandle<Work<(SpoolReader, io::Result<Vec<u8>>)>>;

pub struct AsyncSpoolReader {
    reader: Option<SpoolReader>,
    pending: Option<ReadTask>,
    buffered: Vec<u8>,
    position: usize,
    failed: bool,
}

impl AsyncRead for AsyncSpoolReader {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        output: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if output.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        if self.failed {
            return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()));
        }
        if self.position < self.buffered.len() {
            let count = output.remaining().min(self.buffered.len() - self.position);
            output.put_slice(&self.buffered[self.position..self.position + count]);
            self.position += count;
            return Poll::Ready(Ok(()));
        }
        if self.pending.is_none() {
            let budget = self
                .reader
                .as_ref()
                .expect("idle reader owns its file")
                .owner
                .reservation
                .budget
                .clone();
            let mut reader = self.reader.take().expect("checked reader");
            let job = budget.spawn(move || {
                let mut buffer = vec![0; CHUNK];
                let read = loop {
                    match reader.read(&mut buffer) {
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                        result => break result,
                    }
                };
                let result = read.map(|count| {
                    buffer.truncate(count);
                    buffer
                });
                (reader, result)
            });
            match job {
                Ok(job) => self.pending = Some(job),
                Err(error) => {
                    self.failed = true;
                    return Poll::Ready(Err(error));
                }
            }
        }
        match Pin::new(self.pending.as_mut().expect("pending read")).poll(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(result) => {
                self.pending = None;
                match result.map(Work::finish) {
                    Ok((reader, Ok(bytes))) => {
                        self.reader = Some(reader);
                        self.buffered = bytes;
                        self.position = 0;
                        let count = output.remaining().min(self.buffered.len());
                        output.put_slice(&self.buffered[..count]);
                        self.position = count;
                        Poll::Ready(Ok(()))
                    }
                    Ok((_, Err(error))) => {
                        self.failed = true;
                        Poll::Ready(Err(error))
                    }
                    Err(_) => {
                        self.failed = true;
                        Poll::Ready(Err(io::ErrorKind::Other.into()))
                    }
                }
            }
        }
    }
}
