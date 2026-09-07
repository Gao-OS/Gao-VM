import Foundation
#if canImport(Virtualization)
import Virtualization
#endif
import Darwin

struct Config {
    let vmId: DriverProtocolV2.VMID
    let generation: Int
    let socketPath: String
    let bundlePath: String
    let authToken: String
    let logPath: String
}

struct LegacyConfig {
    let socketPath: String
    let authToken: String
    let logPath: String
}

final class UnixSocket: SocketWriteTransport {
    private let fdLock = NSLock()
    private var storedFD: Int32

    var fd: Int32 {
        fdLock.lock()
        defer { fdLock.unlock() }
        return storedFD
    }

    init(fd: Int32) throws {
        self.storedFD = fd
        var enabled: Int32 = 1
        guard Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        ) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            self.storedFD = -1
            throw DriverError.io("setsockopt(SO_NOSIGPIPE) failed: \(message)")
        }
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n <= 0 {
                    throw DriverError.io("write() failed: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }

    func readExact(_ count: Int, context: String? = nil) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            if n == 0 {
                if offset == 0 {
                    throw DriverError.eof
                }
                let label = context ?? "read"
                throw DriverError.protocolViolation("incomplete \(label): expected \(count) bytes, got \(offset)")
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw DriverError.io("read() failed: \(String(cString: strerror(errno)))")
            }
            offset += n
        }
        return data
    }

    func pollReadable(timeoutMs: Int32) throws -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let rc = Darwin.poll(&pfd, 1, timeoutMs)
        if rc < 0 {
            if errno == EINTR { return false }
            throw DriverError.io("poll() failed: \(String(cString: strerror(errno)))")
        }
        return rc > 0
    }

    func close() {
        fdLock.lock()
        let fd = storedFD
        storedFD = -1
        fdLock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }

    func interrupt() {
        let fd = self.fd
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    deinit { close() }
}

final class UnixListener {
    private(set) var fd: Int32 = -1
    private let path: String
    private var boundIdentity: UnixSocketIdentity?

    init(path: String) {
        self.path = path
    }

    func bindAndListen() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DriverError.socketBind("socket() failed: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < maxLen else {
            throw DriverError.invalidArgs("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            rawBuf.initializeMemory(as: UInt8.self, repeating: 0)
            for (idx, byte) in pathBytes.enumerated() { rawBuf[idx] = byte }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, addrLen)
            }
        }
        guard bindRC == 0 else {
            let err = String(cString: strerror(errno))
            close()
            throw DriverError.socketBind("bind() failed: \(err)")
        }
        boundIdentity = socketIdentity(at: path)
        guard Darwin.listen(fd, 16) == 0 else {
            let err = String(cString: strerror(errno))
            close()
            throw DriverError.socketBind("listen() failed: \(err)")
        }
    }

    func acceptOne() throws -> UnixSocket {
        let clientFD = Darwin.accept(fd, nil, nil)
        guard clientFD >= 0 else {
            throw DriverError.socketAccept("accept() failed: \(String(cString: strerror(errno)))")
        }
        return try UnixSocket(fd: clientFD)
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        if let boundIdentity, socketIdentity(at: path) == boundIdentity {
            unlink(path)
        }
        boundIdentity = nil
    }

    deinit { close() }
}

private struct UnixSocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private func socketIdentity(at path: String) -> UnixSocketIdentity? {
    var status = stat()
    guard lstat(path, &status) == 0 else { return nil }
    return UnixSocketIdentity(device: status.st_dev, inode: status.st_ino)
}

final class DriverSession {
    let config: LegacyConfig
    let logger: RotatingLogger
    private let vmRuntime: VzRuntime
    private lazy var runtimeDispatcher = RuntimeCommandDispatcher(runtime: vmRuntime) { [weak self] error in
        self?.recordFatal(error)
    }
    private let codec = LengthPrefixedJsonRpc()
    private let socketWriter = SerializedSocketWriter()
    let stateQueue = DispatchQueue(label: "gaovm.driver.state")
    private var listener: UnixListener?
    private var socket: UnixSocket?
    private var nextID: Int = 1
    private var pendingRequests: [Int: String] = [:]
    var authenticated = false
    var lastAuthenticatedDaemonRPC = Date()
    private var fatalError: Error?

    init(config: LegacyConfig, logger: RotatingLogger) {
        self.config = config
        self.logger = logger
        self.vmRuntime = VzRuntime(logger: logger)
    }

    func run() throws {
        guard #available(macOS 14.0, *) else {
            throw DriverError.invalidArgs("gaovm-driver-vz requires macOS 14+")
        }
#if canImport(Virtualization)
        _ = VZVirtioNetworkDeviceConfiguration.self
#endif
        logger.log(.info, "starting driver on socket \(config.socketPath)")
        let listener = UnixListener(path: config.socketPath)
        try listener.bindAndListen()
        self.listener = listener
        logger.log(.info, "listening for daemon connection")
        let socket = try listener.acceptOne()
        self.socket = socket
        try socketWriter.attach(socket)
        defer {
            socketWriter.close()
            listener.close()
        }
        markControlConnectionAccepted()
        logger.log(.info, "daemon connected")
        try sendHello()

        while true {
            if let fatal = takeFatalError() {
                throw fatal
            }
            if isHeartbeatExpired() {
                try gracefulExit(reason: "heartbeat timeout (no authenticated daemon RPC within 15s)", code: 12)
            }

            let readable = try socket.pollReadable(timeoutMs: 1000)
            if !readable { continue }
            let message: [String: Any]
            do {
                message = try readFrame()
            } catch DriverError.eof {
                try gracefulExit(reason: "control socket EOF", code: 0)
            }
            try handle(message: message)
        }
    }

    private func readFrame() throws -> [String: Any] {
        guard let socket else { throw DriverError.io("no control socket") }
        let header = try socket.readExact(4, context: "frame header")
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if length == 0 {
            throw DriverError.protocolViolation("zero-length frame not allowed")
        }
        if length > UInt32(LengthPrefixedJsonRpc.maxFrameSize) {
            throw DriverError.protocolViolation("frame length \(length) exceeds maxFrameSize \(LengthPrefixedJsonRpc.maxFrameSize)")
        }
        let payload = try socket.readExact(Int(length), context: "frame payload")
        return try codec.decode(payload)
    }

    private func send(_ object: [String: Any]) throws {
        let data = try codec.encode(object)
        try socketWriter.write(data)
    }

    private func sendHello() throws {
        let id = nextRequestID()
        stateQueue.sync {
            pendingRequests[id] = "hello"
        }
        try send([
            "jsonrpc": "2.0",
            "id": id,
            "method": "hello",
            "params": [
                "protocol": DriverProtocol.protocolVersion,
                "authToken": config.authToken,
                "capabilities": DriverProtocol.capabilities,
                "requiredCapabilities": DriverProtocol.requiredCapabilities
            ]
        ])
        logger.log(.debug, "sent hello request")
    }

    private func handle(message: [String: Any]) throws {
        guard let version = message["jsonrpc"] as? String, version == "2.0" else {
            throw DriverError.protocolViolation("jsonrpc version must be 2.0")
        }
        if let method = message["method"] as? String {
            try handleRequest(method: method, message: message)
            return
        }
        if message["id"] != nil {
            try handleResponse(message: message)
            return
        }
        throw DriverError.protocolViolation("invalid JSON-RPC object")
    }

    private func handleResponse(message: [String: Any]) throws {
        if let errorObj = message["error"] {
            throw DriverError.handshakeFailed("daemon returned error: \(errorObj)")
        }
        guard let idNum = message["id"] as? Int ?? (message["id"] as? NSNumber)?.intValue else {
            throw DriverError.protocolViolation("response id missing or invalid")
        }
        let pendingMethod = stateQueue.sync { pendingRequests.removeValue(forKey: idNum) }
        if pendingMethod == "hello" {
            guard let result = message["result"] as? [String: Any] else {
                throw DriverError.handshakeFailed("hello response missing result")
            }
            try validateHelloResult(result)
            logger.log(.info, "hello response accepted")
            return
        }
        throw DriverError.protocolViolation("unexpected response id: \(idNum)")
    }

    private func handleRequest(method: String, message: [String: Any]) throws {
        guard let id = message["id"] else { return }

        if method == "hello" {
            try handleHelloRequest(id: id, message: message)
            return
        }

        if !isAuthenticated() {
            try sendError(id: id, code: -32010, message: "hello handshake required")
            return
        }

        markAuthenticatedRpc()
        do {
            switch method {
            case "ping":
                runtimeDispatcher.ping { result in
                    self.sendRuntimeResponse(id: id, method: method, result: result)
                }
            case "vm.configure":
                guard let params = message["params"] as? [String: Any],
                      let cfg = params["config"] as? [String: Any] else {
                    try sendError(id: id, code: -32602, message: "vm.configure requires params.config object")
                    return
                }
                runtimeDispatcher.configure(with: cfg) { result in
                    self.sendRuntimeResponse(id: id, method: method, result: result)
                }
            case "vm.start":
                runtimeDispatcher.start { result in
                    self.sendRuntimeResponse(id: id, method: method, result: result)
                }
            case "vm.stop":
                runtimeDispatcher.stop { result in
                    self.sendRuntimeResponse(id: id, method: method, result: result)
                }
            case "vm.status":
                runtimeDispatcher.status { result in
                    self.sendRuntimeResponse(id: id, method: method, result: result)
                }
            case "open_display":
                let result = try vmRuntime.openDisplay()
                try sendResult(id: id, result: result)
            case "close_display":
                let result = try vmRuntime.closeDisplay()
                try sendResult(id: id, result: result)
            default:
                try sendError(id: id, code: -32601, message: "method not found: \(method)")
            }
        } catch {
            logger.log(.error, "request \(method) failed: \(error)")
            try sendError(id: id, code: -32603, message: "\(error)")
        }
    }

    private func sendRuntimeResponse(id: Any, method: String, result: RuntimeResult) {
        do {
            switch result {
            case .success(let payload):
                try sendResult(id: id, result: payload)
            case .failure(let error):
                logger.log(.error, "request \(method) failed: \(error)")
                try sendError(id: id, code: -32603, message: "\(error)")
            }
        } catch {
            recordFatal(error)
        }
    }

    func sendResult(id: Any, result: [String: Any]) throws {
        try send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func sendError(id: Any, code: Int, message: String) throws {
        try send([
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private func nextRequestID() -> Int {
        stateQueue.sync {
            defer { nextID += 1 }
            return nextID
        }
    }

    private func recordFatal(_ error: Error) {
        let shouldStore = stateQueue.sync { () -> Bool in
            if fatalError != nil {
                return false
            }
            fatalError = error
            return true
        }
        if shouldStore {
            logger.log(.error, "fatal driver loop error: \(error)")
            socketWriter.close()
        }
    }

    private func takeFatalError() -> Error? {
        stateQueue.sync {
            let out = fatalError
            fatalError = nil
            return out
        }
    }

    private func gracefulExit(reason: String, code: Int32) throws -> Never {
        logger.log(.warn, reason)
        fputs("[gaovm-driver-vz] \(reason)\n", stderr)
        let stopFinished = DispatchGroup()
        var stopResult: RuntimeResult?
        stopFinished.enter()
        runtimeDispatcher.closeAndShutdown(reason: reason) { result in
            stopResult = result
            stopFinished.leave()
        }
        socketWriter.close()
        if stopFinished.wait(timeout: .now() + 50) == .timedOut {
            logger.log(.error, "timed out waiting for VM stop before driver exit")
            fputs("[gaovm-driver-vz] timed out waiting for VM stop before exit\n", stderr)
        } else if case .failure(let error) = stopResult {
            logger.log(.error, "failed to stop VM before driver exit: \(error)")
            fputs("[gaovm-driver-vz] failed to stop VM before exit: \(error)\n", stderr)
        } else {
            logger.log(.info, "VM stopped before driver exit")
        }
        listener?.close()
        Foundation.exit(code)
    }
}
