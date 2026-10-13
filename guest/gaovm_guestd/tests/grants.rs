#![cfg(unix)]

use gaovm_guestd::artifact::{ArtifactCollector, ArtifactLimits};
use gaovm_guestd::binary::{
    BinaryHeader, BinarySource, CommittedHeader, ExecOutput, OpenHeader, ReadyHeader,
};
use gaovm_guestd::binary_io::{BodyReader, read_header, write_header};
use gaovm_guestd::control::{FrameReader, FrameWriter, negotiate};
use gaovm_guestd::exec::{ExecLimits, Executor, OutputStream};
use gaovm_guestd::grants::GrantRegistry;
use gaovm_guestd::protocol::ErrorCode;
use gaovm_guestd::session::{CORE_CAPABILITIES, ControlEpoch, Role, Session};
use serde_json::{Value, json};
use tokio::io::AsyncReadExt;
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::time::{Duration, Instant, timeout};

const VM: &str = "vm_01J00000000000000000000000";
const OP: &str = "op_01J00000000000000000000001";

struct ControlFixture {
    guest: Session,
    epoch: ControlEpoch,
    host_reader: FrameReader<OwnedReadHalf>,
    guest_writer: FrameWriter<OwnedWriteHalf>,
    _host_writer: FrameWriter<OwnedWriteHalf>,
    _guest_reader: FrameReader<OwnedReadHalf>,
}

async fn control_fixture(vm: &str, generation: u64) -> ControlFixture {
    let (host_socket, guest_socket) = UnixStream::pair().unwrap();
    let (host_read, host_write) = host_socket.into_split();
    let (guest_read, guest_write) = guest_socket.into_split();
    let mut host_reader = FrameReader::new(host_read);
    let mut host_writer = FrameWriter::new(host_write);
    let mut guest_reader = FrameReader::new(guest_read);
    let mut guest_writer = FrameWriter::new(guest_write);
    let mut host = Session::new(
        Role::Host,
        vm,
        generation,
        &CORE_CAPABILITIES,
        &CORE_CAPABILITIES,
    )
    .unwrap();
    let mut guest = Session::new(
        Role::Guest,
        vm,
        generation,
        &CORE_CAPABILITIES,
        &CORE_CAPABILITIES,
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let (host_result, guest_result) = tokio::join!(
        negotiate(&mut host, &mut host_reader, &mut host_writer, deadline),
        negotiate(&mut guest, &mut guest_reader, &mut guest_writer, deadline),
    );
    host_result.unwrap();
    ControlFixture {
        guest,
        epoch: guest_result.unwrap(),
        host_reader,
        guest_writer,
        _host_writer: host_writer,
        _guest_reader: guest_reader,
    }
}

fn collection_request(paths: &[&str]) -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "collect-grant",
        "method": "artifact.collect", "vm_id": VM, "driver_generation": 8, "operation_id": OP,
        "params": {"paths": paths.iter().map(|path| json!({"path": path, "kind": "result"})).collect::<Vec<_>>(),
        "max_total_bytes": 4096}})
}

fn collection_open(response: &Value, index: usize) -> OpenHeader {
    let descriptor = &response["result"]["artifacts"][index];
    OpenHeader {
        protocol_version: "gaovm.binary.v1".to_owned(),
        vm_id: response["vm_id"].as_str().unwrap().to_owned(),
        driver_generation: response["driver_generation"].as_u64().unwrap(),
        operation_id: response["operation_id"].as_str().unwrap().to_owned(),
        artifact_id: descriptor["artifact_id"].as_str().unwrap().to_owned(),
        source: BinarySource::Collection {
            stream_id: descriptor["stream_id"].as_str().unwrap().to_owned(),
        },
    }
}

#[tokio::test]
async fn completed_wire_negotiation_issues_an_epoch_revoked_by_session_drop() {
    let (host_socket, guest_socket) = UnixStream::pair().unwrap();
    let (host_read, host_write) = host_socket.into_split();
    let (guest_read, guest_write) = guest_socket.into_split();
    let mut host_reader = FrameReader::new(host_read);
    let mut host_writer = FrameWriter::new(host_write);
    let mut guest_reader = FrameReader::new(guest_read);
    let mut guest_writer = FrameWriter::new(guest_write);
    let mut host = Session::new(Role::Host, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    let mut guest =
        Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let (host_result, guest_result) = tokio::join!(
        negotiate(&mut host, &mut host_reader, &mut host_writer, deadline),
        negotiate(&mut guest, &mut guest_reader, &mut guest_writer, deadline),
    );
    host_result.unwrap();
    let epoch = guest_result.unwrap();
    assert!(epoch.is_active());
    drop(guest);
    assert!(!epoch.is_active());
    timeout(Duration::from_millis(100), epoch.invalidated())
        .await
        .unwrap();
}

#[tokio::test]
async fn a_collection_grant_is_usable_only_after_its_authorized_response_flushes() {
    let mut control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let reply = registry
        .prepare_collection(
            &control.guest,
            &mut collector,
            &collection_request(&["result"]),
            deadline,
        )
        .await
        .unwrap();
    let open = collection_open(reply.message(), 0);
    let expected = reply.message().clone();
    assert_eq!(
        registry.try_open(&control.epoch, &open).err().unwrap().code,
        ErrorCode::ArtifactNotFound
    );
    let (flushed, received) = tokio::join!(
        reply.flush(&mut control.guest_writer, deadline),
        control.host_reader.read_object(deadline)
    );
    flushed.unwrap();
    assert_eq!(received.unwrap().unwrap(), expected);
    let lease = registry.try_open(&control.epoch, &open).unwrap();
    assert_eq!(
        serde_json::to_value(lease.artifact()).unwrap(),
        expected["result"]["artifacts"][0]
    );
    assert_eq!(lease.artifact().stream_id.len(), 64);
    assert!(
        lease
            .artifact()
            .stream_id
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    );
}

#[tokio::test]
async fn an_invalidated_epoch_cannot_even_write_a_prepared_metadata_response() {
    let control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let reply = registry
        .prepare_collection(
            &control.guest,
            &mut collector,
            &collection_request(&["result"]),
            deadline,
        )
        .await
        .unwrap();
    control.epoch.invalidate();
    let (transport, mut peer) = tokio::io::duplex(4096);
    let mut writer = FrameWriter::new(transport);
    assert!(reply.flush(&mut writer, deadline).await.is_err());
    drop(writer);
    let mut bytes = Vec::new();
    peer.read_to_end(&mut bytes).await.unwrap();
    assert!(bytes.is_empty(), "a revoked epoch published stale metadata");
}

#[tokio::test]
async fn cancelling_a_partial_metadata_flush_revokes_new_and_previously_published_grants() {
    let mut control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let request = collection_request(&["result"]);
    let first = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let old_open = collection_open(first.message(), 0);
    first
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    control
        .host_reader
        .read_object(deadline)
        .await
        .unwrap()
        .unwrap();
    let mut second_request = request;
    second_request["operation_id"] = json!("op_01J00000000000000000000002");
    let second = registry
        .prepare_collection(&control.guest, &mut collector, &second_request, deadline)
        .await
        .unwrap();
    let new_open = collection_open(second.message(), 0);
    let (transport, mut peer) = tokio::io::duplex(1);
    let mut writer = FrameWriter::new(tokio::io::BufWriter::with_capacity(4096, transport));
    let mut pending = Box::pin(second.flush(&mut writer, deadline));
    let mut prefix = [0; 2];
    tokio::select! {
        biased;
        result = peer.read_exact(&mut prefix) => { result.unwrap(); },
        result = &mut pending => panic!("flush completed without a draining peer: {result:?}"),
    }
    assert_eq!(
        registry
            .try_open(&control.epoch, &new_open)
            .err()
            .unwrap()
            .code,
        ErrorCode::ArtifactNotFound
    );
    drop(pending);
    assert!(!control.epoch.is_active());
    assert!(!control.guest.is_ready());
    for open in [old_open, new_open] {
        assert_eq!(
            registry.try_open(&control.epoch, &open).err().unwrap().code,
            ErrorCode::InvalidRequest
        );
    }
    assert_eq!(
        writer
            .write_object(&json!({"kind": "unused"}), deadline)
            .await
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::BrokenPipe
    );
}

#[tokio::test]
async fn equal_vm_and_generation_strings_do_not_authorize_another_control_epoch() {
    let mut control = control_fixture(VM, 8).await;
    let replacement = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let request = collection_request(&["result"]);
    assert_eq!(
        registry
            .prepare_collection(&replacement.guest, &mut collector, &request, deadline)
            .await
            .err()
            .unwrap()
            .code,
        ErrorCode::InvalidRequest
    );
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let open = collection_open(reply.message(), 0);
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    assert_eq!(
        registry
            .try_open(&replacement.epoch, &open)
            .err()
            .unwrap()
            .code,
        ErrorCode::InvalidRequest
    );
    for foreign in [
        OpenHeader {
            vm_id: "vm_01J00000000000000000000001".to_owned(),
            ..open.clone()
        },
        OpenHeader {
            driver_generation: 9,
            ..open.clone()
        },
        OpenHeader {
            operation_id: "op_01J00000000000000000000002".to_owned(),
            ..open.clone()
        },
        OpenHeader {
            artifact_id: "art_01J00000000000000000000002".to_owned(),
            ..open.clone()
        },
        OpenHeader {
            source: BinarySource::Collection {
                stream_id: "0".repeat(64),
            },
            ..open.clone()
        },
    ] {
        assert!(registry.try_open(&control.epoch, &foreign).is_err());
    }
    let lease = registry.try_open(&control.epoch, &open).unwrap();
    control.epoch.invalidate();
    drop(lease);
    assert!(registry.try_open(&control.epoch, &open).is_err());
    assert!(replacement.epoch.is_active());
}

async fn receive_and_ack(stream: UnixStream, deadline: Instant) -> Vec<u8> {
    let (ready, stream, bytes) = receive_body(stream, deadline).await;
    let stream = write_header(
        stream,
        &BinaryHeader::Committed(commit_header(ready)),
        deadline,
    )
    .await
    .unwrap();
    drop(stream);
    bytes
}

async fn receive_body(stream: UnixStream, deadline: Instant) -> (ReadyHeader, UnixStream, Vec<u8>) {
    let (header, stream) = read_header(stream, deadline).await.unwrap();
    let BinaryHeader::Ready(ready) = header else {
        panic!("expected ready");
    };
    let mut reader = BodyReader::new(stream, &ready.artifact, deadline).unwrap();
    let mut bytes = Vec::new();
    while let Some(chunk) = reader.read_chunk().await.unwrap() {
        bytes.extend(chunk);
    }
    let stream = reader.finish().unwrap();
    (ready, stream, bytes)
}

fn commit_header(ready: ReadyHeader) -> CommittedHeader {
    CommittedHeader {
        protocol_version: "gaovm.binary.v1".to_owned(),
        vm_id: ready.vm_id,
        driver_generation: ready.driver_generation,
        operation_id: ready.operation_id,
        artifact_id: ready.artifact.artifact_id,
        stream_id: ready.artifact.stream_id,
        size_bytes: ready.artifact.size_bytes,
        digest: ready.artifact.digest,
    }
}

#[tokio::test]
async fn a_matching_commit_ack_retires_only_its_grant_not_the_sibling_spools() {
    let mut control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("first"), b"first sealed bytes").unwrap();
    std::fs::write(source.path().join("second"), b"second sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let request = collection_request(&["first", "second"]);
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let first = collection_open(reply.message(), 0);
    let second = collection_open(reply.message(), 1);
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    let lease = registry.try_open(&control.epoch, &first).unwrap();
    let file = collector
        .open_artifact(&control.guest, &request, &first.artifact_id)
        .unwrap()
        .into_inner();
    let (guest, host) = UnixStream::pair().unwrap();
    let (sent, bytes) = tokio::join!(
        lease.serve(guest, file.into_async(), deadline, deadline),
        receive_and_ack(host, deadline)
    );
    let completed = sent.unwrap();
    assert_eq!(completed.artifact_id(), first.artifact_id);
    assert_eq!(bytes, b"first sealed bytes");
    assert_eq!(
        registry
            .try_open(&control.epoch, &first)
            .err()
            .unwrap()
            .code,
        ErrorCode::ArtifactNotFound
    );
    assert!(registry.try_open(&control.epoch, &second).is_ok());
    for open in [first, second] {
        let mut bytes = Vec::new();
        std::io::Read::read_to_end(
            &mut collector
                .open_artifact(&control.guest, &request, &open.artifact_id)
                .unwrap(),
            &mut bytes,
        )
        .unwrap();
        assert!(!bytes.is_empty(), "a transfer retired an entire collection");
    }
}

#[tokio::test]
async fn a_retired_grant_requires_a_fresh_flushed_metadata_response_to_be_reissued() {
    let mut control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let request = collection_request(&["result"]);
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let original = collection_open(reply.message(), 0);
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    let lease = registry.try_open(&control.epoch, &original).unwrap();
    let file = collector
        .open_artifact(&control.guest, &request, &original.artifact_id)
        .unwrap()
        .into_inner();
    let (guest, host) = UnixStream::pair().unwrap();
    let (sent, _) = tokio::join!(
        lease.serve(guest, file.into_async(), deadline, deadline),
        receive_and_ack(host, deadline)
    );
    sent.unwrap();
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let renewed = collection_open(reply.message(), 0);
    assert_eq!(renewed.artifact_id, original.artifact_id);
    assert_ne!(renewed.source, original.source);
    assert!(registry.try_open(&control.epoch, &renewed).is_err());
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    assert!(registry.try_open(&control.epoch, &original).is_err());
    assert!(registry.try_open(&control.epoch, &renewed).is_ok());
}

fn exec_request(method: &str) -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "exec-grant",
        "method": method, "vm_id": VM, "driver_generation": 8, "operation_id": OP, "params": {}})
}

fn exec_start(command: &str) -> Value {
    let mut request = exec_request("exec.start");
    request["params"] = json!({"argv": ["/bin/sh", "-c", command], "cwd": "/", "env": {},
        "timeout_seconds": 3, "capture": {"stdout": true, "stderr": true, "max_inline_bytes": 0}});
    request
}

fn exec_open(artifact_id: &str, output: ExecOutput) -> OpenHeader {
    OpenHeader {
        protocol_version: "gaovm.binary.v1".to_owned(),
        vm_id: VM.to_owned(),
        driver_generation: 8,
        operation_id: OP.to_owned(),
        artifact_id: artifact_id.to_owned(),
        source: BinarySource::ExecOutput { output },
    }
}

#[tokio::test]
async fn only_a_flushed_terminal_exec_status_grants_the_exact_spilled_output() {
    let mut control = control_fixture(VM, 8).await;
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let start = exec_start("printf 'hello world'; printf err >&2; exit 7");
    assert_eq!(
        registry
            .prepare_exec_status(&control.guest, &mut executor, &start, deadline)
            .await
            .err()
            .unwrap()
            .code,
        ErrorCode::InvalidRequest
    );
    executor.handle(&control.guest, &start).unwrap();
    let status = exec_request("exec.status");
    timeout(
        Duration::from_secs(4),
        executor.wait(&control.guest, &status),
    )
    .await
    .unwrap()
    .unwrap();
    let original = executor.handle(&control.guest, &status).unwrap();
    let stdout_id = original["result"]["stdout"]["artifact_id"]
        .as_str()
        .unwrap();
    let stderr_id = original["result"]["stderr"]["artifact_id"]
        .as_str()
        .unwrap();
    let stdout = exec_open(stdout_id, ExecOutput::Stdout);
    let stderr = exec_open(stderr_id, ExecOutput::Stderr);
    assert!(registry.try_open(&control.epoch, &stdout).is_err());
    let reply = registry
        .prepare_exec_status(&control.guest, &mut executor, &status, deadline)
        .await
        .unwrap();
    assert_eq!(
        reply.message(),
        &original,
        "grants changed the frozen exec result"
    );
    assert!(registry.try_open(&control.epoch, &stdout).is_err());
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    assert!(
        registry
            .try_open(
                &control.epoch,
                &OpenHeader {
                    source: BinarySource::ExecOutput {
                        output: ExecOutput::Stderr
                    },
                    ..stdout.clone()
                }
            )
            .is_err()
    );
    let lease = registry.try_open(&control.epoch, &stdout).unwrap();
    assert_eq!(lease.artifact().size_bytes, 11);
    assert_eq!(
        lease.artifact().digest,
        "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    );
    let file = executor
        .open_output(&control.guest, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap()
        .into_inner();
    let (guest, host) = UnixStream::pair().unwrap();
    let (sent, bytes) = tokio::join!(
        lease.serve(guest, file.into_async(), deadline, deadline),
        receive_and_ack(host, deadline)
    );
    sent.unwrap();
    assert_eq!(bytes, b"hello world");
    assert!(registry.try_open(&control.epoch, &stdout).is_err());
    assert!(registry.try_open(&control.epoch, &stderr).is_ok());
    assert!(
        executor
            .open_output(&control.guest, &status, OutputStream::Stderr)
            .unwrap()
            .is_some()
    );
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn expired_active_readers_keep_their_slots_until_closed_and_cannot_be_reissued() {
    let mut control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    for path in ["first", "second", "third"] {
        std::fs::write(source.path().join(path), b"sealed bytes").unwrap();
    }
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let expires = Instant::now() + Duration::from_secs(1);
    let request = collection_request(&["first", "second", "third"]);
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, expires)
        .await
        .unwrap();
    let first = collection_open(reply.message(), 0);
    let second = collection_open(reply.message(), 1);
    let third = collection_open(reply.message(), 2);
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    let first_lease = registry.try_open(&control.epoch, &first).unwrap();
    assert!(
        registry.try_open(&control.epoch, &first).is_err(),
        "a grant admitted a second reader"
    );
    let second_lease = registry.try_open(&control.epoch, &second).unwrap();
    assert_eq!(
        registry
            .try_open(&control.epoch, &third)
            .err()
            .unwrap()
            .code,
        ErrorCode::ArtifactLimitExceeded
    );
    tokio::time::sleep_until(expires).await;
    assert_eq!(
        registry
            .prepare_collection(&control.guest, &mut collector, &request, deadline)
            .await
            .err()
            .unwrap()
            .code,
        ErrorCode::ArtifactLimitExceeded
    );
    let mut next = collection_request(&["third"]);
    next["operation_id"] = json!("op_01J00000000000000000000002");
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &next, deadline)
        .await
        .unwrap();
    let fresh = collection_open(reply.message(), 0);
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    assert_eq!(
        registry
            .try_open(&control.epoch, &fresh)
            .err()
            .unwrap()
            .code,
        ErrorCode::ArtifactLimitExceeded
    );
    drop(first_lease);
    let fresh_lease = registry.try_open(&control.epoch, &fresh).unwrap();
    drop(second_lease);
    assert!(
        registry.try_open(&control.epoch, &fresh).is_err(),
        "an old drop released another reader's lease"
    );
    drop(fresh_lease);
    assert!(registry.try_open(&control.epoch, &fresh).is_ok());
}

#[tokio::test]
async fn an_epoch_cannot_create_independent_registries_to_bypass_transfer_limits() {
    let control = control_fixture(VM, 8).await;
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let sibling = registry.clone();
    assert_eq!(
        GrantRegistry::new(control.epoch.clone())
            .err()
            .unwrap()
            .code,
        ErrorCode::InvalidRequest
    );
    drop(registry);
    drop(sibling);
    assert!(
        GrantRegistry::new(control.epoch.clone()).is_err(),
        "dropping a registry reopened admission in the same epoch"
    );
    let next = control_fixture(VM, 8).await;
    assert!(GrantRegistry::new(next.epoch).is_ok());
}

#[tokio::test]
async fn every_commit_binding_field_must_match_before_retirement_and_retry_starts_at_zero() {
    let mut control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let request = collection_request(&["result"]);
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let open = collection_open(reply.message(), 0);
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    for field in [
        "vm",
        "generation",
        "operation",
        "artifact",
        "stream",
        "size",
        "digest",
        "missing",
    ] {
        let lease = registry.try_open(&control.epoch, &open).unwrap();
        let file = collector
            .open_artifact(&control.guest, &request, &open.artifact_id)
            .unwrap()
            .into_inner();
        let (guest, host) = UnixStream::pair().unwrap();
        let peer = async {
            let (ready, stream, bytes) = receive_body(host, deadline).await;
            assert_eq!(bytes, b"sealed bytes");
            let mut ack = commit_header(ready);
            match field {
                "vm" => ack.vm_id = "vm_01J00000000000000000000001".to_owned(),
                "generation" => ack.driver_generation += 1,
                "operation" => ack.operation_id = "op_01J00000000000000000000002".to_owned(),
                "artifact" => ack.artifact_id = "art_01J00000000000000000000002".to_owned(),
                "stream" => ack.stream_id.replace_range(
                    0..1,
                    if ack.stream_id.starts_with('0') {
                        "1"
                    } else {
                        "0"
                    },
                ),
                "size" => ack.size_bytes += 1,
                "digest" => ack.digest.replace_range(
                    7..8,
                    if ack.digest.as_bytes()[7] == b'0' {
                        "1"
                    } else {
                        "0"
                    },
                ),
                "missing" => {
                    drop(stream);
                    return;
                }
                _ => unreachable!(),
            }
            drop(
                write_header(stream, &BinaryHeader::Committed(ack), deadline)
                    .await
                    .unwrap(),
            );
        };
        let (result, ()) = tokio::join!(
            lease.serve(guest, file.into_async(), deadline, deadline),
            peer
        );
        let error = result
            .err()
            .expect("a mismatched/missing ACK retired a grant");
        assert_eq!(
            error.kind(),
            if field == "missing" {
                std::io::ErrorKind::UnexpectedEof
            } else {
                std::io::ErrorKind::InvalidData
            }
        );
        assert!(control.epoch.is_active());
    }
    assert!(registry.try_open(&control.epoch, &open).is_ok());
}

#[tokio::test]
async fn revocation_aborts_owned_binary_io_while_control_health_remains_responsive() {
    let mut control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    let reply = registry
        .prepare_collection(
            &control.guest,
            &mut collector,
            &collection_request(&["result"]),
            deadline,
        )
        .await
        .unwrap();
    let open = collection_open(reply.message(), 0);
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    control
        .host_reader
        .read_object(deadline)
        .await
        .unwrap()
        .unwrap();
    let lease = registry.try_open(&control.epoch, &open).unwrap();
    let (guest, host) = UnixStream::pair().unwrap();
    let (stalled_source, _source_owner) = tokio::io::duplex(1);
    let serving = tokio::spawn(lease.serve(guest, stalled_source, deadline, deadline));
    let (ready, mut host) = read_header(host, deadline).await.unwrap();
    assert!(matches!(ready, BinaryHeader::Ready(_)));
    let queries = gaovm_guestd::system::SystemQueries::new(VM, 8, source.path()).unwrap();
    let health = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "health-during-transfer",
        "method": "health", "vm_id": VM, "driver_generation": 8, "operation_id": null, "params": {}});
    let response = queries.handle(&control.guest, &health).unwrap();
    control
        .guest_writer
        .write_object(&response, deadline)
        .await
        .unwrap();
    assert_eq!(
        control
            .host_reader
            .read_object(deadline)
            .await
            .unwrap()
            .unwrap(),
        response
    );
    control.epoch.invalidate();
    assert!(
        registry.try_open(&control.epoch, &open).is_err(),
        "invalidation did not fence admission first"
    );
    assert_eq!(
        timeout(Duration::from_secs(1), serving)
            .await
            .unwrap()
            .unwrap()
            .err()
            .unwrap()
            .kind(),
        std::io::ErrorKind::ConnectionAborted
    );
    let mut bytes = Vec::new();
    timeout(Duration::from_secs(1), host.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    assert!(
        bytes.is_empty(),
        "the revoked transfer kept emitting a body"
    );
}

#[tokio::test]
async fn body_and_ack_waits_obey_the_outer_deadline_and_release_retry_capacity() {
    let mut control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let request = collection_request(&["result"]);
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let open = collection_open(reply.message(), 0);
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();

    let lease = registry.try_open(&control.epoch, &open).unwrap();
    let (guest, host) = UnixStream::pair().unwrap();
    let (stalled_source, _source_owner) = tokio::io::duplex(1);
    let serving = tokio::spawn(lease.serve(
        guest,
        stalled_source,
        deadline,
        Instant::now() + Duration::from_millis(150),
    ));
    let (_, mut host) = read_header(host, deadline).await.unwrap();
    assert_eq!(
        serving.await.unwrap().err().unwrap().kind(),
        std::io::ErrorKind::TimedOut
    );
    let mut bytes = Vec::new();
    timeout(Duration::from_secs(1), host.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    assert!(bytes.is_empty());

    let lease = registry.try_open(&control.epoch, &open).unwrap();
    let file = collector
        .open_artifact(&control.guest, &request, &open.artifact_id)
        .unwrap()
        .into_inner();
    let (guest, host) = UnixStream::pair().unwrap();
    let serving = tokio::spawn(lease.serve(
        guest,
        file.into_async(),
        deadline,
        Instant::now() + Duration::from_millis(250),
    ));
    let (_, mut host, bytes) = receive_body(host, deadline).await;
    assert_eq!(bytes, b"sealed bytes");
    assert_eq!(
        serving.await.unwrap().err().unwrap().kind(),
        std::io::ErrorKind::TimedOut
    );
    let mut remainder = Vec::new();
    timeout(Duration::from_secs(1), host.read_to_end(&mut remainder))
        .await
        .unwrap()
        .unwrap();
    assert!(remainder.is_empty());
    assert!(registry.try_open(&control.epoch, &open).is_ok());
    assert!(control.epoch.is_active());
}

#[tokio::test]
async fn cancelling_only_the_binary_future_closes_it_and_preserves_the_current_grant() {
    let mut control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let request = collection_request(&["result"]);
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let open = collection_open(reply.message(), 0);
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    let lease = registry.try_open(&control.epoch, &open).unwrap();
    let original = lease.artifact().clone();
    let (guest, host) = UnixStream::pair().unwrap();
    let (stalled_source, _source_owner) = tokio::io::duplex(1);
    let serving = tokio::spawn(lease.serve(guest, stalled_source, deadline, deadline));
    let (_, mut host) = read_header(host, deadline).await.unwrap();
    serving.abort();
    assert!(serving.await.err().unwrap().is_cancelled());
    let mut bytes = Vec::new();
    timeout(Duration::from_secs(1), host.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    assert!(bytes.is_empty());
    assert!(control.epoch.is_active());
    let lease = registry.try_open(&control.epoch, &open).unwrap();
    assert_eq!(lease.artifact(), &original);
    let file = collector
        .open_artifact(&control.guest, &request, &open.artifact_id)
        .unwrap()
        .into_inner();
    let (guest, host) = UnixStream::pair().unwrap();
    let (sent, bytes) = tokio::join!(
        lease.serve(guest, file.into_async(), deadline, deadline),
        receive_and_ack(host, deadline)
    );
    sent.unwrap();
    assert_eq!(bytes, b"sealed bytes");
}

#[tokio::test]
async fn running_and_inline_exec_statuses_do_not_invent_binary_grants() {
    let mut control = control_fixture(VM, 8).await;
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    executor
        .start(&control.guest, &exec_start("exec /bin/sleep 30"))
        .unwrap();
    let status = exec_request("exec.status");
    let reply = registry
        .prepare_exec_status(&control.guest, &mut executor, &status, deadline)
        .await
        .unwrap();
    assert_eq!(reply.message()["result"]["state"], "running");
    assert_eq!(reply.message()["result"]["stdout"]["mode"], "inline");
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    assert!(
        registry
            .try_open(
                &control.epoch,
                &exec_open("art_01J00000000000000000000002", ExecOutput::Stdout)
            )
            .is_err()
    );
    let cancel = exec_request("exec.cancel");
    assert_eq!(
        registry
            .prepare_exec_status(&control.guest, &mut executor, &cancel, deadline)
            .await
            .err()
            .unwrap()
            .code,
        ErrorCode::InvalidRequest
    );
    executor.cancel(&control.guest, &cancel).unwrap();
    timeout(
        Duration::from_secs(3),
        executor.wait(&control.guest, &status),
    )
    .await
    .unwrap()
    .unwrap();

    let mut start = exec_start("printf abc");
    start["operation_id"] = json!("op_01J00000000000000000000002");
    start["params"]["capture"]["max_inline_bytes"] = json!(1024);
    executor.start(&control.guest, &start).unwrap();
    let mut status = status;
    status["operation_id"] = start["operation_id"].clone();
    timeout(
        Duration::from_secs(3),
        executor.wait(&control.guest, &status),
    )
    .await
    .unwrap()
    .unwrap();
    let reply = registry
        .prepare_exec_status(&control.guest, &mut executor, &status, deadline)
        .await
        .unwrap();
    assert_eq!(reply.message()["result"]["stdout"]["mode"], "inline");
    assert_eq!(reply.message()["result"]["stdout"]["text"], "abc");
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    let open = OpenHeader {
        operation_id: status["operation_id"].as_str().unwrap().to_owned(),
        ..exec_open("art_01J00000000000000000000002", ExecOutput::Stdout)
    };
    assert!(registry.try_open(&control.epoch, &open).is_err());
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn terminal_exec_error_details_keep_diagnostic_grants_without_turning_into_success() {
    let mut control = control_fixture(VM, 8).await;
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(
        VM,
        8,
        spool.path(),
        ExecLimits {
            max_output_bytes: 4,
            ..ExecLimits::default()
        },
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    executor
        .start(&control.guest, &exec_start("printf 'hello world'"))
        .unwrap();
    let status = exec_request("exec.status");
    timeout(
        Duration::from_secs(3),
        executor.wait(&control.guest, &status),
    )
    .await
    .unwrap()
    .unwrap();
    let reply = registry
        .prepare_exec_status(&control.guest, &mut executor, &status, deadline)
        .await
        .unwrap();
    assert_eq!(reply.message()["kind"], "error");
    assert_eq!(reply.message()["error"]["code"], "OUTPUT_LIMIT_EXCEEDED");
    let artifact_id = reply.message()["error"]["details"]["result"]["stdout"]["artifact_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let open = exec_open(&artifact_id, ExecOutput::Stdout);
    assert!(registry.try_open(&control.epoch, &open).is_err());
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    let lease = registry.try_open(&control.epoch, &open).unwrap();
    assert_eq!(lease.artifact().size_bytes, 4);
    let file = executor
        .open_output(&control.guest, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap()
        .into_inner();
    let (guest, host) = UnixStream::pair().unwrap();
    let (sent, bytes) = tokio::join!(
        lease.serve(guest, file.into_async(), deadline, deadline),
        receive_and_ack(host, deadline)
    );
    sent.unwrap();
    assert_eq!(bytes, b"hell");
    assert_eq!(
        executor.handle(&control.guest, &status).unwrap()["error"]["code"],
        "OUTPUT_LIMIT_EXCEEDED"
    );
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn an_unwritten_reply_rolls_back_only_its_reservation_but_a_write_failure_revokes_the_epoch()
{
    let control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let request = collection_request(&["result"]);
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let original = reply.message()["result"]["artifacts"][0].clone();
    let old_open = collection_open(reply.message(), 0);
    assert!(
        registry
            .prepare_collection(&control.guest, &mut collector, &request, deadline)
            .await
            .is_err(),
        "a second reply replaced an unpublished reservation"
    );
    drop(reply);
    assert!(control.epoch.is_active());
    assert!(registry.try_open(&control.epoch, &old_open).is_err());
    std::fs::write(
        source.path().join("result"),
        b"a new source must not replace the sealed capture",
    )
    .unwrap();
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let descriptor = &reply.message()["result"]["artifacts"][0];
    for field in [
        "artifact_id",
        "kind",
        "content_type",
        "size_bytes",
        "digest",
    ] {
        assert_eq!(descriptor[field], original[field]);
    }
    assert_ne!(descriptor["stream_id"], original["stream_id"]);
    let open = collection_open(reply.message(), 0);
    let (transport, peer) = tokio::io::duplex(1);
    drop(peer);
    let mut writer = FrameWriter::new(transport);
    assert_eq!(
        reply.flush(&mut writer, deadline).await.unwrap_err().kind(),
        std::io::ErrorKind::BrokenPipe
    );
    assert!(!control.epoch.is_active());
    assert!(registry.try_open(&control.epoch, &open).is_err());
}

#[tokio::test]
async fn a_metadata_replay_cannot_extend_the_lifetime_of_an_existing_grant() {
    let mut control = control_fixture(VM, 8).await;
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let registry = GrantRegistry::new(control.epoch.clone()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let expires = Instant::now() + Duration::from_secs(1);
    let request = collection_request(&["result"]);
    let reply = registry
        .prepare_collection(&control.guest, &mut collector, &request, expires)
        .await
        .unwrap();
    let original = collection_open(reply.message(), 0);
    reply
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    let replay = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    assert_eq!(collection_open(replay.message(), 0), original);
    tokio::time::sleep_until(expires).await;
    let (transport, mut peer) = tokio::io::duplex(4096);
    let mut writer = FrameWriter::new(transport);
    assert!(
        replay.flush(&mut writer, deadline).await.is_err(),
        "a replay published an expired grant as usable"
    );
    drop(writer);
    let mut bytes = Vec::new();
    peer.read_to_end(&mut bytes).await.unwrap();
    assert!(bytes.is_empty());
    assert!(control.epoch.is_active());
    let renewed = registry
        .prepare_collection(&control.guest, &mut collector, &request, deadline)
        .await
        .unwrap();
    let fresh = collection_open(renewed.message(), 0);
    assert_eq!(fresh.artifact_id, original.artifact_id);
    assert_ne!(fresh.source, original.source);
    renewed
        .flush(&mut control.guest_writer, deadline)
        .await
        .unwrap();
    assert!(registry.try_open(&control.epoch, &fresh).is_ok());
}
