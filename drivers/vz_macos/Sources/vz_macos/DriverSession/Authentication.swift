import Foundation

extension DriverSession {
    func handleHelloRequest(id: Any, message: [String: Any]) throws {
        guard let params = message["params"] as? [String: Any] else {
            try sendError(id: id, code: -32602, message: "hello params must be object")
            return
        }
        let protocolVersion = params["protocol"] as? String
        let token = params["authToken"] as? String
        let daemonCaps = (params["capabilities"] as? [Any] ?? []).map { String(describing: $0) }
        if protocolVersion != DriverProtocol.protocolVersion {
            try sendError(id: id, code: -32010, message: "protocol mismatch")
            return
        }
        if token != config.authToken {
            try sendError(id: id, code: -32011, message: "auth token mismatch")
            return
        }
        let accepted = daemonCaps.filter { DriverProtocol.capabilities.contains($0) }
        guard DriverProtocol.requiredCapabilities.allSatisfy({ accepted.contains($0) }) else {
            try sendError(id: id, code: -32012, message: "capability mismatch")
            return
        }
        markAuthenticatedRpc()
        logger.log(.info, "daemon hello accepted; authenticated")
        try sendResult(id: id, result: [
            "protocol": DriverProtocol.protocolVersion,
            "capabilities": DriverProtocol.capabilities,
            "acceptedCapabilities": accepted
        ])
        return
    }

    func validateHelloResult(_ result: [String: Any]) throws {
        let protocolVersion = result["protocol"] as? String
        let accepted = (result["acceptedCapabilities"] as? [Any] ?? []).map { String(describing: $0) }
        guard protocolVersion == DriverProtocol.protocolVersion else {
            throw DriverError.handshakeFailed("daemon hello result protocol mismatch")
        }
        guard DriverProtocol.requiredCapabilities.allSatisfy({ accepted.contains($0) }) else {
            throw DriverError.handshakeFailed("daemon hello result capability mismatch")
        }
    }

    func isAuthenticated() -> Bool {
        stateQueue.sync { authenticated }
    }

    func markAuthenticatedRpc() {
        stateQueue.sync {
            authenticated = true
            lastAuthenticatedDaemonRPC = Date()
        }
    }
}
