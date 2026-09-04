import Foundation

func authenticationDeadlineExpired(
    since lastAuthenticatedRPC: Date,
    now: Date = Date(),
    timeout: TimeInterval = 15
) -> Bool {
    now.timeIntervalSince(lastAuthenticatedRPC) > timeout
}

extension DriverSession {
    func markControlConnectionAccepted() {
        stateQueue.sync {
            authenticated = false
            lastAuthenticatedDaemonRPC = Date()
        }
    }

    func isHeartbeatExpired() -> Bool {
        stateQueue.sync {
            authenticationDeadlineExpired(since: lastAuthenticatedDaemonRPC)
        }
    }
}
