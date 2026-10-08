use serde::Serialize;
use serde_json::Value;
use std::sync::OnceLock;

pub const PROTOCOL_VERSION: &str = "gaovm.guest.v1";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    InvalidRequest,
    ProtocolVersionMismatch,
    CapabilityMismatch,
    CapabilityNotSupported,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProtocolError {
    pub code: ErrorCode,
    pub message: &'static str,
}

pub fn validate_message(message: &Value) -> Result<(), ProtocolError> {
    if message
        .get("protocol_version")
        .and_then(Value::as_str)
        .is_some_and(|version| version != PROTOCOL_VERSION)
    {
        return Err(ProtocolError {
            code: ErrorCode::ProtocolVersionMismatch,
            message: "guest protocol version is not supported",
        });
    }
    static VALIDATOR: OnceLock<jsonschema::Validator> = OnceLock::new();
    let validator = VALIDATOR.get_or_init(|| {
        let schema: Value = serde_json::from_str(include_str!(
            "../../../schemas/guest-protocol/v1.schema.json"
        ))
        .expect("the checked-in guest schema must be valid JSON");
        jsonschema::options()
            .should_validate_formats(true)
            .build(&schema)
            .expect("the checked-in guest schema must compile")
    });
    if validator.is_valid(message) {
        return Ok(());
    }
    Err(ProtocolError {
        code: ErrorCode::InvalidRequest,
        message: "guest message is invalid",
    })
}
