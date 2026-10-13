#![cfg(target_os = "linux")]

use gaovm_guestd::vsock::HostListener;
use std::io::ErrorKind;

#[test]
fn privileged_or_zero_configured_ports_are_rejected_before_runtime_or_socket_creation() {
    for port in [0, 1, 1023] {
        let error = HostListener::bind(port).err().unwrap();
        assert_eq!(error.kind(), ErrorKind::InvalidInput);
    }
}
