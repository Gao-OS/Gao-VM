#![cfg(unix)]

use gaovm_guestd::control::{FrameReader, FrameWriter, negotiate};
use gaovm_guestd::exec::{ExecLimits, Executor, OutputStream};
use gaovm_guestd::protocol::{ErrorCode, validate_message};
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use serde_json::{Value, json};
use std::time::Duration;

const VM: &str = "vm_01J00000000000000000000000";
const OP: &str = "op_01J00000000000000000000000";

fn session() -> Session {
    session_with(&CORE_CAPABILITIES)
}

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

fn request(method: &str, id: &str) -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": id,
        "method": method, "vm_id": VM, "driver_generation": 8, "operation_id": OP, "params": {}})
}

fn start_request(argv: &[&str]) -> Value {
    let mut start = request("exec.start", "start-command");
    start["params"] = json!({"argv": argv, "cwd": "/", "env": {}, "timeout_seconds": 5,
        "capture": {"stdout": true, "stderr": true, "max_inline_bytes": 65536}});
    start
}

fn assert_correlation(response: &Value, request: &Value) {
    validate_message(response).unwrap();
    for field in ["id", "method", "vm_id", "driver_generation", "operation_id"] {
        assert_eq!(response[field], request[field]);
    }
}

#[tokio::test]
async fn exec_dispatch_returns_acceptance_and_the_real_nonzero_command_result() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let start = start_request(&["/bin/sh", "-c", "printf out; printf err >&2; exit 7"]);
    let accepted = executor.handle(&session, &start).unwrap();
    assert_correlation(&accepted, &start);
    assert_eq!(accepted["kind"], "response");
    assert_eq!(accepted["result"]["state"], "running");

    let status = request("exec.status", "read-command");
    tokio::time::timeout(Duration::from_secs(3), executor.wait(&session, &status))
        .await
        .unwrap()
        .unwrap();
    let completed = executor.handle(&session, &status).unwrap();
    assert_correlation(&completed, &status);
    assert_eq!(completed["kind"], "response");
    assert_eq!(completed["result"]["state"], "failed");
    assert_eq!(completed["result"]["exit_code"], 7);
    assert_eq!(completed["result"]["stdout"]["text"], "out");
    assert_eq!(completed["result"]["stderr"]["text"], "err");
    assert_eq!(completed["result"]["timed_out"], false);
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn an_execution_timeout_is_a_correlated_error_with_its_terminal_result() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let mut start = start_request(&["/bin/sleep", "30"]);
    start["params"]["timeout_seconds"] = json!(0.03);
    executor.handle(&session, &start).unwrap();
    let status = request("exec.status", "read-timeout");
    tokio::time::timeout(Duration::from_secs(3), executor.wait(&session, &status))
        .await
        .unwrap()
        .unwrap();
    let response = executor.handle(&session, &status).unwrap();
    assert_correlation(&response, &status);
    assert_eq!(response["kind"], "error");
    assert_eq!(response["error"]["code"], "EXEC_TIMEOUT");
    assert_eq!(response["error"]["retryable"], false);
    assert_eq!(response["error"]["details"]["result"]["state"], "failed");
    assert_eq!(response["error"]["details"]["result"]["timed_out"], true);
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn exec_cancel_acknowledges_the_request_and_status_observes_actual_exit() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    executor
        .handle(&session, &start_request(&["/bin/sleep", "30"]))
        .unwrap();
    let cancel = request("exec.cancel", "cancel-command");
    let accepted = executor.handle(&session, &cancel).unwrap();
    assert_correlation(&accepted, &cancel);
    assert_eq!(accepted["result"]["state"], "running");
    let status = request("exec.status", "read-cancelled-command");
    tokio::time::timeout(Duration::from_secs(3), executor.wait(&session, &status))
        .await
        .unwrap()
        .unwrap();
    let completed = executor.handle(&session, &status).unwrap();
    assert_correlation(&completed, &status);
    assert_eq!(completed["kind"], "response");
    assert_eq!(completed["result"]["state"], "cancelled");
    assert_eq!(completed["result"]["timed_out"], false);
    assert!(completed["result"]["signal"].is_number());
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn a_missing_execution_returns_a_correlated_wire_error() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let status = request("exec.status", "missing-command");
    let response = executor.handle(&session, &status).unwrap();
    assert_correlation(&response, &status);
    assert_eq!(response["kind"], "error");
    assert_eq!(response["error"]["code"], "EXEC_NOT_FOUND");
    assert_eq!(response["error"]["retryable"], false);
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn invalid_or_foreign_requests_are_rejected_before_execution_admission() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let ready = session();
    let start = start_request(&["/bin/echo", "must-not-execute"]);
    let unnegotiated =
        Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    assert_eq!(
        executor.handle(&unnegotiated, &start).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
    assert_eq!(
        executor
            .handle(&session_with(&["health"]), &start)
            .unwrap_err()
            .code,
        ErrorCode::CapabilityNotSupported
    );
    let mut foreign_vm = start.clone();
    foreign_vm["vm_id"] = json!("vm_01J00000000000000000000001");
    let mut stale_generation = start.clone();
    stale_generation["driver_generation"] = json!(7);
    let mut invalid_params = start.clone();
    invalid_params["params"]["timeout_seconds"] = json!(0);
    let mut missing_operation = start.clone();
    missing_operation
        .as_object_mut()
        .unwrap()
        .remove("operation_id");
    for invalid in [
        foreign_vm,
        stale_generation,
        invalid_params,
        missing_operation,
    ] {
        assert_eq!(
            executor.handle(&ready, &invalid).unwrap_err().code,
            ErrorCode::InvalidRequest
        );
    }
    let response = executor
        .handle(&ready, &request("exec.status", "no-admission"))
        .unwrap();
    assert_eq!(response["error"]["code"], "EXEC_NOT_FOUND");

    let mut foreign_executor = Executor::new(
        "vm_01J00000000000000000000001",
        8,
        spool.path(),
        ExecLimits::default(),
    )
    .unwrap();
    assert_eq!(
        foreign_executor.handle(&ready, &start).unwrap_err().code,
        ErrorCode::InvalidRequest
    );
    executor.shutdown().await.unwrap();
    foreign_executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn real_unix_frames_dispatch_exec_while_health_remains_responsive() {
    let spool = tempfile::tempdir().unwrap();
    let (host_socket, guest_socket) = tokio::net::UnixStream::pair().unwrap();
    let (host_read, host_write) = host_socket.into_split();
    let (guest_read, guest_write) = guest_socket.into_split();
    let deadline = || tokio::time::Instant::now() + Duration::from_secs(5);
    let guest = async {
        let mut reader = FrameReader::new(guest_read);
        let mut writer = FrameWriter::new(guest_write);
        let mut session =
            Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
        negotiate(&mut session, &mut reader, &mut writer, deadline())
            .await
            .unwrap();
        let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
        let system =
            gaovm_guestd::system::SystemQueries::new(VM, 8, std::path::Path::new("/")).unwrap();
        for _ in 0..4 {
            let request = reader.read_object(deadline()).await.unwrap().unwrap();
            let response = if request["method"] == "health" {
                system.handle(&session, &request).unwrap()
            } else {
                if request["method"] == "exec.status" {
                    // Test-only completion barrier, not a blocking status RPC.
                    executor.wait(&session, &request).await.unwrap();
                }
                executor.handle(&session, &request).unwrap()
            };
            writer.write_object(&response, deadline()).await.unwrap();
        }
        executor.shutdown().await.unwrap();
    };
    let host = async {
        let mut reader = FrameReader::new(host_read);
        let mut writer = FrameWriter::new(host_write);
        let mut session =
            Session::new(Role::Host, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
        negotiate(&mut session, &mut reader, &mut writer, deadline())
            .await
            .unwrap();
        let mut health = request("health", "health-during-exec");
        health["operation_id"] = Value::Null;
        for request in [
            start_request(&["/bin/sleep", "30"]),
            health,
            request("exec.cancel", "wire-cancel"),
            request("exec.status", "wire-status"),
        ] {
            writer.write_object(&request, deadline()).await.unwrap();
            let response = reader.read_object(deadline()).await.unwrap().unwrap();
            assert_correlation(&response, &request);
            assert_eq!(response["kind"], "response");
            match request["method"].as_str().unwrap() {
                "health" => assert_eq!(response["result"]["status"], "ok"),
                "exec.status" => assert_eq!(response["result"]["state"], "cancelled"),
                _ => assert_eq!(response["result"]["state"], "running"),
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(8), async {
        tokio::join!(host, guest);
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn a_spawn_failure_does_not_echo_command_or_environment_data() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let missing = spool.path().join("missing-private-command");
    let mut start = start_request(&[missing.to_str().unwrap(), "private-argument"]);
    start["params"]["env"] = json!({"PRIVATE_VALUE": "private-environment"});
    let response = executor.handle(&session, &start).unwrap();
    assert_correlation(&response, &start);
    assert_eq!(response["kind"], "error");
    assert_eq!(response["error"]["code"], "EXEC_START_FAILED");
    let wire = response.to_string();
    for private in [
        "missing-private-command",
        "private-argument",
        "PRIVATE_VALUE",
        "private-environment",
    ] {
        assert!(!wire.contains(private));
    }
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn dispatch_replays_an_operation_and_rejects_conflicting_input_without_respawning() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(
        VM,
        8,
        spool.path(),
        ExecLimits {
            max_concurrent: 1,
            max_retained: 1,
            ..ExecLimits::default()
        },
    )
    .unwrap();
    let session = session();
    let marker = spool.path().join("executions");
    let mut start = start_request(&["/bin/sh", "-c", "printf x >> \"$MARKER\"; cat \"$MARKER\""]);
    start["params"]["env"] = json!({"MARKER": marker});
    executor.handle(&session, &start).unwrap();
    let status = request("exec.status", "read-original");
    tokio::time::timeout(Duration::from_secs(3), executor.wait(&session, &status))
        .await
        .unwrap()
        .unwrap();
    let original = executor.handle(&session, &status).unwrap();
    let mut replay = start.clone();
    replay["id"] = json!("replay-command");
    let response = executor.handle(&session, &replay).unwrap();
    assert_correlation(&response, &replay);
    assert_eq!(response["result"], original["result"]);
    replay["params"]["argv"] = json!(["/bin/echo", "different"]);
    replay["id"] = json!("conflicting-command");
    let conflict = executor.handle(&session, &replay).unwrap();
    assert_correlation(&conflict, &replay);
    assert_eq!(conflict["kind"], "error");
    assert_eq!(conflict["error"]["code"], "INVALID_REQUEST");
    assert_eq!(std::fs::read_to_string(marker).unwrap(), "x");
    assert_eq!(
        executor.handle(&session, &status).unwrap()["result"],
        original["result"]
    );
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn output_overflow_stays_a_wire_error_with_bounded_captured_output() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(
        VM,
        8,
        spool.path(),
        ExecLimits {
            max_output_bytes: 16,
            ..ExecLimits::default()
        },
    )
    .unwrap();
    let session = session();
    executor
        .handle(
            &session,
            &start_request(&["/bin/echo", "abcdefghijklmnopqrstuvwxyz"]),
        )
        .unwrap();
    let status = request("exec.status", "read-overflow");
    tokio::time::timeout(Duration::from_secs(3), executor.wait(&session, &status))
        .await
        .unwrap()
        .unwrap();
    let response = executor.handle(&session, &status).unwrap();
    assert_correlation(&response, &status);
    assert_eq!(response["kind"], "error");
    assert_eq!(response["error"]["code"], "OUTPUT_LIMIT_EXCEEDED");
    let result = &response["error"]["details"]["result"];
    assert_eq!(result["state"], "failed");
    assert_eq!(result["stdout"]["size_bytes"], 16);
    assert_eq!(result["stdout"]["truncated"], true);
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn spilled_output_keeps_its_local_artifact_reference_and_lossless_bytes() {
    use std::io::Read;
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let mut start = start_request(&["/bin/echo", "abc"]);
    start["params"]["capture"]["max_inline_bytes"] = json!(2);
    executor.handle(&session, &start).unwrap();
    let status = request("exec.status", "read-spilled-output");
    tokio::time::timeout(Duration::from_secs(3), executor.wait(&session, &status))
        .await
        .unwrap()
        .unwrap();
    let response = executor.handle(&session, &status).unwrap();
    assert_correlation(&response, &status);
    assert_eq!(response["kind"], "response");
    let stdout = &response["result"]["stdout"];
    assert_eq!(stdout["mode"], "artifact");
    assert_eq!(stdout["size_bytes"], 4);
    assert!(stdout["artifact_id"].as_str().unwrap().starts_with("art_"));
    let mut bytes = Vec::new();
    executor
        .open_output(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    assert_eq!(bytes, b"abc\n");
    executor.shutdown().await.unwrap();
}
