use serde_json::Value;
use std::io::{self, Read, Write};

pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

pub fn read_object<R: Read>(reader: &mut R) -> io::Result<Option<Value>> {
    let mut header = [0; 4];
    loop {
        match reader.read(&mut header[..1]) {
            Ok(0) => return Ok(None),
            Ok(_) => break,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    reader.read_exact(&mut header[1..])?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid frame length",
        ));
    }
    let mut payload = vec![0; length];
    reader.read_exact(&mut payload)?;
    let value: Value = serde_json::from_slice(&payload)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if !value.is_object() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame must contain one object",
        ));
    }
    Ok(Some(value))
}

pub fn write_object<W: Write>(writer: &mut W, value: &Value) -> io::Result<()> {
    if !value.is_object() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "frame must contain one object",
        ));
    }
    let payload = serde_json::to_vec(value)?;
    if payload.len() > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "frame is too large",
        ));
    }
    writer.write_all(&(payload.len() as u32).to_be_bytes())?;
    writer.write_all(&payload)?;
    writer.flush()
}
