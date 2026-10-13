#![cfg(unix)]

use gaovm_guestd::control::{FrameReader, FrameWriter, NegotiationError};
use gaovm_guestd::dispatcher::GuestResources;
use gaovm_guestd::guest_connection::ControlSlot;
use gaovm_guestd::service::GuestControl;
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use serde_json::{Value, json};
use tokio::io::AsyncReadExt;
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::time::{Duration, Instant};

const VM: &str = "vm_01J00000000000000000000009";
const GENERATION: u64 = 31;

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(3)
}

async fn send_hello(host: &mut UnixStream) -> Session {
    let mut session = Session::new(
        Role::Host,
        VM,
        GENERATION,
        &CORE_CAPABILITIES,
        &CORE_CAPABILITIES,
    )
    .unwrap();
    FrameWriter::new(host)
        .write_object(&session.hello().unwrap(), deadline())
        .await
        .unwrap();
    session
}

#[tokio::test]
async fn unavailable_handlers_never_advertise_core_in_a_hello_or_acknowledgement() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(&root.path().join("missing"), spool.path(), root.path());
    let slot = ControlSlot::new();
    let mut opening = slot.reserve().unwrap();
    let (mut host, guest) = UnixStream::pair().unwrap();
    let (read, write) = guest.into_split();
    let mut reader = FrameReader::new(read);
    let mut writer = FrameWriter::new(write);
    send_hello(&mut host).await;

    let result = resources
        .bootstrap(&mut opening, &mut reader, &mut writer, deadline())
        .await;
    assert!(matches!(result, Err(NegotiationError::Protocol(_))));
    assert!(
        slot.reserve().is_err(),
        "failed initialization still owns its cleanup slot"
    );
    drop(reader);
    drop(writer);
    let mut emitted = Vec::new();
    tokio::time::timeout(Duration::from_secs(1), host.read_to_end(&mut emitted))
        .await
        .unwrap()
        .unwrap();
    assert!(
        emitted.is_empty(),
        "resource failure must not acknowledge core readiness"
    );
    let closing = opening.begin_close().unwrap();
    resources.quiesce().await.unwrap();
    closing.finish().unwrap();
    assert!(slot.reserve().is_ok());
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
fn cancelled_initialization_emits_nothing_and_keeps_cleanup_owned_until_the_actual_worker_finishes()
{
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let root = tempfile::tempdir().unwrap();
        let spool = tempfile::tempdir().unwrap();
        let resources = GuestResources::new(root.path(), spool.path(), root.path());
        let slot = ControlSlot::new();
        let mut opening = slot.reserve().unwrap();
        let (mut host, guest) = UnixStream::pair().unwrap();
        let (read, write) = guest.into_split();
        let mut reader = FrameReader::new(read);
        let mut writer = FrameWriter::new(write);
        send_hello(&mut host).await;
        let (started, ready) = tokio::sync::oneshot::channel();
        let (release, wait) = std::sync::mpsc::channel();
        let release = ReleaseWorker(Some(release));
        let worker = tokio::task::spawn_blocking(move || { started.send(()).unwrap(); wait.recv().unwrap(); });
        ready.await.unwrap();
        let mut pending = Box::pin(resources.bootstrap(&mut opening, &mut reader, &mut writer, deadline()));
        tokio::select! {
            biased;
            result = &mut pending => panic!("initialization completed while its actual worker was queued: {}", result.is_ok()),
            () = tokio::task::yield_now() => {},
        }
        let mut byte = [0];
        assert!(tokio::time::timeout(Duration::from_millis(20), host.read(&mut byte)).await.is_err());
        drop(pending);
        // A cancelled attempt is one-shot even if fresh framing halves are
        // supplied; it cannot resume with a new deadline or a second binding.
        let (_unused, fresh) = UnixStream::pair().unwrap();
        let (read, write) = fresh.into_split();
        let result = tokio::time::timeout(Duration::from_millis(100), resources.bootstrap(
            &mut opening, &mut FrameReader::new(read), &mut FrameWriter::new(write), deadline(),
        )).await.expect("a cancelled initialization owner cannot start another bootstrap");
        assert!(result.is_err());
        drop(reader);
        drop(writer);
        let closing = opening.begin_close().unwrap();
        assert!(slot.reserve().is_err());
        let mut quiescent = Box::pin(resources.quiesce());
        tokio::select! {
            biased;
            result = &mut quiescent => panic!("discarded worker/result still owned: {}", result.is_ok()),
            () = tokio::task::yield_now() => {},
        }
        drop(release);
        worker.await.unwrap();
        quiescent.await.unwrap();
        closing.finish().unwrap();
        assert!(slot.reserve().is_ok());
        let mut emitted = Vec::new();
        host.read_to_end(&mut emitted).await.unwrap();
        assert!(emitted.is_empty());
        assert_eq!(std::fs::read_dir(spool.path()).unwrap().count(), 0);
    });
}

async fn connected(
    resources: &GuestResources,
    slot: &ControlSlot,
) -> (GuestControl<OwnedReadHalf, OwnedWriteHalf>, UnixStream) {
    let (mut host, guest) = UnixStream::pair().unwrap();
    let (read, write) = guest.into_split();
    let mut session = send_hello(&mut host).await;
    let handshake = async {
        let ack = FrameReader::new(&mut host)
            .read_object(deadline())
            .await
            .unwrap()
            .unwrap();
        session.receive_hello(&ack).unwrap();
        let hello = FrameReader::new(&mut host)
            .read_object(deadline())
            .await
            .unwrap()
            .unwrap();
        let ack = session.receive_hello(&hello).unwrap().unwrap();
        FrameWriter::new(&mut host)
            .write_object(&ack, deadline())
            .await
            .unwrap();
    };
    let (control, ()) = tokio::join!(
        GuestControl::bootstrap(
            resources,
            slot,
            FrameReader::new(read),
            FrameWriter::new(write),
            deadline()
        ),
        handshake
    );
    (control.unwrap(), host)
}

fn request(method: &str, operation: Option<&str>, params: Value) -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": format!("service-{method}"),
        "method": method, "vm_id": VM, "driver_generation": GENERATION, "operation_id": operation, "params": params})
}

async fn exchange(host: &mut UnixStream, request: &Value) -> Value {
    FrameWriter::new(&mut *host)
        .write_object(request, deadline())
        .await
        .unwrap();
    let response = FrameReader::new(host)
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
async fn owned_control_loop_dispatches_health_and_finishes_cleanup_before_replacement() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(root.path(), spool.path(), root.path());
    let slot = ControlSlot::new();
    let (control, mut host) = connected(&resources, &slot).await;
    let running = tokio::spawn(control.run(Duration::from_secs(3)));
    let response = exchange(&mut host, &request("health", None, json!({}))).await;
    assert_eq!(response["result"]["status"], "ok");
    drop(host);
    tokio::time::timeout(Duration::from_secs(1), running)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(std::fs::read_dir(spool.path()).unwrap().count(), 0);
    assert!(slot.reserve().is_ok());
}

#[tokio::test]
async fn stale_application_input_is_not_reflected_and_does_not_fence_the_healthy_binding() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(root.path(), spool.path(), root.path());
    let slot = ControlSlot::new();
    let (control, mut host) = connected(&resources, &slot).await;
    let running = tokio::spawn(control.run(Duration::from_secs(3)));
    let mut stale = request("health", None, json!({}));
    stale["driver_generation"] = json!(GENERATION - 1);
    FrameWriter::new(&mut host)
        .write_object(&stale, deadline())
        .await
        .unwrap();
    assert!(
        tokio::time::timeout(Duration::from_millis(20), host.read(&mut [0]))
            .await
            .is_err(),
        "foreign application input must not emit bytes or close a healthy session"
    );
    assert_eq!(
        exchange(&mut host, &request("health", None, json!({}))).await["result"]["status"],
        "ok"
    );
    assert!(slot.reserve().is_err());
    drop(host);
    running.await.unwrap().unwrap();
    assert!(slot.reserve().is_ok());
}

#[tokio::test]
async fn control_eof_joins_a_stalled_owned_binary_transfer_before_reusing_its_slot() {
    use gaovm_guestd::binary::{BinaryHeader, BinarySource, OpenHeader};
    use gaovm_guestd::binary_io::{read_header, write_header};
    use std::sync::Arc;

    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let payload = vec![0xab; 2 * 1024 * 1024];
    std::fs::write(root.path().join("large"), &payload).unwrap();
    let resources = GuestResources::new(root.path(), spool.path(), root.path());
    let slot = ControlSlot::new();
    let (control, mut host) = connected(&resources, &slot).await;
    let handle = control.handle();
    let running = tokio::spawn(control.run(Duration::from_secs(3)));
    let op = "op_01J00000000000000000000009";
    let response = exchange(
        &mut host,
        &request(
            "artifact.collect",
            Some(op),
            json!({
                "paths": [{"path": "large", "kind": "result"}], "max_total_bytes": payload.len(),
            }),
        ),
    )
    .await;
    let descriptor = &response["result"]["artifacts"][0];
    let open = BinaryHeader::Open(OpenHeader {
        protocol_version: "gaovm.binary.v1".to_owned(),
        vm_id: VM.to_owned(),
        driver_generation: GENERATION,
        operation_id: op.to_owned(),
        artifact_id: descriptor["artifact_id"].as_str().unwrap().to_owned(),
        source: BinarySource::Collection {
            stream_id: descriptor["stream_id"].as_str().unwrap().to_owned(),
        },
    });
    let pending = Arc::new(tokio::sync::Semaphore::new(8));
    let (server, binary) = UnixStream::pair().unwrap();
    handle
        .accept_binary(
            server,
            pending.clone().try_acquire_owned().unwrap(),
            deadline(),
            deadline(),
        )
        .unwrap();
    let binary = write_header(binary, &open, deadline()).await.unwrap();
    let (ready, mut binary) = read_header(binary, deadline()).await.unwrap();
    assert!(matches!(ready, BinaryHeader::Ready(_)));
    assert_eq!(
        exchange(&mut host, &request("health", None, json!({}))).await["result"]["status"],
        "ok"
    );
    drop(host);
    tokio::time::timeout(Duration::from_secs(1), running)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let mut partial = Vec::new();
    tokio::time::timeout(Duration::from_secs(1), binary.read_to_end(&mut partial))
        .await
        .unwrap()
        .unwrap();
    assert!(partial.len() < payload.len());
    assert_eq!(pending.available_permits(), 8);
    assert_eq!(std::fs::read_dir(spool.path()).unwrap().count(), 0);
    assert!(slot.reserve().is_ok());
    let (server, mut client) = UnixStream::pair().unwrap();
    assert!(
        handle
            .accept_binary(
                server,
                pending.try_acquire_owned().unwrap(),
                deadline(),
                deadline()
            )
            .is_err()
    );
    assert_eq!(client.read(&mut [0]).await.unwrap(), 0);
}

#[tokio::test]
async fn owned_binary_jobs_transfer_verified_bytes_and_one_fixture_ack_preserves_the_sibling() {
    use gaovm_guestd::binary::{BinaryHeader, BinarySource, CommittedHeader, OpenHeader};
    use gaovm_guestd::binary_io::{BodyReader, read_header, write_header};
    use std::sync::Arc;

    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("left"), b"left").unwrap();
    std::fs::write(root.path().join("right"), b"right").unwrap();
    let resources = GuestResources::new(root.path(), spool.path(), root.path());
    let slot = ControlSlot::new();
    let (control, mut host) = connected(&resources, &slot).await;
    let handle = control.handle();
    let running = tokio::spawn(control.run(Duration::from_secs(3)));
    let op = "op_01J00000000000000000000009";
    let response = exchange(&mut host, &request("artifact.collect", Some(op), json!({
        "paths": [{"path": "left", "kind": "result"}, {"path": "right", "kind": "result"}], "max_total_bytes": 9,
    }))).await;
    let pending = Arc::new(tokio::sync::Semaphore::new(8));
    for (index, expected) in [b"left".as_slice(), b"right".as_slice()]
        .into_iter()
        .enumerate()
    {
        let descriptor = &response["result"]["artifacts"][index];
        let open = BinaryHeader::Open(OpenHeader {
            protocol_version: "gaovm.binary.v1".to_owned(),
            vm_id: VM.to_owned(),
            driver_generation: GENERATION,
            operation_id: op.to_owned(),
            artifact_id: descriptor["artifact_id"].as_str().unwrap().to_owned(),
            source: BinarySource::Collection {
                stream_id: descriptor["stream_id"].as_str().unwrap().to_owned(),
            },
        });
        let (server, client) = UnixStream::pair().unwrap();
        handle
            .accept_binary(
                server,
                pending.clone().try_acquire_owned().unwrap(),
                deadline(),
                deadline(),
            )
            .unwrap();
        let client = write_header(client, &open, deadline()).await.unwrap();
        let (BinaryHeader::Ready(ready), client) = read_header(client, deadline()).await.unwrap()
        else {
            panic!("expected ready");
        };
        let mut reader = BodyReader::new(client, &ready.artifact, deadline()).unwrap();
        let mut bytes = Vec::new();
        while let Some(chunk) = reader.read_chunk().await.unwrap() {
            bytes.extend_from_slice(&chunk);
        }
        assert_eq!(bytes, expected);
        let client = reader.finish().unwrap();
        let mut client = write_header(
            client,
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
        assert_eq!(client.read(&mut [0]).await.unwrap(), 0);
    }
    assert_eq!(
        exchange(&mut host, &request("health", None, json!({}))).await["result"]["status"],
        "ok"
    );
    drop(host);
    running.await.unwrap().unwrap();
    assert_eq!(pending.available_permits(), 8);
    assert_eq!(std::fs::read_dir(spool.path()).unwrap().count(), 0);
}

#[tokio::test]
async fn requested_service_stop_reaps_its_real_execution_before_finishing_cleanup() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(root.path(), spool.path(), root.path());
    let slot = ControlSlot::new();
    let (control, mut host) = connected(&resources, &slot).await;
    let handle = control.handle();
    let running = tokio::spawn(control.run(Duration::from_secs(3)));
    let accepted = exchange(&mut host, &request("exec.start", Some("op_01J00000000000000000000009"), json!({
        "argv": ["/bin/sh", "-c", "echo $$ > pid; exec sleep 30"], "cwd": root.path(), "env": {}, "timeout_seconds": 60,
        "capture": {"stdout": true, "stderr": true, "max_inline_bytes": 64},
    }))).await;
    assert_eq!(accepted["result"]["state"], "running");
    let pid: i32 = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if let Ok(text) = std::fs::read_to_string(root.path().join("pid"))
                && let Ok(pid) = text.trim().parse()
            {
                break pid;
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await
    .unwrap();
    handle.stop();
    tokio::time::timeout(Duration::from_secs(1), running)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).unwrap_err(),
        nix::errno::Errno::ESRCH
    );
    assert_eq!(host.read(&mut [0]).await.unwrap(), 0);
    assert!(slot.reserve().is_ok());
    assert_eq!(std::fs::read_dir(spool.path()).unwrap().count(), 0);
}

#[tokio::test]
async fn requested_stop_cannot_hide_drop_time_spool_failure_or_advertise_on_a_fresh_slot() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("eight"), b"12345678").unwrap();
    let resources = GuestResources::new(root.path(), spool.path(), root.path());
    let slot = ControlSlot::new();
    let (control, mut host) = connected(&resources, &slot).await;
    let handle = control.handle();
    let running = tokio::spawn(control.run(Duration::from_secs(3)));
    let response = exchange(
        &mut host,
        &request(
            "artifact.collect",
            Some("op_01J00000000000000000000009"),
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
    // Only our private temporary fixture is replaced. The sentinel proves the
    // coordinator does not remove an unconfirmed namespace or declare it clean.
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    let sentinel = file.join("preserve");
    std::fs::write(&sentinel, b"unconfirmed namespace").unwrap();
    handle.stop();
    let result = tokio::time::timeout(Duration::from_secs(1), running)
        .await
        .unwrap()
        .unwrap();
    assert!(result.is_err(), "requested stop cannot mask failed cleanup");
    assert!(slot.reserve().is_err());
    assert_eq!(std::fs::read(&sentinel).unwrap(), b"unconfirmed namespace");
    assert_eq!(host.read(&mut [0]).await.unwrap(), 0);

    // A different slot must not hide a quarantined process-lifetime resource
    // owner. Initialization fails before a guest hello or host hello ACK.
    let fresh_slot = ControlSlot::new();
    let (mut fresh_host, guest) = UnixStream::pair().unwrap();
    let (read, write) = guest.into_split();
    send_hello(&mut fresh_host).await;
    assert!(
        GuestControl::bootstrap(
            &resources,
            &fresh_slot,
            FrameReader::new(read),
            FrameWriter::new(write),
            deadline(),
        )
        .await
        .is_err()
    );
    let mut emitted = Vec::new();
    tokio::time::timeout(Duration::from_secs(1), fresh_host.read_to_end(&mut emitted))
        .await
        .unwrap()
        .unwrap();
    assert!(emitted.is_empty());
    assert!(fresh_slot.reserve().is_err());
    assert_eq!(std::fs::read(&sentinel).unwrap(), b"unconfirmed namespace");
}
