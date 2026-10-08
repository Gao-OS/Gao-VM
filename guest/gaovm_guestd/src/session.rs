use crate::protocol::{ErrorCode, PROTOCOL_VERSION, ProtocolError, validate_message};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::BTreeSet;

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

pub struct Session {
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
        Ok(Self {
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
            self.failed = true;
        }
        result
    }

    pub fn is_ready(&self) -> bool {
        !self.failed
            && self.sent_hello
            && self.negotiated.is_some()
            && self.negotiated == self.acknowledged
    }

    pub(crate) fn invalidate(&mut self) {
        self.failed = true;
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
