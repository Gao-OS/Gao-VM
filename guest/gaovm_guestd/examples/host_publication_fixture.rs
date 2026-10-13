//! Test-only Unix bridge adapter for the real guest coordinator. Never shipped
//! as gaovm-guestd or used as its native-CID authentication/transport fallback.

#[cfg(unix)]
#[tokio::main(flavor = "current_thread")]
async fn main() -> std::io::Result<()> {
    use gaovm_guestd::acceptor::GuestAcceptor;
    use gaovm_guestd::dispatcher::GuestResources;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::Arc;
    use tokio::net::UnixListener;
    use tokio::signal::unix::{SignalKind, signal};
    use tokio::sync::Semaphore;
    use tokio::time::{Duration, Instant};

    let args: Vec<PathBuf> = std::env::args_os().skip(1).map(PathBuf::from).collect();
    if args.len() != 3 || args.iter().any(|path| !path.is_absolute()) {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    let token =
        std::env::var("GAOVM_GUEST_FIXTURE_TOKEN").map_err(|_| std::io::ErrorKind::InvalidInput)?;
    if token.is_empty() {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    let mut terminate = signal(SignalKind::terminate())?;
    let mut interrupt = signal(SignalKind::interrupt())?;
    let listener = UnixListener::bind(&args[0])?;
    std::fs::set_permissions(&args[0], std::fs::Permissions::from_mode(0o600))?;
    let resources = GuestResources::new(&args[1], &args[2], &args[1]);
    let mut service = GuestAcceptor::new(resources, Duration::from_secs(30))?;
    let pending = Arc::new(Semaphore::new(8));
    println!("ready");
    let outcome = loop {
        tokio::select! {
            biased;
            _ = terminate.recv() => break Ok(()),
            _ = interrupt.recv() => break Ok(()),
            result = service.completed() => if let Err(error) = result { break Err(error); },
            accepted = listener.accept() => {
                let (mut stream, _) = match accepted {
                    Ok(accepted) => accepted,
                    Err(error) => break Err(error),
                };
                // This is real same-UID Unix admission, not native vsock proof.
                let peer = match stream.peer_cred() {
                    Ok(peer) => peer,
                    Err(error) => break Err(error),
                };
                if peer.uid() != nix::unistd::geteuid().as_raw() {
                    continue;
                }
                let Ok(permit) = pending.clone().try_acquire_owned() else { continue; };
                let deadline = Instant::now() + Duration::from_secs(5);
                if bridge(&mut stream, &token, deadline).await.is_err() {
                    continue;
                }
                if let Err(error) = service.accept(stream, permit, deadline, Instant::now() + Duration::from_secs(30)) {
                    break Err(error);
                }
            }
        }
    };
    drop(listener);
    service.shutdown().await?;
    outcome
}

#[cfg(unix)]
async fn bridge(
    stream: &mut tokio::net::UnixStream,
    token: &str,
    deadline: tokio::time::Instant,
) -> std::io::Result<()> {
    use gaovm_guestd::frame::read_object;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    tokio::time::timeout_at(deadline, async {
        let length = stream.read_u32().await?;
        if !(1..=4096).contains(&length) {
            return Err(std::io::ErrorKind::InvalidData.into());
        }
        let mut bytes = vec![0; length as usize];
        stream.read_exact(&mut bytes).await?;
        let mut frame = length.to_be_bytes().to_vec();
        frame.extend(bytes);
        let mut request =
            read_object(&mut frame.as_slice())?.ok_or(std::io::ErrorKind::UnexpectedEof)?;
        let fields = [
            "protocol_version",
            "kind",
            "vm_id",
            "driver_generation",
            "request_id",
            "operation_id",
            "stream_kind",
            "auth_token",
        ];
        let object = request
            .as_object_mut()
            .ok_or(std::io::ErrorKind::InvalidData)?;
        if object.len() != fields.len()
            || fields.iter().any(|key| !object.contains_key(*key))
            || object["protocol_version"] != "gaovm.bridge.v1"
            || object["kind"] != "open"
            || object["auth_token"] != token
            || !matches!(object["stream_kind"].as_str(), Some("control" | "binary"))
        {
            return Err(std::io::ErrorKind::PermissionDenied.into());
        }
        object.remove("auth_token");
        object.insert("kind".into(), "ready".into());
        let response = serde_json::to_vec(&request).map_err(|_| std::io::ErrorKind::InvalidData)?;
        stream.write_u32(response.len() as u32).await?;
        stream.write_all(&response).await?;
        stream.flush().await
    })
    .await
    .map_err(|_| std::io::ErrorKind::TimedOut)?
}

#[cfg(not(unix))]
fn main() {
    panic!("host-publication fixture requires Unix; no transport fallback");
}
