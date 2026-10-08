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
    decode_object(&payload).map(Some)
}

pub(crate) fn decode_object(payload: &[u8]) -> io::Result<Value> {
    let value: Value = serde_json::from_slice(payload)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid control JSON"))?;
    if !value.is_object() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame must contain one object",
        ));
    }
    Ok(value)
}

pub fn write_object<W: Write>(writer: &mut W, value: &Value) -> io::Result<()> {
    let payload = encode_object(value)?;
    writer.write_all(&(payload.len() as u32).to_be_bytes())?;
    writer.write_all(&payload)?;
    writer.flush()
}

pub(crate) fn encode_object(value: &Value) -> io::Result<Vec<u8>> {
    if !value.is_object() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "frame must contain one object",
        ));
    }
    let mut payload = BoundedPayload(Vec::new());
    serde_json::to_writer(&mut payload, value)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "frame is too large"))?;
    Ok(payload.0)
}

struct BoundedPayload(Vec<u8>);

impl Write for BoundedPayload {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > MAX_FRAME_BYTES - self.0.len() {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let needed = self.0.len() + bytes.len();
        if needed > self.0.capacity() {
            let capacity = self
                .0
                .capacity()
                .max(8)
                .saturating_mul(2)
                .max(needed)
                .min(MAX_FRAME_BYTES);
            self.0.reserve_exact(capacity - self.0.len());
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
