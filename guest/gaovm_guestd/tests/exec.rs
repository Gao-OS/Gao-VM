#![cfg(unix)]

use gaovm_guestd::exec::{ExecLimits, ExecState, Executor, OutputReference, OutputStream};
use gaovm_guestd::protocol::{ErrorCode, validate_message};
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use serde_json::{Value, json};
use std::io::Read;
use std::time::Duration;

const VM: &str = "vm_01J00000000000000000000000";
const OP: &str = "op_01J00000000000000000000000";

fn session() -> Session {
    let mut host = Session::new(Role::Host, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    let mut guest =
        Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    let host_hello = host.hello().unwrap();
    let guest_hello = guest.hello().unwrap();
    let host_ack = guest.receive_hello(&host_hello).unwrap().unwrap();
    let guest_ack = host.receive_hello(&guest_hello).unwrap().unwrap();
    host.receive_hello(&host_ack).unwrap();
    guest.receive_hello(&guest_ack).unwrap();
    guest
}

fn request(method: &str, operation: &str) -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "exec-test",
        "method": method, "vm_id": VM, "driver_generation": 8, "operation_id": operation, "params": {}})
}

fn start_request(argv: &[&str]) -> Value {
    let mut request = request("exec.start", OP);
    request["params"] = json!({"argv": argv, "cwd": "/", "env": {}, "timeout_seconds": 5,
        "capture": {"stdout": true, "stderr": true, "max_inline_bytes": 65536}});
    request
}

fn inline(output: &OutputReference) -> &str {
    match output {
        OutputReference::Inline { text, .. } => text,
        _ => panic!("small output must remain inline"),
    }
}

#[tokio::test]
async fn real_argv_execution_returns_separate_output_and_a_structured_exit() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let start = start_request(&[
        "/bin/sh",
        "-c",
        "printf 'out:%s' \"$1\"; printf 'err' >&2; exit 7",
        "sh",
        "literal ; $(not-executed)",
    ]);
    let accepted = executor.start(&session, &start).unwrap();
    assert_eq!(accepted.result.state, ExecState::Running);
    let completed = tokio::time::timeout(
        Duration::from_secs(5),
        executor.wait(&session, &request("exec.status", OP)),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(completed.result.state, ExecState::Failed);
    assert_eq!(completed.binding.vm_id, VM);
    assert_eq!(completed.binding.driver_generation, 8);
    assert_eq!(completed.binding.operation_id, OP);
    assert_eq!(completed.result.exit_code, Some(7));
    assert_eq!(
        inline(&completed.result.stdout),
        "out:literal ; $(not-executed)"
    );
    assert_eq!(inline(&completed.result.stderr), "err");
    assert!(!completed.result.timed_out);
    assert!(completed.failure.is_none());
    let mut response = request("exec.status", OP);
    response["kind"] = json!("response");
    response.as_object_mut().unwrap().remove("params");
    response["result"] = serde_json::to_value(completed.result).unwrap();
    validate_message(&response).unwrap();
}

#[tokio::test]
async fn operation_replays_do_not_spawn_again_and_conflicting_input_is_rejected() {
    let spool = tempfile::tempdir().unwrap();
    let limits = ExecLimits {
        max_concurrent: 1,
        max_retained: 1,
        ..ExecLimits::default()
    };
    let mut executor = Executor::new(VM, 8, spool.path(), limits).unwrap();
    let session = session();
    let mut start = start_request(&["/bin/sh", "-c", "printf x >> \"$MARKER\"; cat \"$MARKER\""]);
    start["params"]["env"] = json!({"MARKER": spool.path().join("executions")});
    executor.start(&session, &start).unwrap();
    let mut replay = start.clone();
    replay["id"] = json!("retry-request");
    executor.start(&session, &replay).unwrap();
    let completed = executor
        .wait(&session, &request("exec.status", OP))
        .await
        .unwrap();
    assert_eq!(inline(&completed.result.stdout), "x");
    assert_eq!(
        executor.start(&session, &replay).unwrap().result.state,
        ExecState::Succeeded
    );
    assert_eq!(
        std::fs::read_to_string(spool.path().join("executions")).unwrap(),
        "x"
    );
    replay["params"]["argv"] = json!(["/bin/echo", "different"]);
    assert_eq!(
        executor.start(&session, &replay).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
}

#[tokio::test]
async fn timeout_stops_a_real_command_and_reports_a_stable_terminal_result() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let mut start = start_request(&["/bin/sleep", "30"]);
    start["params"]["timeout_seconds"] = json!(0.05);
    executor.start(&session, &start).unwrap();
    let completed = tokio::time::timeout(
        Duration::from_secs(3),
        executor.wait(&session, &request("exec.status", OP)),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(completed.result.state, ExecState::Failed);
    assert_eq!(completed.failure, Some(ErrorCode::ExecTimeout));
    assert!(completed.result.timed_out);
    assert!(completed.result.signal.is_some());
    assert_eq!(
        executor
            .cancel(&session, &request("exec.cancel", OP))
            .unwrap()
            .failure,
        Some(ErrorCode::ExecTimeout)
    );
}

#[tokio::test]
async fn command_deadline_is_measured_from_acceptance_not_scheduler_availability() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let mut start = start_request(&["/bin/sleep", "0.02"]);
    start["params"]["timeout_seconds"] = json!(0.001);
    executor.start(&session, &start).unwrap();
    // A bounded native wait makes this single-thread runtime unavailable until
    // after the accepted deadline. A late worker must not grant a new timeout.
    assert!(
        std::process::Command::new("/bin/sleep")
            .arg("0.2")
            .status()
            .unwrap()
            .success()
    );
    let completed = executor
        .wait(&session, &request("exec.status", OP))
        .await
        .unwrap();
    assert!(completed.result.timed_out);
    assert_eq!(completed.failure, Some(ErrorCode::ExecTimeout));
}

#[tokio::test]
async fn output_above_the_inline_threshold_is_sealed_in_a_private_read_only_spool() {
    use std::os::unix::fs::PermissionsExt;
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let payload = "z".repeat(65536);
    let mut start = start_request(&["/bin/sh", "-c", "printf '%s' \"$PAYLOAD\"; printf err >&2"]);
    start["params"]["env"] = json!({"PAYLOAD": payload});
    start["params"]["capture"]["max_inline_bytes"] = json!(16);
    executor.start(&session, &start).unwrap();
    let status = request("exec.status", OP);
    let completed = executor.wait(&session, &status).await.unwrap();
    assert_eq!(completed.result.state, ExecState::Succeeded);
    let OutputReference::Artifact {
        artifact_id,
        size_bytes,
    } = &completed.result.stdout
    else {
        panic!("large output must spill")
    };
    assert_eq!(*size_bytes, 65536);
    assert!(artifact_id.starts_with("art_"));
    let mut file = executor
        .open_output(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    assert_eq!(file.limit(), *size_bytes);
    assert_eq!(
        file.get_ref().metadata().unwrap().permissions().mode() & 0o077,
        0
    );
    let mut bytes = String::new();
    file.read_to_string(&mut bytes).unwrap();
    assert_eq!(bytes, payload);
    assert!(std::io::Write::write_all(file.get_mut(), b"altered").is_err());
    assert_eq!(inline(&completed.result.stderr), "err");
    assert!(
        executor
            .open_output(&session, &status, OutputStream::Stderr)
            .unwrap()
            .is_none()
    );
    let mut response = status;
    response["kind"] = json!("response");
    response.as_object_mut().unwrap().remove("params");
    response["result"] = serde_json::to_value(completed.result).unwrap();
    validate_message(&response).unwrap();
}

#[tokio::test]
async fn combined_stdout_and_stderr_overflow_stops_the_process_without_unbounded_spooling() {
    let spool = tempfile::tempdir().unwrap();
    let limits = ExecLimits {
        max_output_bytes: 1024,
        ..ExecLimits::default()
    };
    let mut executor = Executor::new(VM, 8, spool.path(), limits).unwrap();
    let session = session();
    let mut start = start_request(&[
        "/bin/sh",
        "-c",
        "while :; do printf 0123456789abcdef; printf fedcba9876543210 >&2; done",
    ]);
    start["params"]["capture"]["max_inline_bytes"] = json!(16);
    executor.start(&session, &start).unwrap();
    let status = request("exec.status", OP);
    let completed = tokio::time::timeout(Duration::from_secs(3), executor.wait(&session, &status))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(completed.result.state, ExecState::Failed);
    assert_eq!(completed.failure, Some(ErrorCode::OutputLimitExceeded));
    assert!(!completed.result.timed_out);
    let mut total = 0;
    for (stream, reference) in [
        (OutputStream::Stdout, &completed.result.stdout),
        (OutputStream::Stderr, &completed.result.stderr),
    ] {
        let size = match reference {
            OutputReference::Inline { size_bytes, .. }
            | OutputReference::Artifact { size_bytes, .. } => *size_bytes,
        };
        total += size;
        if let Some(mut file) = executor.open_output(&session, &status, stream).unwrap() {
            let mut bytes = Vec::new();
            file.read_to_end(&mut bytes).unwrap();
            assert_eq!(bytes.len() as u64, size);
        }
    }
    assert_eq!(total, 1024);
}

async fn read_ready_file(path: &std::path::Path) -> String {
    tokio::time::timeout(Duration::from_secs(3), async {
        let mut tick = tokio::time::interval(Duration::from_millis(5));
        loop {
            match tokio::fs::read_to_string(path).await {
                Ok(contents) if !contents.is_empty() => return contents,
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => panic!("ready-file read failed: {error}"),
            }
            tick.tick().await;
        }
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn cancelling_one_operation_stops_its_process_group_but_not_another_operation() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let ready = spool.path().join("child-ready");
    let mut start = start_request(&[
        "/bin/sh",
        "-c",
        "trap 'wait; exit 0' TERM; sleep 30 & printf '%s' \"$!\" > \"$READY_FILE\"; wait",
    ]);
    start["params"]["env"] = json!({"READY_FILE": ready});
    executor.start(&session, &start).unwrap();
    let child_pid: i32 = read_ready_file(&ready).await.parse().unwrap();
    let other_op = "op_01J00000000000000000000001";
    let mut other = start_request(&["/bin/sleep", "30"]);
    other["operation_id"] = json!(other_op);
    executor.start(&session, &other).unwrap();
    executor
        .cancel(&session, &request("exec.cancel", OP))
        .unwrap();
    let completed = tokio::time::timeout(
        Duration::from_secs(3),
        executor.wait(&session, &request("exec.status", OP)),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(completed.result.state, ExecState::Cancelled);
    assert!(!completed.result.timed_out);
    assert_eq!(
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(child_pid), None),
        Err(nix::errno::Errno::ESRCH)
    );
    assert_eq!(
        executor
            .status(&session, &request("exec.status", other_op))
            .unwrap()
            .result
            .state,
        ExecState::Running
    );
    executor
        .cancel(&session, &request("exec.cancel", other_op))
        .unwrap();
    let other = executor
        .wait(&session, &request("exec.status", other_op))
        .await
        .unwrap();
    assert_eq!(other.result.state, ExecState::Cancelled);
}

#[tokio::test]
async fn admission_and_retention_are_bounded_until_completed_outputs_are_released() {
    let spool = tempfile::tempdir().unwrap();
    let limits = ExecLimits {
        max_concurrent: 1,
        max_retained: 1,
        ..ExecLimits::default()
    };
    let mut executor = Executor::new(VM, 8, spool.path(), limits).unwrap();
    let session = session();
    executor
        .start(&session, &start_request(&["/bin/sleep", "30"]))
        .unwrap();
    let status = request("exec.status", OP);
    assert_eq!(
        executor.release(&session, &status).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
    let other_op = "op_01J00000000000000000000001";
    let mut other = start_request(&["/bin/echo", "next"]);
    other["operation_id"] = json!(other_op);
    assert_eq!(
        executor.start(&session, &other).unwrap_err().code,
        ErrorCode::ExecStartFailed
    );
    executor
        .cancel(&session, &request("exec.cancel", OP))
        .unwrap();
    executor.wait(&session, &status).await.unwrap();
    assert_eq!(
        executor.start(&session, &other).unwrap_err().code,
        ErrorCode::ExecStartFailed
    );
    executor.release(&session, &status).unwrap();
    assert_eq!(
        executor.status(&session, &status).unwrap_err().code,
        ErrorCode::ExecNotFound
    );
    executor.start(&session, &other).unwrap();
    let completed = executor
        .wait(&session, &request("exec.status", other_op))
        .await
        .unwrap();
    assert_eq!(completed.result.state, ExecState::Succeeded);
}

#[tokio::test]
async fn execution_cannot_bypass_negotiation_identity_or_generation_guards() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let not_ready =
        Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    let start = start_request(&["/bin/echo", "guarded"]);
    assert_eq!(
        executor.start(&not_ready, &start).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
    let session = session();
    for (field, value) in [
        ("vm_id", json!("vm_01J00000000000000000000001")),
        ("driver_generation", json!(9)),
    ] {
        let mut stale = start.clone();
        stale[field] = value;
        assert_eq!(
            executor.start(&session, &stale).unwrap_err().code,
            ErrorCode::InvalidRequest
        );
        stale["method"] = json!("exec.cancel");
        stale["params"] = json!({});
        assert_eq!(
            executor.cancel(&session, &stale).unwrap_err().code,
            ErrorCode::InvalidRequest
        );
    }
    let mut other = Executor::new(
        "vm_01J00000000000000000000001",
        8,
        spool.path(),
        ExecLimits::default(),
    )
    .unwrap();
    assert_eq!(
        other.start(&session, &start).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
    executor.start(&session, &start).unwrap();
    assert_eq!(
        executor
            .wait(&session, &request("exec.status", OP))
            .await
            .unwrap()
            .result
            .state,
        ExecState::Succeeded
    );
}

#[tokio::test]
async fn cwd_and_explicit_environment_apply_without_inheriting_parent_environment_or_stdin() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let mut start = start_request(&[
        "/bin/sh",
        "-c",
        "read -r line && exit 9; printf '%s|%s|%s' \"${HOME-unset}\" \"$GAOVM_TEST_VALUE\" \"$PWD\"",
    ]);
    let cwd = spool.path().canonicalize().unwrap();
    start["params"]["cwd"] = json!(cwd);
    start["params"]["env"] = json!({"GAOVM_TEST_VALUE": "supplied"});
    executor.start(&session, &start).unwrap();
    let completed = executor
        .wait(&session, &request("exec.status", OP))
        .await
        .unwrap();
    assert_eq!(completed.result.state, ExecState::Succeeded);
    assert_eq!(
        inline(&completed.result.stdout),
        format!("unset|supplied|{}", cwd.display())
    );
}

#[tokio::test]
async fn non_utf8_output_uses_a_lossless_binary_spool_instead_of_replacement_text() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    executor
        .start(
            &session,
            &start_request(&["/bin/sh", "-c", "printf '\\377\\000a'"]),
        )
        .unwrap();
    let status = request("exec.status", OP);
    let completed = executor.wait(&session, &status).await.unwrap();
    assert!(matches!(
        completed.result.stdout,
        OutputReference::Artifact { size_bytes: 3, .. }
    ));
    let mut bytes = Vec::new();
    executor
        .open_output(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    assert_eq!(bytes, [0xff, 0, b'a']);
}

#[tokio::test]
async fn shutdown_cancels_active_operations_and_rejects_new_execution_idempotently() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let start = start_request(&["/bin/sleep", "30"]);
    executor.start(&session, &start).unwrap();
    tokio::time::timeout(Duration::from_secs(3), executor.shutdown())
        .await
        .unwrap()
        .unwrap();
    let status = executor
        .status(&session, &request("exec.status", OP))
        .unwrap();
    assert_eq!(status.result.state, ExecState::Cancelled);
    assert_eq!(
        executor.start(&session, &start).unwrap_err().code,
        ErrorCode::ExecStartFailed
    );
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn failed_spawn_and_unknown_operations_return_stable_errors_without_echoing_inputs() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let mut start = start_request(&["/not-present/secret-must-not-appear"]);
    let failure = executor.start(&session, &start).unwrap_err();
    assert_eq!(failure.code, ErrorCode::ExecStartFailed);
    assert!(!failure.message.contains("secret-must-not-appear"));
    assert_eq!(
        executor
            .status(&session, &request("exec.status", OP))
            .unwrap_err()
            .code,
        ErrorCode::ExecNotFound
    );
    assert_eq!(
        executor
            .cancel(&session, &request("exec.cancel", OP))
            .unwrap_err()
            .code,
        ErrorCode::ExecNotFound
    );
    start["params"]["timeout_seconds"] = json!(0);
    assert_eq!(
        executor.start(&session, &start).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
    // A failed spawn must not retain a slot or prevent a later valid command.
    executor
        .start(&session, &start_request(&["/bin/echo", "recovered"]))
        .unwrap();
    assert_eq!(
        executor
            .wait(&session, &request("exec.status", OP))
            .await
            .unwrap()
            .result
            .state,
        ExecState::Succeeded
    );
}

#[tokio::test]
async fn disabling_capture_discards_output_without_consuming_the_spool_budget() {
    let spool = tempfile::tempdir().unwrap();
    let limits = ExecLimits {
        max_output_bytes: 1,
        ..ExecLimits::default()
    };
    let mut executor = Executor::new(VM, 8, spool.path(), limits).unwrap();
    let session = session();
    let mut start = start_request(&[
        "/bin/sh",
        "-c",
        "printf discarded-stdout; printf discarded-stderr >&2",
    ]);
    start["params"]["capture"] = json!({"stdout": false, "stderr": false, "max_inline_bytes": 0});
    executor.start(&session, &start).unwrap();
    let completed = executor
        .wait(&session, &request("exec.status", OP))
        .await
        .unwrap();
    assert_eq!(completed.result.state, ExecState::Succeeded);
    assert_eq!(inline(&completed.result.stdout), "");
    assert_eq!(inline(&completed.result.stderr), "");
    assert!(completed.failure.is_none());
}

#[tokio::test]
async fn dropping_the_executor_reaps_its_owned_process_and_preserves_parent_files() {
    let spool = tempfile::tempdir().unwrap();
    let sentinel = spool.path().join("user-owned");
    std::fs::write(&sentinel, b"preserve").unwrap();
    let ready = spool.path().join("leader-ready");
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let mut start = start_request(&[
        "/bin/sh",
        "-c",
        "printf '%s' \"$$\" > \"$READY_FILE\"; exec sleep 30",
    ]);
    start["params"]["env"] = json!({"READY_FILE": ready});
    executor.start(&session, &start).unwrap();
    let pid = nix::unistd::Pid::from_raw(read_ready_file(&ready).await.parse().unwrap());
    drop(executor);
    tokio::time::timeout(Duration::from_secs(3), async {
        let mut tick = tokio::time::interval(Duration::from_millis(5));
        loop {
            if nix::sys::signal::kill(pid, None) == Err(nix::errno::Errno::ESRCH) {
                break;
            }
            tick.tick().await;
        }
    })
    .await
    .unwrap();
    assert_eq!(std::fs::read(sentinel).unwrap(), b"preserve");
}

#[tokio::test]
async fn cancellation_escalates_when_an_owned_command_ignores_sigterm() {
    let spool = tempfile::tempdir().unwrap();
    let ready = spool.path().join("term-handler-ready");
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let mut start = start_request(&[
        "/bin/sh",
        "-c",
        "trap '' TERM; printf ready > \"$READY_FILE\"; while :; do :; done",
    ]);
    start["params"]["env"] = json!({"READY_FILE": ready});
    executor.start(&session, &start).unwrap();
    read_ready_file(&ready).await;
    executor
        .cancel(&session, &request("exec.cancel", OP))
        .unwrap();
    let completed = tokio::time::timeout(
        Duration::from_secs(3),
        executor.wait(&session, &request("exec.status", OP)),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(completed.result.state, ExecState::Cancelled);
    assert_eq!(
        completed.result.signal,
        Some(nix::sys::signal::Signal::SIGKILL as i32)
    );
}

#[test]
fn executor_requires_explicit_identity_valid_limits_and_an_owner_private_spool_parent() {
    use std::os::unix::fs::PermissionsExt;
    let spool = tempfile::tempdir().unwrap();
    for (vm, generation, limits) in [
        ("default", 8, ExecLimits::default()),
        (VM, 0, ExecLimits::default()),
        (
            VM,
            8,
            ExecLimits {
                max_concurrent: 0,
                ..ExecLimits::default()
            },
        ),
        (
            VM,
            8,
            ExecLimits {
                max_retained: 1,
                ..ExecLimits::default()
            },
        ),
        (
            VM,
            8,
            ExecLimits {
                max_output_bytes: 0,
                ..ExecLimits::default()
            },
        ),
    ] {
        assert_eq!(
            Executor::new(vm, generation, spool.path(), limits)
                .err()
                .unwrap()
                .code,
            ErrorCode::InvalidRequest
        );
    }
    std::fs::set_permissions(spool.path(), std::fs::Permissions::from_mode(0o777)).unwrap();
    assert_eq!(
        Executor::new(VM, 8, spool.path(), ExecLimits::default())
            .err()
            .unwrap()
            .code,
        ErrorCode::InvalidRequest
    );
    std::fs::set_permissions(spool.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
}
