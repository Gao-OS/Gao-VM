use std::path::PathBuf;
use std::time::Duration;

const USAGE: &str = "gaovm-guestd --artifact-root ABSOLUTE_PATH --spool-parent ABSOLUTE_PATH --io-budget-seconds SECONDS [--port PORT]\n\nLinux resident guest agent; default vsock port: 10777.\nStorage roots and a finite nonzero I/O policy are required.\nRuns as the invoking UID/GID; installation must supply least-privilege policy.\nNo VM identity is configured: binding comes from authenticated host hello.\n";

struct Config {
    artifact_root: PathBuf,
    spool_parent: PathBuf,
    budget: Duration,
    port: u32,
}

fn parse(args: impl Iterator<Item = String>) -> Result<Option<Config>, ()> {
    let args: Vec<String> = args.collect();
    if args == ["--help"] {
        return Ok(None);
    }
    let mut source = None;
    let mut spool = None;
    let mut budget = None;
    let mut port = None;
    let mut args = args.into_iter();
    while let Some(key) = args.next() {
        let value = args.next().ok_or(())?;
        match key.as_str() {
            "--artifact-root" if source.is_none() => source = Some(PathBuf::from(value)),
            "--spool-parent" if spool.is_none() => spool = Some(PathBuf::from(value)),
            "--io-budget-seconds" if budget.is_none() => {
                budget = Some(Duration::from_secs(value.parse().map_err(|_| ())?))
            }
            "--port" if port.is_none() => port = Some(value.parse::<u32>().map_err(|_| ())?),
            _ => return Err(()),
        }
    }
    let config = Config {
        artifact_root: source.ok_or(())?,
        spool_parent: spool.ok_or(())?,
        budget: budget.ok_or(())?,
        port: port.unwrap_or(10777),
    };
    if !config.artifact_root.is_absolute()
        || !config.spool_parent.is_absolute()
        || config.budget.is_zero()
        || std::time::Instant::now()
            .checked_add(config.budget)
            .is_none()
        || config.port < 1024
    {
        return Err(());
    }
    Ok(Some(config))
}

fn main() -> std::process::ExitCode {
    let config = match parse(std::env::args().skip(1)) {
        Ok(None) => {
            print!("{USAGE}");
            return std::process::ExitCode::SUCCESS;
        }
        Ok(Some(config)) => config,
        Err(()) => {
            eprintln!("invalid guest service configuration; use --help");
            return std::process::ExitCode::from(2);
        }
    };
    match run(config) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) if error.kind() == std::io::ErrorKind::Unsupported => {
            eprintln!("guest service requires Linux AF_VSOCK; no transport fallback");
            std::process::ExitCode::FAILURE
        }
        Err(_) => {
            eprintln!("guest service failed; admission or cleanup was not confirmed");
            std::process::ExitCode::FAILURE
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn run(config: Config) -> std::io::Result<()> {
    let _ = (
        config.artifact_root,
        config.spool_parent,
        config.budget,
        config.port,
    );
    Err(std::io::ErrorKind::Unsupported.into())
}

#[cfg(target_os = "linux")]
fn run(config: Config) -> std::io::Result<()> {
    // SAFETY: PR_SET_NO_NEW_PRIVS takes integer arguments and no pointers. This
    // is inherited by exec children; it does not drop existing UID/capabilities
    // or substitute for an unprivileged installed service/cgroup policy.
    if unsafe {
        nix::libc::prctl(
            nix::libc::PR_SET_NO_NEW_PRIVS,
            1 as nix::libc::c_ulong,
            0 as nix::libc::c_ulong,
            0 as nix::libc::c_ulong,
            0 as nix::libc::c_ulong,
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error());
    }
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?
        .block_on(resident(config))
}

#[cfg(target_os = "linux")]
async fn resident(config: Config) -> std::io::Result<()> {
    use gaovm_guestd::acceptor::GuestAcceptor;
    use gaovm_guestd::dispatcher::GuestResources;
    use gaovm_guestd::vsock::HostListener;
    use tokio::signal::unix::{SignalKind, signal};
    use tokio::time::Instant;

    let mut terminate = signal(SignalKind::terminate())?;
    let mut interrupt = signal(SignalKind::interrupt())?;
    let listener = HostListener::bind(config.port)?;
    eprintln!("guest listener bound: port={}", listener.local_port());
    let resources = GuestResources::new(
        &config.artifact_root,
        &config.spool_parent,
        std::path::Path::new("/"),
    );
    let mut service = GuestAcceptor::new(resources, config.budget)?;
    let outcome = loop {
        tokio::select! {
            biased;
            _ = terminate.recv() => break Ok(()),
            _ = interrupt.recv() => break Ok(()),
            completed = service.completed() => if let Err(error) = completed { break Err(error); },
            accepted = listener.accept() => match accepted {
                Ok(accepted) => {
                    let (stream, opening, open_deadline) = accepted.into_parts();
                    let Some(operation_deadline) = Instant::now().checked_add(config.budget) else {
                        break Err(std::io::ErrorKind::InvalidInput.into());
                    };
                    if let Err(error) = service.accept(stream, opening, open_deadline, operation_deadline)
                        && error.kind() != std::io::ErrorKind::WouldBlock {
                        break Err(error);
                    }
                }
                Err(error) if matches!(error.kind(), std::io::ErrorKind::PermissionDenied | std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::Interrupted) => {},
                Err(error) => break Err(error),
            },
        }
        // Ready accepts must not starve owned control work or signal delivery.
        tokio::task::yield_now().await;
    };
    drop(listener);
    service.shutdown().await?;
    outcome
}
