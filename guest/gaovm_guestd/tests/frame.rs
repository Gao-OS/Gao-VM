use gaovm_guestd::frame::{MAX_FRAME_BYTES, read_object, write_object};
use serde_json::json;
use std::io::{self, Cursor, Read};

#[test]
fn control_frames_round_trip_as_one_big_endian_length_prefixed_object() {
    let message = json!({"protocol_version": "gaovm.guest.v1", "method": "health"});
    let mut bytes = Vec::new();
    write_object(&mut bytes, &message).unwrap();
    assert_eq!(
        u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize,
        bytes.len() - 4
    );
    let mut reader = Cursor::new(bytes);
    assert_eq!(read_object(&mut reader).unwrap(), Some(message));
    assert_eq!(read_object(&mut reader).unwrap(), None);
}

#[test]
fn batch_and_scalar_control_messages_are_rejected_on_read_and_write() {
    for value in [
        json!([]),
        json!(null),
        json!("text"),
        json!(4),
        json!(false),
    ] {
        let payload = serde_json::to_vec(&value).unwrap();
        let mut bytes = (payload.len() as u32).to_be_bytes().to_vec();
        bytes.extend_from_slice(&payload);
        assert!(read_object(&mut Cursor::new(bytes)).is_err());
        let mut output = Vec::new();
        assert!(write_object(&mut output, &value).is_err());
        assert!(output.is_empty());
    }
}

#[test]
fn fragmented_interrupted_and_coalesced_frames_preserve_message_boundaries() {
    let first = json!({"text": "GaoOS 雪"});
    let second = json!({"generation": 2});
    let mut bytes = Vec::new();
    write_object(&mut bytes, &first).unwrap();
    write_object(&mut bytes, &second).unwrap();
    let mut reader = Fragmented {
        bytes: Cursor::new(bytes),
        interrupt_once: true,
    };
    assert_eq!(read_object(&mut reader).unwrap(), Some(first));
    assert_eq!(read_object(&mut reader).unwrap(), Some(second));
    assert_eq!(read_object(&mut reader).unwrap(), None);
}

#[test]
fn invalid_lengths_fail_before_any_payload_is_read() {
    for length in [0, (MAX_FRAME_BYTES + 1) as u32, u32::MAX] {
        let error = read_object(&mut Cursor::new(length.to_be_bytes())).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }
}

#[test]
fn eof_is_clean_only_between_complete_frames() {
    for bytes in [vec![0], vec![0, 0], vec![0, 0, 0], vec![0, 0, 0, 2, b'{']] {
        let error = read_object(&mut Cursor::new(bytes)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
    }
}

#[test]
fn malformed_json_and_invalid_utf8_fail_closed() {
    for payload in [vec![b'{'], vec![b'{', b'"', 0xff, b'"', b':', b'0', b'}']] {
        let mut bytes = (payload.len() as u32).to_be_bytes().to_vec();
        bytes.extend(payload);
        assert_eq!(
            read_object(&mut Cursor::new(bytes)).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }
}

#[test]
fn oversized_outbound_objects_do_not_publish_a_partial_frame() {
    let value = json!({"text": "x".repeat(MAX_FRAME_BYTES)});
    let mut bytes = Vec::new();
    assert_eq!(
        write_object(&mut bytes, &value).unwrap_err().kind(),
        io::ErrorKind::InvalidInput
    );
    assert!(bytes.is_empty());
}

struct Fragmented {
    bytes: Cursor<Vec<u8>>,
    interrupt_once: bool,
}

impl Read for Fragmented {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.interrupt_once {
            self.interrupt_once = false;
            return Err(io::ErrorKind::Interrupted.into());
        }
        let length = buffer.len().min(2);
        self.bytes.read(&mut buffer[..length])
    }
}
