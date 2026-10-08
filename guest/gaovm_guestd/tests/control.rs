use gaovm_guestd::control::{FrameReader, FrameWriter, NegotiationError, negotiate};
use gaovm_guestd::frame;
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use serde_json::{Value, json};
use std::io::Cursor;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

const VM: &str = "vm_01J00000000000000000000000";

fn session(role: Role) -> Session {
    Session::new(role, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap()
}

fn health() -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "wire-health",
        "method": "health", "vm_id": VM, "driver_generation": 8, "operation_id": null, "params": {}})
}

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(5)
}

fn wire(value: &Value) -> Vec<u8> {
    let mut bytes = Vec::new();
    frame::write_object(&mut bytes, value).unwrap();
    bytes
}

#[cfg(unix)]
#[tokio::test]
async fn real_unix_channel_negotiates_before_a_correlated_health_round_trip() {
    let (host_socket, guest_socket) = tokio::net::UnixStream::pair().unwrap();
    let (host_read, host_write) = host_socket.into_split();
    let (guest_read, guest_write) = guest_socket.into_split();
    let mut host_reader = FrameReader::new(host_read);
    let mut host_writer = FrameWriter::new(host_write);
    let mut guest_reader = FrameReader::new(guest_read);
    let mut guest_writer = FrameWriter::new(guest_write);
    let mut host = session(Role::Host);
    let mut guest = session(Role::Guest);
    let handshake_deadline = deadline();
    let (host_result, guest_result) = tokio::join!(
        negotiate(
            &mut host,
            &mut host_reader,
            &mut host_writer,
            handshake_deadline
        ),
        negotiate(
            &mut guest,
            &mut guest_reader,
            &mut guest_writer,
            handshake_deadline
        ),
    );
    host_result.unwrap();
    guest_result.unwrap();
    assert!(host.is_ready());
    assert!(guest.is_ready());
    host_writer
        .write_object(&health(), deadline())
        .await
        .unwrap();
    let request = guest_reader.read_object(deadline()).await.unwrap().unwrap();
    let system =
        gaovm_guestd::system::SystemQueries::new(VM, 8, std::path::Path::new("/")).unwrap();
    let response = system.handle(&guest, &request).unwrap();
    guest_writer
        .write_object(&response, deadline())
        .await
        .unwrap();
    let response = host_reader.read_object(deadline()).await.unwrap().unwrap();
    gaovm_guestd::protocol::validate_message(&response).unwrap();
    for field in ["id", "method", "vm_id", "driver_generation", "operation_id"] {
        assert_eq!(response[field], request[field]);
    }
    assert_eq!(response["kind"], "response");
    assert_eq!(response["result"]["status"], "ok");
}

#[tokio::test]
async fn cancelling_an_acknowledgement_flush_invalidates_the_session_and_both_halves() {
    let (socket, peer) = tokio::io::duplex(1);
    let (read, write) = tokio::io::split(socket);
    let (mut peer_read, mut peer_write) = tokio::io::split(peer);
    let mut reader = FrameReader::new(read);
    let mut writer = FrameWriter::new(tokio::io::BufWriter::with_capacity(4096, write));
    let mut guest = session(Role::Guest);
    let exchange = async {
        let guest_hello = FrameReader::new(&mut peer_read)
            .read_object(deadline())
            .await
            .unwrap()
            .unwrap();
        let mut host = session(Role::Host);
        let host_hello = host.hello().unwrap();
        let acknowledgement = host.receive_hello(&guest_hello).unwrap().unwrap();
        let mut peer_writer = FrameWriter::new(&mut peer_write);
        peer_writer
            .write_object(&acknowledgement, deadline())
            .await
            .unwrap();
        peer_writer
            .write_object(&host_hello, deadline())
            .await
            .unwrap();
        // The acknowledgement fits in the BufWriter, so its bytes reach the
        // one-byte pipe only during flush, which cannot finish after this prefix.
        let mut prefix = [0; 2];
        peer_read.read_exact(&mut prefix).await.unwrap();
    };
    let mut pending = Box::pin(negotiate(&mut guest, &mut reader, &mut writer, deadline()));
    tokio::select! {
        biased;
        () = exchange => {},
        result = &mut pending => panic!("negotiation completed before the final acknowledgement: {result:?}"),
    }
    drop(pending);
    assert!(!guest.is_ready());
    assert!(guest.authorize_request(&health()).is_err());
    assert_eq!(
        reader.read_object(deadline()).await.unwrap_err().kind(),
        std::io::ErrorKind::BrokenPipe
    );
    assert_eq!(
        writer
            .write_object(&health(), deadline())
            .await
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::BrokenPipe
    );
}

#[tokio::test]
async fn a_failed_final_acknowledgement_flush_cannot_authorize_the_session() {
    let (socket, peer) = tokio::io::duplex(8192);
    let (read, write) = tokio::io::split(socket);
    let mut reader = FrameReader::new(read);
    let mut writer = FrameWriter::new(tokio::io::BufWriter::with_capacity(4096, write));
    let mut guest = session(Role::Guest);
    let exchange = async move {
        let (peer_read, peer_write) = tokio::io::split(peer);
        let mut peer_reader = FrameReader::new(peer_read);
        let mut peer_writer = FrameWriter::new(peer_write);
        let guest_hello = peer_reader.read_object(deadline()).await.unwrap().unwrap();
        let mut host = session(Role::Host);
        let host_hello = host.hello().unwrap();
        let acknowledgement = host.receive_hello(&guest_hello).unwrap().unwrap();
        peer_writer
            .write_object(&acknowledgement, deadline())
            .await
            .unwrap();
        peer_writer
            .write_object(&host_hello, deadline())
            .await
            .unwrap();
        // Closing this peer leaves both inbound messages buffered, but rejects
        // the guest's final acknowledgement when its BufWriter flushes.
    };
    let (result, ()) = tokio::join!(
        negotiate(&mut guest, &mut reader, &mut writer, deadline()),
        exchange
    );
    assert!(
        matches!(result, Err(NegotiationError::Io(error)) if error.kind() == std::io::ErrorKind::BrokenPipe)
    );
    assert!(!guest.is_ready());
    assert!(guest.authorize_request(&health()).is_err());
    assert_eq!(
        reader.read_object(deadline()).await.unwrap_err().kind(),
        std::io::ErrorKind::BrokenPipe
    );
    assert_eq!(
        writer
            .write_object(&health(), deadline())
            .await
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::BrokenPipe
    );
}

#[tokio::test]
async fn acknowledgement_first_order_preserves_capabilities_and_the_next_frame() {
    let (socket, peer) = tokio::io::duplex(8192);
    let (read, write) = tokio::io::split(socket);
    let (mut peer_read, mut peer_write) = tokio::io::split(peer);
    let mut reader = FrameReader::new(read);
    let mut writer = FrameWriter::new(write);
    let mut guest = Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &["health"]).unwrap();
    let exchange = async {
        let guest_hello = FrameReader::new(&mut peer_read)
            .read_object(deadline())
            .await
            .unwrap()
            .unwrap();
        let mut host = Session::new(Role::Host, VM, 8, &["health"], &["health"]).unwrap();
        let host_hello = host.hello().unwrap();
        let acknowledgement = host.receive_hello(&guest_hello).unwrap().unwrap();
        let mut bytes = wire(&acknowledgement);
        bytes.extend(wire(&host_hello));
        bytes.extend(wire(&health()));
        peer_write.write_all(&bytes).await.unwrap();
        let reply = FrameReader::new(&mut peer_read)
            .read_object(deadline())
            .await
            .unwrap()
            .unwrap();
        host.receive_hello(&reply).unwrap();
        assert!(host.is_ready());
    };
    let (result, ()) = tokio::join!(
        negotiate(&mut guest, &mut reader, &mut writer, deadline()),
        exchange
    );
    result.unwrap();
    let request = reader.read_object(deadline()).await.unwrap().unwrap();
    assert_eq!(request, health());
    guest.authorize_request(&request).unwrap();
    let mut unnegotiated = request;
    unnegotiated["method"] = json!("system.info");
    assert_eq!(
        guest.authorize_request(&unnegotiated).unwrap_err().code,
        gaovm_guestd::protocol::ErrorCode::CapabilityNotSupported
    );
}

#[tokio::test]
async fn invalid_wire_hellos_fail_with_their_protocol_code_and_close_both_halves() {
    use gaovm_guestd::protocol::ErrorCode;

    let valid = session(Role::Host).hello().unwrap();
    let mut version = valid.clone();
    version["protocol_version"] = json!("gaovm.guest.v2");
    let mut vm = valid.clone();
    vm["vm_id"] = json!("vm_01J00000000000000000000001");
    let mut generation = valid.clone();
    generation["driver_generation"] = json!(7);
    let mut role = valid.clone();
    role["params"]["peer_role"] = json!("guest");
    let capabilities = Session::new(Role::Host, VM, 8, &["health"], &["health"])
        .unwrap()
        .hello()
        .unwrap();
    for (message, code) in [
        (health(), ErrorCode::InvalidRequest),
        (version, ErrorCode::ProtocolVersionMismatch),
        (vm, ErrorCode::InvalidRequest),
        (generation, ErrorCode::InvalidRequest),
        (role, ErrorCode::InvalidRequest),
        (capabilities, ErrorCode::CapabilityMismatch),
    ] {
        let (socket, mut peer) = tokio::io::duplex(8192);
        peer.write_all(&wire(&message)).await.unwrap();
        let (read, write) = tokio::io::split(socket);
        let mut reader = FrameReader::new(read);
        let mut writer = FrameWriter::new(write);
        let mut guest = session(Role::Guest);
        let result = negotiate(&mut guest, &mut reader, &mut writer, deadline()).await;
        assert!(matches!(result, Err(NegotiationError::Protocol(error)) if error.code == code));
        assert!(!guest.is_ready());
        assert!(guest.authorize_request(&health()).is_err());
        assert!(guest.receive_hello(&valid).is_err());
        assert_eq!(
            reader.read_object(deadline()).await.unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );
        assert_eq!(
            writer
                .write_object(&health(), deadline())
                .await
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::BrokenPipe
        );
    }
}

#[tokio::test]
async fn malformed_or_incomplete_hello_frames_fail_closed_as_io_errors() {
    use std::io::ErrorKind;

    for (bytes, kind) in [
        (vec![], ErrorKind::UnexpectedEof),
        (vec![0, 0, 0], ErrorKind::UnexpectedEof),
        (vec![0, 0, 0, 0], ErrorKind::InvalidData),
        (vec![0, 0, 0, 2, b'[', b']'], ErrorKind::InvalidData),
    ] {
        let (socket, mut peer) = tokio::io::duplex(8192);
        peer.write_all(&bytes).await.unwrap();
        peer.shutdown().await.unwrap();
        let (read, write) = tokio::io::split(socket);
        let mut reader = FrameReader::new(read);
        let mut writer = FrameWriter::new(write);
        let mut guest = session(Role::Guest);
        let result = negotiate(&mut guest, &mut reader, &mut writer, deadline()).await;
        assert!(matches!(result, Err(NegotiationError::Io(error)) if error.kind() == kind));
        assert!(!guest.is_ready());
        assert!(guest.authorize_request(&health()).is_err());
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
    }
}

#[tokio::test]
async fn negotiation_deadlines_cover_silence_and_the_final_acknowledgement_flush() {
    for stall_final_flush in [false, true] {
        let (socket, peer) = tokio::io::duplex(1);
        let (read, write) = tokio::io::split(socket);
        let (mut peer_read, mut peer_write) = tokio::io::split(peer);
        let mut reader = FrameReader::new(read);
        let mut writer = FrameWriter::new(tokio::io::BufWriter::with_capacity(4096, write));
        let mut guest = session(Role::Guest);
        let exchange = async {
            let guest_hello = FrameReader::new(&mut peer_read)
                .read_object(deadline())
                .await
                .unwrap()
                .unwrap();
            if stall_final_flush {
                let mut host = session(Role::Host);
                let host_hello = host.hello().unwrap();
                let acknowledgement = host.receive_hello(&guest_hello).unwrap().unwrap();
                let mut peer_writer = FrameWriter::new(&mut peer_write);
                peer_writer
                    .write_object(&acknowledgement, deadline())
                    .await
                    .unwrap();
                peer_writer
                    .write_object(&host_hello, deadline())
                    .await
                    .unwrap();
                let mut prefix = [0; 2];
                peer_read.read_exact(&mut prefix).await.unwrap();
            }
        };
        let handshake_deadline = Instant::now() + Duration::from_millis(500);
        let (result, ()) = tokio::join!(
            negotiate(&mut guest, &mut reader, &mut writer, handshake_deadline),
            exchange
        );
        assert!(
            matches!(result, Err(NegotiationError::Io(error)) if error.kind() == std::io::ErrorKind::TimedOut)
        );
        assert!(!guest.is_ready());
        assert!(guest.authorize_request(&health()).is_err());
        assert_eq!(
            reader.read_object(deadline()).await.unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );
        assert_eq!(
            writer
                .write_object(&health(), deadline())
                .await
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::BrokenPipe
        );
    }
}

#[cfg(unix)]
#[tokio::test]
async fn real_unix_socket_frames_interoperate_with_the_frozen_sync_codec() {
    let (left, right) = tokio::net::UnixStream::pair().unwrap();
    let (left_read, left_write) = left.into_split();
    let (right_read, mut right_write) = right.into_split();
    let mut reader = FrameReader::new(left_read);
    let mut writer = FrameWriter::new(left_write);
    let first = json!({"text": "GaoOS 雪"});
    let second = json!({"generation": 8});
    let mut bytes = wire(&first);
    bytes.extend(wire(&second));
    right_write.write_all(&bytes).await.unwrap();
    right_write.shutdown().await.unwrap();
    assert_eq!(
        reader.read_object(deadline()).await.unwrap(),
        Some(first.clone())
    );
    assert_eq!(reader.read_object(deadline()).await.unwrap(), Some(second));
    assert_eq!(reader.read_object(deadline()).await.unwrap(), None);
    writer.write_object(&first, deadline()).await.unwrap();
    let mut response = vec![0; wire(&first).len()];
    let mut right_read = right_read;
    right_read.read_exact(&mut response).await.unwrap();
    assert_eq!(
        frame::read_object(&mut Cursor::new(response)).unwrap(),
        Some(first)
    );
}

#[tokio::test]
async fn cancelling_a_partial_header_read_preserves_consumed_bytes() {
    let message = json!({"text": "resume me"});
    let bytes = wire(&message);
    let (socket, mut peer) = tokio::io::duplex(1);
    let mut reader = FrameReader::new(socket);
    let (sent, acknowledged) = tokio::sync::oneshot::channel();
    let producer = tokio::spawn(async move {
        peer.write_all(&bytes[..3]).await.unwrap();
        sent.send(()).unwrap();
        peer.write_all(&bytes[3..]).await.unwrap();
    });
    let original_deadline = deadline();
    let mut pending = Box::pin(reader.read_object(original_deadline));
    tokio::select! {
        biased;
        result = acknowledged => result.unwrap(),
        result = &mut pending => panic!("read completed before partial-header acknowledgement: {result:?}"),
    }
    drop(pending);
    assert_eq!(
        reader.read_object(original_deadline).await.unwrap(),
        Some(message)
    );
    producer.await.unwrap();
    assert_eq!(reader.read_object(deadline()).await.unwrap(), None);
}

#[tokio::test]
async fn cancelling_a_partial_write_permanently_closes_the_writer() {
    let (socket, mut peer) = tokio::io::duplex(1);
    let mut writer = FrameWriter::new(socket);
    let message = json!({"text": "cannot replay a partial frame"});
    let mut pending = Box::pin(writer.write_object(&message, deadline()));
    let mut prefix = [0; 2];
    tokio::select! {
        biased;
        result = peer.read_exact(&mut prefix) => { result.unwrap(); },
        result = &mut pending => panic!("write completed without a draining peer: {result:?}"),
    }
    drop(pending);
    assert_eq!(
        writer
            .write_object(&message, Instant::now())
            .await
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::BrokenPipe
    );
}

#[tokio::test]
async fn cancelling_a_partial_payload_read_preserves_the_frame_boundary() {
    let message = json!({"text": "GaoOS 雪 payload"});
    let bytes = wire(&message);
    let (socket, mut peer) = tokio::io::duplex(1);
    let mut reader = FrameReader::new(socket);
    let (sent, acknowledged) = tokio::sync::oneshot::channel();
    let producer = tokio::spawn(async move {
        peer.write_all(&bytes[..9]).await.unwrap();
        sent.send(()).unwrap();
        peer.write_all(&bytes[9..]).await.unwrap();
    });
    let original_deadline = deadline();
    let mut pending = Box::pin(reader.read_object(original_deadline));
    tokio::select! {
        biased;
        result = acknowledged => result.unwrap(),
        result = &mut pending => panic!("read completed before partial-payload acknowledgement: {result:?}"),
    }
    drop(pending);
    assert_eq!(
        reader.read_object(original_deadline).await.unwrap(),
        Some(message)
    );
    producer.await.unwrap();
}

#[tokio::test]
async fn cancelling_and_resuming_does_not_extend_the_original_read_deadline() {
    let (socket, mut peer) = tokio::io::duplex(1);
    let mut reader = FrameReader::new(socket);
    let (sent, acknowledged) = tokio::sync::oneshot::channel();
    let producer = tokio::spawn(async move {
        peer.write_all(&[0, 0, 0]).await.unwrap();
        sent.send(()).unwrap();
        peer
    });
    let original_deadline = Instant::now() + Duration::from_millis(200);
    let mut pending = Box::pin(reader.read_object(original_deadline));
    tokio::select! {
        biased;
        result = acknowledged => result.unwrap(),
        result = &mut pending => panic!("read completed before partial-header acknowledgement: {result:?}"),
    }
    drop(pending);
    let _peer = producer.await.unwrap();
    // Wait for the deadline event itself, not a guessed synchronization delay.
    tokio::time::sleep_until(original_deadline).await;
    let result = tokio::time::timeout(Duration::from_millis(100), reader.read_object(deadline()))
        .await
        .unwrap();
    assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::TimedOut);
    assert_eq!(
        reader.read_object(deadline()).await.unwrap_err().kind(),
        std::io::ErrorKind::BrokenPipe
    );
}

#[tokio::test]
async fn malformed_frames_fail_closed_and_cannot_be_followed_by_a_valid_frame() {
    let mut invalid = Vec::new();
    for length in [0, frame::MAX_FRAME_BYTES as u32 + 1, u32::MAX] {
        invalid.push(length.to_be_bytes().to_vec());
    }
    for payload in [
        b"[]".to_vec(),
        b"null".to_vec(),
        b"false".to_vec(),
        b"{} junk".to_vec(),
        vec![b'{', 0xff, b'}'],
    ] {
        let mut bytes = (payload.len() as u32).to_be_bytes().to_vec();
        bytes.extend(payload);
        invalid.push(bytes);
    }
    for mut bytes in invalid {
        bytes.extend(wire(&json!({"must": "not resynchronize"})));
        let (socket, mut peer) = tokio::io::duplex(1024);
        peer.write_all(&bytes).await.unwrap();
        let mut reader = FrameReader::new(socket);
        assert_eq!(
            reader.read_object(deadline()).await.unwrap_err().kind(),
            std::io::ErrorKind::InvalidData
        );
        assert_eq!(
            reader.read_object(deadline()).await.unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );
    }
}

#[tokio::test]
async fn eof_is_terminal_and_only_clean_between_complete_frames() {
    for bytes in [vec![0], vec![0, 0], vec![0, 0, 0], vec![0, 0, 0, 2, b'{']] {
        let (socket, mut peer) = tokio::io::duplex(64);
        peer.write_all(&bytes).await.unwrap();
        drop(peer);
        let mut reader = FrameReader::new(socket);
        assert_eq!(
            reader.read_object(deadline()).await.unwrap_err().kind(),
            std::io::ErrorKind::UnexpectedEof
        );
        assert_eq!(
            reader.read_object(deadline()).await.unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );
    }
    let (socket, peer) = tokio::io::duplex(64);
    drop(peer);
    let mut reader = FrameReader::new(socket);
    assert!(reader.read_object(deadline()).await.unwrap().is_none());
    assert!(reader.read_object(deadline()).await.unwrap().is_none());
}

#[tokio::test]
async fn expired_deadlines_do_not_accept_ready_input_or_emit_output() {
    let (socket, mut peer) = tokio::io::duplex(64);
    peer.write_all(&wire(&json!({"ready": true})))
        .await
        .unwrap();
    let mut reader = FrameReader::new(socket);
    assert_eq!(
        reader.read_object(Instant::now()).await.unwrap_err().kind(),
        std::io::ErrorKind::TimedOut
    );
    let (socket, mut peer) = tokio::io::duplex(64);
    let mut writer = FrameWriter::new(socket);
    assert_eq!(
        writer
            .write_object(&json!({"must": "not write"}), Instant::now())
            .await
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::TimedOut
    );
    assert_eq!(
        writer
            .write_object(&json!({"must": "not retry"}), deadline())
            .await
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::BrokenPipe
    );
    drop(writer);
    let mut bytes = Vec::new();
    peer.read_to_end(&mut bytes).await.unwrap();
    assert!(bytes.is_empty());
}

#[tokio::test]
async fn outbound_validation_writes_nothing_and_allows_a_later_valid_message() {
    let (socket, peer) = tokio::io::duplex(64);
    let mut writer = FrameWriter::new(socket);
    for value in [
        json!([]),
        json!(null),
        json!({"text": "x".repeat(frame::MAX_FRAME_BYTES)}),
    ] {
        assert_eq!(
            writer
                .write_object(&value, deadline())
                .await
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::InvalidInput
        );
    }
    let valid = json!({"ok": true});
    writer.write_object(&valid, deadline()).await.unwrap();
    let mut reader = FrameReader::new(peer);
    assert_eq!(reader.read_object(deadline()).await.unwrap(), Some(valid));
}

#[tokio::test]
async fn stalled_write_times_out_and_prevents_any_later_frame() {
    let (socket, _peer) = tokio::io::duplex(1);
    let mut writer = FrameWriter::new(socket);
    let message = json!({"text": "blocked"});
    assert_eq!(
        writer
            .write_object(&message, Instant::now() + Duration::from_millis(50))
            .await
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::TimedOut
    );
    assert_eq!(
        writer
            .write_object(&message, deadline())
            .await
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::BrokenPipe
    );
}
