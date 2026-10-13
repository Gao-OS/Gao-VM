#![cfg(unix)]

use gaovm_guestd::binary::{
    BinaryArtifact, BinaryHeader, BinarySource, CommittedHeader, ExecOutput, OpenHeader,
};
use gaovm_guestd::binary_io::{BodyReader, read_header, write_header};
use gaovm_guestd::control::{FrameReader, FrameWriter};
use gaovm_guestd::dispatcher::{GuestDispatcher, GuestResources};
use gaovm_guestd::guest_connection::{ActiveControl, ControlSlot};
use gaovm_guestd::protocol::validate_message;
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use serde_json::{Value, json};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::time::{Duration, Instant};

const VM: &str = "vm_01J00000000000000000000000";
const OP: &str = "op_01J00000000000000000000001";

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(3)
}

fn request(method: &str, operation: Option<&str>, params: Value) -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": format!("request-{method}"),
        "method": method, "vm_id": VM, "driver_generation": 8, "operation_id": operation, "params": params})
}

struct ControlFixture {
    owner: ActiveControl,
    reader: FrameReader<OwnedReadHalf>,
    writer: FrameWriter<OwnedWriteHalf>,
    host_reader: FrameReader<OwnedReadHalf>,
    host_writer: FrameWriter<OwnedWriteHalf>,
}

async fn connect(slot: &ControlSlot) -> ControlFixture {
    let (host, guest) = UnixStream::pair().unwrap();
    let (host_read, host_write) = host.into_split();
    let (read, write) = guest.into_split();
    let mut host_reader = FrameReader::new(host_read);
    let mut host_writer = FrameWriter::new(host_write);
    let mut reader = FrameReader::new(read);
    let mut writer = FrameWriter::new(write);
    let limit = deadline();
    let opening = slot.reserve().unwrap();
    let handshake = async {
        let mut host =
            Session::new(Role::Host, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
        host_writer
            .write_object(&host.hello().unwrap(), limit)
            .await
            .unwrap();
        let ack = host_reader.read_object(limit).await.unwrap().unwrap();
        host.receive_hello(&ack).unwrap();
        let hello = host_reader.read_object(limit).await.unwrap().unwrap();
        let ack = host.receive_hello(&hello).unwrap().unwrap();
        host_writer.write_object(&ack, limit).await.unwrap();
    };
    let (owner, ()) = tokio::join!(
        opening.bootstrap(
            &mut reader,
            &mut writer,
            &CORE_CAPABILITIES,
            &CORE_CAPABILITIES,
            limit
        ),
        handshake
    );
    ControlFixture {
        owner: owner.unwrap(),
        reader,
        writer,
        host_reader,
        host_writer,
    }
}

async fn exchange(
    dispatcher: &GuestDispatcher,
    control: &mut ControlFixture,
    request: &Value,
) -> Value {
    let limit = deadline();
    control
        .host_writer
        .write_object(request, limit)
        .await
        .unwrap();
    let received = control
        .owner
        .read_message(&mut control.reader, limit)
        .await
        .unwrap()
        .unwrap();
    let reply = dispatcher.prepare_request(&received, limit).await.unwrap();
    let expected = reply.message().clone();
    reply.flush(&mut control.writer, limit).await.unwrap();
    let response = control
        .host_reader
        .read_object(limit)
        .await
        .unwrap()
        .unwrap();
    validate_message(&response).unwrap();
    assert_eq!(response, expected);
    response
}

#[tokio::test]
async fn a_real_negotiated_control_request_dispatches_health_with_unchanged_correlation() {
    let slot = ControlSlot::new();
    let mut control = connect(&slot).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let system = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(source.path(), spool.path(), system.path());
    let dispatcher = resources.bind(&control.owner).unwrap();
    let response = exchange(
        &dispatcher,
        &mut control,
        &request("health", None, json!({})),
    )
    .await;
    assert_eq!(response["result"]["status"], "ok");
    assert_eq!(response["vm_id"], VM);
    assert_eq!(response["driver_generation"], 8);
    assert_eq!(response["operation_id"], Value::Null);
    assert_eq!(response["id"], "request-health");
    assert!(control.owner.epoch().is_active());
}

fn start(root: &std::path::Path, argv: Value, inline: u64) -> Value {
    request(
        "exec.start",
        Some(OP),
        json!({"argv": argv, "cwd": root, "env": {}, "timeout_seconds": 5,
        "capture": {"stdout": true, "stderr": true, "max_inline_bytes": inline}}),
    )
}

async fn terminal(dispatcher: &GuestDispatcher, control: &mut ControlFixture) -> Value {
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let response = exchange(
                dispatcher,
                control,
                &request("exec.status", Some(OP), json!({})),
            )
            .await;
            let result = if response["kind"] == "error" {
                &response["error"]["details"]["result"]
            } else {
                &response["result"]
            };
            if result["state"] != "running" {
                return response;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn dispatched_exec_runs_a_real_command_and_returns_the_frozen_terminal_result_over_control() {
    let mut control = connect(&ControlSlot::new()).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(source.path(), spool.path(), source.path());
    let dispatcher = resources.bind(&control.owner).unwrap();
    let started = exchange(
        &dispatcher,
        &mut control,
        &start(
            source.path(),
            json!(["/bin/sh", "-c", "printf 'real guest command'"]),
            4096,
        ),
    )
    .await;
    assert_eq!(started["result"]["state"], "running");
    let response = terminal(&dispatcher, &mut control).await;
    assert_eq!(response["result"]["state"], "succeeded");
    assert_eq!(response["result"]["exit_code"], 0);
    assert_eq!(
        response["result"]["stdout"],
        json!({"mode": "inline", "text": "real guest command", "truncated": false, "size_bytes": 18})
    );
    assert_eq!(response["result"]["stderr"]["size_bytes"], 0);
    assert_eq!(response["operation_id"], OP);
}

fn collection_open(response: &Value, index: usize) -> OpenHeader {
    let artifact = &response["result"]["artifacts"][index];
    OpenHeader {
        protocol_version: "gaovm.binary.v1".to_owned(),
        vm_id: VM.to_owned(),
        driver_generation: 8,
        operation_id: response["operation_id"].as_str().unwrap().to_owned(),
        artifact_id: artifact["artifact_id"].as_str().unwrap().to_owned(),
        source: BinarySource::Collection {
            stream_id: artifact["stream_id"].as_str().unwrap().to_owned(),
        },
    }
}

async fn download(dispatcher: &GuestDispatcher, open: &OpenHeader) -> (BinaryArtifact, Vec<u8>) {
    let transfer = dispatcher.open_transfer(open).await.unwrap();
    let expected = transfer.artifact().clone();
    let (guest, host) = UnixStream::pair().unwrap();
    let limit = deadline();
    let receive = async {
        let (header, host) = read_header(host, limit).await.unwrap();
        let BinaryHeader::Ready(ready) = header else {
            panic!("expected ready");
        };
        assert_eq!(
            serde_json::to_value(&ready.artifact).unwrap(),
            serde_json::to_value(&expected).unwrap()
        );
        let mut reader = BodyReader::new(host, &ready.artifact, limit).unwrap();
        let mut bytes = Vec::new();
        while let Some(chunk) = reader.read_chunk().await.unwrap() {
            bytes.extend_from_slice(&chunk);
        }
        let host = reader.finish().unwrap();
        let ack = BinaryHeader::Committed(CommittedHeader {
            protocol_version: "gaovm.binary.v1".to_owned(),
            vm_id: VM.to_owned(),
            driver_generation: 8,
            operation_id: open.operation_id.clone(),
            artifact_id: ready.artifact.artifact_id.clone(),
            stream_id: ready.artifact.stream_id.clone(),
            size_bytes: ready.artifact.size_bytes,
            digest: ready.artifact.digest.clone(),
        });
        drop(write_header(host, &ack, limit).await.unwrap());
        (ready.artifact, bytes)
    };
    let (completed, received) = tokio::join!(transfer.serve(guest, limit, limit), receive);
    assert_eq!(completed.unwrap().artifact_id(), open.artifact_id);
    received
}

#[tokio::test]
async fn collection_dispatch_publishes_sealed_bytes_and_a_single_ack_leaves_the_sibling_available()
{
    let mut control = connect(&ControlSlot::new()).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("one"), b"original\0\xff").unwrap();
    std::fs::write(source.path().join("two"), b"sibling bytes").unwrap();
    let resources = GuestResources::new(source.path(), spool.path(), source.path());
    let dispatcher = resources.bind(&control.owner).unwrap();
    let response = exchange(&dispatcher, &mut control, &request("artifact.collect", Some(OP),
        json!({"paths": [{"path": "one", "kind": "result"}, {"path": "two", "kind": "result"}], "max_total_bytes": 4096}))).await;
    assert_eq!(response["result"]["artifacts"].as_array().unwrap().len(), 2);
    std::fs::write(source.path().join("one"), b"later source contents").unwrap();
    let first = collection_open(&response, 0);
    let (metadata, bytes) = download(&dispatcher, &first).await;
    assert_eq!(bytes, b"original\0\xff");
    assert_eq!(
        serde_json::to_value(metadata).unwrap(),
        response["result"]["artifacts"][0]
    );
    assert!(
        dispatcher.open_transfer(&first).await.is_err(),
        "retired grant admitted another reader"
    );
    let (_, sibling) = download(&dispatcher, &collection_open(&response, 1)).await;
    assert_eq!(sibling, b"sibling bytes");
}

#[tokio::test]
async fn terminal_exec_status_grants_both_real_spills_without_adding_fields_or_reexecuting() {
    let mut control = connect(&ControlSlot::new()).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let marker = source.path().join("executions");
    let resources = GuestResources::new(source.path(), spool.path(), source.path());
    let dispatcher = resources.bind(&control.owner).unwrap();
    let command = start(
        source.path(),
        json!([
            "/bin/sh",
            "-c",
            "printf 'stdout bytes'; printf 'stderr bytes' >&2; printf executed >> \"$1\"",
            "sh",
            marker
        ]),
        1,
    );
    exchange(&dispatcher, &mut control, &command).await;
    let response = terminal(&dispatcher, &mut control).await;
    for (name, selector, bytes) in [
        ("stdout", ExecOutput::Stdout, b"stdout bytes"),
        ("stderr", ExecOutput::Stderr, b"stderr bytes"),
    ] {
        let output = &response["result"][name];
        assert_eq!(output["mode"], "artifact");
        assert_eq!(
            output.as_object().unwrap().len(),
            3,
            "frozen exec output gained transport metadata"
        );
        let open = OpenHeader {
            protocol_version: "gaovm.binary.v1".to_owned(),
            vm_id: VM.to_owned(),
            driver_generation: 8,
            operation_id: OP.to_owned(),
            artifact_id: output["artifact_id"].as_str().unwrap().to_owned(),
            source: BinarySource::ExecOutput { output: selector },
        };
        let (metadata, received) = download(&dispatcher, &open).await;
        assert_eq!(metadata.kind, name);
        assert_eq!(received, bytes);
    }
    exchange(&dispatcher, &mut control, &command).await;
    assert_eq!(
        std::fs::read(&marker).unwrap(),
        b"executed",
        "transfer/replay reexecuted the command"
    );
}

#[tokio::test]
async fn capabilities_and_system_info_dispatch_without_guest_specific_assumptions() {
    let mut control = connect(&ControlSlot::new()).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let system = tempfile::tempdir().unwrap();
    std::fs::create_dir(system.path().join("etc")).unwrap();
    std::fs::write(
        system.path().join("etc/os-release"),
        b"NAME='Generic guest'\nVERSION_ID=1.2\n",
    )
    .unwrap();
    let resources = GuestResources::new(source.path(), spool.path(), system.path());
    let dispatcher = resources.bind(&control.owner).unwrap();
    let capabilities = exchange(
        &dispatcher,
        &mut control,
        &request("capabilities.get", None, json!({})),
    )
    .await;
    assert_eq!(
        capabilities["result"]["capabilities"],
        json!(CORE_CAPABILITIES)
    );
    let info = exchange(
        &dispatcher,
        &mut control,
        &request("system.info", None, json!({})),
    )
    .await;
    assert_eq!(info["result"]["os"]["name"], "Generic guest");
    assert_eq!(info["result"]["os"]["version"], "1.2");
    assert!(info["result"]["kernel"].is_string());
}

struct ReleaseBlockingWorker(std::sync::mpsc::Sender<()>);
impl Drop for ReleaseBlockingWorker {
    fn drop(&mut self) {
        let _ = self.0.send(());
    }
}

#[test]
fn health_and_cancel_remain_responsive_while_terminal_metadata_waits_for_its_entropy_worker() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let mut control = connect(&ControlSlot::new()).await;
        let source = tempfile::tempdir().unwrap();
        let spool = tempfile::tempdir().unwrap();
        let resources = GuestResources::new(source.path(), spool.path(), source.path());
        let dispatcher = resources.bind(&control.owner).unwrap();
        exchange(&dispatcher, &mut control, &start(source.path(), json!(["/bin/sh", "-c", "printf spill"]), 0)).await;
        terminal(&dispatcher, &mut control).await;

        // Occupy the real runtime's one blocking thread so the OS entropy task
        // is definitely queued; no timing assumption or mock registry is used.
        let (started, ready) = tokio::sync::oneshot::channel();
        let (release, wait) = std::sync::mpsc::channel();
        let release = ReleaseBlockingWorker(release);
        let occupied = tokio::task::spawn_blocking(move || { started.send(()).unwrap(); wait.recv().unwrap(); });
        ready.await.unwrap();
        let status_request = request("exec.status", Some(OP), json!({}));
        let mut status = Box::pin(dispatcher.prepare_request(&status_request, deadline()));
        tokio::select! {
            biased;
            result = &mut status => panic!("metadata completed while entropy was queued: {}", result.is_ok()),
            () = tokio::task::yield_now() => {},
        }
        let health = tokio::time::timeout(Duration::from_millis(100), exchange(&dispatcher, &mut control, &request("health", None, json!({})))).await.unwrap();
        assert_eq!(health["result"]["status"], "ok");
        let cancel = tokio::time::timeout(Duration::from_millis(100), exchange(&dispatcher, &mut control, &request("exec.cancel", Some(OP), json!({})))).await.unwrap();
        assert_eq!(cancel["kind"], "response");
        drop(release);
        occupied.await.unwrap();
        drop(status.await.unwrap());
    });
}

#[tokio::test]
async fn authorized_collection_faults_are_correlated_errors_but_foreign_requests_are_never_reflected()
 {
    let mut control = connect(&ControlSlot::new()).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(source.path(), spool.path(), source.path());
    let dispatcher = resources.bind(&control.owner).unwrap();
    let collect = request(
        "artifact.collect",
        Some(OP),
        json!({"paths": [{"path": "missing-sensitive-path", "kind": "result"}], "max_total_bytes": 4096}),
    );
    let response = exchange(&dispatcher, &mut control, &collect).await;
    assert_eq!(response["kind"], "error");
    assert_eq!(response["error"]["code"], "ARTIFACT_NOT_FOUND");
    assert_eq!(response["id"], collect["id"]);
    assert_eq!(response["operation_id"], OP);
    assert!(!response.to_string().contains("missing-sensitive-path"));
    for (field, value) in [
        ("vm_id", json!("vm_01J00000000000000000000009")),
        ("driver_generation", json!(7)),
    ] {
        let mut foreign = collect.clone();
        foreign[field] = value;
        assert!(
            dispatcher
                .prepare_request(&foreign, deadline())
                .await
                .is_err()
        );
        assert!(control.owner.epoch().is_active());
    }
}

#[test]
fn cancelled_entropy_work_keeps_the_shared_blocking_slot_until_the_real_worker_finishes() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .unwrap();
    runtime.block_on(async {
        let mut control = connect(&ControlSlot::new()).await;
        let source = tempfile::tempdir().unwrap();
        let spool = tempfile::tempdir().unwrap();
        let resources = GuestResources::new(source.path(), spool.path(), source.path());
        let dispatcher = resources.bind(&control.owner).unwrap();
        exchange(&dispatcher, &mut control, &start(source.path(), json!(["/bin/sh", "-c", "printf spill"]), 0)).await;
        terminal(&dispatcher, &mut control).await;
        let (started, ready) = tokio::sync::oneshot::channel();
        let (release, wait) = std::sync::mpsc::channel();
        let release = ReleaseBlockingWorker(release);
        let occupied = tokio::task::spawn_blocking(move || { started.send(()).unwrap(); wait.recv().unwrap(); });
        ready.await.unwrap();
        let status_request = request("exec.status", Some(OP), json!({}));
        let mut status = Box::pin(dispatcher.prepare_request(&status_request, deadline()));
        tokio::select! {
            biased;
            result = &mut status => panic!("metadata completed while entropy was queued: {}", result.is_ok()),
            () = tokio::task::yield_now() => {},
        }
        drop(status);
        let info_request = request("system.info", None, json!({}));
        tokio::select! {
            biased;
            result = dispatcher.prepare_request(&info_request, deadline()) => {
                let reply = result.unwrap();
                assert_eq!(reply.message()["error"]["code"], "GUEST_INTERNAL_ERROR");
            },
            () = tokio::task::yield_now() => panic!("a cancelled entropy caller released capacity and queued extra blocking work"),
        }
        drop(release);
        occupied.await.unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let reply = dispatcher.prepare_request(&info_request, deadline()).await.unwrap();
                if reply.message()["kind"] == "response" { break; }
                tokio::task::yield_now().await;
            }
        }).await.unwrap();
    });
}

#[tokio::test]
async fn dispatcher_shutdown_fences_before_reaping_its_real_running_process() {
    let slot = ControlSlot::new();
    let mut control = connect(&slot).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let marker = source.path().join("pid");
    let resources = GuestResources::new(source.path(), spool.path(), source.path());
    let dispatcher = resources.bind(&control.owner).unwrap();
    exchange(
        &dispatcher,
        &mut control,
        &start(
            source.path(),
            json!([
                "/bin/sh",
                "-c",
                "echo $$ > \"$1\"; exec sleep 30",
                "sh",
                marker
            ]),
            0,
        ),
    )
    .await;
    let pid: i32 = tokio::time::timeout(Duration::from_secs(1), async {
        loop {
            if let Ok(text) = std::fs::read_to_string(&marker)
                && let Ok(pid) = text.trim().parse()
            {
                break pid;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    let health_request = request("health", None, json!({}));
    let (stopped, late) = tokio::join!(dispatcher.shutdown(), async {
        assert!(
            !control.owner.epoch().is_active(),
            "cleanup waited before fencing admission"
        );
        dispatcher
            .prepare_request(&health_request, deadline())
            .await
    });
    stopped.unwrap();
    assert!(late.is_err());
    assert_eq!(
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).unwrap_err(),
        nix::errno::Errno::ESRCH
    );
    assert!(slot.reserve().is_err());
    drop(dispatcher);
    let closing = control.owner.begin_close();
    drop(control.reader);
    drop(control.writer);
    drop(control.host_reader);
    drop(control.host_writer);
    resources.quiesce().await.unwrap();
    closing.finish().unwrap();
    assert!(slot.reserve().is_ok());
}

#[tokio::test]
async fn a_revoked_plain_reply_writes_nothing_and_a_failed_flush_fences_the_owner() {
    use tokio::io::AsyncReadExt;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(source.path(), spool.path(), source.path());
    let control = connect(&ControlSlot::new()).await;
    let dispatcher = resources.bind(&control.owner).unwrap();
    let reply = dispatcher
        .prepare_request(&request("health", None, json!({})), deadline())
        .await
        .unwrap();
    control.owner.epoch().invalidate();
    let (transport, mut peer) = tokio::io::duplex(4096);
    let mut writer = FrameWriter::new(transport);
    assert!(reply.flush(&mut writer, deadline()).await.is_err());
    drop(writer);
    let mut bytes = Vec::new();
    peer.read_to_end(&mut bytes).await.unwrap();
    assert!(bytes.is_empty());

    let control = connect(&ControlSlot::new()).await;
    let dispatcher = resources.bind(&control.owner).unwrap();
    let reply = dispatcher
        .prepare_request(&request("health", None, json!({})), deadline())
        .await
        .unwrap();
    let (transport, peer) = tokio::io::duplex(1);
    drop(peer);
    let mut writer = FrameWriter::new(transport);
    assert!(reply.flush(&mut writer, deadline()).await.is_err());
    assert!(!control.owner.epoch().is_active());
}

#[tokio::test]
async fn revoking_an_epoch_interrupts_an_already_stalled_plain_reply() {
    use std::future::Future;
    use std::task::Poll;
    use tokio::io::AsyncReadExt;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(source.path(), spool.path(), source.path());
    let control = connect(&ControlSlot::new()).await;
    let dispatcher = resources.bind(&control.owner).unwrap();
    let reply = dispatcher
        .prepare_request(&request("health", None, json!({})), deadline())
        .await
        .unwrap();
    let (transport, mut peer) = tokio::io::duplex(1);
    let mut writer = FrameWriter::new(transport);
    let mut flush = Box::pin(reply.flush(&mut writer, deadline()));
    std::future::poll_fn(|cx| {
        assert!(matches!(flush.as_mut().poll(cx), Poll::Pending));
        Poll::Ready(())
    })
    .await;

    control.owner.epoch().invalidate();
    let result = tokio::time::timeout(Duration::from_millis(100), &mut flush)
        .await
        .expect("revocation must interrupt the write without waiting for its original deadline");
    assert!(result.is_err());
    drop(flush);
    assert!(
        writer
            .write_object(&request("health", None, json!({})), deadline())
            .await
            .is_err()
    );
    drop(writer);
    let mut bytes = Vec::new();
    peer.read_to_end(&mut bytes).await.unwrap();
    assert_eq!(
        bytes.len(),
        1,
        "the revoked reply must not finish its frame"
    );
}

#[tokio::test]
async fn control_eof_interrupts_an_owned_sealed_file_transfer_before_slot_reuse() {
    use tokio::io::AsyncReadExt;

    let slot = ControlSlot::new();
    let mut control = connect(&slot).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let payload = vec![0xa5; 2 * 1024 * 1024];
    std::fs::write(source.path().join("large.bin"), &payload).unwrap();
    let resources = GuestResources::new(source.path(), spool.path(), source.path());
    let dispatcher = resources.bind(&control.owner).unwrap();
    let response = exchange(
        &dispatcher,
        &mut control,
        &request(
            "artifact.collect",
            Some(OP),
            json!({"paths": [{"path": "large.bin", "kind": "result"}], "max_total_bytes": payload.len()}),
        ),
    )
    .await;
    let open = collection_open(&response, 0);
    let transfer = dispatcher.open_transfer(&open).await.unwrap();
    let (server, host) = UnixStream::pair().unwrap();
    let serving = tokio::spawn(transfer.serve(server, deadline(), deadline()));
    let (ready, mut host) = read_header(host, deadline()).await.unwrap();
    assert!(matches!(ready, BinaryHeader::Ready(_)));

    drop(control.host_writer);
    assert!(
        control
            .owner
            .read_message(&mut control.reader, deadline())
            .await
            .unwrap()
            .is_none()
    );
    let closing = control.owner.begin_close();
    assert!(slot.reserve().is_err());
    let result = tokio::time::timeout(Duration::from_secs(1), serving)
        .await
        .expect("control EOF must interrupt the backpressured binary writer")
        .unwrap();
    assert!(result.is_err());
    let mut partial = Vec::new();
    tokio::time::timeout(Duration::from_secs(1), host.read_to_end(&mut partial))
        .await
        .unwrap()
        .unwrap();
    assert!(partial.len() < payload.len());
    dispatcher.shutdown().await.unwrap();
    drop(dispatcher);
    drop(control.reader);
    drop(control.writer);
    drop(control.host_reader);
    resources.quiesce().await.unwrap();
    closing.finish().unwrap();
    let replacement = connect(&slot).await;
    assert!(resources.bind(&replacement.owner).is_ok());
}

#[tokio::test]
async fn timeout_diagnostics_remain_errors_and_their_sealed_stdout_is_still_downloadable() {
    let mut control = connect(&ControlSlot::new()).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let resources = GuestResources::new(source.path(), spool.path(), source.path());
    let dispatcher = resources.bind(&control.owner).unwrap();
    let mut command = start(
        source.path(),
        json!(["/bin/sh", "-c", "printf diagnostic; exec sleep 30"]),
        0,
    );
    command["params"]["timeout_seconds"] = json!(0.1);
    exchange(&dispatcher, &mut control, &command).await;
    let response = terminal(&dispatcher, &mut control).await;
    assert_eq!(response["kind"], "error");
    assert_eq!(response["error"]["code"], "EXEC_TIMEOUT");
    assert_eq!(response["error"]["details"]["result"]["timed_out"], true);
    let output = &response["error"]["details"]["result"]["stdout"];
    let open = OpenHeader {
        protocol_version: "gaovm.binary.v1".to_owned(),
        vm_id: VM.to_owned(),
        driver_generation: 8,
        operation_id: OP.to_owned(),
        artifact_id: output["artifact_id"].as_str().unwrap().to_owned(),
        source: BinarySource::ExecOutput {
            output: ExecOutput::Stdout,
        },
    };
    assert_eq!(download(&dispatcher, &open).await.1, b"diagnostic");
}

#[tokio::test]
async fn running_exec_and_collection_dispatch_share_one_capture_budget() {
    use gaovm_guestd::spool::SpoolBudget;

    let mut control = connect(&ControlSlot::new()).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("eight"), b"12345678").unwrap();
    let resources = GuestResources::with_spool_budget(
        source.path(),
        spool.path(),
        source.path(),
        SpoolBudget::new(16 * 1024 * 1024),
    );
    let dispatcher = resources.bind(&control.owner).unwrap();
    let started = exchange(
        &dispatcher,
        &mut control,
        &start(source.path(), json!(["/bin/sh", "-c", "exec sleep 30"]), 0),
    )
    .await;
    assert_eq!(started["result"]["state"], "running");
    let collection = request(
        "artifact.collect",
        Some("op_01J00000000000000000000002"),
        json!({"paths": [{"path": "eight", "kind": "result"}], "max_total_bytes": 8}),
    );
    let rejected = exchange(&dispatcher, &mut control, &collection).await;
    assert_eq!(rejected["kind"], "error");
    assert_eq!(rejected["error"]["code"], "ARTIFACT_LIMIT_EXCEEDED");
    exchange(
        &dispatcher,
        &mut control,
        &request("exec.cancel", Some(OP), json!({})),
    )
    .await;
    assert_eq!(
        terminal(&dispatcher, &mut control).await["result"]["state"],
        "cancelled"
    );
    let accepted = exchange(&dispatcher, &mut control, &collection).await;
    assert_eq!(accepted["result"]["artifacts"][0]["size_bytes"], 8);
    assert_eq!(
        download(&dispatcher, &collection_open(&accepted, 0))
            .await
            .1,
        b"12345678"
    );
}

#[tokio::test]
async fn final_resource_barrier_observes_drop_time_cleanup_failure_before_slot_reuse() {
    use gaovm_guestd::protocol::ErrorCode;

    let slot = ControlSlot::new();
    let mut control = connect(&slot).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("eight"), b"12345678").unwrap();
    let resources = GuestResources::new(source.path(), spool.path(), source.path());
    let dispatcher = resources.bind(&control.owner).unwrap();
    let response = exchange(
        &dispatcher,
        &mut control,
        &request(
            "artifact.collect",
            Some(OP),
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
    std::fs::remove_file(&file).unwrap();
    std::fs::create_dir(&file).unwrap();
    let sentinel = file.join("preserve");
    std::fs::write(&sentinel, b"unconfirmed namespace").unwrap();

    let closing = control.owner.begin_close();
    dispatcher.shutdown().await.unwrap();
    // Retained files are still owned at shutdown's task barrier. Their final
    // cleanup runs on Drop, so the resource owner's final barrier is necessary.
    drop(dispatcher);
    drop(control.reader);
    drop(control.writer);
    drop(control.host_reader);
    drop(control.host_writer);
    assert_eq!(
        resources.quiesce().await.unwrap_err().code,
        ErrorCode::GuestInternalError
    );
    assert_eq!(std::fs::read(&sentinel).unwrap(), b"unconfirmed namespace");
    assert!(slot.reserve().is_err());
    drop(closing);
    assert!(
        slot.reserve().is_err(),
        "unknown cleanup cannot reopen control admission"
    );
}
