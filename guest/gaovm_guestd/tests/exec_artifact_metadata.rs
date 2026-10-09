#![cfg(unix)]

use gaovm_guestd::exec::{ExecLimits, Executor, OutputStream};
use gaovm_guestd::protocol::{ErrorCode, validate_message};
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use serde_json::{Value, json};
use std::io::Read;
use std::time::Duration;

const VM: &str = "vm_01J00000000000000000000000";
const OP: &str = "op_01J00000000000000000000000";

fn session_with(vm: &str, generation: u64, capabilities: &[&str]) -> Session {
    let mut host = Session::new(Role::Host, vm, generation, capabilities, capabilities).unwrap();
    let mut guest = Session::new(
        Role::Guest,
        vm,
        generation,
        &CORE_CAPABILITIES,
        capabilities,
    )
    .unwrap();
    let host_hello = host.hello().unwrap();
    let guest_hello = guest.hello().unwrap();
    let host_ack = guest.receive_hello(&host_hello).unwrap().unwrap();
    let guest_ack = host.receive_hello(&guest_hello).unwrap().unwrap();
    host.receive_hello(&host_ack).unwrap();
    guest.receive_hello(&guest_ack).unwrap();
    guest
}

fn session() -> Session {
    session_with(VM, 8, &CORE_CAPABILITIES)
}

fn request(method: &str, operation: &str) -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "metadata-test",
        "method": method, "vm_id": VM, "driver_generation": 8, "operation_id": operation, "params": {}})
}

fn start_request(command: &str) -> Value {
    let mut start = request("exec.start", OP);
    start["params"] = json!({"argv": ["/bin/sh", "-c", command], "cwd": "/", "env": {},
        "timeout_seconds": 5, "capture": {"stdout": true, "stderr": true, "max_inline_bytes": 0}});
    start
}

async fn complete(executor: &Executor, session: &Session, status: &Value) {
    tokio::time::timeout(Duration::from_secs(5), executor.wait(session, status))
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn spilled_stdout_retains_its_sealed_digest_without_changing_the_control_result() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    executor
        .start(&session, &start_request("printf 'hello world'"))
        .unwrap();
    let status = request("exec.status", OP);
    complete(&executor, &session, &status).await;

    let info = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    assert_eq!(info.kind, "stdout");
    assert_eq!(info.content_type, "application/octet-stream");
    assert_eq!(info.size_bytes, 11);
    assert_eq!(
        info.digest,
        "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    );
    let response = executor.handle(&session, &status).unwrap();
    validate_message(&response).unwrap();
    assert_eq!(
        response["result"]["stdout"],
        json!({"mode": "artifact", "artifact_id": info.artifact_id, "size_bytes": 11})
    );
    let mut bytes = String::new();
    executor
        .open_output(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap()
        .read_to_string(&mut bytes)
        .unwrap();
    assert_eq!(bytes, "hello world");
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn failed_commands_keep_independent_stdout_and_stderr_artifact_metadata() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    executor
        .start(
            &session,
            &start_request("printf abc; printf 'hello world' >&2; exit 7"),
        )
        .unwrap();
    let status = request("exec.status", OP);
    complete(&executor, &session, &status).await;
    let stdout = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    let stderr = executor
        .output_artifact(&session, &status, OutputStream::Stderr)
        .unwrap()
        .unwrap();
    assert_ne!(stdout.artifact_id, stderr.artifact_id);
    assert_eq!(stdout.kind, "stdout");
    assert_eq!(stdout.size_bytes, 3);
    assert_eq!(
        stdout.digest,
        "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(stderr.kind, "stderr");
    assert_eq!(stderr.content_type, "application/octet-stream");
    assert_eq!(stderr.size_bytes, 11);
    assert_eq!(
        stderr.digest,
        "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    );
    let response = executor.handle(&session, &status).unwrap();
    validate_message(&response).unwrap();
    assert_eq!(response["kind"], "response");
    assert_eq!(response["result"]["state"], "failed");
    assert_eq!(response["result"]["exit_code"], 7);
    assert_eq!(
        response["result"]["stderr"]["artifact_id"],
        stderr.artifact_id
    );
    assert_eq!(
        response["result"]["stdout"]["artifact_id"],
        stdout.artifact_id
    );
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn non_utf8_output_has_lossless_artifact_metadata_even_below_the_inline_limit() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let mut start = start_request("printf '\\377\\000a'");
    start["params"]["capture"]["max_inline_bytes"] = json!(65536);
    executor.start(&session, &start).unwrap();
    let status = request("exec.status", OP);
    complete(&executor, &session, &status).await;
    let info = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    assert_eq!(info.size_bytes, 3);
    assert_eq!(
        info.digest,
        "sha256:f9789675a25a87605b0d60387568e25cda7b568653ecdc42e9248588dc70acd5"
    );
    let mut bytes = Vec::new();
    executor
        .open_output(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    assert_eq!(bytes, [255, 0, b'a']);
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn multi_chunk_output_keeps_a_complete_digest_and_a_size_bounded_reader() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    executor
        .start(
            &session,
            &start_request("dd if=/dev/zero bs=8192 count=256 2>/dev/null"),
        )
        .unwrap();
    let status = request("exec.status", OP);
    complete(&executor, &session, &status).await;
    let info = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    assert_eq!(info.size_bytes, 2 * 1024 * 1024);
    assert_eq!(
        info.digest,
        "sha256:5647f05ec18958947d32874eeb788fa396a05d0bab7c1b71f112ceb7e9b31eee"
    );
    let mut reader = executor
        .open_output(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    assert_eq!(reader.limit(), info.size_bytes);
    let mut buffer = [0u8; 8192];
    let mut size = 0;
    loop {
        let read = reader.read(&mut buffer).unwrap();
        if read == 0 {
            break;
        }
        assert!(buffer[..read].iter().all(|byte| *byte == 0));
        size += read as u64;
    }
    assert_eq!(size, info.size_bytes);
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn metadata_reads_require_negotiated_capability_and_exact_execution_binding() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let start = start_request("printf 'hello world'");
    executor.start(&session, &start).unwrap();
    let status = request("exec.status", OP);
    complete(&executor, &session, &status).await;

    let unready = Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &CORE_CAPABILITIES).unwrap();
    assert_eq!(
        executor
            .output_artifact(&unready, &status, OutputStream::Stdout)
            .unwrap_err()
            .code,
        ErrorCode::InvalidRequest
    );
    assert_eq!(
        executor
            .output_artifact(
                &session_with(VM, 8, &["health"]),
                &status,
                OutputStream::Stdout
            )
            .unwrap_err()
            .code,
        ErrorCode::CapabilityNotSupported
    );
    let mut foreign_vm = status.clone();
    foreign_vm["vm_id"] = json!("vm_01J00000000000000000000001");
    let mut old_generation = status.clone();
    old_generation["driver_generation"] = json!(7);
    let mut missing_operation = status.clone();
    missing_operation["operation_id"] = Value::Null;
    let mut malformed = status.clone();
    malformed["params"]["unexpected"] = json!(true);
    for invalid in [
        &foreign_vm,
        &old_generation,
        &missing_operation,
        &malformed,
        &start,
    ] {
        assert_eq!(
            executor
                .output_artifact(&session, invalid, OutputStream::Stdout)
                .unwrap_err()
                .code,
            ErrorCode::InvalidRequest
        );
    }
    assert_eq!(
        executor
            .output_artifact(
                &session_with("vm_01J00000000000000000000001", 8, &CORE_CAPABILITIES),
                &foreign_vm,
                OutputStream::Stdout,
            )
            .unwrap_err()
            .code,
        ErrorCode::InvalidRequest
    );
    assert_eq!(
        executor
            .output_artifact(
                &session_with(VM, 7, &CORE_CAPABILITIES),
                &old_generation,
                OutputStream::Stdout,
            )
            .unwrap_err()
            .code,
        ErrorCode::InvalidRequest
    );
    assert_eq!(
        executor
            .output_artifact(
                &session,
                &request("exec.status", "op_01J00000000000000000000001"),
                OutputStream::Stdout,
            )
            .unwrap_err()
            .code,
        ErrorCode::ExecNotFound
    );
    assert_eq!(
        executor
            .output_artifact(&session, &status, OutputStream::Stdout)
            .unwrap()
            .unwrap()
            .size_bytes,
        11
    );
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn running_inline_empty_and_disabled_outputs_do_not_invent_artifact_metadata() {
    for case in ["running", "inline", "empty", "disabled"] {
        let spool = tempfile::tempdir().unwrap();
        let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
        let session = session();
        let mut start = start_request(match case {
            "running" => "sleep 30",
            "empty" => "true",
            _ => "printf 'hello world'; printf abc >&2",
        });
        if case == "inline" {
            start["params"]["capture"]["max_inline_bytes"] = json!(65536);
        }
        if case == "disabled" {
            start["params"]["capture"]["stdout"] = json!(false);
            start["params"]["capture"]["stderr"] = json!(false);
        }
        executor.start(&session, &start).unwrap();
        let status = request("exec.status", OP);
        if case == "running" {
            assert_eq!(
                executor
                    .output_artifact(&session, &status, OutputStream::Stdout)
                    .unwrap_err()
                    .code,
                ErrorCode::InvalidRequest
            );
            executor
                .cancel(&session, &request("exec.cancel", OP))
                .unwrap();
        }
        complete(&executor, &session, &status).await;
        for stream in [OutputStream::Stdout, OutputStream::Stderr] {
            assert!(
                executor
                    .output_artifact(&session, &status, stream)
                    .unwrap()
                    .is_none(),
                "{case} must not produce a spool descriptor"
            );
        }
        executor.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn later_spool_corruption_cannot_redefine_the_original_capture_digest() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    executor
        .start(&session, &start_request("printf 'hello world'"))
        .unwrap();
    let status = request("exec.status", OP);
    complete(&executor, &session, &status).await;
    let original = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();

    // Fault injection at the filesystem boundary, beneath this test's owned root.
    // The metadata API must not recompute its digest from these altered bytes.
    let directories: Vec<_> = std::fs::read_dir(spool.path())
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    assert_eq!(directories.len(), 1);
    let files: Vec<_> = std::fs::read_dir(&directories[0])
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect();
    assert_eq!(files.len(), 1);
    std::fs::write(&files[0], b"HELLO WORLD").unwrap();
    let retained = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    assert_eq!(retained.digest, original.digest);
    assert_eq!(retained.artifact_id, original.artifact_id);
    assert_eq!(retained.size_bytes, 11);
    let mut bytes = String::new();
    executor
        .open_output(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap()
        .read_to_string(&mut bytes)
        .unwrap();
    assert_eq!(bytes, "HELLO WORLD");
    assert_ne!(bytes, "hello world");

    std::fs::remove_file(&files[0]).unwrap();
    assert_eq!(
        executor
            .output_artifact(&session, &status, OutputStream::Stdout)
            .unwrap()
            .unwrap()
            .digest,
        original.digest
    );
    assert_eq!(
        executor
            .open_output(&session, &status, OutputStream::Stdout)
            .unwrap_err()
            .code,
        ErrorCode::GuestInternalError
    );
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn overflow_metadata_describes_only_the_retained_prefix_not_a_successful_command() {
    let spool = tempfile::tempdir().unwrap();
    let limits = ExecLimits {
        max_output_bytes: 5,
        ..ExecLimits::default()
    };
    let mut executor = Executor::new(VM, 8, spool.path(), limits).unwrap();
    let session = session();
    executor
        .start(&session, &start_request("printf 'hello world'"))
        .unwrap();
    let status = request("exec.status", OP);
    complete(&executor, &session, &status).await;
    let info = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    assert_eq!(info.size_bytes, 5);
    assert_eq!(
        info.digest,
        "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    );
    let mut bytes = String::new();
    executor
        .open_output(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap()
        .read_to_string(&mut bytes)
        .unwrap();
    assert_eq!(bytes, "hello");
    let response = executor.handle(&session, &status).unwrap();
    validate_message(&response).unwrap();
    assert_eq!(response["kind"], "error");
    assert_eq!(response["error"]["code"], "OUTPUT_LIMIT_EXCEEDED");
    assert_eq!(response["error"]["details"]["result"]["state"], "failed");
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn replay_preserves_metadata_and_release_retires_it_without_invalidating_an_open_reader() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let marker = spool.path().join("executions");
    let mut start = start_request("printf x >> \"$MARKER\"; printf 'hello world'");
    start["params"]["env"] = json!({"MARKER": marker});
    executor.start(&session, &start).unwrap();
    let status = request("exec.status", OP);
    complete(&executor, &session, &status).await;
    let original = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    let mut replay = start.clone();
    replay["id"] = json!("replayed-start");
    executor.start(&session, &replay).unwrap();
    let retained = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    assert_eq!(
        serde_json::to_value(&retained).unwrap(),
        serde_json::to_value(&original).unwrap()
    );
    assert_eq!(std::fs::read_to_string(&marker).unwrap(), "x");
    replay["params"]["argv"] = json!(["/bin/echo", "conflicting"]);
    assert_eq!(
        executor.start(&session, &replay).unwrap_err().code,
        ErrorCode::InvalidRequest
    );

    let mut reader = executor
        .open_output(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    executor.shutdown().await.unwrap();
    assert_eq!(
        executor
            .output_artifact(&session, &status, OutputStream::Stdout)
            .unwrap()
            .unwrap()
            .digest,
        original.digest
    );
    executor.release(&session, &status).unwrap();
    assert_eq!(
        executor
            .output_artifact(&session, &status, OutputStream::Stdout)
            .unwrap_err()
            .code,
        ErrorCode::ExecNotFound
    );
    let mut bytes = String::new();
    reader.read_to_string(&mut bytes).unwrap();
    assert_eq!(bytes, "hello world");
}

#[tokio::test]
async fn cancellation_keeps_sealed_partial_output_without_claiming_command_success() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let marker = spool.path().join("ready");
    let mut start = start_request("printf 'hello world'; : > \"$READY\"; sleep 30");
    start["params"]["env"] = json!({"READY": marker});
    executor.start(&session, &start).unwrap();
    tokio::time::timeout(Duration::from_secs(3), async {
        while !marker.exists() {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
    executor
        .cancel(&session, &request("exec.cancel", OP))
        .unwrap();
    let status = request("exec.status", OP);
    complete(&executor, &session, &status).await;
    let info = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    assert_eq!(info.size_bytes, 11);
    assert_eq!(
        info.digest,
        "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    );
    let response = executor.handle(&session, &status).unwrap();
    validate_message(&response).unwrap();
    assert_eq!(response["kind"], "response");
    assert_eq!(response["result"]["state"], "cancelled");
    assert_eq!(
        response["result"]["stdout"]["artifact_id"],
        info.artifact_id
    );
    assert!(
        executor
            .output_artifact(&session, &status, OutputStream::Stderr)
            .unwrap()
            .is_none()
    );
    executor.shutdown().await.unwrap();
}

#[tokio::test]
async fn timeout_retains_output_metadata_alongside_the_terminal_failure() {
    let spool = tempfile::tempdir().unwrap();
    let mut executor = Executor::new(VM, 8, spool.path(), ExecLimits::default()).unwrap();
    let session = session();
    let mut start = start_request("printf 'hello world'; sleep 30");
    start["params"]["timeout_seconds"] = json!(1);
    executor.start(&session, &start).unwrap();
    let status = request("exec.status", OP);
    complete(&executor, &session, &status).await;
    let info = executor
        .output_artifact(&session, &status, OutputStream::Stdout)
        .unwrap()
        .unwrap();
    assert_eq!(info.size_bytes, 11);
    assert_eq!(
        info.digest,
        "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    );
    let response = executor.handle(&session, &status).unwrap();
    validate_message(&response).unwrap();
    assert_eq!(response["kind"], "error");
    assert_eq!(response["error"]["code"], "EXEC_TIMEOUT");
    assert_eq!(response["error"]["details"]["result"]["timed_out"], true);
    assert_eq!(response["error"]["details"]["result"]["state"], "failed");
    assert_eq!(
        response["error"]["details"]["result"]["stdout"]["artifact_id"],
        info.artifact_id
    );
    executor.shutdown().await.unwrap();
}
