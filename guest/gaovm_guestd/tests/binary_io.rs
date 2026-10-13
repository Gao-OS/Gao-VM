#![cfg(unix)]

use gaovm_guestd::binary::{BinaryArtifact, BinaryHeader, MAX_ARTIFACT_BYTES, MAX_CHUNK_BYTES};
use gaovm_guestd::binary_io::{
    BodyReader, Demultiplexed, accept_preface, read_header, write_body, write_header,
};
use serde_json::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::time::{Duration, Instant};

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(2)
}

fn artifact() -> BinaryArtifact {
    let BinaryHeader::Ready(ready) =
        gaovm_guestd::binary::decode_header(&serde_json::to_vec(&examples()[2]).unwrap()).unwrap()
    else {
        panic!("missing ready fixture");
    };
    ready.artifact
}

async fn streams(bytes: &[u8]) -> (UnixStream, UnixStream) {
    let (mut sender, receiver) = UnixStream::pair().unwrap();
    sender.write_all(bytes).await.unwrap();
    (sender, receiver)
}

fn examples() -> Vec<Value> {
    let schema: Value =
        serde_json::from_str(include_str!("../../../schemas/guest-binary/v1.schema.json")).unwrap();
    schema["examples"].as_array().unwrap().clone()
}

fn frame(value: &Value) -> Vec<u8> {
    let payload = serde_json::to_vec(value).unwrap();
    let mut wire = (payload.len() as u32).to_be_bytes().to_vec();
    wire.extend(payload);
    wire
}

#[tokio::test]
async fn fragmented_open_and_coalesced_body_end_do_not_depend_on_eof() {
    let (mut host, guest) = UnixStream::pair().unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    let examples = examples();
    let mut open_wire = b"GAB1".to_vec();
    open_wire.extend(frame(&examples[0]));
    let ready_wire = frame(&examples[2]);
    let guest_task = tokio::spawn(async move {
        let Demultiplexed::Binary { stream } = accept_preface(guest, deadline).await.unwrap()
        else {
            panic!("binary preface was routed to control");
        };
        let (open, mut guest) = read_header(stream, deadline).await.unwrap();
        assert!(matches!(open, BinaryHeader::Open(_)));
        guest.write_all(&ready_wire).await.unwrap();
        // Independent fixed wire fixture: two raw chunks and an explicit end.
        guest
            .write_all(b"\x00\x00\x00\x05hello\x00\x00\x00\x06 world\x00\x00\x00\x00!")
            .await
            .unwrap();
        guest
    });
    for byte in open_wire {
        host.write_all(&[byte]).await.unwrap();
        tokio::task::yield_now().await;
    }
    let (ready, host) = read_header(host, deadline).await.unwrap();
    let BinaryHeader::Ready(ready) = ready else {
        panic!("missing ready");
    };
    let mut body = BodyReader::new(host, &ready.artifact, deadline).unwrap();
    let mut received = Vec::new();
    while let Some(chunk) = body.read_chunk().await.unwrap() {
        received.extend(chunk);
    }
    assert_eq!(received, b"hello world");
    let mut host = body.finish().unwrap();
    assert_eq!(host.read_u8().await.unwrap(), b'!');
    // Keep the peer open until after decoding: end, not EOF, delimits the body.
    drop(guest_task.await.unwrap());
}

#[tokio::test]
async fn control_demux_preserves_its_original_length_prefix() {
    let schema: Value = serde_json::from_str(include_str!(
        "../../../schemas/guest-protocol/v1.schema.json"
    ))
    .unwrap();
    let message = &schema["examples"][0];
    let wire = frame(message);
    let (_sender, receiver) = streams(&wire).await;
    let Demultiplexed::Control {
        length_prefix,
        stream,
    } = accept_preface(receiver, deadline()).await.unwrap()
    else {
        panic!("control prefix was routed to binary");
    };
    assert_eq!(length_prefix, wire[..4]);
    let prefixed = std::io::Cursor::new(length_prefix).chain(stream);
    let mut reader = gaovm_guestd::control::FrameReader::new(prefixed);
    assert_eq!(
        reader.read_object(deadline()).await.unwrap().as_ref(),
        Some(message)
    );
}

#[tokio::test]
async fn unknown_magic_and_invalid_lengths_are_not_downgraded_to_control() {
    for prefix in [
        *b"GAB2",
        *b"GAB0",
        [0; 4],
        u32::MAX.to_be_bytes(),
        16777217_u32.to_be_bytes(),
    ] {
        let (_sender, receiver) = streams(&prefix).await;
        let result = tokio::time::timeout(
            Duration::from_millis(200),
            accept_preface(receiver, deadline()),
        )
        .await
        .unwrap();
        assert_eq!(
            result.err().unwrap().kind(),
            std::io::ErrorKind::InvalidData
        );
    }
}

#[tokio::test]
async fn invalid_header_lengths_fail_without_waiting_for_payload_or_eof() {
    for length in [0_u32, 4097, u32::MAX] {
        let (_sender, receiver) = streams(&length.to_be_bytes()).await;
        let result = tokio::time::timeout(
            Duration::from_millis(200),
            read_header(receiver, deadline()),
        )
        .await
        .unwrap();
        assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::InvalidData);
    }
}

#[tokio::test]
async fn chunk_bounds_and_remaining_size_are_checked_before_payload_read() {
    for (size, length) in [(10000_u64, (MAX_CHUNK_BYTES + 1) as u32), (11, 12), (11, 0)] {
        let mut artifact = artifact();
        artifact.size_bytes = size;
        let (_sender, receiver) = streams(&length.to_be_bytes()).await;
        let mut reader = BodyReader::new(receiver, &artifact, deadline()).unwrap();
        let result = tokio::time::timeout(Duration::from_millis(200), reader.read_chunk())
            .await
            .unwrap();
        assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(
            reader.read_chunk().await.unwrap_err().kind(),
            std::io::ErrorKind::BrokenPipe
        );
        assert!(reader.finish().is_err());
    }
}

#[tokio::test]
async fn truncation_missing_end_and_digest_mismatch_never_finish_a_body() {
    for (wire, kind) in [
        (
            &b"\x00\x00\x00\x05hel"[..],
            std::io::ErrorKind::UnexpectedEof,
        ),
        (
            &b"\x00\x00\x00\x0bhello world"[..],
            std::io::ErrorKind::UnexpectedEof,
        ),
        (
            &b"\x00\x00\x00\x0bHELLO WORLD\x00\x00\x00\x00"[..],
            std::io::ErrorKind::InvalidData,
        ),
    ] {
        let (sender, receiver) = streams(wire).await;
        drop(sender);
        let mut reader = BodyReader::new(receiver, &artifact(), deadline()).unwrap();
        let error = loop {
            match reader.read_chunk().await {
                Ok(Some(_)) => {}
                Ok(None) => panic!("invalid body reached end"),
                Err(error) => break error,
            }
        };
        assert_eq!(error.kind(), kind);
        assert!(reader.finish().is_err());
    }
}

#[tokio::test]
async fn empty_and_non_utf8_bodies_are_raw_bytes_not_control_json() {
    use sha2::{Digest, Sha256};
    for bytes in [vec![], vec![0xff; MAX_CHUNK_BYTES]] {
        let mut artifact = artifact();
        artifact.size_bytes = bytes.len() as u64;
        let hex: String = Sha256::digest(&bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        artifact.digest = format!("sha256:{hex}");
        let mut wire = Vec::new();
        if !bytes.is_empty() {
            wire.extend((bytes.len() as u32).to_be_bytes());
            wire.extend(&bytes);
        }
        wire.extend([0; 4]);
        let (mut sender, receiver) = UnixStream::pair().unwrap();
        let sender_task = tokio::spawn(async move {
            sender.write_all(&wire).await.unwrap();
            sender
        });
        let mut reader = BodyReader::new(receiver, &artifact, deadline()).unwrap();
        let mut received = Vec::new();
        while let Some(chunk) = reader.read_chunk().await.unwrap() {
            assert!(chunk.len() <= MAX_CHUNK_BYTES);
            received.extend(chunk);
        }
        assert_eq!(received, bytes);
        reader.finish().unwrap();
        drop(sender_task.await.unwrap());
    }
    let mut oversized = artifact();
    oversized.size_bytes = MAX_ARTIFACT_BYTES + 1;
    assert!(BodyReader::new(&b""[..], &oversized, deadline()).is_err());
}

#[tokio::test]
async fn cancelling_a_partial_chunk_fences_the_reader() {
    let (_sender, receiver) = streams(&[0, 0]).await;
    let mut reader = BodyReader::new(receiver, &artifact(), deadline()).unwrap();
    assert!(
        tokio::time::timeout(Duration::from_millis(30), reader.read_chunk())
            .await
            .is_err()
    );
    assert_eq!(
        reader.read_chunk().await.unwrap_err().kind(),
        std::io::ErrorKind::BrokenPipe
    );
    assert!(reader.finish().is_err());
}

#[tokio::test]
async fn body_progress_does_not_reset_the_phase_deadline() {
    let (mut sender, receiver) = UnixStream::pair().unwrap();
    let phase_deadline = Instant::now() + Duration::from_millis(500);
    let sender_task = tokio::spawn(async move {
        sender.write_all(b"\x00\x00\x00\x05hello").await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        sender.write_all(b"\x00\x00\x00\x06 world").await.unwrap();
        sender
    });
    let mut reader = BodyReader::new(receiver, &artifact(), phase_deadline).unwrap();
    assert_eq!(reader.read_chunk().await.unwrap().unwrap(), b"hello");
    assert_eq!(reader.read_chunk().await.unwrap().unwrap(), b" world");
    assert_eq!(
        reader.read_chunk().await.unwrap_err().kind(),
        std::io::ErrorKind::TimedOut
    );
    assert_eq!(
        reader.read_chunk().await.unwrap_err().kind(),
        std::io::ErrorKind::BrokenPipe
    );
    assert!(reader.finish().is_err());
    drop(sender_task.await.unwrap());
}

#[tokio::test]
async fn writer_sends_raw_body_and_can_read_a_fixture_ack() {
    let (guest, host) = UnixStream::pair().unwrap();
    let fixtures = examples();
    let ready =
        gaovm_guestd::binary::decode_header(&serde_json::to_vec(&fixtures[2]).unwrap()).unwrap();
    let committed =
        gaovm_guestd::binary::decode_header(&serde_json::to_vec(&fixtures[3]).unwrap()).unwrap();
    let sender_task = tokio::spawn(async move {
        let BinaryHeader::Ready(metadata) = &ready else {
            panic!("missing ready");
        };
        let guest = write_header(guest, &ready, deadline()).await.unwrap();
        let guest = write_body(guest, &b"hello world"[..], &metadata.artifact, deadline())
            .await
            .unwrap();
        let (ack, _guest) = read_header(guest, deadline()).await.unwrap();
        assert_eq!(ack, committed);
    });
    let (ready, host) = read_header(host, deadline()).await.unwrap();
    let BinaryHeader::Ready(metadata) = ready else {
        panic!("missing ready");
    };
    let mut body = BodyReader::new(host, &metadata.artifact, deadline()).unwrap();
    let mut bytes = Vec::new();
    while let Some(chunk) = body.read_chunk().await.unwrap() {
        bytes.extend(chunk);
    }
    assert_eq!(bytes, b"hello world");
    let host = body.finish().unwrap();
    // A codec fixture only: production ACK still requires durable publication.
    let committed =
        gaovm_guestd::binary::decode_header(&serde_json::to_vec(&fixtures[3]).unwrap()).unwrap();
    write_header(host, &committed, deadline()).await.unwrap();
    sender_task.await.unwrap();
}

#[tokio::test]
async fn open_writer_includes_the_binary_magic_and_unknown_headers_publish_nothing() {
    let open =
        gaovm_guestd::binary::decode_header(&serde_json::to_vec(&examples()[0]).unwrap()).unwrap();
    let (sender, receiver) = UnixStream::pair().unwrap();
    let sender = write_header(sender, &open, deadline()).await.unwrap();
    let Demultiplexed::Binary { stream } = accept_preface(receiver, deadline()).await.unwrap()
    else {
        panic!("missing GAB1");
    };
    let (received, _receiver) = read_header(stream, deadline()).await.unwrap();
    assert_eq!(received, open);
    drop(sender);

    let (sender, mut receiver) = UnixStream::pair().unwrap();
    let mut invalid = open;
    let BinaryHeader::Open(metadata) = &mut invalid else {
        unreachable!();
    };
    metadata.protocol_version = "gaovm.binary.v2".into();
    assert_eq!(
        write_header(sender, &invalid, deadline())
            .await
            .unwrap_err()
            .kind(),
        std::io::ErrorKind::InvalidData
    );
    assert_eq!(
        receiver.read_u8().await.unwrap_err().kind(),
        std::io::ErrorKind::UnexpectedEof
    );
}

#[tokio::test]
async fn opening_phases_share_one_deadline_and_a_failed_open_closes_its_stream() {
    let (mut sender, receiver) = streams(b"GAB1").await;
    let open_deadline = Instant::now() + Duration::from_millis(40);
    let Demultiplexed::Binary { stream } = accept_preface(receiver, open_deadline).await.unwrap()
    else {
        panic!("missing GAB1");
    };
    assert_eq!(
        read_header(stream, open_deadline).await.unwrap_err().kind(),
        std::io::ErrorKind::TimedOut
    );
    assert_eq!(
        sender.read_u8().await.unwrap_err().kind(),
        std::io::ErrorKind::UnexpectedEof
    );
}

#[tokio::test]
async fn short_overlong_and_changed_sources_never_send_an_end_marker() {
    for source in [&b"hi"[..], &b"hello world!"[..], &b"HELLO WORLD"[..]] {
        let (sender, receiver) = UnixStream::pair().unwrap();
        let failure = write_body(sender, source, &artifact(), deadline())
            .await
            .unwrap_err();
        assert_eq!(failure.kind(), std::io::ErrorKind::InvalidData);
        let mut body = BodyReader::new(receiver, &artifact(), deadline()).unwrap();
        let error = loop {
            match body.read_chunk().await {
                Ok(Some(_)) => {}
                Ok(None) => panic!("failed source emitted a valid end"),
                Err(error) => break error,
            }
        };
        assert_eq!(error.kind(), std::io::ErrorKind::UnexpectedEof);
        assert!(body.finish().is_err());
    }
}

async fn backpressured_streams() -> (UnixStream, UnixStream, usize) {
    let (sender, receiver) = UnixStream::pair().unwrap();
    sender.writable().await.unwrap();
    let mut count = 0;
    loop {
        match sender.try_write(&[0; MAX_CHUNK_BYTES]) {
            Ok(written) => {
                assert_ne!(written, 0);
                count += written;
                assert!(
                    count < 16 * 1024 * 1024,
                    "owned socket did not apply backpressure"
                );
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(error) => panic!("{error}"),
        }
    }
    (sender, receiver, count)
}

#[tokio::test]
async fn stalled_buffered_header_flush_times_out_and_closes_the_owned_socket() {
    let (sender, mut receiver, filled) = backpressured_streams().await;
    let ready =
        gaovm_guestd::binary::decode_header(&serde_json::to_vec(&examples()[2]).unwrap()).unwrap();
    let writer = tokio::io::BufWriter::with_capacity(8192, sender);
    let failure = write_header(writer, &ready, Instant::now() + Duration::from_millis(40))
        .await
        .unwrap_err();
    assert_eq!(failure.kind(), std::io::ErrorKind::TimedOut);
    let mut drained = Vec::new();
    tokio::time::timeout(Duration::from_secs(1), receiver.read_to_end(&mut drained))
        .await
        .unwrap()
        .unwrap();
    assert!(drained.len() >= filled);
}

#[tokio::test]
async fn cancelling_a_stalled_body_send_drops_its_owned_socket() {
    let (sender, mut receiver, filled) = backpressured_streams().await;
    assert!(
        tokio::time::timeout(
            Duration::from_millis(40),
            write_body(sender, &b"hello world"[..], &artifact(), deadline())
        )
        .await
        .is_err()
    );
    let mut drained = Vec::new();
    tokio::time::timeout(Duration::from_secs(1), receiver.read_to_end(&mut drained))
        .await
        .unwrap()
        .unwrap();
    assert!(drained.len() >= filled);
}
