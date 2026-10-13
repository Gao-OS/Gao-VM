#![cfg(unix)]

use gaovm_guestd::artifact::{ArtifactCollector, ArtifactLimits};
use gaovm_guestd::exec::{ExecLimits, ExecState, Executor};
use gaovm_guestd::protocol::ErrorCode;
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use gaovm_guestd::spool::SpoolBudget;
use serde_json::{Value, json};

const VM: &str = "vm_01J00000000000000000000000";
const OP: &str = "op_01J00000000000000000000000";

fn session() -> Session {
    session_at(8)
}

fn session_at(generation: u64) -> Session {
    let mut host = Session::new(
        Role::Host,
        VM,
        generation,
        &CORE_CAPABILITIES,
        &CORE_CAPABILITIES,
    )
    .unwrap();
    let mut guest = Session::new(
        Role::Guest,
        VM,
        generation,
        &CORE_CAPABILITIES,
        &CORE_CAPABILITIES,
    )
    .unwrap();
    let host_hello = host.hello().unwrap();
    let guest_hello = guest.hello().unwrap();
    let host_ack = guest.receive_hello(&host_hello).unwrap().unwrap();
    let guest_ack = host.receive_hello(&guest_hello).unwrap().unwrap();
    host.receive_hello(&host_ack).unwrap();
    guest.receive_hello(&guest_ack).unwrap();
    guest
}

fn collect(path: &str, bytes: u64) -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "collect-quota",
        "method": "artifact.collect", "vm_id": VM, "driver_generation": 8, "operation_id": OP,
        "params": {"paths": [{"path": path, "kind": "result"}], "max_total_bytes": bytes}})
}

#[tokio::test]
async fn collectors_share_one_budget_and_a_failed_capture_does_not_leak_it() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("eight"), b"12345678").unwrap();
    std::fs::write(root.path().join("nine"), b"123456789").unwrap();
    let budget = SpoolBudget::new(16);
    let mut first = ArtifactCollector::with_spool_budget(
        VM,
        8,
        root.path(),
        spool.path(),
        ArtifactLimits::default(),
        budget.clone(),
    )
    .unwrap();
    let mut second = ArtifactCollector::with_spool_budget(
        VM,
        8,
        root.path(),
        spool.path(),
        ArtifactLimits::default(),
        budget,
    )
    .unwrap();
    let session = session();
    let eight = collect("eight", 8);
    let nine = collect("nine", 9);
    first.collect(&session, &eight).await.unwrap();
    assert_eq!(
        second.collect(&session, &nine).await.unwrap_err().code,
        ErrorCode::ArtifactLimitExceeded
    );
    first.release(&session, &eight).unwrap();
    assert_eq!(
        second.collect(&session, &nine).await.unwrap().artifacts[0].size_bytes,
        9
    );
}

#[tokio::test]
async fn capture_quota_is_shared_with_exec_and_rejects_a_command_before_its_side_effect() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("eight"), b"12345678").unwrap();
    std::fs::write(root.path().join("nine"), b"123456789").unwrap();
    let budget = SpoolBudget::new(16);
    let mut collector = ArtifactCollector::with_spool_budget(
        VM,
        8,
        root.path(),
        spool.path(),
        ArtifactLimits::default(),
        budget.clone(),
    )
    .unwrap();
    let mut executor = Executor::with_spool_budget(
        VM,
        8,
        spool.path(),
        ExecLimits {
            max_output_bytes: 16,
            ..ExecLimits::default()
        },
        budget,
    )
    .unwrap();
    let session = session();
    let eight = collect("eight", 8);
    let nine = collect("nine", 9);
    collector.collect(&session, &eight).await.unwrap();
    let start = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "start-quota",
        "method": "exec.start", "vm_id": VM, "driver_generation": 8, "operation_id": OP,
        "params": {"argv": ["/bin/sh", "-c", "printf executed > marker; printf 12345678"],
        "cwd": root.path(), "env": {}, "timeout_seconds": 3,
        "capture": {"stdout": true, "stderr": true, "max_inline_bytes": 0}}});
    assert_eq!(
        executor.start(&session, &start).unwrap_err().code,
        ErrorCode::ExecStartFailed
    );
    assert!(!root.path().join("marker").exists());
    collector.release(&session, &eight).unwrap();
    executor.start(&session, &start).unwrap();
    let status = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "status-quota",
        "method": "exec.status", "vm_id": VM, "driver_generation": 8, "operation_id": OP, "params": {}});
    let terminal = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        executor.wait(&session, &status),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(terminal.result.state, ExecState::Succeeded);
    assert_eq!(
        std::fs::read(root.path().join("marker")).unwrap(),
        b"executed"
    );
    assert_eq!(
        collector.collect(&session, &nine).await.unwrap_err().code,
        ErrorCode::ArtifactLimitExceeded
    );
    executor.release(&session, &status).unwrap();
    assert_eq!(
        collector.collect(&session, &nine).await.unwrap().artifacts[0].size_bytes,
        9
    );
}

#[tokio::test]
async fn an_open_reader_keeps_its_quota_and_bytes_after_collection_release_and_owner_drop() {
    use std::io::Read;

    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("eight"), b"12345678").unwrap();
    std::fs::write(root.path().join("one"), b"x").unwrap();
    let budget = SpoolBudget::new(8);
    let mut first = ArtifactCollector::with_spool_budget(
        VM,
        8,
        root.path(),
        spool.path(),
        ArtifactLimits::default(),
        budget.clone(),
    )
    .unwrap();
    let mut second = ArtifactCollector::with_spool_budget(
        VM,
        9,
        root.path(),
        spool.path(),
        ArtifactLimits::default(),
        budget,
    )
    .unwrap();
    let session = session();
    let request = collect("eight", 8);
    let snapshot = first.collect(&session, &request).await.unwrap();
    let mut reader = first
        .open_artifact(&session, &request, &snapshot.artifacts[0].artifact_id)
        .unwrap();
    first.release(&session, &request).unwrap();
    drop(first);
    let new_session = session_at(9);
    let mut one = collect("one", 1);
    one["driver_generation"] = json!(9);
    assert_eq!(
        second.collect(&new_session, &one).await.unwrap_err().code,
        ErrorCode::ArtifactLimitExceeded
    );
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, b"12345678");
    drop(reader);
    assert_eq!(
        second.collect(&new_session, &one).await.unwrap().artifacts[0].size_bytes,
        1
    );
}

struct ReleaseWorker(Option<std::sync::mpsc::Sender<()>>);

impl Drop for ReleaseWorker {
    fn drop(&mut self) {
        if let Some(sender) = self.0.take() {
            let _ = sender.send(());
        }
    }
}

#[test]
fn cancelling_a_queued_read_does_not_free_quota_before_the_actual_worker_closes_its_file() {
    use std::future::Future;
    use std::task::Poll;
    use tokio::io::AsyncReadExt;

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let root = tempfile::tempdir().unwrap();
        let spool = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("eight"), b"12345678").unwrap();
        let budget = SpoolBudget::new(8);
        let mut collector = ArtifactCollector::with_spool_budget(
            VM, 8, root.path(), spool.path(), ArtifactLimits::default(), budget.clone(),
        ).unwrap();
        let session = session();
        let request = collect("eight", 8);
        let snapshot = collector.collect(&session, &request).await.unwrap();
        let mut reader = collector.open_artifact(&session, &request, &snapshot.artifacts[0].artifact_id)
            .unwrap().into_inner().into_async();
        let (started, ready) = tokio::sync::oneshot::channel();
        let (release, wait) = std::sync::mpsc::channel();
        let blocker = tokio::task::spawn_blocking(move || { started.send(()).unwrap(); wait.recv().unwrap(); });
        let release = ReleaseWorker(Some(release));
        ready.await.unwrap();
        let mut bytes = [0; 8];
        let mut pending = Box::pin(reader.read(&mut bytes));
        std::future::poll_fn(|cx| { assert!(pending.as_mut().poll(cx).is_pending()); Poll::Ready(()) }).await;
        drop(pending);
        drop(reader);
        collector.release(&session, &request).unwrap();
        drop(collector);
        let mut executor = Executor::with_spool_budget(
            VM, 8, spool.path(), ExecLimits { max_output_bytes: 1, ..ExecLimits::default() }, budget.clone(),
        ).unwrap();
        let start = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "start-quota",
            "method": "exec.start", "vm_id": VM, "driver_generation": 8, "operation_id": OP,
            "params": {"argv": ["/bin/sh", "-c", "printf x"], "cwd": root.path(), "env": {}, "timeout_seconds": 3,
            "capture": {"stdout": true, "stderr": false, "max_inline_bytes": 0}}});
        assert_eq!(executor.start(&session, &start).unwrap_err().code, ErrorCode::ExecStartFailed);
        drop(release);
        blocker.await.unwrap();
        budget.quiesce().await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                match executor.start(&session, &start) {
                    Ok(_) => break,
                    Err(error) => { assert_eq!(error.code, ErrorCode::ExecStartFailed); tokio::task::yield_now().await; }
                }
            }
        }).await.unwrap();
        let status = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "status-quota",
            "method": "exec.status", "vm_id": VM, "driver_generation": 8, "operation_id": OP, "params": {}});
        assert_eq!(executor.wait(&session, &status).await.unwrap().result.state, ExecState::Succeeded);
        executor.shutdown().await.unwrap();
    });
}

#[test]
fn cancelled_capture_keeps_a_queued_writer_charged_after_its_executor_is_dropped() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let root = tempfile::tempdir().unwrap();
        let spool = tempfile::tempdir().unwrap();
        let budget = SpoolBudget::new(8);
        let mut executor = Executor::with_spool_budget(
            VM, 8, spool.path(), ExecLimits { max_output_bytes: 8, ..ExecLimits::default() }, budget.clone(),
        ).unwrap();
        let session = session();
        let (started, ready) = tokio::sync::oneshot::channel();
        let (release, wait) = std::sync::mpsc::channel();
        let blocker = tokio::task::spawn_blocking(move || { started.send(()).unwrap(); wait.recv().unwrap(); });
        let release = ReleaseWorker(Some(release));
        ready.await.unwrap();
        let mut start = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "start-quota",
            "method": "exec.start", "vm_id": VM, "driver_generation": 8, "operation_id": OP,
            "params": {"argv": ["/bin/sh", "-c", "printf 12345678; printf ready > marker; exec sleep 30"],
            "cwd": root.path(), "env": {}, "timeout_seconds": 5,
            "capture": {"stdout": true, "stderr": false, "max_inline_bytes": 0}}});
        executor.start(&session, &start).unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while std::fs::read(root.path().join("marker")).ok().as_deref() != Some(b"ready") {
                tokio::time::sleep(std::time::Duration::from_millis(1)).await;
            }
        }).await.unwrap();
        let mut status = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "status-quota",
            "method": "exec.status", "vm_id": VM, "driver_generation": 8, "operation_id": OP, "params": {}});
        let mut cancel = status.clone();
        cancel["method"] = json!("exec.cancel");
        executor.cancel(&session, &cancel).unwrap();
        let result = tokio::time::timeout(std::time::Duration::from_secs(4), executor.wait(&session, &status)).await.unwrap().unwrap();
        assert_eq!(result.failure, Some(ErrorCode::GuestInternalError), "unconfirmed capture cleanup must not claim success");
        drop(executor);
        for _ in 0..4 { tokio::task::yield_now().await; }
        let mut replacement = Executor::with_spool_budget(
            VM, 8, spool.path(), ExecLimits { max_output_bytes: 1, ..ExecLimits::default() }, budget.clone(),
        ).unwrap();
        start["operation_id"] = json!("op_01J00000000000000000000001");
        start["params"]["argv"] = json!(["/bin/sh", "-c", "printf x"]);
        status["operation_id"] = start["operation_id"].clone();
        assert_eq!(replacement.start(&session, &start).unwrap_err().code, ErrorCode::ExecStartFailed);
        drop(release);
        blocker.await.unwrap();
        budget.quiesce().await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            loop {
                match replacement.start(&session, &start) {
                    Ok(_) => break,
                    Err(error) => { assert_eq!(error.code, ErrorCode::ExecStartFailed); tokio::task::yield_now().await; }
                }
            }
        }).await.unwrap();
        assert_eq!(replacement.wait(&session, &status).await.unwrap().result.state, ExecState::Succeeded);
        replacement.shutdown().await.unwrap();
    });
}

#[tokio::test]
async fn uncertain_spool_removal_fails_closed_instead_of_recycling_its_capacity() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("eight"), b"12345678").unwrap();
    let budget = SpoolBudget::new(8);
    let mut collector = ArtifactCollector::with_spool_budget(
        VM,
        8,
        root.path(),
        spool.path(),
        ArtifactLimits::default(),
        budget.clone(),
    )
    .unwrap();
    let session = session();
    let request = collect("eight", 8);
    collector.collect(&session, &request).await.unwrap();
    let directory = std::fs::read_dir(spool.path())
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let file = std::fs::read_dir(&directory)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    // Directory replacement makes remove_file fail even under root, unlike a
    // permissions-only fixture. This is our owned temporary test workspace.
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    let sentinel = file.join("preserve");
    std::fs::write(&sentinel, b"unconfirmed namespace").unwrap();
    collector.release(&session, &request).unwrap();
    drop(collector);
    assert!(
        budget.quiesce().await.is_err(),
        "unknown cleanup must be observable"
    );
    assert_eq!(std::fs::read(&sentinel).unwrap(), b"unconfirmed namespace");
    let mut executor = Executor::with_spool_budget(
        VM,
        8,
        spool.path(),
        ExecLimits {
            max_output_bytes: 1,
            ..ExecLimits::default()
        },
        budget,
    )
    .unwrap();
    let start = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "start-quota",
        "method": "exec.start", "vm_id": VM, "driver_generation": 8, "operation_id": OP,
        "params": {"argv": ["/bin/sh", "-c", "printf unsafe > marker"],
        "cwd": root.path(), "env": {}, "timeout_seconds": 3,
        "capture": {"stdout": true, "stderr": false, "max_inline_bytes": 0}}});
    assert_eq!(
        executor.start(&session, &start).unwrap_err().code,
        ErrorCode::ExecStartFailed
    );
    assert!(!root.path().join("marker").exists());
}

#[tokio::test]
async fn inline_capture_cleanup_failure_cannot_be_sealed_as_a_clean_terminal_result() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let budget = SpoolBudget::new(8);
    let mut executor = Executor::with_spool_budget(
        VM,
        8,
        spool.path(),
        ExecLimits {
            max_output_bytes: 8,
            ..ExecLimits::default()
        },
        budget.clone(),
    )
    .unwrap();
    let session = session();
    let start = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "start-quota",
        "method": "exec.start", "vm_id": VM, "driver_generation": 8, "operation_id": OP,
        "params": {"argv": ["/bin/sh", "-c", "printf 12345678; exec sleep 30"],
        "cwd": root.path(), "env": {}, "timeout_seconds": 10,
        "capture": {"stdout": true, "stderr": false, "max_inline_bytes": 64}}});
    executor.start(&session, &start).unwrap();
    let directory = std::fs::read_dir(spool.path())
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let file = std::fs::read_dir(&directory)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    tokio::time::timeout(std::time::Duration::from_secs(1), async {
        while std::fs::metadata(&file).unwrap().len() != 8 {
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
    })
    .await
    .unwrap();
    // The capture writer still owns the original inode. Its eventual inline
    // result drops that inode's path before the execution reservation is sealed.
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    let sentinel = file.join("preserve");
    std::fs::write(&sentinel, b"unconfirmed namespace").unwrap();
    let cancel = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "cancel-quota",
        "method": "exec.cancel", "vm_id": VM, "driver_generation": 8, "operation_id": OP, "params": {}});
    executor.cancel(&session, &cancel).unwrap();
    let mut status = cancel;
    status["method"] = json!("exec.status");
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(4),
        executor.wait(&session, &status),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(
        result.failure,
        Some(ErrorCode::GuestInternalError),
        "unconfirmed inline cleanup is not successful completion"
    );
    assert!(budget.quiesce().await.is_err());
    executor.release(&session, &status).unwrap();
    drop(executor);
    assert_eq!(std::fs::read(&sentinel).unwrap(), b"unconfirmed namespace");
}
