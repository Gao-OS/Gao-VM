use gaovm_guestd::protocol::{ErrorCode, validate_message};
use serde_json::{Value, json};

#[test]
fn the_frozen_guest_schema_examples_are_accepted() {
    let schema: Value = serde_json::from_str(include_str!(
        "../../../schemas/guest-protocol/v1.schema.json"
    ))
    .unwrap();
    for example in schema["examples"].as_array().unwrap() {
        validate_message(example).unwrap();
    }
}

fn exec_request() -> Value {
    let schema: Value = serde_json::from_str(include_str!(
        "../../../schemas/guest-protocol/v1.schema.json"
    ))
    .unwrap();
    schema["examples"][0].clone()
}

#[test]
fn correlation_and_envelope_fields_are_not_optional_or_extensible() {
    for field in [
        "protocol_version",
        "kind",
        "id",
        "method",
        "vm_id",
        "driver_generation",
        "operation_id",
        "params",
    ] {
        let mut message = exec_request();
        message.as_object_mut().unwrap().remove(field);
        assert_eq!(
            validate_message(&message).unwrap_err().code,
            ErrorCode::InvalidRequest,
            "{field}"
        );
    }
    for (field, value) in [
        ("vm_id", json!("vm_81J00000000000000000000000")),
        ("driver_generation", json!(0)),
        ("operation_id", Value::Null),
        ("method", json!("driver.exec")),
        ("jsonrpc", json!("2.0")),
    ] {
        let mut message = exec_request();
        message[field] = value;
        assert_eq!(
            validate_message(&message).unwrap_err().code,
            ErrorCode::InvalidRequest,
            "{field}"
        );
    }
}

#[test]
fn exec_uses_bounded_argv_and_capture_instead_of_an_implicit_shell() {
    for (field, value) in [
        ("argv", json!("echo unsafe")),
        ("argv", json!([])),
        ("cwd", json!("")),
        ("env", json!({"INVALID-NAME": "secret-must-not-be-echoed"})),
        ("timeout_seconds", json!(0)),
        ("timeout_seconds", json!(86401)),
        (
            "capture",
            json!({"stdout": true, "stderr": true, "max_inline_bytes": 1048577}),
        ),
    ] {
        let mut message = exec_request();
        message["params"][field] = value;
        let error = validate_message(&message).unwrap_err();
        assert_eq!(error.code, ErrorCode::InvalidRequest, "{field}");
        assert!(!error.message.contains("secret-must-not-be-echoed"));
    }
}

#[test]
fn protocol_version_mismatches_have_a_stable_error() {
    let mut message = exec_request();
    message["protocol_version"] = json!("gaovm.guest.v2");
    assert_eq!(
        validate_message(&message).unwrap_err().code,
        ErrorCode::ProtocolVersionMismatch
    );
}

#[test]
fn artifact_collection_cannot_follow_symlinks() {
    let mut message = exec_request();
    message["method"] = json!("artifact.collect");
    message["params"] = json!({"paths": [{"path": "/logs/test.log", "kind": "test.log"}], "max_total_bytes": 1024, "follow_symlinks": false});
    validate_message(&message).unwrap();
    message["params"]["follow_symlinks"] = json!(true);
    assert_eq!(
        validate_message(&message).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
}
