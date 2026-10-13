use gaovm_guestd::binary::{decode_header, encode_header};
use serde_json::Value;

fn examples() -> Vec<Value> {
    let schema: Value =
        serde_json::from_str(include_str!("../../../schemas/guest-binary/v1.schema.json")).unwrap();
    schema["examples"].as_array().unwrap().clone()
}

#[test]
fn typed_headers_round_trip_the_independent_golden_examples() {
    for example in examples() {
        let bytes = serde_json::to_vec(&example).unwrap();
        let header = decode_header(&bytes).unwrap();
        let encoded = encode_header(&header).unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&encoded).unwrap(), example);
        assert_eq!(decode_header(&encoded).unwrap(), header);
    }
}

#[test]
fn duplicate_keys_are_rejected_before_they_can_be_collapsed() {
    let examples = examples();
    for example in &examples {
        let raw = serde_json::to_string(example).unwrap();
        for (key, value) in example.as_object().unwrap() {
            let duplicate = format!(
                "{{{}:{},{}",
                serde_json::to_string(key).unwrap(),
                value,
                &raw[1..]
            );
            assert!(
                decode_header(duplicate.as_bytes()).is_err(),
                "duplicate {key}"
            );
        }
    }
    let open = serde_json::to_string(&examples[0]).unwrap();
    let ready = serde_json::to_string(&examples[2]).unwrap();
    let error = serde_json::to_string(&examples[4]).unwrap();
    for raw in [
        format!("{{\"vm_id\":\"vm_01J00000000000000000000000\",{}", &open[1..]),
        format!("{{\"vm_\\u0069d\":\"vm_01J00000000000000000000000\",{}", &open[1..]),
        open.replace("\"source\":{", "\"source\":{\"kind\":\"collection\","),
        open.replace("\"source\":{", "\"source\":{\"stream_id\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\","),
        ready.replace("\"artifact\":{", "\"artifact\":{\"size_bytes\":11,"),
        error.replace("\"error\":{", "\"error\":{\"retryable\":false,"),
    ] {
        let failure = decode_header(raw.as_bytes()).expect_err("duplicate key was accepted");
        assert_eq!(failure.kind(), std::io::ErrorKind::InvalidData);
        assert_eq!(failure.to_string(), "invalid binary header");
    }
}

#[test]
fn error_messages_are_bounded_in_utf8_bytes_not_characters() {
    let mut error = examples()[4].clone();
    error["error"]["message"] = serde_json::json!("雪".repeat(85));
    let header = decode_header(&serde_json::to_vec(&error).unwrap()).unwrap();
    encode_header(&header).unwrap();
    error["error"]["message"] = serde_json::json!("雪".repeat(86));
    assert!(decode_header(&serde_json::to_vec(&error).unwrap()).is_err());
    let mut invalid = header;
    let gaovm_guestd::binary::BinaryHeader::Error(error) = &mut invalid else {
        unreachable!();
    };
    error.error.message = "雪".repeat(86);
    assert!(encode_header(&invalid).is_err());
}

#[test]
fn invalid_utf8_json_shapes_fields_and_header_byte_budgets_fail_closed() {
    for payload in [
        &b"[]"[..],
        &b"true"[..],
        &b"{}"[..],
        &b"\xff"[..],
        &b"\"scalar\""[..],
        &b"{"[..],
        &b"{}{}"[..],
    ] {
        assert_eq!(
            decode_header(payload).unwrap_err().kind(),
            std::io::ErrorKind::InvalidData
        );
    }
    let open = examples()[0].clone();
    let mut payload = serde_json::to_vec(&open).unwrap();
    payload.resize(4096, b' ');
    decode_header(&payload).unwrap();
    payload.push(b' ');
    assert!(decode_header(&payload).is_err());
    for (field, value) in [
        ("protocol_version", serde_json::json!("gaovm.binary.v2")),
        ("driver_generation", serde_json::json!(0)),
        ("operation_id", Value::Null),
        ("path", serde_json::json!("/not-a-selector")),
    ] {
        let mut invalid = open.clone();
        invalid[field] = value;
        assert!(decode_header(&serde_json::to_vec(&invalid).unwrap()).is_err());
    }
}
