use crate::protocol::{ErrorCode, PROTOCOL_VERSION, ProtocolError, validate_message};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::watch;

pub const CORE_CAPABILITIES: [&str; 6] = [
    "health",
    "system.info",
    "exec.start",
    "exec.status",
    "exec.cancel",
    "artifact.collect",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Host,
    Guest,
}

/// Opaque connection identity issued only by successful wire negotiation. It
/// proves completed hello/flush, not native peer authentication. Never serialize
/// it or reconstruct it from VM/generation strings supplied on a binary stream.
#[derive(Clone)]
pub struct ControlEpoch(Arc<EpochState>);

struct EpochState {
    role: Role,
    vm_id: String,
    driver_generation: u64,
    active: Mutex<bool>,
    grant_registry_claimed: AtomicBool,
    invalidated: watch::Sender<bool>,
}

impl std::fmt::Debug for ControlEpoch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ControlEpoch")
            .field("vm_id", &self.0.vm_id)
            .field("driver_generation", &self.0.driver_generation)
            .finish_non_exhaustive()
    }
}

impl ControlEpoch {
    pub fn vm_id(&self) -> &str {
        &self.0.vm_id
    }

    pub fn driver_generation(&self) -> u64 {
        self.0.driver_generation
    }

    pub fn is_active(&self) -> bool {
        self.0.active.lock().is_ok_and(|active| *active)
    }

    /// Fence new work before waking transfers. EOF/replacement handlers call
    /// this first, then abort/close their owned transports and clean up spools.
    pub fn invalidate(&self) {
        if let Ok(mut active) = self.0.active.lock() {
            *active = false;
        }
        self.0.invalidated.send_replace(true);
    }

    pub async fn invalidated(&self) {
        let mut changed = self.0.invalidated.subscribe();
        while !*changed.borrow_and_update() {
            if changed.changed().await.is_err() {
                break;
            }
        }
    }

    pub(crate) fn same(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }

    pub(crate) fn is_guest(&self) -> bool {
        self.0.role == Role::Guest
    }

    pub(crate) fn claim_grant_registry(&self) -> bool {
        self.while_active(|| !self.0.grant_registry_claimed.swap(true, Ordering::Relaxed))
            .unwrap_or(false)
    }

    /// Short synchronous state transitions only. No I/O/await while holding
    /// this gate; invalidation and authorization have one linearization point.
    pub(crate) fn while_active<T>(&self, transition: impl FnOnce() -> T) -> Option<T> {
        let active = self.0.active.lock().ok()?;
        if !*active {
            return None;
        }
        Some(transition())
    }
}

pub struct Session {
    epoch: ControlEpoch,
    role: Role,
    vm_id: String,
    driver_generation: u64,
    hello: Value,
    offered: BTreeSet<String>,
    required: BTreeSet<String>,
    sent_hello: bool,
    negotiated: Option<BTreeSet<String>>,
    acknowledged: Option<BTreeSet<String>>,
    failed: bool,
}

impl Session {
    pub fn new(
        role: Role,
        vm_id: &str,
        driver_generation: u64,
        offered: &[&str],
        required: &[&str],
    ) -> Result<Self, ProtocolError> {
        let hello = json!({
            "protocol_version": PROTOCOL_VERSION,
            "kind": "request",
            "id": match role { Role::Host => "host-hello", Role::Guest => "guest-hello" },
            "method": "session.hello",
            "vm_id": vm_id,
            "driver_generation": driver_generation,
            "operation_id": null,
            "params": {"peer_role": role, "offered_capabilities": offered, "required_capabilities": required},
        });
        validate_message(&hello)?;
        let (invalidated, _) = watch::channel(false);
        Ok(Self {
            epoch: ControlEpoch(Arc::new(EpochState {
                role,
                vm_id: vm_id.to_owned(),
                driver_generation,
                active: Mutex::new(true),
                grant_registry_claimed: AtomicBool::new(false),
                invalidated,
            })),
            role,
            vm_id: vm_id.to_owned(),
            driver_generation,
            hello,
            offered: offered.iter().map(|s| (*s).to_owned()).collect(),
            required: required.iter().map(|s| (*s).to_owned()).collect(),
            sent_hello: false,
            negotiated: None,
            acknowledged: None,
            failed: false,
        })
    }

    pub fn hello(&mut self) -> Result<Value, ProtocolError> {
        if self.failed || self.sent_hello {
            return Err(invalid("guest hello cannot be sent in this session state"));
        }
        self.sent_hello = true;
        Ok(self.hello.clone())
    }

    pub fn receive_hello(&mut self, message: &Value) -> Result<Option<Value>, ProtocolError> {
        let result = self.process_hello(message);
        if result.is_err() {
            self.invalidate();
        }
        result
    }

    pub fn is_ready(&self) -> bool {
        !self.failed
            && self.epoch.is_active()
            && self.sent_hello
            && self.negotiated.is_some()
            && self.negotiated == self.acknowledged
    }

    pub(crate) fn invalidate(&mut self) {
        self.failed = true;
        self.epoch.invalidate();
    }

    pub(crate) fn completed_epoch(&self) -> Result<ControlEpoch, ProtocolError> {
        if !self.is_ready() {
            return Err(invalid("guest session is not ready"));
        }
        Ok(self.epoch.clone())
    }

    pub(crate) fn belongs_to(&self, epoch: &ControlEpoch) -> bool {
        self.epoch.same(epoch)
    }

    pub fn authorize_request(&self, message: &Value) -> Result<(), ProtocolError> {
        if !self.is_ready() {
            return Err(invalid("guest session is not ready"));
        }
        validate_message(message)?;
        self.check_binding(message)?;
        if message["kind"] != "request" || message["method"] == "session.hello" {
            return Err(invalid("an application request is required"));
        }
        let method = message["method"]
            .as_str()
            .expect("validated request method");
        if method != "capabilities.get"
            && !self
                .negotiated
                .as_ref()
                .expect("ready session has negotiated capabilities")
                .contains(method)
        {
            return Err(ProtocolError {
                code: ErrorCode::CapabilityNotSupported,
                message: "guest capability was not negotiated",
            });
        }
        Ok(())
    }

    fn process_hello(&mut self, message: &Value) -> Result<Option<Value>, ProtocolError> {
        if self.failed {
            return Err(invalid("guest session has failed"));
        }
        validate_message(message)?;
        self.check_binding(message)?;
        if message["method"] != "session.hello" || !message["operation_id"].is_null() {
            return Err(invalid("a correlated guest hello is required"));
        }
        match message["kind"].as_str() {
            Some("request") => {
                if self.negotiated.is_some() || message["params"]["peer_role"] == json!(self.role) {
                    return Err(invalid("duplicate hello or unexpected peer role"));
                }
                let offered = capabilities(&message["params"]["offered_capabilities"]);
                let required = capabilities(&message["params"]["required_capabilities"]);
                let accepted: BTreeSet<_> = self.offered.intersection(&offered).cloned().collect();
                if !required.is_subset(&accepted)
                    || !self.required.is_subset(&accepted)
                    || self
                        .acknowledged
                        .as_ref()
                        .is_some_and(|ack| ack != &accepted)
                {
                    return Err(capability_mismatch());
                }
                let reply = json!({
                    "protocol_version": PROTOCOL_VERSION, "kind": "response", "id": message["id"],
                    "method": "session.hello", "vm_id": self.vm_id,
                    "driver_generation": self.driver_generation, "operation_id": null,
                    "result": {"accepted_capabilities": accepted},
                });
                validate_message(&reply)?;
                self.negotiated = Some(accepted);
                Ok(Some(reply))
            }
            Some("response") => {
                if !self.sent_hello
                    || self.acknowledged.is_some()
                    || message["id"] != self.hello["id"]
                {
                    return Err(invalid("unexpected guest hello acknowledgement"));
                }
                let accepted = capabilities(&message["result"]["accepted_capabilities"]);
                if !accepted.is_subset(&self.offered)
                    || !self.required.is_subset(&accepted)
                    || self
                        .negotiated
                        .as_ref()
                        .is_some_and(|caps| caps != &accepted)
                {
                    return Err(capability_mismatch());
                }
                self.acknowledged = Some(accepted);
                Ok(None)
            }
            Some("error") => Err(ProtocolError {
                code: match message["error"]["code"].as_str() {
                    Some("CAPABILITY_MISMATCH") => ErrorCode::CapabilityMismatch,
                    Some("PROTOCOL_VERSION_MISMATCH") => ErrorCode::ProtocolVersionMismatch,
                    _ => ErrorCode::InvalidRequest,
                },
                message: "peer rejected the guest hello",
            }),
            _ => Err(invalid("unexpected guest hello message kind")),
        }
    }

    fn check_binding(&self, message: &Value) -> Result<(), ProtocolError> {
        if message["vm_id"].as_str() != Some(self.vm_id.as_str())
            || message["driver_generation"].as_u64() != Some(self.driver_generation)
        {
            return Err(invalid(
                "guest message belongs to another VM or driver generation",
            ));
        }
        Ok(())
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.epoch.invalidate();
    }
}

fn capabilities(value: &Value) -> BTreeSet<String> {
    value
        .as_array()
        .expect("validated capability set")
        .iter()
        .map(|value| value.as_str().expect("validated capability").to_owned())
        .collect()
}

fn invalid(message: &'static str) -> ProtocolError {
    ProtocolError {
        code: ErrorCode::InvalidRequest,
        message,
    }
}

fn capability_mismatch() -> ProtocolError {
    ProtocolError {
        code: ErrorCode::CapabilityMismatch,
        message: "guest capabilities do not satisfy both peers",
    }
}
