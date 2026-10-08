//! Per-VM/generation execution behind a negotiated session. This is not a
//! transport listener, a sandbox, or a durable host operation repository.

use crate::protocol::{ErrorCode, PROTOCOL_VERSION, ProtocolError, validate_message};
use crate::session::Session;
use nix::sys::signal::{Signal, killpg};
use nix::unistd::{Pid, Uid};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::fs::{File, Permissions};
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::{ExitStatus, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tempfile::{NamedTempFile, TempDir};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::{JoinHandle, JoinSet};

const TERMINATE_GRACE: Duration = Duration::from_millis(200);
const CLEANUP_DEADLINE: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug)]
pub struct ExecLimits {
    pub max_concurrent: usize,
    pub max_retained: usize,
    pub max_output_bytes: u64,
}

impl Default for ExecLimits {
    fn default() -> Self {
        Self {
            max_concurrent: 4,
            max_retained: 32,
            max_output_bytes: 16 * 1024 * 1024,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ExecState {
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "mode", rename_all = "lowercase")]
pub enum OutputReference {
    Inline {
        text: String,
        truncated: bool,
        size_bytes: u64,
    },
    Artifact {
        artifact_id: String,
        size_bytes: u64,
    },
}

#[derive(Clone, Debug, Serialize)]
pub struct ExecResult {
    pub state: ExecState,
    pub exit_code: Option<i32>,
    pub stdout: OutputReference,
    pub stderr: OutputReference,
    pub duration_ms: u64,
    pub timed_out: bool,
    pub signal: Option<i32>,
}

#[derive(Clone, Debug)]
pub struct ExecBinding {
    pub vm_id: String,
    pub driver_generation: u64,
    pub operation_id: String,
}

#[derive(Clone, Debug)]
pub struct ExecSnapshot {
    pub binding: ExecBinding,
    pub result: ExecResult,
    pub failure: Option<ErrorCode>,
}

#[derive(Clone, Copy)]
pub enum OutputStream {
    Stdout,
    Stderr,
}

#[derive(Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct ExecParams {
    argv: Vec<String>,
    cwd: String,
    env: BTreeMap<String, String>,
    timeout_seconds: f64,
    capture: CaptureOptions,
}

#[derive(Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct CaptureOptions {
    stdout: bool,
    stderr: bool,
    max_inline_bytes: u64,
}

struct StoredOutput {
    reference: OutputReference,
    file: Option<NamedTempFile>,
    failure: Option<ErrorCode>,
}

impl StoredOutput {
    fn empty() -> Self {
        Self {
            reference: empty_output(),
            file: None,
            failure: None,
        }
    }
}

struct Completed {
    snapshot: ExecSnapshot,
    stdout: StoredOutput,
    stderr: StoredOutput,
}

struct Job {
    binding: ExecBinding,
    params: ExecParams,
    completed: watch::Receiver<Option<Arc<Completed>>>,
    cancel: Option<oneshot::Sender<()>>,
    worker: Option<JoinHandle<()>>,
}

impl Job {
    fn snapshot(&self) -> ExecSnapshot {
        self.completed.borrow().as_ref().map_or_else(
            || running_snapshot(self.binding.clone()),
            |done| done.snapshot.clone(),
        )
    }
}

pub struct Executor {
    vm_id: String,
    generation: u64,
    spool: Arc<TempDir>,
    limits: ExecLimits,
    jobs: HashMap<String, Job>,
    closed: bool,
}

impl Executor {
    pub fn new(
        vm_id: &str,
        generation: u64,
        spool_parent: &Path,
        limits: ExecLimits,
    ) -> Result<Self, ProtocolError> {
        validate_message(
            &json!({"protocol_version": PROTOCOL_VERSION, "kind": "request", "id": "exec-binding",
            "method": "health", "vm_id": vm_id, "driver_generation": generation, "operation_id": null, "params": {}}),
        )?;
        if limits.max_concurrent == 0
            || limits.max_retained < limits.max_concurrent
            || limits.max_output_bytes == 0
            || limits.max_output_bytes > 256 * 1024 * 1024
        {
            return Err(error(ErrorCode::InvalidRequest));
        }
        let parent = spool_parent
            .canonicalize()
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        let metadata = parent
            .metadata()
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        if !metadata.is_dir()
            || metadata.uid() != Uid::effective().as_raw()
            || metadata.mode() & 0o022 != 0
        {
            return Err(error(ErrorCode::InvalidRequest));
        }
        let spool = tempfile::Builder::new()
            .prefix("gaovm-exec-")
            .permissions(Permissions::from_mode(0o700))
            .tempdir_in(parent)
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        Ok(Self {
            vm_id: vm_id.to_owned(),
            generation,
            spool: Arc::new(spool),
            limits,
            jobs: HashMap::new(),
            closed: false,
        })
    }

    pub fn start(
        &mut self,
        session: &Session,
        request: &Value,
    ) -> Result<ExecSnapshot, ProtocolError> {
        let operation = self.authorize(session, request, "exec.start")?.to_owned();
        let params: ExecParams = serde_json::from_value(request["params"].clone())
            .map_err(|_| error(ErrorCode::InvalidRequest))?;
        if self.closed {
            return Err(error(ErrorCode::ExecStartFailed));
        }
        if let Some(job) = self.jobs.get(&operation) {
            return if job.params == params {
                Ok(job.snapshot())
            } else {
                Err(error(ErrorCode::InvalidRequest))
            };
        }
        if self.jobs.len() >= self.limits.max_retained
            || self
                .jobs
                .values()
                .filter(|job| job.completed.borrow().is_none())
                .count()
                >= self.limits.max_concurrent
        {
            return Err(error(ErrorCode::ExecStartFailed));
        }
        tokio::runtime::Handle::try_current().map_err(|_| error(ErrorCode::GuestInternalError))?;
        let stdout_file = self.capture_file(params.capture.stdout)?;
        let stderr_file = self.capture_file(params.capture.stderr)?;
        let mut command = Command::new(&params.argv[0]);
        command
            .args(&params.argv[1..])
            .current_dir(&params.cwd)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .envs(&params.env)
            .stdin(Stdio::null())
            .stdout(if params.capture.stdout {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stderr(if params.capture.stderr {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .process_group(0)
            .kill_on_drop(true);
        let binding = ExecBinding {
            vm_id: self.vm_id.clone(),
            driver_generation: self.generation,
            operation_id: operation.clone(),
        };
        let started = Instant::now();
        let plan = RunPlan {
            binding: binding.clone(),
            started,
            deadline: tokio::time::Instant::now() + Duration::from_secs_f64(params.timeout_seconds),
            limits: Arc::new(RunLimits {
                inline: params.capture.max_inline_bytes,
                total: self.limits.max_output_bytes,
            }),
        };
        let child = command
            .spawn()
            .map_err(|_| error(ErrorCode::ExecStartFailed))?;
        let group = ProcessGroup {
            pid: Pid::from_raw(child.id().expect("new child has a PID") as i32),
            armed: true,
        };
        let (cancel_tx, cancel_rx) = oneshot::channel();
        let (complete_tx, complete_rx) = watch::channel(None);
        let spool = Arc::clone(&self.spool);
        let worker = tokio::spawn(async move {
            let _spool = spool;
            let done = run(child, group, stdout_file, stderr_file, cancel_rx, plan).await;
            complete_tx.send_replace(Some(Arc::new(done)));
        });
        self.jobs.insert(
            operation,
            Job {
                binding: binding.clone(),
                params,
                completed: complete_rx,
                cancel: Some(cancel_tx),
                worker: Some(worker),
            },
        );
        Ok(running_snapshot(binding))
    }

    pub fn status(
        &self,
        session: &Session,
        request: &Value,
    ) -> Result<ExecSnapshot, ProtocolError> {
        let operation = self.authorize(session, request, "exec.status")?;
        Ok(self
            .jobs
            .get(operation)
            .ok_or_else(|| error(ErrorCode::ExecNotFound))?
            .snapshot())
    }

    pub fn cancel(
        &mut self,
        session: &Session,
        request: &Value,
    ) -> Result<ExecSnapshot, ProtocolError> {
        let operation = self.authorize(session, request, "exec.cancel")?.to_owned();
        let job = self
            .jobs
            .get_mut(&operation)
            .ok_or_else(|| error(ErrorCode::ExecNotFound))?;
        if let Some(cancel) = job.cancel.take() {
            let _ = cancel.send(());
        }
        Ok(job.snapshot())
    }

    pub async fn wait(
        &self,
        session: &Session,
        request: &Value,
    ) -> Result<ExecSnapshot, ProtocolError> {
        let operation = self.authorize(session, request, "exec.status")?;
        let mut receiver = self
            .jobs
            .get(operation)
            .ok_or_else(|| error(ErrorCode::ExecNotFound))?
            .completed
            .clone();
        let done = receiver
            .wait_for(|done| done.is_some())
            .await
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        Ok(done.as_ref().expect("completed execution").snapshot.clone())
    }

    pub fn open_output(
        &self,
        session: &Session,
        request: &Value,
        stream: OutputStream,
    ) -> Result<Option<io::Take<File>>, ProtocolError> {
        let operation = self.authorize(session, request, "exec.status")?;
        let job = self
            .jobs
            .get(operation)
            .ok_or_else(|| error(ErrorCode::ExecNotFound))?;
        let completed = job.completed.borrow();
        let done = completed
            .as_ref()
            .ok_or_else(|| error(ErrorCode::InvalidRequest))?;
        let output = match stream {
            OutputStream::Stdout => &done.stdout,
            OutputStream::Stderr => &done.stderr,
        };
        let size = match &output.reference {
            OutputReference::Inline { size_bytes, .. }
            | OutputReference::Artifact { size_bytes, .. } => *size_bytes,
        };
        output
            .file
            .as_ref()
            .map(|file| {
                File::open(file.path())
                    .map(|file| std::io::Read::take(file, size))
                    .map_err(|_| error(ErrorCode::GuestInternalError))
            })
            .transpose()
    }

    pub fn release(&mut self, session: &Session, request: &Value) -> Result<(), ProtocolError> {
        let operation = self.authorize(session, request, "exec.status")?.to_owned();
        let job = self
            .jobs
            .get(&operation)
            .ok_or_else(|| error(ErrorCode::ExecNotFound))?;
        if job.completed.borrow().is_none() {
            return Err(error(ErrorCode::InvalidRequest));
        }
        self.jobs.remove(&operation);
        Ok(())
    }

    pub async fn shutdown(&mut self) -> Result<(), ProtocolError> {
        self.closed = true;
        for job in self.jobs.values_mut() {
            if let Some(cancel) = job.cancel.take() {
                let _ = cancel.send(());
            }
        }
        for job in self.jobs.values_mut() {
            if let Some(worker) = job.worker.take() {
                worker
                    .await
                    .map_err(|_| error(ErrorCode::GuestInternalError))?;
            }
        }
        Ok(())
    }

    fn capture_file(&self, enabled: bool) -> Result<Option<NamedTempFile>, ProtocolError> {
        enabled
            .then(|| {
                NamedTempFile::new_in(self.spool.path())
                    .map_err(|_| error(ErrorCode::ExecStartFailed))
            })
            .transpose()
    }

    fn authorize<'a>(
        &self,
        session: &Session,
        request: &'a Value,
        method: &str,
    ) -> Result<&'a str, ProtocolError> {
        session.authorize_request(request)?;
        if request["method"] != method
            || request["vm_id"] != self.vm_id
            || request["driver_generation"] != self.generation
        {
            return Err(error(ErrorCode::InvalidRequest));
        }
        request["operation_id"]
            .as_str()
            .ok_or_else(|| error(ErrorCode::InvalidRequest))
    }
}

impl Drop for Executor {
    fn drop(&mut self) {
        for job in self.jobs.values_mut() {
            if let Some(cancel) = job.cancel.take() {
                let _ = cancel.send(());
            }
        }
    }
}

struct ProcessGroup {
    pid: Pid,
    armed: bool,
}

impl ProcessGroup {
    fn kill(&mut self) {
        let _ = killpg(self.pid, Signal::SIGKILL);
        self.armed = false;
    }
}

impl Drop for ProcessGroup {
    fn drop(&mut self) {
        if self.armed {
            self.kill();
        }
    }
}

enum Stop {
    Exited(io::Result<ExitStatus>),
    Cancelled,
    Timeout,
    Fault(ErrorCode),
}

struct RunLimits {
    inline: u64,
    total: u64,
}

struct RunPlan {
    binding: ExecBinding,
    started: Instant,
    deadline: tokio::time::Instant,
    limits: Arc<RunLimits>,
}

async fn run(
    mut child: Child,
    mut group: ProcessGroup,
    stdout_file: Option<NamedTempFile>,
    stderr_file: Option<NamedTempFile>,
    cancel: oneshot::Receiver<()>,
    plan: RunPlan,
) -> Completed {
    let (fault_tx, mut fault_rx) = mpsc::channel(2);
    let total = Arc::new(AtomicU64::new(0));
    let limits = plan.limits;
    let mut readers = JoinSet::new();
    spawn_capture(
        &mut readers,
        OutputStream::Stdout,
        child.stdout.take(),
        stdout_file,
        Arc::clone(&limits),
        Arc::clone(&total),
        fault_tx.clone(),
    );
    spawn_capture(
        &mut readers,
        OutputStream::Stderr,
        child.stderr.take(),
        stderr_file,
        limits,
        total,
        fault_tx,
    );
    let stop = if tokio::time::Instant::now() >= plan.deadline {
        Stop::Timeout
    } else {
        tokio::select! {
            biased;
            status = child.wait() => Stop::Exited(status),
            _ = cancel => Stop::Cancelled,
            _ = tokio::time::sleep_until(plan.deadline) => Stop::Timeout,
            Some(fault) = fault_rx.recv() => Stop::Fault(fault),
        }
    };
    let cancelled = matches!(stop, Stop::Cancelled);
    let timed_out = matches!(stop, Stop::Timeout);
    let mut failure = match &stop {
        Stop::Timeout => Some(ErrorCode::ExecTimeout),
        Stop::Fault(code) => Some(*code),
        _ => None,
    };
    let status = match stop {
        Stop::Exited(status) => {
            group.kill();
            status.ok()
        }
        _ => {
            let _ = killpg(group.pid, Signal::SIGTERM);
            let graceful = tokio::time::timeout(TERMINATE_GRACE, child.wait()).await;
            group.kill();
            match graceful {
                Ok(status) => status.ok(),
                Err(_) => tokio::time::timeout(CLEANUP_DEADLINE, child.wait())
                    .await
                    .ok()
                    .and_then(Result::ok),
            }
        }
    };
    if status.is_none() {
        failure = Some(if cancelled {
            ErrorCode::ExecCancelFailed
        } else {
            ErrorCode::GuestInternalError
        });
    }
    let mut stdout = StoredOutput::empty();
    let mut stderr = StoredOutput::empty();
    let outputs = tokio::time::timeout(CLEANUP_DEADLINE, async {
        while let Some(result) = readers.join_next().await {
            match result {
                Ok((stream, Ok(output))) => {
                    failure = failure.or(output.failure);
                    match stream {
                        OutputStream::Stdout => stdout = output,
                        OutputStream::Stderr => stderr = output,
                    }
                }
                _ => failure = Some(ErrorCode::GuestInternalError),
            }
        }
    })
    .await;
    if outputs.is_err() {
        readers.abort_all();
        failure = Some(ErrorCode::GuestInternalError);
    }
    let state = if cancelled && status.is_some() {
        ExecState::Cancelled
    } else if failure.is_some() || !status.is_some_and(|status| status.success()) {
        ExecState::Failed
    } else {
        ExecState::Succeeded
    };
    let result = ExecResult {
        state,
        exit_code: status.and_then(|s| s.code()),
        stdout: stdout.reference.clone(),
        stderr: stderr.reference.clone(),
        duration_ms: plan
            .started
            .elapsed()
            .as_millis()
            .try_into()
            .unwrap_or(u64::MAX),
        timed_out,
        signal: status.and_then(|s| s.signal()),
    };
    Completed {
        snapshot: ExecSnapshot {
            binding: plan.binding,
            result,
            failure,
        },
        stdout,
        stderr,
    }
}

type CaptureTask = (OutputStream, Result<StoredOutput, ErrorCode>);

fn spawn_capture<R: AsyncRead + Unpin + Send + 'static>(
    readers: &mut JoinSet<CaptureTask>,
    stream: OutputStream,
    pipe: Option<R>,
    file: Option<NamedTempFile>,
    limits: Arc<RunLimits>,
    total: Arc<AtomicU64>,
    faults: mpsc::Sender<ErrorCode>,
) {
    readers.spawn(async move {
        let output = match (pipe, file) {
            (Some(pipe), Some(file)) => capture(pipe, file, limits, total, &faults).await,
            _ => Ok(StoredOutput::empty()),
        };
        if let Err(fault) = output {
            let _ = faults.try_send(fault);
        }
        (stream, output)
    });
}

async fn capture<R: AsyncRead + Unpin>(
    mut pipe: R,
    file: NamedTempFile,
    limits: Arc<RunLimits>,
    total: Arc<AtomicU64>,
    faults: &mpsc::Sender<ErrorCode>,
) -> Result<StoredOutput, ErrorCode> {
    let mut writer =
        tokio::fs::File::from_std(file.reopen().map_err(|_| ErrorCode::GuestInternalError)?);
    let mut buffer = [0u8; 8192];
    let mut size = 0;
    let mut failure = None;
    loop {
        let count = pipe
            .read(&mut buffer)
            .await
            .map_err(|_| ErrorCode::GuestInternalError)?;
        if count == 0 {
            break;
        }
        let before = total.fetch_add(count as u64, Ordering::Relaxed);
        let allowed = (count as u64).min(limits.total.saturating_sub(before)) as usize;
        writer
            .write_all(&buffer[..allowed])
            .await
            .map_err(|_| ErrorCode::GuestInternalError)?;
        size += allowed as u64;
        if allowed < count {
            failure = Some(ErrorCode::OutputLimitExceeded);
            let _ = faults.try_send(ErrorCode::OutputLimitExceeded);
            break;
        }
    }
    writer
        .flush()
        .await
        .map_err(|_| ErrorCode::GuestInternalError)?;
    writer
        .sync_all()
        .await
        .map_err(|_| ErrorCode::GuestInternalError)?;
    drop(writer);
    if size <= limits.inline {
        let reader =
            tokio::fs::File::from_std(file.reopen().map_err(|_| ErrorCode::GuestInternalError)?);
        let mut bytes = Vec::with_capacity(size as usize);
        reader
            .take(size)
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| ErrorCode::GuestInternalError)?;
        if bytes.len() as u64 != size {
            return Err(ErrorCode::GuestInternalError);
        }
        if let Ok(text) = String::from_utf8(bytes) {
            return Ok(StoredOutput {
                reference: OutputReference::Inline {
                    text,
                    truncated: failure.is_some(),
                    size_bytes: size,
                },
                file: None,
                failure,
            });
        }
    }
    Ok(StoredOutput {
        reference: OutputReference::Artifact {
            artifact_id: format!("art_{}", ulid::Ulid::generate()),
            size_bytes: size,
        },
        file: Some(file),
        failure,
    })
}

fn empty_output() -> OutputReference {
    OutputReference::Inline {
        text: String::new(),
        truncated: false,
        size_bytes: 0,
    }
}

fn running_snapshot(binding: ExecBinding) -> ExecSnapshot {
    ExecSnapshot {
        binding,
        result: ExecResult {
            state: ExecState::Running,
            exit_code: None,
            stdout: empty_output(),
            stderr: empty_output(),
            duration_ms: 0,
            timed_out: false,
            signal: None,
        },
        failure: None,
    }
}

fn error(code: ErrorCode) -> ProtocolError {
    ProtocolError {
        code,
        message: match code {
            ErrorCode::ExecNotFound => "execution was not found",
            ErrorCode::ExecStartFailed => "execution could not start",
            ErrorCode::InvalidRequest => "execution request is invalid",
            _ => "guest execution failed",
        },
    }
}
