use gaovm_guestd::control::{FrameReader, FrameWriter};
use gaovm_guestd::frame;
use serde_json::{Value, json};
use std::io::Cursor;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::Instant;

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
