//! Independent binary headers/framing, not peer authentication or grant admission.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{self, Write};
use std::sync::OnceLock;

pub const MAX_HEADER_BYTES: usize = 4096;
pub const MAX_CHUNK_BYTES: usize = 8192;
pub const MAX_ARTIFACT_BYTES: u64 = 256 * 1024 * 1024;
pub const BINARY_MAGIC: [u8; 4] = *b"GAB1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum BinaryHeader {
    Open(OpenHeader),
    Ready(ReadyHeader),
    Committed(CommittedHeader),
    Error(ErrorHeader),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OpenHeader {
    pub protocol_version: String,
    pub vm_id: String,
    pub driver_generation: u64,
    pub operation_id: String,
    pub artifact_id: String,
    pub source: BinarySource,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum BinarySource {
    Collection { stream_id: String },
    ExecOutput { output: ExecOutput },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecOutput {
    Stdout,
    Stderr,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReadyHeader {
    pub protocol_version: String,
    pub vm_id: String,
    pub driver_generation: u64,
    pub operation_id: String,
    pub artifact: BinaryArtifact,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BinaryArtifact {
    pub artifact_id: String,
    pub kind: String,
    pub content_type: String,
    pub size_bytes: u64,
    pub digest: String,
    pub stream_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommittedHeader {
    pub protocol_version: String,
    pub vm_id: String,
    pub driver_generation: u64,
    pub operation_id: String,
    pub artifact_id: String,
    pub stream_id: String,
    pub size_bytes: u64,
    pub digest: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ErrorHeader {
    pub protocol_version: String,
    pub vm_id: String,
    pub driver_generation: u64,
    pub operation_id: String,
    pub artifact_id: String,
    pub error: BinaryFailure,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BinaryFailure {
    pub code: BinaryErrorCode,
    pub message: String,
    pub retryable: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum BinaryErrorCode {
    ProtocolVersionMismatch,
    InvalidRequest,
    ArtifactNotFound,
    ArtifactLimitExceeded,
    GuestInternalError,
}

pub fn decode_header(payload: &[u8]) -> io::Result<BinaryHeader> {
    validate_payload(payload)?;
    // Deserialize raw keys directly: a Value would collapse duplicates before
    // the typed visitor could reject them, including escaped/nested keys.
    serde_json::from_slice(payload).map_err(|_| invalid_header())
}

/// Validate into a bounded buffer before publishing any bytes to a transport.
pub fn encode_header(header: &BinaryHeader) -> io::Result<Vec<u8>> {
    let mut bytes = [0; MAX_HEADER_BYTES];
    let mut buffer = io::Cursor::new(bytes.as_mut_slice());
    serde_json::to_writer(&mut buffer, header).map_err(|_| invalid_header())?;
    buffer.flush()?;
    let length = buffer.position() as usize;
    validate_payload(&bytes[..length])?;
    Ok(bytes[..length].to_vec())
}

fn validate_payload(payload: &[u8]) -> io::Result<()> {
    if payload.is_empty() || payload.len() > MAX_HEADER_BYTES {
        return Err(invalid_header());
    }
    let value: Value = serde_json::from_slice(payload).map_err(|_| invalid_header())?;
    static VALIDATOR: OnceLock<jsonschema::Validator> = OnceLock::new();
    let validator = VALIDATOR.get_or_init(|| {
        let schema: Value =
            serde_json::from_str(include_str!("../../../schemas/guest-binary/v1.schema.json"))
                .expect("the checked-in binary schema must be valid JSON");
        jsonschema::validator_for(&schema).expect("the checked-in binary schema must compile")
    });
    if !validator.is_valid(&value) {
        return Err(invalid_header());
    }
    if value["error"]["message"]
        .as_str()
        .is_some_and(|message| message.len() > 256)
    {
        return Err(invalid_header());
    }
    Ok(())
}

fn invalid_header() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid binary header")
}
