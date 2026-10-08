use gaovm_guestd::frame::{read_object, write_object};
use gaovm_guestd::protocol::ErrorCode;
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use serde_json::{Value, json};
use std::io::Cursor;

const VM: &str = "vm_01J00000000000000000000000";

fn wire(message: &Value) -> Value {
    let mut bytes = Vec::new();
    write_object(&mut bytes, message).unwrap();
    read_object(&mut Cursor::new(bytes)).unwrap().unwrap()
}

#[test]
fn readiness_requires_both_directional_hellos_and_matching_acknowledgements() {
    let mut host = Session::new(Role::Host, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    let mut guest =
        Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    let host_hello = host.hello().unwrap();
    assert!(!host.is_ready());
    assert!(!guest.is_ready());
    let host_ack = guest.receive_hello(&wire(&host_hello)).unwrap().unwrap();
    assert!(host.receive_hello(&wire(&host_ack)).unwrap().is_none());
    assert!(!host.is_ready());
    let guest_hello = guest.hello().unwrap();
    let guest_ack = host.receive_hello(&wire(&guest_hello)).unwrap().unwrap();
    assert!(host.is_ready());
    assert!(!guest.is_ready());
    assert!(guest.receive_hello(&wire(&guest_ack)).unwrap().is_none());
    assert!(guest.is_ready());
}

fn health() -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "health-1", "method": "health", "vm_id": VM, "driver_generation": 8, "operation_id": null, "params": {}})
}

#[test]
fn application_requests_cannot_bypass_the_bidirectional_hello() {
    let guest = Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    assert_eq!(
        guest.authorize_request(&health()).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
    assert!(!guest.is_ready());
}

fn handshake(host: &mut Session, guest: &mut Session) {
    let host_hello = host.hello().unwrap();
    let guest_hello = guest.hello().unwrap();
    let host_ack = guest.receive_hello(&wire(&host_hello)).unwrap().unwrap();
    let guest_ack = host.receive_hello(&wire(&guest_hello)).unwrap().unwrap();
    host.receive_hello(&wire(&host_ack)).unwrap();
    guest.receive_hello(&wire(&guest_ack)).unwrap();
}

#[test]
fn guest_core_capabilities_and_constructor_identity_follow_the_schema() {
    assert!(Session::new(Role::Guest, VM, 8, &["health"], &[]).is_err());
    assert!(Session::new(Role::Host, VM, 0, &CORE_CAPABILITIES, &[]).is_err());
    assert!(Session::new(Role::Host, "default", 8, &CORE_CAPABILITIES, &[]).is_err());
    assert!(Session::new(Role::Host, VM, 8, &["health", "health"], &[]).is_err());
    assert!(Session::new(Role::Host, VM, 8, &["driver.exec"], &[]).is_err());
}

#[test]
fn wrong_vm_generation_role_and_version_permanently_fail_the_hello() {
    for (field, value, code) in [
        (
            "vm_id",
            json!("vm_01J00000000000000000000001"),
            ErrorCode::InvalidRequest,
        ),
        ("driver_generation", json!(9), ErrorCode::InvalidRequest),
        (
            "protocol_version",
            json!("gaovm.guest.v2"),
            ErrorCode::ProtocolVersionMismatch,
        ),
        (
            "params",
            json!({"peer_role": "guest", "offered_capabilities": CORE_CAPABILITIES, "required_capabilities": CORE_CAPABILITIES}),
            ErrorCode::InvalidRequest,
        ),
    ] {
        let mut host =
            Session::new(Role::Host, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
        let mut guest =
            Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
        let valid = host.hello().unwrap();
        let mut invalid = valid.clone();
        invalid[field] = value;
        assert_eq!(guest.receive_hello(&invalid).unwrap_err().code, code);
        assert!(!guest.is_ready());
        assert!(guest.receive_hello(&valid).is_err());
        assert!(guest.hello().is_err());
    }
}

#[test]
fn missing_required_capabilities_do_not_become_ready() {
    let mut host = Session::new(Role::Host, VM, 8, &["health"], &["health"]).unwrap();
    let mut guest =
        Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    assert_eq!(
        guest
            .receive_hello(&host.hello().unwrap())
            .unwrap_err()
            .code,
        ErrorCode::CapabilityMismatch
    );
    assert!(!guest.is_ready());
}

#[test]
fn forged_capability_acknowledgements_and_wrong_request_ids_fail_closed() {
    for (field, value, code) in [
        ("id", json!("unrelated-hello"), ErrorCode::InvalidRequest),
        (
            "result",
            json!({"accepted_capabilities": ["health"]}),
            ErrorCode::CapabilityMismatch,
        ),
    ] {
        let mut host =
            Session::new(Role::Host, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
        let mut guest =
            Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
        let mut acknowledgement = guest
            .receive_hello(&host.hello().unwrap())
            .unwrap()
            .unwrap();
        acknowledgement[field] = value;
        assert_eq!(host.receive_hello(&acknowledgement).unwrap_err().code, code);
        assert!(!host.is_ready());
    }
}

#[test]
fn stale_application_messages_cannot_rebind_a_ready_session() {
    let mut host = Session::new(Role::Host, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    let mut guest =
        Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    handshake(&mut host, &mut guest);
    guest.authorize_request(&health()).unwrap();
    for (field, value) in [
        ("vm_id", json!("vm_01J00000000000000000000001")),
        ("driver_generation", json!(7)),
    ] {
        let mut stale = health();
        stale[field] = value;
        assert_eq!(
            guest.authorize_request(&stale).unwrap_err().code,
            ErrorCode::InvalidRequest
        );
        assert!(guest.is_ready());
        guest.authorize_request(&health()).unwrap();
    }
}

#[test]
fn unnegotiated_application_capabilities_and_non_requests_are_rejected() {
    let mut host = Session::new(Role::Host, VM, 8, &["health"], &["health"]).unwrap();
    let mut guest = Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &["health"]).unwrap();
    handshake(&mut host, &mut guest);
    guest.authorize_request(&health()).unwrap();
    let mut message = health();
    message["method"] = json!("system.info");
    assert_eq!(
        guest.authorize_request(&message).unwrap_err().code,
        ErrorCode::CapabilityNotSupported
    );
    message = health();
    message["method"] = json!("capabilities.get");
    guest.authorize_request(&message).unwrap();
    message["kind"] = json!("response");
    message.as_object_mut().unwrap().remove("params");
    message["result"] = json!({"capabilities": ["health"]});
    assert_eq!(
        guest.authorize_request(&message).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
}

#[test]
fn an_established_session_cannot_renegotiate_its_identity_or_capabilities() {
    let mut host = Session::new(Role::Host, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    let mut guest =
        Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    handshake(&mut host, &mut guest);
    let mut replacement =
        Session::new(Role::Host, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    assert!(guest.receive_hello(&replacement.hello().unwrap()).is_err());
    assert!(!guest.is_ready());
    assert!(guest.authorize_request(&health()).is_err());
}
