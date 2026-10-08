#![cfg(unix)]

use gaovm_guestd::artifact::{ArtifactCollector, ArtifactLimits};
use gaovm_guestd::session::{CORE_CAPABILITIES, Role, Session};
use serde_json::{Value, json};
use std::io::Read;

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

fn request(paths: &[&str], max_bytes: u64) -> Value {
    json!({"protocol_version": "gaovm.guest.v1", "kind": "request", "id": "collect-test",
        "method": "artifact.collect", "vm_id": VM, "driver_generation": 8, "operation_id": OP,
        "params": {"paths": paths.iter().map(|path| json!({"path": path, "kind": "test_result"})).collect::<Vec<_>>(),
        "max_total_bytes": max_bytes}})
}

#[tokio::test]
async fn collected_bytes_are_private_lossless_and_bound_to_the_operation() {
    use std::os::unix::fs::PermissionsExt;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result.bin"), b"hello world").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let session = session();
    let request = request(&["result.bin"], 11);
    let result = collector.collect(&session, &request).await.unwrap();
    assert_eq!(result.vm_id, VM);
    assert_eq!(result.driver_generation, 8);
    assert_eq!(result.operation_id, OP);
    let info = &result.artifacts[0];
    assert_eq!(info.kind, "test_result");
    assert_eq!(info.content_type, "application/octet-stream");
    assert_eq!(info.size_bytes, 11);
    assert_eq!(
        info.digest,
        "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    );
    assert!(info.artifact_id.starts_with("art_"));
    let mut bytes = Vec::new();
    collector
        .open_artifact(&session, &request, &info.artifact_id)
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    assert_eq!(bytes, b"hello world");
    let owned = std::fs::read_dir(spool.path())
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert_eq!(
        owned.metadata().unwrap().permissions().mode() & 0o777,
        0o700
    );
    let file = std::fs::read_dir(owned)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert_eq!(file.metadata().unwrap().permissions().mode() & 0o777, 0o600);
}

#[tokio::test]
async fn retained_replays_keep_the_original_bytes_and_reject_conflicting_inputs() {
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("result.bin"), b"first").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let session = session();
    let request = request(&["result.bin"], 16);
    let first = collector.collect(&session, &request).await.unwrap();
    std::fs::write(source.path().join("result.bin"), b"changed").unwrap();
    let mut retry = request.clone();
    retry["id"] = json!("retry");
    retry["params"]["follow_symlinks"] = json!(false);
    let replay = collector.collect(&session, &retry).await.unwrap();
    assert_eq!(
        replay.artifacts[0].artifact_id,
        first.artifacts[0].artifact_id
    );
    let mut bytes = Vec::new();
    collector
        .open_artifact(&session, &retry, &first.artifacts[0].artifact_id)
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    assert_eq!(bytes, b"first");
    retry["params"]["max_total_bytes"] = json!(15);
    assert_eq!(
        collector.collect(&session, &retry).await.unwrap_err().code,
        gaovm_guestd::protocol::ErrorCode::InvalidRequest
    );
}

#[tokio::test]
async fn retention_and_total_storage_budgets_reject_new_collections() {
    use gaovm_guestd::protocol::ErrorCode;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("a"), b"1234").unwrap();
    let limits = ArtifactLimits {
        max_collection_bytes: 4,
        max_stored_bytes: 4,
        max_retained: 2,
    };
    let mut collector = ArtifactCollector::new(VM, 8, source.path(), spool.path(), limits).unwrap();
    let session = session();
    let first = request(&["a"], 4);
    let mut second = first.clone();
    second["operation_id"] = json!("op_01J00000000000000000000001");
    let accepted = collector.collect(&session, &first).await.unwrap();
    assert_eq!(
        collector.collect(&session, &second).await.unwrap_err().code,
        ErrorCode::ArtifactLimitExceeded
    );
    assert_eq!(
        collector.collect(&session, &first).await.unwrap().artifacts[0].artifact_id,
        accepted.artifacts[0].artifact_id
    );

    let limits = ArtifactLimits {
        max_collection_bytes: 4,
        max_stored_bytes: 8,
        max_retained: 1,
    };
    let mut collector = ArtifactCollector::new(VM, 8, source.path(), spool.path(), limits).unwrap();
    collector.collect(&session, &first).await.unwrap();
    assert_eq!(
        collector.collect(&session, &second).await.unwrap_err().code,
        ErrorCode::ArtifactLimitExceeded
    );
}

#[tokio::test]
async fn release_reclaims_capacity_but_already_open_readers_keep_the_sealed_bytes() {
    use gaovm_guestd::protocol::ErrorCode;
    use std::io::Write;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("a"), b"1234").unwrap();
    let limits = ArtifactLimits {
        max_collection_bytes: 4,
        max_stored_bytes: 4,
        max_retained: 1,
    };
    let mut collector = ArtifactCollector::new(VM, 8, source.path(), spool.path(), limits).unwrap();
    let session = session();
    let first = request(&["a"], 4);
    let info = collector
        .collect(&session, &first)
        .await
        .unwrap()
        .artifacts
        .remove(0);
    let mut reader = collector
        .open_artifact(&session, &first, &info.artifact_id)
        .unwrap();
    assert!(reader.get_mut().write_all(b"must not write").is_err());
    collector.release(&session, &first).unwrap();
    assert_eq!(
        collector
            .open_artifact(&session, &first, &info.artifact_id)
            .unwrap_err()
            .code,
        ErrorCode::ArtifactNotFound
    );
    let mut second = first.clone();
    second["operation_id"] = json!("op_01J00000000000000000000001");
    collector.collect(&session, &second).await.unwrap();
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, b"1234");
}

#[tokio::test]
async fn paths_cannot_escape_through_traversal_links_or_writable_entries() {
    use gaovm_guestd::protocol::ErrorCode;
    use std::os::unix::fs::{PermissionsExt, symlink};

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("secret"), b"not an artifact").unwrap();
    std::fs::write(source.path().join("good"), b"ok").unwrap();
    std::fs::create_dir(source.path().join("nested")).unwrap();
    std::fs::write(source.path().join("nested/good"), b"nested").unwrap();
    symlink(outside.path().join("secret"), source.path().join("link")).unwrap();
    symlink(outside.path(), source.path().join("linked-dir")).unwrap();
    std::fs::hard_link(
        outside.path().join("secret"),
        source.path().join("hard-link"),
    )
    .unwrap();
    std::fs::write(source.path().join("writable"), b"not trusted").unwrap();
    std::fs::set_permissions(
        source.path().join("writable"),
        std::fs::Permissions::from_mode(0o666),
    )
    .unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let session = session();
    for path in [
        "../secret",
        "nested/../good",
        "./good",
        "nested/./good",
        "nested//good",
        "good\0suffix",
    ] {
        assert_eq!(
            collector
                .collect(&session, &request(&[path], 1024))
                .await
                .unwrap_err()
                .code,
            ErrorCode::InvalidRequest,
            "{path}"
        );
    }
    let absolute = outside.path().join("secret");
    assert_eq!(
        collector
            .collect(&session, &request(&[absolute.to_str().unwrap()], 1024))
            .await
            .unwrap_err()
            .code,
        ErrorCode::InvalidRequest
    );
    for path in [
        "link",
        "linked-dir/secret",
        "hard-link",
        "nested",
        "writable",
        "missing",
    ] {
        assert_eq!(
            collector
                .collect(&session, &request(&[path], 1024))
                .await
                .unwrap_err()
                .code,
            ErrorCode::ArtifactNotFound,
            "{path}"
        );
    }
    assert_eq!(
        collector
            .collect(&session, &request(&["nested/good"], 1024))
            .await
            .unwrap()
            .artifacts[0]
            .size_bytes,
        6
    );
    assert_eq!(std::fs::read(absolute).unwrap(), b"not an artifact");
}

#[tokio::test]
async fn special_files_are_rejected_without_waiting_for_a_writer() {
    use gaovm_guestd::protocol::ErrorCode;
    use nix::sys::stat::Mode;
    use nix::unistd::mkfifo;
    use std::time::Duration;

    const CHILD: &str = "GAOVM_ARTIFACT_SPECIAL_FILE_CHILD";
    if std::env::var_os(CHILD).is_none() {
        let output = tokio::time::timeout(
            Duration::from_secs(5),
            tokio::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "special_files_are_rejected_without_waiting_for_a_writer",
                    "--nocapture",
                ])
                .env(CHILD, "1")
                .kill_on_drop(true)
                .output(),
        )
        .await
        .expect("special-file open must not block")
        .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    mkfifo(&source.path().join("fifo"), Mode::S_IRUSR | Mode::S_IWUSR).unwrap();
    let _socket = std::os::unix::net::UnixListener::bind(source.path().join("socket")).unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    for path in ["fifo", "socket"] {
        assert_eq!(
            collector
                .collect(&session(), &request(&[path], 1024))
                .await
                .unwrap_err()
                .code,
            ErrorCode::ArtifactNotFound
        );
    }
}

#[tokio::test]
async fn failed_collection_publishes_nothing_and_does_not_consume_retention_or_bytes() {
    use gaovm_guestd::protocol::ErrorCode;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("a"), b"123").unwrap();
    std::fs::write(source.path().join("b"), b"456").unwrap();
    let limits = ArtifactLimits {
        max_collection_bytes: 6,
        max_stored_bytes: 6,
        max_retained: 1,
    };
    let mut collector = ArtifactCollector::new(VM, 8, source.path(), spool.path(), limits).unwrap();
    let session = session();
    let limited = request(&["a", "b"], 5);
    assert_eq!(
        collector
            .collect(&session, &limited)
            .await
            .unwrap_err()
            .code,
        ErrorCode::ArtifactLimitExceeded
    );
    assert_eq!(
        collector
            .open_artifact(&session, &limited, "unknown")
            .unwrap_err()
            .code,
        ErrorCode::ArtifactNotFound
    );
    let owned = std::fs::read_dir(spool.path())
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert_eq!(std::fs::read_dir(&owned).unwrap().count(), 0);
    assert_eq!(
        collector
            .collect(&session, &request(&["a", "missing"], 6))
            .await
            .unwrap_err()
            .code,
        ErrorCode::ArtifactNotFound
    );
    assert_eq!(std::fs::read_dir(&owned).unwrap().count(), 0);
    let accepted = collector
        .collect(&session, &request(&["a", "b"], 6))
        .await
        .unwrap();
    assert_eq!(accepted.artifacts.len(), 2);
    assert_eq!(
        accepted
            .artifacts
            .iter()
            .map(|info| info.size_bytes)
            .sum::<u64>(),
        6
    );
}

#[tokio::test]
async fn collection_reads_and_release_require_a_negotiated_correctly_bound_session() {
    use gaovm_guestd::protocol::ErrorCode;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("a"), b"data").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let first = request(&["a"], 4);
    let unready = Session::new(Role::Guest, VM, 8, &CORE_CAPABILITIES, &[]).unwrap();
    assert_eq!(
        collector.collect(&unready, &first).await.unwrap_err().code,
        ErrorCode::InvalidRequest
    );
    assert_eq!(
        collector
            .collect(&session_with(&["health"]), &first)
            .await
            .unwrap_err()
            .code,
        ErrorCode::CapabilityNotSupported
    );
    let session = session();
    let id = collector
        .collect(&session, &first)
        .await
        .unwrap()
        .artifacts
        .remove(0)
        .artifact_id;
    for (field, value) in [
        ("vm_id", json!("vm_01J00000000000000000000001")),
        ("driver_generation", json!(7)),
        ("method", json!("exec.start")),
    ] {
        let mut stale = first.clone();
        stale[field] = value;
        assert_eq!(
            collector.collect(&session, &stale).await.unwrap_err().code,
            ErrorCode::InvalidRequest
        );
        assert_eq!(
            collector
                .open_artifact(&session, &stale, &id)
                .unwrap_err()
                .code,
            ErrorCode::InvalidRequest
        );
        assert_eq!(
            collector.release(&session, &stale).unwrap_err().code,
            ErrorCode::InvalidRequest
        );
    }
    let mut other = first.clone();
    other["operation_id"] = json!("op_01J00000000000000000000001");
    assert_eq!(
        collector
            .open_artifact(&session, &other, &id)
            .unwrap_err()
            .code,
        ErrorCode::ArtifactNotFound
    );
    let mut other_collector = ArtifactCollector::new(
        VM,
        9,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    assert_eq!(
        other_collector
            .collect(&session, &first)
            .await
            .unwrap_err()
            .code,
        ErrorCode::InvalidRequest
    );
    collector.open_artifact(&session, &first, &id).unwrap();
}

#[tokio::test]
async fn the_source_root_is_pinned_even_if_its_original_path_is_replaced() {
    use std::os::unix::fs::symlink;

    let parent = tempfile::tempdir().unwrap();
    let root = parent.path().join("root");
    std::fs::create_dir(&root).unwrap();
    std::fs::write(root.join("a"), b"original").unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("a"), b"replacement").unwrap();
    let spool = tempfile::tempdir().unwrap();
    let mut collector =
        ArtifactCollector::new(VM, 8, &root, spool.path(), ArtifactLimits::default()).unwrap();
    std::fs::rename(&root, parent.path().join("original")).unwrap();
    symlink(outside.path(), &root).unwrap();
    let session = session();
    let request = request(&["a"], 64);
    let id = collector
        .collect(&session, &request)
        .await
        .unwrap()
        .artifacts
        .remove(0)
        .artifact_id;
    let mut bytes = Vec::new();
    collector
        .open_artifact(&session, &request, &id)
        .unwrap()
        .read_to_end(&mut bytes)
        .unwrap();
    assert_eq!(bytes, b"original");
}

#[tokio::test]
async fn empty_binary_and_multichunk_files_keep_exact_bounded_bytes() {
    use std::io::Write;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("empty"), b"").unwrap();
    let payload: Vec<_> = (0..65536).map(|i| (i % 256) as u8).collect();
    std::fs::write(source.path().join("binary"), &payload).unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let session = session();
    let empty = request(&["empty"], 0);
    let result = collector.collect(&session, &empty).await.unwrap();
    assert_eq!(
        result.artifacts[0].digest,
        "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
    collector.release(&session, &empty).unwrap();
    let binary = request(&["binary"], 65536);
    let result = collector.collect(&session, &binary).await.unwrap();
    let owned = std::fs::read_dir(spool.path())
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let file = std::fs::read_dir(owned)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    std::fs::OpenOptions::new()
        .append(true)
        .open(file)
        .unwrap()
        .write_all(b"not in declared artifact")
        .unwrap();
    let mut reader = collector
        .open_artifact(&session, &binary, &result.artifacts[0].artifact_id)
        .unwrap();
    assert_eq!(reader.limit(), 65536);
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes).unwrap();
    assert_eq!(bytes, payload);
}

#[tokio::test]
async fn dropping_an_in_flight_collection_discards_partial_spools_and_allows_retry() {
    use std::future::Future;
    use std::task::Poll;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::File::create(source.path().join("large"))
        .unwrap()
        .set_len(8 * 1024 * 1024)
        .unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let session = session();
    let request = request(&["large"], 8 * 1024 * 1024);
    let mut pending = Box::pin(collector.collect(&session, &request));
    std::future::poll_fn(|context| {
        assert!(pending.as_mut().poll(context).is_pending());
        Poll::Ready(())
    })
    .await;
    drop(pending);
    let owned = std::fs::read_dir(spool.path())
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert_eq!(std::fs::read_dir(owned).unwrap().count(), 0);
    let result = collector.collect(&session, &request).await.unwrap();
    assert_eq!(result.artifacts[0].size_bytes, 8 * 1024 * 1024);
}

#[tokio::test]
async fn an_observed_source_change_discards_the_entire_collection() {
    use gaovm_guestd::protocol::ErrorCode;
    use std::future::Future;
    use std::task::Poll;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let file = std::fs::File::create(source.path().join("changing")).unwrap();
    file.set_len(8 * 1024 * 1024).unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let session = session();
    let request = request(&["changing"], 8 * 1024 * 1024);
    let mut pending = Box::pin(collector.collect(&session, &request));
    std::future::poll_fn(|context| {
        assert!(pending.as_mut().poll(context).is_pending());
        Poll::Ready(())
    })
    .await;
    file.set_len(0).unwrap();
    assert_eq!(
        pending.await.unwrap_err().code,
        ErrorCode::GuestInternalError
    );
    let owned = std::fs::read_dir(spool.path())
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert_eq!(std::fs::read_dir(owned).unwrap().count(), 0);
    assert_eq!(
        collector
            .collect(&session, &request)
            .await
            .unwrap()
            .artifacts[0]
            .size_bytes,
        0
    );
}

#[tokio::test]
async fn a_root_that_becomes_writable_by_other_users_no_longer_admits_files() {
    use gaovm_guestd::protocol::ErrorCode;
    use std::os::unix::fs::PermissionsExt;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    std::fs::write(source.path().join("a"), b"data").unwrap();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    std::fs::set_permissions(source.path(), std::fs::Permissions::from_mode(0o777)).unwrap();
    let result = collector.collect(&session(), &request(&["a"], 4)).await;
    std::fs::set_permissions(source.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(result.unwrap_err().code, ErrorCode::ArtifactNotFound);
}

#[tokio::test]
async fn retained_artifacts_do_not_keep_a_descriptor_open_per_file() {
    use std::time::Duration;

    const CHILD: &str = "GAOVM_ARTIFACT_DESCRIPTOR_CHILD";
    if std::env::var_os(CHILD).is_none() {
        let output = tokio::time::timeout(Duration::from_secs(10), tokio::process::Command::new("/bin/sh")
            .args(["-c", "ulimit -n 64 && exec \"$1\" --exact retained_artifacts_do_not_keep_a_descriptor_open_per_file --nocapture", "artifact-fd-test"])
            .arg(std::env::current_exe().unwrap()).env(CHILD, "1").kill_on_drop(true).output())
            .await.expect("bounded descriptor check must finish").unwrap();
        assert!(
            output.status.success(),
            "stdout: {}\nstderr: {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }
    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    let paths: Vec<_> = (0..128).map(|index| format!("empty-{index}")).collect();
    for path in &paths {
        std::fs::write(source.path().join(path), []).unwrap();
    }
    let paths: Vec<_> = paths.iter().map(String::as_str).collect();
    let request = request(&paths, 0);
    let session = session();
    let mut collector = ArtifactCollector::new(
        VM,
        8,
        source.path(),
        spool.path(),
        ArtifactLimits::default(),
    )
    .unwrap();
    let result = collector.collect(&session, &request).await.unwrap();
    assert_eq!(result.artifacts.len(), 128);
    let mut byte = [0];
    assert_eq!(
        collector
            .open_artifact(&session, &request, &result.artifacts[127].artifact_id)
            .unwrap()
            .read(&mut byte)
            .unwrap(),
        0
    );
}

#[test]
fn constructors_require_valid_binding_limits_and_owned_non_writable_directories() {
    use std::os::unix::fs::PermissionsExt;

    let source = tempfile::tempdir().unwrap();
    let spool = tempfile::tempdir().unwrap();
    for (vm, generation) in [("default", 8), (VM, 0)] {
        assert!(
            ArtifactCollector::new(
                vm,
                generation,
                source.path(),
                spool.path(),
                ArtifactLimits::default()
            )
            .is_err()
        );
    }
    for limits in [
        ArtifactLimits {
            max_retained: 0,
            ..ArtifactLimits::default()
        },
        ArtifactLimits {
            max_collection_bytes: 257 * 1024 * 1024,
            ..ArtifactLimits::default()
        },
        ArtifactLimits {
            max_stored_bytes: 1,
            ..ArtifactLimits::default()
        },
    ] {
        assert!(ArtifactCollector::new(VM, 8, source.path(), spool.path(), limits).is_err());
    }
    std::fs::set_permissions(source.path(), std::fs::Permissions::from_mode(0o777)).unwrap();
    assert!(
        ArtifactCollector::new(
            VM,
            8,
            source.path(),
            spool.path(),
            ArtifactLimits::default()
        )
        .is_err()
    );
    std::fs::set_permissions(source.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::set_permissions(spool.path(), std::fs::Permissions::from_mode(0o777)).unwrap();
    assert!(
        ArtifactCollector::new(
            VM,
            8,
            source.path(),
            spool.path(),
            ArtifactLimits::default()
        )
        .is_err()
    );
    std::fs::set_permissions(spool.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::write(source.path().join("file"), b"data").unwrap();
    assert!(
        ArtifactCollector::new(
            VM,
            8,
            &source.path().join("file"),
            spool.path(),
            ArtifactLimits::default()
        )
        .is_err()
    );
}
