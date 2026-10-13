use serde::de::{Deserialize, Deserializer, Error, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Number, Value};
use std::fmt;
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
    // Validate raw keys before constructing Value: its ordinary deserializer
    // silently replaces duplicates, including escaped/nested binding keys.
    let value = serde_json::from_slice::<UniqueValue>(payload)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid control JSON"))?
        .0;
    if !value.is_object() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame must contain one object",
        ));
    }
    Ok(value)
}

struct UniqueValue(Value);

impl<'de> Deserialize<'de> for UniqueValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(UniqueVisitor)
    }
}

struct UniqueVisitor;

impl<'de> Visitor<'de> for UniqueVisitor {
    type Value = UniqueValue;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("JSON with unique object keys")
    }

    fn visit_unit<E: Error>(self) -> Result<UniqueValue, E> {
        Ok(UniqueValue(Value::Null))
    }
    fn visit_bool<E: Error>(self, value: bool) -> Result<UniqueValue, E> {
        Ok(UniqueValue(Value::Bool(value)))
    }
    fn visit_i64<E: Error>(self, value: i64) -> Result<UniqueValue, E> {
        Ok(UniqueValue(Value::Number(value.into())))
    }
    fn visit_u64<E: Error>(self, value: u64) -> Result<UniqueValue, E> {
        Ok(UniqueValue(Value::Number(value.into())))
    }
    fn visit_f64<E: Error>(self, value: f64) -> Result<UniqueValue, E> {
        Number::from_f64(value)
            .map(|number| UniqueValue(Value::Number(number)))
            .ok_or_else(|| E::custom("invalid number"))
    }
    fn visit_str<E: Error>(self, value: &str) -> Result<UniqueValue, E> {
        self.visit_string(value.to_owned())
    }
    fn visit_string<E: Error>(self, value: String) -> Result<UniqueValue, E> {
        Ok(UniqueValue(Value::String(value)))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<UniqueValue, A::Error> {
        let mut values = Vec::new();
        while let Some(value) = sequence.next_element::<UniqueValue>()? {
            values.push(value.0);
        }
        Ok(UniqueValue(Value::Array(values)))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut object: A) -> Result<UniqueValue, A::Error> {
        let mut values = Map::new();
        while let Some(key) = object.next_key::<String>()? {
            if values.contains_key(&key) {
                return Err(A::Error::custom("duplicate object key"));
            }
            values.insert(key, object.next_value::<UniqueValue>()?.0);
        }
        Ok(UniqueValue(Value::Object(values)))
    }
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
