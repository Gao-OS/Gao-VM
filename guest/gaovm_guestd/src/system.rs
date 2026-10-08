//! Read-only core queries. Readiness of application services is a separate concern.

use crate::protocol::{ErrorCode, PROTOCOL_VERSION, ProtocolError, validate_message};
use crate::session::Session;
use serde_json::{Value, json};
use std::fs::OpenOptions;
use std::io::{ErrorKind, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

pub struct SystemQueries {
    vm_id: String,
    generation: u64,
    started: Instant,
    root: PathBuf,
}

impl SystemQueries {
    pub fn new(vm_id: &str, generation: u64, system_root: &Path) -> Result<Self, ProtocolError> {
        validate_message(
            &json!({"protocol_version": PROTOCOL_VERSION, "kind": "request", "id": "system-binding",
            "method": "health", "vm_id": vm_id, "driver_generation": generation, "operation_id": null, "params": {}}),
        )?;
        if !system_root.is_dir() {
            return Err(error(ErrorCode::InvalidRequest));
        }
        let root = system_root
            .canonicalize()
            .map_err(|_| error(ErrorCode::GuestInternalError))?;
        Ok(Self {
            vm_id: vm_id.to_owned(),
            generation,
            started: Instant::now(),
            root,
        })
    }

    pub fn handle(&self, session: &Session, request: &Value) -> Result<Value, ProtocolError> {
        session.authorize_request(request)?;
        if request["vm_id"] != self.vm_id || request["driver_generation"] != self.generation {
            return Err(error(ErrorCode::InvalidRequest));
        }
        let result = match request["method"].as_str() {
            Some("health") => {
                json!({"status": "ok", "uptime_seconds": self.started.elapsed().as_secs_f64()})
            }
            Some("system.info") => {
                let identity =
                    nix::sys::utsname::uname().map_err(|_| error(ErrorCode::GuestInternalError))?;
                let os = self.os_release()?;
                let boot_id =
                    read_small_file(&self.root.join("proc/sys/kernel/random/boot_id"), 128)?
                        .map(|value| value.trim().to_owned())
                        .filter(|value| !value.is_empty());
                json!({"os": {"name": os.name.unwrap_or_else(|| identity.sysname().to_string_lossy().into_owned()),
                    "version": os.version.unwrap_or_else(|| "unknown".to_owned()),
                    "build_id": os.build_id, "channel": null},
                    "kernel": identity.release().to_string_lossy(), "architecture": identity.machine().to_string_lossy(),
                    "hostname": identity.nodename().to_string_lossy(), "boot_id": boot_id})
            }
            _ => return Err(error(ErrorCode::CapabilityNotSupported)),
        };
        let response = json!({"protocol_version": PROTOCOL_VERSION, "kind": "response", "id": request["id"],
            "method": request["method"], "vm_id": self.vm_id, "driver_generation": self.generation,
            "operation_id": request["operation_id"], "result": result});
        validate_message(&response).map_err(|_| error(ErrorCode::GuestInternalError))?;
        Ok(response)
    }

    fn os_release(&self) -> Result<OsRelease, ProtocolError> {
        let contents = match read_small_file(&self.root.join("etc/os-release"), 65536)? {
            Some(contents) => Some(contents),
            None => read_small_file(&self.root.join("usr/lib/os-release"), 65536)?,
        };
        let mut result = OsRelease::default();
        for line in contents.as_deref().unwrap_or("").lines() {
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let field = match key {
                "NAME" => &mut result.name,
                "VERSION_ID" => &mut result.version,
                "BUILD_ID" => &mut result.build_id,
                _ => continue,
            };
            *field = decode_value(value)?;
        }
        Ok(result)
    }
}

#[derive(Default)]
struct OsRelease {
    name: Option<String>,
    version: Option<String>,
    build_id: Option<String>,
}

fn read_small_file(path: &Path, limit: u64) -> Result<Option<String>, ProtocolError> {
    // Only fixed metadata paths, never a request-supplied path. os-release may
    // legitimately be a vendor symlink. Nonblocking open also rejects FIFOs.
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(nix::fcntl::OFlag::O_NONBLOCK.bits() | nix::fcntl::OFlag::O_CLOEXEC.bits())
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(error(ErrorCode::GuestInternalError)),
    };
    if !file
        .metadata()
        .map_err(|_| error(ErrorCode::GuestInternalError))?
        .is_file()
    {
        return Err(error(ErrorCode::GuestInternalError));
    }
    let mut contents = String::new();
    file.take(limit + 1)
        .read_to_string(&mut contents)
        .map_err(|_| error(ErrorCode::GuestInternalError))?;
    if contents.len() as u64 > limit {
        return Err(error(ErrorCode::GuestInternalError));
    }
    Ok(Some(contents))
}

fn decode_value(raw: &str) -> Result<Option<String>, ProtocolError> {
    let raw = raw.trim();
    let value = if let Some(value) = raw.strip_prefix('\'') {
        let value = value
            .strip_suffix('\'')
            .ok_or_else(|| error(ErrorCode::GuestInternalError))?;
        if value.contains('\'') {
            return Err(error(ErrorCode::GuestInternalError));
        }
        value.to_owned()
    } else {
        let quoted = raw.starts_with('"');
        let value = if quoted {
            raw.strip_prefix('"')
                .and_then(|value| value.strip_suffix('"'))
                .ok_or_else(|| error(ErrorCode::GuestInternalError))?
        } else {
            raw
        };
        let mut chars = value.chars();
        let mut result = String::new();
        while let Some(character) = chars.next() {
            if character == '\\' {
                let next = chars
                    .next()
                    .ok_or_else(|| error(ErrorCode::GuestInternalError))?;
                if quoted && !matches!(next, '$' | '\u{0060}' | '"' | '\\') {
                    result.push('\\');
                }
                result.push(next);
            } else if character == '"'
                || (!quoted && (character == '\'' || character.is_whitespace()))
            {
                return Err(error(ErrorCode::GuestInternalError));
            } else {
                result.push(character);
            }
        }
        result
    };
    if value.chars().any(char::is_control) {
        return Err(error(ErrorCode::GuestInternalError));
    }
    Ok((!value.is_empty()).then_some(value))
}

fn error(code: ErrorCode) -> ProtocolError {
    ProtocolError {
        code,
        message: "system query failed",
    }
}
