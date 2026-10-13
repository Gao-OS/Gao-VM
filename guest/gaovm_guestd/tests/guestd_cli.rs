use std::process::Command;

#[test]
fn help_describes_explicit_roots_and_io_policy_without_starting_a_listener() {
    let output = Command::new(env!("CARGO_BIN_EXE_gaovm-guestd"))
        .arg("--help")
        .output()
        .unwrap();
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(text.contains("--artifact-root"));
    assert!(text.contains("--spool-parent"));
    assert!(text.contains("--io-budget-seconds"));
    assert!(text.contains("10777"));
    assert!(!text.contains("--vm-id"));
}

#[test]
fn missing_or_invalid_service_policy_fails_before_runtime_admission_without_echoing_inputs() {
    for args in [
        vec![],
        vec![
            "--artifact-root",
            "relative",
            "--spool-parent",
            "/private/spool",
            "--io-budget-seconds",
            "3",
        ],
        vec![
            "--artifact-root",
            "/private/source",
            "--spool-parent",
            "/private/spool",
            "--io-budget-seconds",
            "0",
        ],
        vec![
            "--artifact-root",
            "/private/source",
            "--spool-parent",
            "/private/spool",
            "--io-budget-seconds",
            "3",
            "--port",
            "1023",
        ],
        vec![
            "--artifact-root",
            "/private/source",
            "--spool-parent",
            "/private/spool",
            "--io-budget-seconds",
            "3",
            "--unexpected-secret",
            "fixture-secret",
        ],
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_gaovm-guestd"))
            .args(args)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        let error = String::from_utf8(output.stderr).unwrap();
        assert!(!error.contains("fixture-secret"));
        assert!(!error.contains("/private"));
    }
}

#[cfg(not(target_os = "linux"))]
#[test]
fn a_valid_non_linux_invocation_fails_without_a_socket_or_storage_fallback() {
    let root = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_gaovm-guestd"))
        .args([
            "--artifact-root",
            root.path().to_str().unwrap(),
            "--spool-parent",
            spool.path().to_str().unwrap(),
            "--io-budget-seconds",
            "3",
        ])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8(output.stderr)
            .unwrap()
            .contains("requires Linux AF_VSOCK")
    );
    assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 0);
    assert_eq!(std::fs::read_dir(spool.path()).unwrap().count(), 0);
}
