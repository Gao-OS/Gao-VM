#![cfg(unix)]

use gaovm_guestd::artifact::{ArtifactCollector, ArtifactLimits};
use gaovm_guestd::binary::{BinaryHeader, BinarySource, OpenHeader};
use gaovm_guestd::binary_io::read_header;
use gaovm_guestd::control::{FrameReader, FrameWriter};
use gaovm_guestd::grants::GrantRegistry;
use gaovm_guestd::guest_connection::{ActiveControl, ControlSlot};
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use serde_json::{Value, json};
use std::io::ErrorKind;
use std::pin::Pin;
use std::task::{Context, Poll};
use tokio::io::AsyncWriteExt;
use tokio::io::{AsyncReadExt, AsyncWrite};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::time::{Duration, Instant};

const VM: &str = "vm_01J00000000000000000000009";
const GENERATION: u64 = 31;

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(3)
}

fn health() -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "bound-health",
        "method": "health", "vm_id": VM, "driver_generation": GENERATION, "operation_id": null, "params": {}})
}

#[tokio::test]
async fn generic_guest_adopts_the_host_binding_and_flushes_its_ack_before_its_own_hello() {
    let slot = ControlSlot::new();
    let opening = slot.reserve().unwrap();
    assert!(
        slot.reserve().is_err(),
        "two connections reserved the first binding"
    );
    let (host, guest) = UnixStream::pair().unwrap();
    let (host_read, host_write) = host.into_split();
    let (guest_read, guest_write) = guest.into_split();
    let mut host_reader = FrameReader::new(host_read);
    let mut host_writer = FrameWriter::new(host_write);
    let mut guest_reader = FrameReader::new(guest_read);
    let mut guest_writer = FrameWriter::new(guest_write);
    let limit = deadline();
    let host = async {
        let mut session = Session::new(
            Role::Host,
            VM,
            GENERATION,
            &CORE_CAPABILITIES,
            &CORE_CAPABILITIES,
        )
        .unwrap();
        let hello = session.hello().unwrap();
        host_writer.write_object(&hello, limit).await.unwrap();
        let ack = host_reader.read_object(limit).await.unwrap().unwrap();
        assert_eq!(ack["kind"], "response");
        assert_eq!(ack["id"], hello["id"]);
        assert_eq!(ack["vm_id"], VM);
        assert_eq!(ack["driver_generation"], GENERATION);
        assert!(session.receive_hello(&ack).unwrap().is_none());
        let guest_hello = host_reader.read_object(limit).await.unwrap().unwrap();
        assert_eq!(guest_hello["kind"], "request");
        assert_eq!(guest_hello["params"]["peer_role"], "guest");
        assert_eq!(guest_hello["vm_id"], VM);
        assert_eq!(guest_hello["driver_generation"], GENERATION);
        let ack = session.receive_hello(&guest_hello).unwrap().unwrap();
        host_writer.write_object(&ack, limit).await.unwrap();
        assert!(session.is_ready());
    };
    let (guest, ()) = tokio::join!(
        opening.bootstrap(
            &mut guest_reader,
            &mut guest_writer,
            &CORE_CAPABILITIES,
            &CORE_CAPABILITIES,
            limit
        ),
        host
    );
    let guest = guest.unwrap();
    assert_eq!(guest.epoch().vm_id(), VM);
    assert_eq!(guest.epoch().driver_generation(), GENERATION);
    assert!(guest.epoch().is_active());
    guest.session().authorize_request(&health()).unwrap();
    assert!(
        slot.reserve().is_err(),
        "an active session permitted rebinding"
    );
    guest.begin_close().finish().unwrap();
    assert!(slot.reserve().is_ok());
}

#[tokio::test]
async fn duplicate_or_escaped_duplicate_binding_keys_cannot_be_normalized_into_a_valid_first_hello()
{
    for key in ["vm_id", "vm\\u005fid", "driver_generation", "params"] {
        let slot = ControlSlot::new();
        let opening = slot.reserve().unwrap();
        let (mut host, guest) = UnixStream::pair().unwrap();
        let (guest_read, guest_write) = guest.into_split();
        let mut reader = FrameReader::new(guest_read);
        let mut writer = FrameWriter::new(guest_write);
        let mut host_session = Session::new(
            Role::Host,
            VM,
            GENERATION,
            &CORE_CAPABILITIES,
            &CORE_CAPABILITIES,
        )
        .unwrap();
        let hello = host_session.hello().unwrap();
        let value = match key {
            "driver_generation" => json!(GENERATION),
            "params" => hello["params"].clone(),
            _ => json!(VM),
        };
        let original = serde_json::to_string(&hello).unwrap();
        let duplicated = format!("{},\"{key}\":{value}}}", &original[..original.len() - 1]);
        let ack = json!({"protocol_version": "gaovm.guest.v1", "kind": "response", "id": "guest-hello",
            "method": "session.hello", "vm_id": VM, "driver_generation": GENERATION, "operation_id": null,
            "result": {"accepted_capabilities": CORE_CAPABILITIES}});
        let send = async {
            host.write_all(&(duplicated.len() as u32).to_be_bytes())
                .await
                .unwrap();
            host.write_all(duplicated.as_bytes()).await.unwrap();
            FrameWriter::new(&mut host)
                .write_object(&ack, deadline())
                .await
                .unwrap();
        };
        let (result, ()) = tokio::join!(
            opening.bootstrap(
                &mut reader,
                &mut writer,
                &CORE_CAPABILITIES,
                &CORE_CAPABILITIES,
                deadline()
            ),
            send
        );
        assert!(
            result.is_err(),
            "duplicate {key} established a control binding"
        );
        assert!(slot.reserve().is_ok());
    }
}

struct ControlFixture {
    owner: ActiveControl,
    reader: FrameReader<OwnedReadHalf>,
    _writer: FrameWriter<OwnedWriteHalf>,
    peer: UnixStream,
}

async fn connect(slot: &ControlSlot) -> ControlFixture {
    let opening = slot.reserve().unwrap();
    let (mut peer, guest) = UnixStream::pair().unwrap();
    let (read, write) = guest.into_split();
    let mut reader = FrameReader::new(read);
    let mut writer = FrameWriter::new(write);
    let limit = deadline();
    let handshake = async {
        let mut host = Session::new(
            Role::Host,
            VM,
            GENERATION,
            &CORE_CAPABILITIES,
            &CORE_CAPABILITIES,
        )
        .unwrap();
        FrameWriter::new(&mut peer)
            .write_object(&host.hello().unwrap(), limit)
            .await
            .unwrap();
        let ack = FrameReader::new(&mut peer)
            .read_object(limit)
            .await
            .unwrap()
            .unwrap();
        assert!(host.receive_hello(&ack).unwrap().is_none());
        let hello = FrameReader::new(&mut peer)
            .read_object(limit)
            .await
            .unwrap()
            .unwrap();
        let ack = host.receive_hello(&hello).unwrap().unwrap();
        FrameWriter::new(&mut peer)
            .write_object(&ack, limit)
            .await
            .unwrap();
        peer
    };
    let (owner, peer) = tokio::join!(
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
        _writer: writer,
        peer,
    }
}

#[tokio::test]
async fn eof_fences_the_epoch_before_return_and_keeps_replacement_closed_until_cleanup() {
    let slot = ControlSlot::new();
    let ControlFixture {
        owner,
        mut reader,
        _writer,
        peer,
    } = connect(&slot).await;
    let epoch = owner.epoch().clone();
    drop(peer);
    assert!(
        owner
            .read_message(&mut reader, deadline())
            .await
            .unwrap()
            .is_none()
    );
    assert!(
        !epoch.is_active(),
        "EOF returned while old grants remained authorized"
    );
    assert!(owner.session().authorize_request(&health()).is_err());
    assert!(
        slot.reserve().is_err(),
        "EOF reopened before owned cleanup completed"
    );
    let closing = owner.begin_close();
    assert!(slot.reserve().is_err());
    closing.finish().unwrap();
    let replacement = connect(&slot).await;
    epoch.invalidate();
    assert!(
        replacement.owner.epoch().is_active(),
        "old-epoch callback fenced same-binding replacement"
    );
    replacement
        .owner
        .session()
        .authorize_request(&health())
        .unwrap();
    assert!(slot.reserve().is_err());
    replacement.owner.begin_close().finish().unwrap();
}

#[tokio::test]
async fn malformed_frame_and_read_deadline_fence_before_the_error_is_observed() {
    for malformed in [true, false] {
        let slot = ControlSlot::new();
        let mut control = connect(&slot).await;
        let epoch = control.owner.epoch().clone();
        let limit = if malformed {
            control.peer.write_all(&[0; 4]).await.unwrap();
            deadline()
        } else {
            Instant::now() + Duration::from_millis(20)
        };
        let error = control
            .owner
            .read_message(&mut control.reader, limit)
            .await
            .unwrap_err();
        assert_eq!(
            error.kind(),
            if malformed {
                ErrorKind::InvalidData
            } else {
                ErrorKind::TimedOut
            }
        );
        assert!(!epoch.is_active());
        assert!(slot.reserve().is_err());
        control.owner.begin_close().finish().unwrap();
        assert!(slot.reserve().is_ok());
    }
}

#[tokio::test]
async fn invalidation_wakes_a_pending_control_read_without_another_frame_or_deadline() {
    let slot = ControlSlot::new();
    let mut control = connect(&slot).await;
    let epoch = control.owner.epoch().clone();
    let read = control.owner.read_message(&mut control.reader, deadline());
    let revoke = async {
        tokio::task::yield_now().await;
        epoch.invalidate();
    };
    let (result, ()) = tokio::time::timeout(Duration::from_millis(100), async {
        tokio::join!(read, revoke)
    })
    .await
    .unwrap();
    assert_eq!(result.unwrap_err().kind(), ErrorKind::ConnectionAborted);
    assert!(slot.reserve().is_err());
    control.owner.begin_close().finish().unwrap();
}

#[tokio::test]
async fn dropping_active_or_cleanup_ownership_never_implicitly_reopens_the_slot() {
    for begin_cleanup in [true, false] {
        let slot = ControlSlot::new();
        let control = connect(&slot).await;
        let epoch = control.owner.epoch().clone();
        if begin_cleanup {
            drop(control.owner.begin_close());
        } else {
            drop(control.owner);
        }
        assert!(!epoch.is_active());
        assert!(
            slot.reserve().is_err(),
            "abandoned ownership silently allowed rebinding"
        );
    }
}

#[tokio::test]
async fn stale_application_input_is_rejected_without_rebinding_or_fencing_the_healthy_owner() {
    let slot = ControlSlot::new();
    let mut control = connect(&slot).await;
    let mut stale = health();
    stale["driver_generation"] = json!(GENERATION - 1);
    FrameWriter::new(&mut control.peer)
        .write_object(&stale, deadline())
        .await
        .unwrap();
    let received = control
        .owner
        .read_message(&mut control.reader, deadline())
        .await
        .unwrap()
        .unwrap();
    assert!(
        control
            .owner
            .session()
            .authorize_request(&received)
            .is_err()
    );
    assert!(control.owner.epoch().is_active());
    FrameWriter::new(&mut control.peer)
        .write_object(&health(), deadline())
        .await
        .unwrap();
    let received = control
        .owner
        .read_message(&mut control.reader, deadline())
        .await
        .unwrap()
        .unwrap();
    control
        .owner
        .session()
        .authorize_request(&received)
        .unwrap();
    assert!(slot.reserve().is_err());
    control.owner.begin_close().finish().unwrap();
}

#[tokio::test]
async fn invalid_first_hello_never_outputs_a_binding_or_echo_and_poisoned_io_cannot_resume() {
    let mut host = Session::new(
        Role::Host,
        VM,
        GENERATION,
        &CORE_CAPABILITIES,
        &CORE_CAPABILITIES,
    )
    .unwrap();
    let first_hello = host.hello().unwrap();
    let mut variants = Vec::new();
    for (field, value) in [
        ("vm_id", json!("not-a-vm")),
        ("driver_generation", json!(0)),
        ("protocol_version", json!("gaovm.guest.v0")),
        ("operation_id", json!("op_01J00000000000000000000009")),
    ] {
        let mut hello = first_hello.clone();
        hello[field] = value;
        variants.push(hello);
    }
    let mut wrong_role = first_hello;
    wrong_role["params"]["peer_role"] = json!("guest");
    variants.push(wrong_role);
    variants.push(health());
    for first in variants {
        let slot = ControlSlot::new();
        let opening = slot.reserve().unwrap();
        let (mut peer, guest) = UnixStream::pair().unwrap();
        let (read, write) = guest.into_split();
        let mut reader = FrameReader::new(read);
        let mut writer = FrameWriter::new(write);
        FrameWriter::new(&mut peer)
            .write_object(&first, deadline())
            .await
            .unwrap();
        assert!(
            opening
                .bootstrap(
                    &mut reader,
                    &mut writer,
                    &CORE_CAPABILITIES,
                    &CORE_CAPABILITIES,
                    deadline()
                )
                .await
                .is_err()
        );
        assert_eq!(
            reader.read_object(deadline()).await.unwrap_err().kind(),
            ErrorKind::BrokenPipe
        );
        assert_eq!(
            writer
                .write_object(&health(), deadline())
                .await
                .unwrap_err()
                .kind(),
            ErrorKind::BrokenPipe
        );
        drop(reader);
        drop(writer);
        let mut output = Vec::new();
        peer.read_to_end(&mut output).await.unwrap();
        assert!(
            output.is_empty(),
            "invalid first hello emitted a reflected binding"
        );
        assert!(slot.reserve().is_ok());
    }
}

struct FailFlush<W>(W);

impl<W: AsyncWrite + Unpin> AsyncWrite for FailFlush<W> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.get_mut().0).poll_write(cx, bytes)
    }
    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Err(ErrorKind::BrokenPipe.into()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().0).poll_shutdown(cx)
    }
}

#[tokio::test]
async fn failed_first_ack_flush_cannot_send_the_guest_hello_or_establish_an_epoch() {
    let slot = ControlSlot::new();
    let opening = slot.reserve().unwrap();
    let (mut peer, guest) = UnixStream::pair().unwrap();
    let (read, write) = guest.into_split();
    let mut reader = FrameReader::new(read);
    let mut writer = FrameWriter::new(FailFlush(write));
    let mut host = Session::new(
        Role::Host,
        VM,
        GENERATION,
        &CORE_CAPABILITIES,
        &CORE_CAPABILITIES,
    )
    .unwrap();
    FrameWriter::new(&mut peer)
        .write_object(&host.hello().unwrap(), deadline())
        .await
        .unwrap();
    assert!(
        opening
            .bootstrap(
                &mut reader,
                &mut writer,
                &CORE_CAPABILITIES,
                &CORE_CAPABILITIES,
                deadline()
            )
            .await
            .is_err()
    );
    assert_eq!(
        reader.read_object(deadline()).await.unwrap_err().kind(),
        ErrorKind::BrokenPipe
    );
    assert_eq!(
        writer
            .write_object(&health(), deadline())
            .await
            .unwrap_err()
            .kind(),
        ErrorKind::BrokenPipe
    );
    drop(reader);
    drop(writer);
    let mut received = FrameReader::new(&mut peer);
    assert_eq!(
        received.read_object(deadline()).await.unwrap().unwrap()["kind"],
        "response"
    );
    assert!(
        received.read_object(deadline()).await.unwrap().is_none(),
        "guest hello followed a failed host-ACK flush"
    );
    assert!(slot.reserve().is_ok());
}

#[tokio::test]
async fn cancelled_host_first_handshake_is_not_resumable_after_guest_hello() {
    let slot = ControlSlot::new();
    let opening = slot.reserve().unwrap();
    let (mut peer, guest) = UnixStream::pair().unwrap();
    let (read, write) = guest.into_split();
    let mut reader = FrameReader::new(read);
    let mut writer = FrameWriter::new(write);
    let limit = deadline();
    let exchange = async {
        let mut host = Session::new(
            Role::Host,
            VM,
            GENERATION,
            &CORE_CAPABILITIES,
            &CORE_CAPABILITIES,
        )
        .unwrap();
        FrameWriter::new(&mut peer)
            .write_object(&host.hello().unwrap(), limit)
            .await
            .unwrap();
        let ack = FrameReader::new(&mut peer)
            .read_object(limit)
            .await
            .unwrap()
            .unwrap();
        host.receive_hello(&ack).unwrap();
        let hello = FrameReader::new(&mut peer)
            .read_object(limit)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(hello["method"], "session.hello");
        // Deliberately do not acknowledge the guest hello.
    };
    tokio::select! {
        result = opening.bootstrap(&mut reader, &mut writer, &CORE_CAPABILITIES, &CORE_CAPABILITIES, limit) => panic!("unacknowledged guest hello completed: {}", result.is_ok()),
        () = exchange => {},
    }
    assert_eq!(
        reader.read_object(deadline()).await.unwrap_err().kind(),
        ErrorKind::BrokenPipe
    );
    assert_eq!(
        writer
            .write_object(&health(), deadline())
            .await
            .unwrap_err()
            .kind(),
        ErrorKind::BrokenPipe
    );
    assert!(slot.reserve().is_ok());
}

#[tokio::test]
async fn real_control_eof_revokes_a_published_grant_and_joins_its_owned_binary_io_before_replacement()
 {
    let slot = ControlSlot::new();
    let mut control = connect(&slot).await;
    let epoch = control.owner.epoch().clone();
    let registry = GrantRegistry::new(epoch.clone()).unwrap();
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result"), b"sealed bytes").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        GENERATION,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let request = json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "collect-before-eof",
        "method": "artifact.collect", "vm_id": VM, "driver_generation": GENERATION,
        "operation_id": "op_01J00000000000000000000009", "params": {"paths": [{"path": "result", "kind": "result"}], "max_total_bytes": 4096}});
    let limit = deadline();
    let reply = registry
        .prepare_collection(control.owner.session(), &mut collector, &request, limit)
        .await
        .unwrap();
    let descriptor = &reply.message()["result"]["artifacts"][0];
    let open = OpenHeader {
        protocol_version: "gaovm.binary.v1".to_owned(),
        vm_id: VM.to_owned(),
        driver_generation: GENERATION,
        operation_id: request["operation_id"].as_str().unwrap().to_owned(),
        artifact_id: descriptor["artifact_id"].as_str().unwrap().to_owned(),
        source: BinarySource::Collection {
            stream_id: descriptor["stream_id"].as_str().unwrap().to_owned(),
        },
    };
    reply.flush(&mut control._writer, limit).await.unwrap();
    FrameReader::new(&mut control.peer)
        .read_object(limit)
        .await
        .unwrap()
        .unwrap();
    let file = collector
        .open_artifact(control.owner.session(), &request, &open.artifact_id)
        .unwrap()
        .into_inner();
    let lease = registry.try_open(&epoch, &open).unwrap();
    let (guest, host) = UnixStream::pair().unwrap();
    let serving = tokio::spawn(lease.serve(guest, file.into_async(), limit, limit));
    let (ready, mut host) = read_header(host, limit).await.unwrap();
    assert!(matches!(ready, BinaryHeader::Ready(_)));
    drop(control.peer);
    assert!(
        control
            .owner
            .read_message(&mut control.reader, limit)
            .await
            .unwrap()
            .is_none()
    );
    assert!(registry.try_open(&epoch, &open).is_err());
    let closing = control.owner.begin_close();
    assert!(slot.reserve().is_err());
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(1), serving)
            .await
            .unwrap()
            .unwrap()
            .err()
            .unwrap()
            .kind(),
        ErrorKind::ConnectionAborted
    );
    let mut queued_before_eof = Vec::new();
    tokio::time::timeout(
        Duration::from_secs(1),
        host.read_to_end(&mut queued_before_eof),
    )
    .await
    .unwrap()
    .unwrap();
    drop(control.reader);
    drop(control._writer);
    closing.finish().unwrap();
    let replacement = connect(&slot).await;
    assert!(
        registry.try_open(replacement.owner.epoch(), &open).is_err(),
        "old grant crossed identical wire binding into a new epoch"
    );
    epoch.invalidate();
    replacement
        .owner
        .session()
        .authorize_request(&health())
        .unwrap();
    replacement.owner.begin_close().finish().unwrap();
}
