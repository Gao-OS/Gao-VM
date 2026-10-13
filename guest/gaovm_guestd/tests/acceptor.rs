#![cfg(unix)]

use gaovm_guestd::acceptor::GuestAcceptor;
use gaovm_guestd::control::{FrameReader, FrameWriter};
use gaovm_guestd::dispatcher::GuestResources;
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::io::AsyncReadExt;
use tokio::net::UnixStream;
use tokio::sync::Semaphore;
use tokio::time::{Duration, Instant};

const VM: &str = "vm_01J00000000000000000000010";
const GENERATION: u64 = 32;

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(3)
}

async fn hello(host: &mut UnixStream) {
    let mut session = Session::new(
        Role::Host,
        VM,
        GENERATION,
        &CORE_CAPABILITIES,
        &CORE_CAPABILITIES,
    )
    .unwrap();
    FrameWriter::new(&mut *host)
        .write_object(&session.hello().unwrap(), deadline())
        .await
        .unwrap();
    let ack = FrameReader::new(&mut *host)
        .read_object(deadline())
        .await
        .unwrap()
        .unwrap();
    session.receive_hello(&ack).unwrap();
    let hello = FrameReader::new(&mut *host)
        .read_object(deadline())
        .await
        .unwrap()
        .unwrap();
    let ack = session.receive_hello(&hello).unwrap().unwrap();
    FrameWriter::new(&mut *host)
        .write_object(&ack, deadline())
        .await
        .unwrap();
}

fn request(method: &str, operation: Option<&str>, params: Value) -> Value {
    json!({
        "protocol_version": "gaovm.guest.v1", "kind": "request", "id": format!("acceptor-{method}"), "method": method,
        "vm_id": VM, "driver_generation": GENERATION, "operation_id": operation, "params": params,
    })
}

async fn exchange(host: &mut UnixStream, request: &Value) -> Value {
    FrameWriter::new(&mut *host)
        .write_object(request, deadline())
        .await
        .unwrap();
    let response = FrameReader::new(&mut *host)
        .read_object(deadline())
        .await
        .unwrap()
        .unwrap();
    gaovm_guestd::protocol::validate_message(&response).unwrap();
    assert_eq!(response["id"], request["id"]);
    assert_eq!(response["driver_generation"], GENERATION);
    response
}

#[tokio::test]
async fn the_acceptor_restores_the_control_prefix_and_joins_its_session_on_shutdown() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(root.path(), spool.path(), root.path());
    let mut service = GuestAcceptor::new(resources, Duration::from_secs(3)).unwrap();
    let pending = Arc::new(Semaphore::new(8));
    let (guest, mut host) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    hello(&mut host).await;
    assert_eq!(
        exchange(&mut host, &request("health", None, json!({}))).await["result"]["status"],
        "ok"
    );
    tokio::time::timeout(Duration::from_secs(1), service.shutdown())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(host.read(&mut [0]).await.unwrap(), 0);
    assert_eq!(pending.available_permits(), 8);
    assert_eq!(std::fs::read_dir(spool.path()).unwrap().count(), 0);
}

#[tokio::test]
async fn the_same_port_acceptor_routes_a_published_grant_without_consuming_its_magic_twice() {
    use gaovm_guestd::binary::{BinaryHeader, BinarySource, CommittedHeader, OpenHeader};
    use gaovm_guestd::binary_io::{BodyReader, read_header, write_header};

    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("result"), b"exact bytes").unwrap();
    let mut service = GuestAcceptor::new(
        GuestResources::new(root.path(), spool.path(), root.path()),
        Duration::from_secs(3),
    )
    .unwrap();
    let pending = Arc::new(Semaphore::new(8));
    let (guest, mut host) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    hello(&mut host).await;
    let op = "op_01J00000000000000000000010";
    let response = exchange(
        &mut host,
        &request(
            "artifact.collect",
            Some(op),
            json!({
                "paths": [{"path": "result", "kind": "result"}], "max_total_bytes": 11,
            }),
        ),
    )
    .await;
    let descriptor = &response["result"]["artifacts"][0];
    let (guest, binary) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    let binary = write_header(
        binary,
        &BinaryHeader::Open(OpenHeader {
            protocol_version: "gaovm.binary.v1".to_owned(),
            vm_id: VM.to_owned(),
            driver_generation: GENERATION,
            operation_id: op.to_owned(),
            artifact_id: descriptor["artifact_id"].as_str().unwrap().to_owned(),
            source: BinarySource::Collection {
                stream_id: descriptor["stream_id"].as_str().unwrap().to_owned(),
            },
        }),
        deadline(),
    )
    .await
    .unwrap();
    let (BinaryHeader::Ready(ready), binary) = read_header(binary, deadline()).await.unwrap()
    else {
        panic!("expected ready");
    };
    let mut body = BodyReader::new(binary, &ready.artifact, deadline()).unwrap();
    let mut bytes = Vec::new();
    while let Some(chunk) = body.read_chunk().await.unwrap() {
        bytes.extend_from_slice(&chunk);
    }
    assert_eq!(bytes, b"exact bytes");
    let binary = body.finish().unwrap();
    let mut binary = write_header(
        binary,
        &BinaryHeader::Committed(CommittedHeader {
            protocol_version: "gaovm.binary.v1".to_owned(),
            vm_id: VM.to_owned(),
            driver_generation: GENERATION,
            operation_id: op.to_owned(),
            artifact_id: ready.artifact.artifact_id,
            stream_id: ready.artifact.stream_id,
            size_bytes: ready.artifact.size_bytes,
            digest: ready.artifact.digest,
        }),
        deadline(),
    )
    .await
    .unwrap();
    assert_eq!(binary.read(&mut [0]).await.unwrap(), 0);
    assert_eq!(
        exchange(&mut host, &request("health", None, json!({}))).await["result"]["status"],
        "ok"
    );
    service.shutdown().await.unwrap();
    assert_eq!(pending.available_permits(), 8);
}

#[tokio::test]
async fn another_control_opening_cannot_replace_a_healthy_binding() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let mut service = GuestAcceptor::new(
        GuestResources::new(root.path(), spool.path(), root.path()),
        Duration::from_secs(3),
    )
    .unwrap();
    let pending = Arc::new(Semaphore::new(8));
    let (guest, mut host) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    hello(&mut host).await;
    exchange(&mut host, &request("health", None, json!({}))).await;
    let (guest, mut duplicate) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    let mut session = Session::new(
        Role::Host,
        VM,
        GENERATION,
        &CORE_CAPABILITIES,
        &CORE_CAPABILITIES,
    )
    .unwrap();
    FrameWriter::new(&mut duplicate)
        .write_object(&session.hello().unwrap(), deadline())
        .await
        .unwrap();
    // The four prefix bytes are consumed; unread payload may cause a socket
    // reset on close. Neither EOF nor reset may carry an acknowledgement.
    match tokio::time::timeout(Duration::from_secs(1), duplicate.read(&mut [0]))
        .await
        .unwrap()
    {
        Ok(count) => assert_eq!(count, 0),
        Err(error) => assert_eq!(error.kind(), std::io::ErrorKind::ConnectionReset),
    }
    assert_eq!(
        exchange(&mut host, &request("health", None, json!({}))).await["result"]["status"],
        "ok"
    );
    service.shutdown().await.unwrap();
    assert_eq!(pending.available_permits(), 8);
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
fn acceptor_shutdown_waits_for_an_actual_queued_initializer_after_cancelling_its_opening() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let root = tempfile::tempdir().unwrap();
        let spool = tempfile::tempdir().unwrap();
        let mut service = GuestAcceptor::new(GuestResources::new(root.path(), spool.path(), root.path()), Duration::from_secs(3)).unwrap();
        let pending = Arc::new(Semaphore::new(8));
        let (started, ready) = tokio::sync::oneshot::channel();
        let (release, wait) = std::sync::mpsc::channel();
        let release = ReleaseWorker(Some(release));
        let worker = tokio::task::spawn_blocking(move || { started.send(()).unwrap(); wait.recv().unwrap(); });
        ready.await.unwrap();
        let (guest, mut host) = UnixStream::pair().unwrap();
        service.accept(guest, pending.clone().try_acquire_owned().unwrap(), deadline(), deadline()).unwrap();
        let mut session = Session::new(Role::Host, VM, GENERATION, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
        FrameWriter::new(&mut host).write_object(&session.hello().unwrap(), deadline()).await.unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(20), host.read(&mut [0])).await.is_err());
        assert_eq!(pending.available_permits(), 7, "opening permit is retained through initialization/hello");
        let mut stopping = Box::pin(service.shutdown());
        tokio::select! {
            biased;
            result = &mut stopping => panic!("shutdown forgot its queued actual worker: {}", result.is_ok()),
            () = tokio::task::yield_now() => {},
        }
        tokio::select! {
            biased;
            result = &mut stopping => panic!("caller cancellation did not dispose the actual initialized-engine result: {}", result.is_ok()),
            () = tokio::task::yield_now() => {},
        }
        drop(release);
        worker.await.unwrap();
        tokio::time::timeout(Duration::from_secs(1), stopping).await.unwrap().unwrap();
        let mut emitted = Vec::new();
        host.read_to_end(&mut emitted).await.unwrap();
        assert!(emitted.is_empty());
        assert_eq!(pending.available_permits(), 8);
        assert_eq!(std::fs::read_dir(spool.path()).unwrap().count(), 0);
    });
}

#[tokio::test]
async fn completed_peer_work_is_supervised_without_waiting_for_another_connection() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let mut service = GuestAcceptor::new(
        GuestResources::new(root.path(), spool.path(), root.path()),
        Duration::from_secs(3),
    )
    .unwrap();
    let pending = Arc::new(Semaphore::new(8));
    let (guest, mut host) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    hello(&mut host).await;
    exchange(&mut host, &request("health", None, json!({}))).await;
    drop(host);
    tokio::time::timeout(Duration::from_secs(1), service.completed())
        .await
        .unwrap()
        .unwrap();
    let (guest, mut replacement) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    hello(&mut replacement).await;
    assert_eq!(
        exchange(&mut replacement, &request("health", None, json!({}))).await["result"]["status"],
        "ok"
    );
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn partial_hello_keeps_its_original_accept_deadline_and_returns_the_opening_permit() {
    use tokio::io::AsyncWriteExt;

    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let mut service = GuestAcceptor::new(
        GuestResources::new(root.path(), spool.path(), root.path()),
        Duration::from_secs(3),
    )
    .unwrap();
    let pending = Arc::new(Semaphore::new(8));
    let (guest, mut host) = UnixStream::pair().unwrap();
    let mut session = Session::new(
        Role::Host,
        VM,
        GENERATION,
        &CORE_CAPABILITIES,
        &CORE_CAPABILITIES,
    )
    .unwrap();
    let payload = serde_json::to_vec(&session.hello().unwrap()).unwrap();
    // Prepare/validate the fixture before starting its short wire deadline;
    // first-use schema compilation is not part of an incomplete peer hello.
    let mut partial = (payload.len() as u32).to_be_bytes().to_vec();
    partial.push(payload[0]);
    let expires = Instant::now() + Duration::from_millis(80);
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            expires,
            deadline(),
        )
        .unwrap();
    host.write_all(&partial).await.unwrap();
    assert_eq!(
        tokio::time::timeout(Duration::from_millis(300), host.read(&mut [0]))
            .await
            .unwrap()
            .unwrap(),
        0
    );
    service.completed().await.unwrap();
    assert_eq!(pending.available_permits(), 8);
    // Expiring an opening with confirmed cleanup still permits a fresh hello.
    let (guest, mut replacement) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    hello(&mut replacement).await;
    exchange(&mut replacement, &request("health", None, json!({}))).await;
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn drop_time_cleanup_failure_reaches_the_supervisor_and_closes_further_admission() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("eight"), b"12345678").unwrap();
    let mut service = GuestAcceptor::new(
        GuestResources::new(root.path(), spool.path(), root.path()),
        Duration::from_secs(3),
    )
    .unwrap();
    let pending = Arc::new(Semaphore::new(8));
    let (guest, mut host) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    hello(&mut host).await;
    let response = exchange(
        &mut host,
        &request(
            "artifact.collect",
            Some("op_01J00000000000000000000010"),
            json!({
                "paths": [{"path": "eight", "kind": "result"}], "max_total_bytes": 8,
            }),
        ),
    )
    .await;
    assert_eq!(response["kind"], "response");
    let directory = std::fs::read_dir(spool.path())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("gaovm-artifacts-")
        })
        .unwrap();
    let file = std::fs::read_dir(&directory)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    // A deliberate substitution only in this owned temporary fixture.
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    let sentinel = file.join("preserve");
    std::fs::write(&sentinel, b"unconfirmed namespace").unwrap();
    drop(host);
    assert!(
        tokio::time::timeout(Duration::from_secs(1), service.completed())
            .await
            .unwrap()
            .is_err()
    );
    let (guest, mut replacement) = UnixStream::pair().unwrap();
    assert!(
        service
            .accept(
                guest,
                pending.clone().try_acquire_owned().unwrap(),
                deadline(),
                deadline()
            )
            .is_err()
    );
    assert_eq!(replacement.read(&mut [0]).await.unwrap(), 0);
    assert!(service.shutdown().await.is_err());
    assert_eq!(pending.available_permits(), 8);
    assert_eq!(std::fs::read(&sentinel).unwrap(), b"unconfirmed namespace");
}

fn collection_open(descriptor: &Value) -> gaovm_guestd::binary::OpenHeader {
    use gaovm_guestd::binary::{BinarySource, OpenHeader};
    OpenHeader {
        protocol_version: "gaovm.binary.v1".to_owned(),
        vm_id: VM.to_owned(),
        driver_generation: GENERATION,
        operation_id: "op_01J00000000000000000000010".to_owned(),
        artifact_id: descriptor["artifact_id"].as_str().unwrap().to_owned(),
        source: BinarySource::Collection {
            stream_id: descriptor["stream_id"].as_str().unwrap().to_owned(),
        },
    }
}

async fn binary_open(
    service: &mut GuestAcceptor,
    pending: &Arc<Semaphore>,
    open: &gaovm_guestd::binary::OpenHeader,
) -> UnixStream {
    let (guest, host) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    gaovm_guestd::binary_io::write_header(
        host,
        &gaovm_guestd::binary::BinaryHeader::Open(open.clone()),
        deadline(),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn an_authorized_source_failure_sends_a_correlated_error_without_retiring_the_grant() {
    use gaovm_guestd::binary::{BinaryErrorCode, BinaryHeader, CommittedHeader};
    use gaovm_guestd::binary_io::{BodyReader, read_header, write_header};

    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("eight"), b"12345678").unwrap();
    let mut service = GuestAcceptor::new(
        GuestResources::new(root.path(), spool.path(), root.path()),
        Duration::from_secs(3),
    )
    .unwrap();
    let pending = Arc::new(Semaphore::new(8));
    let (guest, mut host) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    hello(&mut host).await;
    let response = exchange(
        &mut host,
        &request(
            "artifact.collect",
            Some("op_01J00000000000000000000010"),
            json!({
                "paths": [{"path": "eight", "kind": "result"}], "max_total_bytes": 8,
            }),
        ),
    )
    .await;
    let open = collection_open(&response["result"]["artifacts"][0]);
    let directory = std::fs::read_dir(spool.path())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("gaovm-artifacts-")
        })
        .unwrap();
    let file = std::fs::read_dir(&directory)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let backup = file.with_extension("saved-inode");
    std::fs::rename(&file, &backup).unwrap();
    let binary = binary_open(&mut service, &pending, &open).await;
    let (BinaryHeader::Error(error), mut binary) = read_header(binary, deadline())
        .await
        .expect("authorized source failure requires an error header")
    else {
        panic!("expected error");
    };
    assert_eq!(error.vm_id, VM);
    assert_eq!(error.driver_generation, GENERATION);
    assert_eq!(error.operation_id, open.operation_id);
    assert_eq!(error.artifact_id, open.artifact_id);
    assert_eq!(error.error.code, BinaryErrorCode::GuestInternalError);
    assert_eq!(error.error.message, "binary source unavailable");
    assert!(!error.error.retryable);
    assert_eq!(
        binary.read(&mut [0]).await.unwrap(),
        0,
        "no artifact body follows the error"
    );
    std::fs::rename(&backup, &file).unwrap();
    assert_eq!(
        exchange(&mut host, &request("health", None, json!({}))).await["result"]["status"],
        "ok"
    );
    let binary = binary_open(&mut service, &pending, &open).await;
    let (BinaryHeader::Ready(ready), binary) = read_header(binary, deadline()).await.unwrap()
    else {
        panic!("source error retired the grant");
    };
    let mut body = BodyReader::new(binary, &ready.artifact, deadline()).unwrap();
    let mut bytes = Vec::new();
    while let Some(chunk) = body.read_chunk().await.unwrap() {
        bytes.extend_from_slice(&chunk);
    }
    assert_eq!(bytes, b"12345678");
    let binary = body.finish().unwrap();
    let mut binary = write_header(
        binary,
        &BinaryHeader::Committed(CommittedHeader {
            protocol_version: "gaovm.binary.v1".to_owned(),
            vm_id: VM.to_owned(),
            driver_generation: GENERATION,
            operation_id: open.operation_id,
            artifact_id: open.artifact_id,
            stream_id: ready.artifact.stream_id,
            size_bytes: ready.artifact.size_bytes,
            digest: ready.artifact.digest,
        }),
        deadline(),
    )
    .await
    .unwrap();
    assert_eq!(binary.read(&mut [0]).await.unwrap(), 0);
    service.shutdown().await.unwrap();
    assert_eq!(pending.available_permits(), 8);
}

#[tokio::test]
async fn quota_errors_require_a_live_full_binding_and_do_not_consume_retry_capacity() {
    use gaovm_guestd::binary::{BinaryErrorCode, BinaryHeader, BinarySource};
    use gaovm_guestd::binary_io::read_header;
    use tokio::io::AsyncWriteExt;

    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    for name in ["a", "b", "c"] {
        std::fs::write(root.path().join(name), name.as_bytes()).unwrap();
    }
    let mut service = GuestAcceptor::new(
        GuestResources::new(root.path(), spool.path(), root.path()),
        Duration::from_secs(3),
    )
    .unwrap();
    let pending = Arc::new(Semaphore::new(8));
    let (guest, mut host) = UnixStream::pair().unwrap();
    service
        .accept(
            guest,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    hello(&mut host).await;
    let response = exchange(&mut host, &request("artifact.collect", Some("op_01J00000000000000000000010"), json!({
        "paths": [{"path": "a", "kind": "result"}, {"path": "b", "kind": "result"}, {"path": "c", "kind": "result"}], "max_total_bytes": 3,
    }))).await;
    let mut held = Vec::new();
    for index in 0..2 {
        let open = collection_open(&response["result"]["artifacts"][index]);
        let binary = binary_open(&mut service, &pending, &open).await;
        let (BinaryHeader::Ready(_), binary) = read_header(binary, deadline()).await.unwrap()
        else {
            panic!("expected ready");
        };
        held.push(binary);
    }
    let open = collection_open(&response["result"]["artifacts"][2]);
    let binary = binary_open(&mut service, &pending, &open).await;
    let (BinaryHeader::Error(error), mut binary) = read_header(binary, deadline())
        .await
        .expect("a verified quota failure requires an error header")
    else {
        panic!("expected limit error");
    };
    assert_eq!(error.error.code, BinaryErrorCode::ArtifactLimitExceeded);
    assert!(error.error.retryable);
    assert_eq!(error.operation_id, open.operation_id);
    assert_eq!(error.artifact_id, open.artifact_id);
    assert_eq!(binary.read(&mut [0]).await.unwrap(), 0);

    let mut unknown_operation = open.clone();
    unknown_operation.operation_id = "op_01J00000000000000000000011".to_owned();
    let mut unknown_handle = open.clone();
    unknown_handle.source = BinarySource::Collection {
        stream_id: "f".repeat(64),
    };
    let mut stale_generation = open.clone();
    stale_generation.driver_generation -= 1;
    let mut foreign_vm = open.clone();
    foreign_vm.vm_id = "vm_01J00000000000000000000011".to_owned();
    let mut foreign_artifact = open.clone();
    foreign_artifact.artifact_id = "art_01J00000000000000000000011".to_owned();
    let mut wrong_source = open.clone();
    wrong_source.source = BinarySource::ExecOutput {
        output: gaovm_guestd::binary::ExecOutput::Stdout,
    };
    for unverified in [
        unknown_operation,
        unknown_handle,
        stale_generation,
        foreign_vm,
        foreign_artifact,
        wrong_source,
    ] {
        let mut binary = binary_open(&mut service, &pending, &unverified).await;
        let mut emitted = Vec::new();
        binary.read_to_end(&mut emitted).await.unwrap();
        assert!(
            emitted.is_empty(),
            "quota exhaustion must not authorize a foreign binding"
        );
    }
    for mut binary in held {
        binary.shutdown().await.unwrap();
        binary.read_to_end(&mut Vec::new()).await.unwrap();
    }
    let binary = binary_open(&mut service, &pending, &open).await;
    assert!(matches!(
        read_header(binary, deadline()).await.unwrap().0,
        BinaryHeader::Ready(_)
    ));
    assert_eq!(
        exchange(&mut host, &request("health", None, json!({}))).await["result"]["status"],
        "ok"
    );
    service.shutdown().await.unwrap();
    assert_eq!(pending.available_permits(), 8);
}

#[tokio::test]
async fn stalled_error_replies_keep_openings_charged_until_deadline_or_epoch_cleanup() {
    use gaovm_guestd::binary::{BinaryHeader, encode_header};
    use gaovm_guestd::binary_io::write_header;
    use std::io::Write;

    for revoke in [false, true] {
        let root = tempfile::tempdir().unwrap();
        let spool = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("eight"), b"12345678").unwrap();
        let mut service = GuestAcceptor::new(
            GuestResources::new(root.path(), spool.path(), root.path()),
            Duration::from_secs(3),
        )
        .unwrap();
        let pending = Arc::new(Semaphore::new(8));
        let (guest, mut host) = UnixStream::pair().unwrap();
        service
            .accept(
                guest,
                pending.clone().try_acquire_owned().unwrap(),
                deadline(),
                deadline(),
            )
            .unwrap();
        hello(&mut host).await;
        let response = exchange(
            &mut host,
            &request(
                "artifact.collect",
                Some("op_01J00000000000000000000010"),
                json!({
                    "paths": [{"path": "eight", "kind": "result"}], "max_total_bytes": 8,
                }),
            ),
        )
        .await;
        let open = collection_open(&response["result"]["artifacts"][0]);
        let directory = std::fs::read_dir(spool.path())
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .find(|path| {
                path.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("gaovm-artifacts-")
            })
            .unwrap();
        let file = std::fs::read_dir(&directory)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        let backup = file.with_extension("saved-inode");
        std::fs::rename(&file, &backup).unwrap();

        let (mut guest, client) = std::os::unix::net::UnixStream::pair().unwrap();
        guest.set_nonblocking(true).unwrap();
        client.set_nonblocking(true).unwrap();
        nix::sys::socket::setsockopt(&guest, nix::sys::socket::sockopt::SndBuf, &4096usize)
            .unwrap();
        // Fill the real send buffer down to its last byte. No fake writer or
        // handler gate is needed to stall the actual error flush.
        let mut filled = 0;
        loop {
            match guest.write(&[0x5a]) {
                Ok(1) => filled += 1,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                other => panic!("cannot establish real socket backpressure: {other:?}"),
            }
        }
        let guest = UnixStream::from_std(guest).unwrap();
        let client = UnixStream::from_std(client).unwrap();
        let expires = Instant::now() + Duration::from_millis(150);
        service
            .accept(
                guest,
                pending.clone().try_acquire_owned().unwrap(),
                expires,
                deadline(),
            )
            .unwrap();
        let mut binary = write_header(client, &BinaryHeader::Open(open.clone()), deadline())
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(
            pending.available_permits(),
            7,
            "a stalled error is still a charged opening"
        );
        assert_eq!(
            exchange(&mut host, &request("health", None, json!({}))).await["result"]["status"],
            "ok"
        );
        // Restore before final context drop so this fixture isolates stalled
        // reply ownership, not drop-time cleanup quarantine.
        std::fs::rename(&backup, &file).unwrap();
        if revoke {
            drop(host);
            // Completion may first report the finished routing task; actual
            // server shutdown joins the control/binary owner and final barrier.
            service.shutdown().await.unwrap();
        } else {
            tokio::time::sleep_until(expires + Duration::from_millis(20)).await;
            assert_eq!(pending.available_permits(), 8);
            assert_eq!(
                exchange(&mut host, &request("health", None, json!({}))).await["result"]["status"],
                "ok"
            );
            service.shutdown().await.unwrap();
        }
        let mut emitted = Vec::new();
        tokio::time::timeout(Duration::from_secs(1), binary.read_to_end(&mut emitted))
            .await
            .unwrap()
            .unwrap();
        // The filled prefix drains, but the blocked error never completes after
        // expiry/revocation. Closing a partial frame is not a reusable reply.
        let error = BinaryHeader::Error(gaovm_guestd::binary::ErrorHeader {
            protocol_version: "gaovm.binary.v1".to_owned(),
            vm_id: VM.to_owned(),
            driver_generation: GENERATION,
            operation_id: open.operation_id,
            artifact_id: open.artifact_id,
            error: gaovm_guestd::binary::BinaryFailure {
                code: gaovm_guestd::binary::BinaryErrorCode::GuestInternalError,
                message: "binary source unavailable".to_owned(),
                retryable: false,
            },
        });
        assert!(emitted.len() < filled + 4 + encode_header(&error).unwrap().len());
        assert!(emitted[..filled].iter().all(|byte| *byte == 0x5a));
        assert_eq!(pending.available_permits(), 8);
        assert_eq!(std::fs::read_dir(spool.path()).unwrap().count(), 0);
    }
}
