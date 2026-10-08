#![cfg(unix)]

use gaovm_guestd::protocol::{ErrorCode, validate_message};
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use gaovm_guestd::system::SystemQueries;
use serde_json::{Value, json};
use std::path::Path;

const VM: &str = "vm_01J00000000000000000000000";

fn session_with(capabilities: &[&str]) -> Session {
    let mut host = Session::new(Role::Host, VM, 8, capabilities, capabilities).unwrap();
    let mut guest = Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, capabilities).unwrap();
    let host_hello = host.hello().unwrap();
    let guest_hello = guest.hello().unwrap();
    let host_ack = guest.receive_hello(&host_hello).unwrap().unwrap();
    let guest_ack = host.receive_hello(&guest_hello).unwrap().unwrap();
    host.receive_hello(&host_ack).unwrap();
    guest.receive_hello(&guest_ack).unwrap();
    guest
}

fn request(method: &str) -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "system-test",
        "method": method, "vm_id": VM, "driver_generation": 8, "operation_id": null, "params": {}})
}

#[test]
fn health_reports_agent_uptime_and_preserves_the_request_correlation() {
    let system = SystemQueries::new(VM, 8, Path::new("/")).unwrap();
    let session = session_with(&CORE_CAPABILITIES);
    let mut request = request("health");
    request["operation_id"] = json!("op_01J00000000000000000000001");
    let first = system.handle(&session, &request).unwrap();
    validate_message(&first).unwrap();
    assert_eq!(first["kind"], "response");
    for field in ["id", "method", "vm_id", "driver_generation", "operation_id"] {
        assert_eq!(first[field], request[field]);
    }
    assert_eq!(first["result"]["status"], "ok");
    let second = system.handle(&session, &request).unwrap();
    assert!(
        second["result"]["uptime_seconds"].as_f64().unwrap()
            >= first["result"]["uptime_seconds"].as_f64().unwrap()
    );
}

#[test]
fn system_info_identifies_the_real_running_kernel_and_machine() {
    let system = SystemQueries::new(VM, 8, Path::new("/")).unwrap();
    let response = system
        .handle(&session_with(&CORE_CAPABILITIES), &request("system.info"))
        .unwrap();
    validate_message(&response).unwrap();
    let actual = nix::sys::utsname::uname().unwrap();
    assert_eq!(
        response["result"]["kernel"],
        actual.release().to_str().unwrap()
    );
    assert_eq!(
        response["result"]["architecture"],
        actual.machine().to_str().unwrap()
    );
    assert_eq!(
        response["result"]["hostname"],
        actual.nodename().to_str().unwrap()
    );
}

#[test]
fn system_info_reads_os_release_and_boot_identity_without_running_its_contents() {
    let root = tempfile::tempdir().unwrap();
    std::fs::create_dir(root.path().join("etc")).unwrap();
    std::fs::create_dir_all(root.path().join("proc/sys/kernel/random")).unwrap();
    let marker = root.path().join("must-not-exist");
    std::fs::write(
        root.path().join("etc/os-release"),
        format!(
            r#"# image identity
NAME=old
NAME="GaoOS \"test\""
VERSION_ID='2026.10'
BUILD_ID="\$(touch {})"
"#,
            marker.display()
        ),
    )
    .unwrap();
    std::fs::write(
        root.path().join("proc/sys/kernel/random/boot_id"),
        "f572fce4-6e72-4aaa-8c88-ffddfe15ccab\n",
    )
    .unwrap();
    let system = SystemQueries::new(VM, 8, root.path()).unwrap();
    let response = system
        .handle(&session_with(&CORE_CAPABILITIES), &request("system.info"))
        .unwrap();
    validate_message(&response).unwrap();
    assert_eq!(response["result"]["os"]["name"], "GaoOS \"test\"");
    assert_eq!(response["result"]["os"]["version"], "2026.10");
    assert_eq!(
        response["result"]["os"]["build_id"],
        format!("$(touch {})", marker.display())
    );
    assert_eq!(
        response["result"]["boot_id"],
        "f572fce4-6e72-4aaa-8c88-ffddfe15ccab"
    );
    assert!(!marker.exists());
}

#[test]
fn os_release_precedence_and_missing_identity_are_explicit() {
    let root = tempfile::tempdir().unwrap();
    std::fs::create_dir(root.path().join("etc")).unwrap();
    std::fs::create_dir_all(root.path().join("usr/lib")).unwrap();
    std::fs::write(
        root.path().join("usr/lib/os-release"),
        "NAME=Vendor\nVERSION_ID=1\nBUILD_ID=vendor-build\n",
    )
    .unwrap();
    let system = SystemQueries::new(VM, 8, root.path()).unwrap();
    let session = session_with(&CORE_CAPABILITIES);
    let query = request("system.info");
    assert_eq!(
        system.handle(&session, &query).unwrap()["result"]["os"]["name"],
        "Vendor"
    );
    std::fs::write(root.path().join("etc/os-release"), "NAME=Override\n").unwrap();
    let result = system.handle(&session, &query).unwrap();
    assert_eq!(result["result"]["os"]["name"], "Override");
    assert_eq!(result["result"]["os"]["version"], "unknown");
    assert!(result["result"]["os"]["build_id"].is_null());
    assert!(result["result"]["os"]["channel"].is_null());
    assert!(result["result"]["boot_id"].is_null());

    let empty = tempfile::tempdir().unwrap();
    let empty = SystemQueries::new(VM, 8, empty.path()).unwrap();
    let result = empty.handle(&session, &query).unwrap();
    validate_message(&result).unwrap();
    assert_eq!(
        result["result"]["os"]["name"],
        nix::sys::utsname::uname()
            .unwrap()
            .sysname()
            .to_str()
            .unwrap()
    );
}

#[test]
fn missing_os_version_never_masquerades_as_the_kernel_release() {
    let root = tempfile::tempdir().unwrap();
    let system = SystemQueries::new(VM, 8, root.path()).unwrap();
    let session = session_with(&CORE_CAPABILITIES);
    let query = request("system.info");
    assert_eq!(
        system.handle(&session, &query).unwrap()["result"]["os"]["version"],
        "unknown"
    );
    std::fs::create_dir(root.path().join("etc")).unwrap();
    std::fs::write(root.path().join("etc/os-release"), "NAME=RollingOS\n").unwrap();
    let result = system.handle(&session, &query).unwrap();
    assert_eq!(result["result"]["os"]["name"], "RollingOS");
    assert_eq!(result["result"]["os"]["version"], "unknown");
    assert_eq!(
        result["result"]["kernel"],
        nix::sys::utsname::uname()
            .unwrap()
            .release()
            .to_str()
            .unwrap()
    );
}

#[test]
fn unreadable_malformed_or_oversized_metadata_is_not_reported_as_healthy_system_info() {
    let root = tempfile::tempdir().unwrap();
    std::fs::create_dir(root.path().join("etc")).unwrap();
    let path = root.path().join("etc/os-release");
    let system = SystemQueries::new(VM, 8, root.path()).unwrap();
    let session = session_with(&CORE_CAPABILITIES);
    for bytes in [
        b"NAME=\"unterminated-secret".to_vec(),
        b"NAME='unterminated-secret".to_vec(),
        b"NAME=\"quote\"suffix\"\n".to_vec(),
        b"NAME=\xff".to_vec(),
        vec![b'x'; 65537],
    ] {
        std::fs::write(&path, bytes).unwrap();
        let error = system
            .handle(&session, &request("system.info"))
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::GuestInternalError);
        assert!(!error.message.contains("secret"));
        // Health is responsiveness of this agent, not success of a metadata read.
        assert_eq!(
            system.handle(&session, &request("health")).unwrap()["result"]["status"],
            "ok"
        );
    }
    std::fs::remove_file(&path).unwrap();
    std::fs::create_dir(&path).unwrap();
    assert_eq!(
        system
            .handle(&session, &request("system.info"))
            .unwrap_err()
            .code,
        ErrorCode::GuestInternalError
    );
}

#[test]
fn queries_cannot_bypass_negotiation_or_use_a_different_vm_generation() {
    let system = SystemQueries::new(VM, 8, Path::new("/")).unwrap();
    let unready = Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &[]).unwrap();
    assert_eq!(
        system
            .handle(&unready, &request("health"))
            .unwrap_err()
            .code,
        ErrorCode::InvalidRequest
    );
    assert_eq!(
        system
            .handle(&session_with(&["health"]), &request("system.info"))
            .unwrap_err()
            .code,
        ErrorCode::CapabilityNotSupported
    );
    let session = session_with(&CORE_CAPABILITIES);
    for (field, value) in [
        ("vm_id", json!("vm_01J00000000000000000000001")),
        ("driver_generation", json!(7)),
        ("protocol_version", json!("gaovm.guest.v2")),
        ("params", json!({"unexpected": "must-not-echo-secret"})),
    ] {
        let mut invalid = request("health");
        invalid[field] = value;
        let error = system.handle(&session, &invalid).unwrap_err();
        assert!(matches!(
            error.code,
            ErrorCode::InvalidRequest | ErrorCode::ProtocolVersionMismatch
        ));
        assert!(!error.message.contains("secret"));
    }
    let other = SystemQueries::new(VM, 9, Path::new("/")).unwrap();
    assert_eq!(
        other.handle(&session, &request("health")).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
    assert_eq!(
        system
            .handle(&session, &request("capabilities.get"))
            .unwrap_err()
            .code,
        ErrorCode::CapabilityNotSupported
    );
    system.handle(&session, &request("health")).unwrap();
}

#[test]
fn invalid_constructor_bindings_and_non_directory_roots_are_rejected() {
    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("file"), b"not a directory").unwrap();
    for (vm, generation) in [("default", 8), (VM, 0)] {
        assert!(SystemQueries::new(vm, generation, root.path()).is_err());
    }
    assert!(SystemQueries::new(VM, 8, &root.path().join("file")).is_err());
    assert!(SystemQueries::new(VM, 8, &root.path().join("missing")).is_err());
}
