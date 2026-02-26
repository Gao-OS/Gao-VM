import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Virtualization)
import Virtualization
#endif
import Darwin

enum DriverError: Error, CustomStringConvertible {
    case invalidArgs(String)
    case socketBind(String)
    case socketAccept(String)
    case io(String)
    case eof
    case protocolViolation(String)
    case handshakeFailed(String)
    case authMissing

    var description: String {
        switch self {
        case .invalidArgs(let s), .socketBind(let s), .socketAccept(let s), .io(let s), .protocolViolation(let s), .handshakeFailed(let s):
            return s
        case .eof:
            return "socket EOF"
        case .authMissing:
            return "GAOVM_AUTH_TOKEN is required"
        }
    }
}

struct Config {
    let socketPath: String
    let authToken: String
    let logPath: String
}

enum LogLevel: String {
    case error, warn, info, debug
}

final class RotatingLogger {
    private let path: String
    private let maxBytes = 10 * 1024 * 1024
    private let maxRotations = 3
    private let queue = DispatchQueue(label: "gaovm.driver.logger")

    init(path: String) {
        self.path = path
    }

    func log(_ level: LogLevel, _ message: String) {
        queue.sync {
            do {
                try rotateIfNeeded()
                try ensureParentDir()
                let line = "[\(ISO8601DateFormatter().string(from: Date()))] [\(level.rawValue)] \(message)\n"
                let data = Data(line.utf8)
                if FileManager.default.fileExists(atPath: path) {
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    FileManager.default.createFile(atPath: path, contents: data)
                }
            } catch {
                fputs("[gaovm-driver-vz][logger] \(error)\n", stderr)
            }
        }
    }

    private func ensureParentDir() throws {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func rotateIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maxBytes else { return }

        let fm = FileManager.default
        let oldest = "\(path).\(maxRotations)"
        if fm.fileExists(atPath: oldest) { try fm.removeItem(atPath: oldest) }
        if maxRotations > 1 {
            for i in stride(from: maxRotations - 1, through: 1, by: -1) {
                let src = "\(path).\(i)"
                let dst = "\(path).\(i + 1)"
                if fm.fileExists(atPath: src) {
                    if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
                    try fm.moveItem(atPath: src, toPath: dst)
                }
            }
        }
        let first = "\(path).1"
        if fm.fileExists(atPath: first) { try fm.removeItem(atPath: first) }
        try fm.moveItem(atPath: path, toPath: first)
    }
}

final class LengthPrefixedJsonRpc {
    func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DriverError.protocolViolation("invalid JSON object")
        }
        let payload = try JSONSerialization.data(withJSONObject: object, options: [])
        var len = UInt32(payload.count).bigEndian
        var data = Data(bytes: &len, count: 4)
        data.append(payload)
        return data
    }

    func decode(_ payload: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: payload, options: [])
        if obj is [Any] {
            throw DriverError.protocolViolation("JSON-RPC batch is not supported")
        }
        guard let map = obj as? [String: Any] else {
            throw DriverError.protocolViolation("top-level JSON must be object")
        }
        return map
    }
}

final class UnixSocket {
    private(set) var fd: Int32

    init(fd: Int32) {
        self.fd = fd
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

    func readExact(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            if n == 0 { throw DriverError.eof }
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
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

final class UnixListener {
    private(set) var fd: Int32 = -1
    private let path: String

    init(path: String) {
        self.path = path
    }

    func bindAndListen() throws {
        unlink(path)
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
        return UnixSocket(fd: clientFD)
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        unlink(path)
    }

    deinit { close() }
}

final class VmRuntime {
    private let logger: RotatingLogger
    private var config: [String: Any]?
#if canImport(Virtualization)
    private var virtualMachine: VZVirtualMachine?
#endif
#if canImport(AppKit) && canImport(Virtualization)
    private var displayWindow: NSWindow?
    private var displayView: VZVirtualMachineView?
    private var windowCloseObserver: NSObjectProtocol?
#endif

    init(logger: RotatingLogger) {
        self.logger = logger
    }

    func configure(with config: [String: Any]) throws -> [String: Any] {
        _ = try normalizedConfig(config)
        self.config = config
        logger.log(.info, "vm configured")
        return status()
    }

    func start() throws -> [String: Any] {
#if canImport(Virtualization)
        guard #available(macOS 14.0, *) else {
            throw DriverError.invalidArgs("Virtualization.framework requires macOS 14+")
        }
        guard let config else {
            throw DriverError.invalidArgs("vm is not configured")
        }
        let spec = try normalizedConfig(config)
        if let vm = virtualMachine {
            switch vm.state {
            case .running, .starting, .pausing, .paused, .resuming, .stopping, .saving, .restoring:
                return status()
            case .stopped, .error:
                break
            @unknown default:
                break
            }
        }

        try ensureSparseDisk(spec.diskPath, sizeMiB: spec.diskSizeMiB)
        let vmConfig = try buildConfiguration(spec)
        let vm = VZVirtualMachine(configuration: vmConfig)
        virtualMachine = vm

        let sem = DispatchSemaphore(value: 0)
        var startError: Error?
        vm.start { result in
            switch result {
            case .success:
                break
            case .failure(let err):
                startError = err
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 30)
        if let startError {
            throw startError
        }
        logger.log(.info, "vm started")
        return status()
#else
        throw DriverError.invalidArgs("Virtualization.framework unavailable")
#endif
    }

    func stop() throws -> [String: Any] {
#if canImport(Virtualization)
        guard #available(macOS 14.0, *) else {
            throw DriverError.invalidArgs("Virtualization.framework requires macOS 14+")
        }
        guard let vm = virtualMachine else {
            return status()
        }

        if vm.canRequestStop {
            try vm.requestStop()
            logger.log(.info, "vm stop requested")
        }
        return status()
#else
        throw DriverError.invalidArgs("Virtualization.framework unavailable")
#endif
    }

    func status() -> [String: Any] {
        var out: [String: Any] = [
            "configured": config != nil,
            "graphicsWindowOpen": isDisplayOpen()
        ]
#if canImport(Virtualization)
        if let vm = virtualMachine {
            out["state"] = vmStateName(vm.state)
            out["canStart"] = vm.canStart
            out["canPause"] = vm.canPause
            out["canResume"] = vm.canResume
            out["canRequestStop"] = vm.canRequestStop
        } else {
            out["state"] = "not_created"
        }
#else
        out["state"] = "virtualization_unavailable"
#endif
        return out
    }

    func openDisplay() throws -> [String: Any] {
        guard #available(macOS 14.0, *) else {
            throw DriverError.invalidArgs("display requires macOS 14+")
        }
#if canImport(AppKit) && canImport(Virtualization)
        guard let vm = virtualMachine else {
            throw DriverError.invalidArgs("vm is not created")
        }
        let spec = try currentNormalizedConfig()
        guard spec.graphicsEnabled else {
            throw DriverError.invalidArgs("graphics is disabled in config")
        }
        DispatchQueue.main.sync {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            if let existing = displayWindow {
                existing.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                return
            }

            let rect = NSRect(x: 120, y: 120, width: spec.graphicsWidth, height: spec.graphicsHeight)
            let window = NSWindow(
                contentRect: rect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "GaoVM"
            let vmView = VZVirtualMachineView(frame: rect)
            vmView.autoresizingMask = [.width, .height]
            vmView.virtualMachine = vm
            window.contentView = vmView
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)

            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: nil
            ) { [weak self] _ in
                self?.displayWindow = nil
                self?.displayView = nil
                if let observer = self?.windowCloseObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self?.windowCloseObserver = nil
                }
            }

            self.displayWindow = window
            self.displayView = vmView
        }
        return [
            "ok": true,
            "supported": true,
            "open": true
        ]
#else
        return [
            "ok": true,
            "supported": false,
            "message": "AppKit display is unavailable in this build"
        ]
#endif
    }

    func closeDisplay() throws -> [String: Any] {
        guard #available(macOS 14.0, *) else {
            throw DriverError.invalidArgs("display requires macOS 14+")
        }
#if canImport(AppKit) && canImport(Virtualization)
        DispatchQueue.main.sync {
            displayWindow?.close()
            displayWindow = nil
            displayView = nil
            if let observer = windowCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                windowCloseObserver = nil
            }
        }
        return [
            "ok": true,
            "supported": true,
            "open": false
        ]
#else
        return [
            "ok": true,
            "supported": false,
            "message": "AppKit display is unavailable in this build"
        ]
#endif
    }

#if canImport(Virtualization)
    @available(macOS 14.0, *)
    private func buildConfiguration(_ spec: NormalizedVmConfig) throws -> VZVirtualMachineConfiguration {
        let cfg = VZVirtualMachineConfiguration()
        cfg.cpuCount = spec.cpu
        cfg.memorySize = UInt64(spec.memoryBytes)

        let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: spec.kernelPath))
        if let initrd = spec.initrdPath {
            bootLoader.initialRamdiskURL = URL(fileURLWithPath: initrd)
        }
        if let cmdline = spec.commandLine, !cmdline.isEmpty {
            bootLoader.commandLine = cmdline
        }
        cfg.bootLoader = bootLoader

        let nat = VZNATNetworkDeviceAttachment()
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = nat
        cfg.networkDevices = [net]

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: spec.diskPath),
            readOnly: false
        )
        cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        if spec.graphicsEnabled {
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(
                    widthInPixels: spec.graphicsWidth,
                    heightInPixels: spec.graphicsHeight
                )
            ]
            cfg.graphicsDevices = [graphics]
            cfg.keyboards = [VZUSBKeyboardConfiguration()]
            cfg.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        } else {
            cfg.graphicsDevices = []
            cfg.keyboards = []
            cfg.pointingDevices = []
        }

        try cfg.validate()
        return cfg
    }
#endif

    private func ensureSparseDisk(_ path: String, sizeMiB: Int) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return }
        let url = URL(fileURLWithPath: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: path, contents: nil) else {
            throw DriverError.io("failed to create disk image: \(path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024)
        logger.log(.info, "created sparse disk at \(path) sizeMiB=\(sizeMiB)")
    }

    private func normalizedConfig(_ root: [String: Any]) throws -> NormalizedVmConfig {
        func dict(_ parent: [String: Any], _ key: String) throws -> [String: Any] {
            guard let value = parent[key] as? [String: Any] else {
                throw DriverError.invalidArgs("config.\(key) must be object")
            }
            return value
        }
        func int(_ parent: [String: Any], _ key: String) throws -> Int {
            if let value = parent[key] as? Int { return value }
            if let value = parent[key] as? NSNumber { return value.intValue }
            throw DriverError.invalidArgs("config.\(key) must be int")
        }
        func strOpt(_ parent: [String: Any], _ key: String) -> String? {
            if let value = parent[key] as? String, !value.isEmpty { return value }
            return nil
        }
        func bool(_ parent: [String: Any], _ key: String) throws -> Bool {
            if let value = parent[key] as? Bool { return value }
            if let value = parent[key] as? NSNumber { return value.boolValue }
            throw DriverError.invalidArgs("config.\(key) must be bool")
        }

        let cpu = try int(root, "cpu")
        let memory = try int(root, "memory")
        let boot = try dict(root, "boot")
        let disk = try dict(root, "disk")
        let network = try dict(root, "network")
        let graphics = try dict(root, "graphics")

        guard (boot["loader"] as? String) == "linux" || (boot["loader"] as? String) == "auto" else {
            throw DriverError.invalidArgs("config.boot.loader must be linux or auto")
        }
        guard let kernelPath = strOpt(boot, "kernelPath") else {
            throw DriverError.invalidArgs("config.boot.kernelPath is required for VZLinuxBootLoader")
        }
        guard let diskPath = strOpt(disk, "path") else {
            throw DriverError.invalidArgs("config.disk.path is required")
        }
        let diskSizeMiB = (disk["sizeMiB"] as? Int) ?? (disk["sizeMiB"] as? NSNumber)?.intValue ?? 8192
        let networkMode = (network["mode"] as? String) ?? "shared"
        guard networkMode == "shared" else {
            throw DriverError.invalidArgs("Only network.mode=shared is supported in v1.2")
        }

        return NormalizedVmConfig(
            cpu: cpu,
            memoryBytes: memory,
            kernelPath: kernelPath,
            initrdPath: strOpt(boot, "initrdPath"),
            commandLine: strOpt(boot, "commandLine"),
            diskPath: diskPath,
            diskSizeMiB: diskSizeMiB,
            graphicsEnabled: try bool(graphics, "enabled"),
            graphicsWidth: (graphics["width"] as? Int) ?? (graphics["width"] as? NSNumber)?.intValue ?? 1280,
            graphicsHeight: (graphics["height"] as? Int) ?? (graphics["height"] as? NSNumber)?.intValue ?? 800
        )
    }

    private func currentNormalizedConfig() throws -> NormalizedVmConfig {
        guard let config else {
            throw DriverError.invalidArgs("vm is not configured")
        }
        return try normalizedConfig(config)
    }

    private func isDisplayOpen() -> Bool {
#if canImport(AppKit) && canImport(Virtualization)
        if Thread.isMainThread {
            return displayWindow != nil
        }
        return DispatchQueue.main.sync { displayWindow != nil }
#else
        return false
#endif
    }

#if canImport(Virtualization)
    private func vmStateName(_ state: VZVirtualMachine.State) -> String {
        switch state {
        case .stopped: return "stopped"
        case .running: return "running"
        case .paused: return "paused"
        case .error: return "error"
        case .starting: return "starting"
        case .pausing: return "pausing"
        case .resuming: return "resuming"
        case .stopping: return "stopping"
        case .saving: return "saving"
        case .restoring: return "restoring"
        @unknown default: return "unknown"
        }
    }
#endif
}

struct NormalizedVmConfig {
    let cpu: Int
    let memoryBytes: Int
    let kernelPath: String
    let initrdPath: String?
    let commandLine: String?
    let diskPath: String
    let diskSizeMiB: Int
    let graphicsEnabled: Bool
    let graphicsWidth: Int
    let graphicsHeight: Int
}

final class Driver {
    static let protocolVersion = "gaovm.v1.2"
    static let capabilities = [
        "hello", "ping",
        "vm.configure", "vm.start", "vm.stop", "vm.status",
        "open_display", "close_display"
    ]
    static let requiredCapabilities = ["hello", "ping"]

    private let config: Config
    private let logger: RotatingLogger
    private let vmRuntime: VmRuntime
    private let codec = LengthPrefixedJsonRpc()
    private var listener: UnixListener?
    private var socket: UnixSocket?
    private var nextID: Int = 1
    private var pendingHelloID: Int?
    private var authenticated = false
    private var lastAuthenticatedDaemonRPC = Date()

    init(config: Config, logger: RotatingLogger) {
        self.config = config
        self.logger = logger
        self.vmRuntime = VmRuntime(logger: logger)
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
        logger.log(.info, "daemon connected")
        try sendHello()

        while true {
            if authenticated {
                let elapsed = Date().timeIntervalSince(lastAuthenticatedDaemonRPC)
                if elapsed > 15 {
                    try gracefulExit(reason: "heartbeat timeout (no authenticated daemon RPC within 15s)", code: 12)
                }
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
        let header = try socket.readExact(4)
        let length = header.withUnsafeBytes { rawBuf -> UInt32 in
            rawBuf.load(as: UInt32.self).bigEndian
        }
        if length == 0 {
            throw DriverError.protocolViolation("zero-length frame not allowed")
        }
        let payload = try socket.readExact(Int(length))
        return try codec.decode(payload)
    }

    private func send(_ object: [String: Any]) throws {
        guard let socket else { throw DriverError.io("no control socket") }
        let data = try codec.encode(object)
        try socket.writeAll(data)
    }

    private func sendHello() throws {
        let id = nextRequestID()
        pendingHelloID = id
        try send([
            "jsonrpc": "2.0",
            "id": id,
            "method": "hello",
            "params": [
                "protocol": Self.protocolVersion,
                "authToken": config.authToken,
                "capabilities": Self.capabilities,
                "requiredCapabilities": Self.requiredCapabilities
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
        if idNum == pendingHelloID {
            guard let result = message["result"] as? [String: Any] else {
                throw DriverError.handshakeFailed("hello response missing result")
            }
            try validateHelloResult(result)
            logger.log(.info, "hello response accepted")
            return
        }
    }

    private func handleRequest(method: String, message: [String: Any]) throws {
        guard let id = message["id"] else { return }

        if method == "hello" {
            guard let params = message["params"] as? [String: Any] else {
                try sendError(id: id, code: -32602, message: "hello params must be object")
                return
            }
            let protocolVersion = params["protocol"] as? String
            let token = params["authToken"] as? String
            let daemonCaps = (params["capabilities"] as? [Any] ?? []).map { String(describing: $0) }
            if protocolVersion != Self.protocolVersion {
                try sendError(id: id, code: -32010, message: "protocol mismatch")
                return
            }
            if token != config.authToken {
                try sendError(id: id, code: -32011, message: "auth token mismatch")
                return
            }
            let accepted = daemonCaps.filter { Self.capabilities.contains($0) }
            guard Self.requiredCapabilities.allSatisfy({ accepted.contains($0) }) else {
                try sendError(id: id, code: -32012, message: "capability mismatch")
                return
            }
            authenticated = true
            lastAuthenticatedDaemonRPC = Date()
            logger.log(.info, "daemon hello accepted; authenticated")
            try sendResult(id: id, result: [
                "protocol": Self.protocolVersion,
                "capabilities": Self.capabilities,
                "acceptedCapabilities": accepted
            ])
            return
        }

        if !authenticated {
            try sendError(id: id, code: -32010, message: "hello handshake required")
            return
        }

        lastAuthenticatedDaemonRPC = Date()
        do {
            switch method {
            case "ping":
                try sendResult(id: id, result: [
                    "ok": true,
                    "ts": ISO8601DateFormatter().string(from: Date())
                ])
            case "vm.configure":
                guard let params = message["params"] as? [String: Any],
                      let cfg = params["config"] as? [String: Any] else {
                    try sendError(id: id, code: -32602, message: "vm.configure requires params.config object")
                    return
                }
                let result = try vmRuntime.configure(with: cfg)
                try sendResult(id: id, result: result)
            case "vm.start":
                let result = try vmRuntime.start()
                try sendResult(id: id, result: result)
            case "vm.stop":
                let result = try vmRuntime.stop()
                try sendResult(id: id, result: result)
            case "vm.status":
                try sendResult(id: id, result: vmRuntime.status())
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

    private func validateHelloResult(_ result: [String: Any]) throws {
        let protocolVersion = result["protocol"] as? String
        let accepted = (result["acceptedCapabilities"] as? [Any] ?? []).map { String(describing: $0) }
        guard protocolVersion == Self.protocolVersion else {
            throw DriverError.handshakeFailed("daemon hello result protocol mismatch")
        }
        guard Self.requiredCapabilities.allSatisfy({ accepted.contains($0) }) else {
            throw DriverError.handshakeFailed("daemon hello result capability mismatch")
        }
    }

    private func sendResult(id: Any, result: [String: Any]) throws {
        try send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func sendError(id: Any, code: Int, message: String) throws {
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
        defer { nextID += 1 }
        return nextID
    }

    private func gracefulExit(reason: String, code: Int32) throws -> Never {
        logger.log(.warn, reason)
        fputs("[gaovm-driver-vz] \(reason)\n", stderr)
        socket?.close()
        listener?.close()
        Foundation.exit(code)
    }
}

func parseArgs(_ args: [String]) throws -> Config {
    var socketPath: String?
    var idx = 1
    while idx < args.count {
        let arg = args[idx]
        switch arg {
        case "--socket-path":
            idx += 1
            guard idx < args.count else { throw DriverError.invalidArgs("missing value for --socket-path") }
            socketPath = args[idx]
        case "--auth-token":
            idx += 1
            guard idx < args.count else { throw DriverError.invalidArgs("missing value for --auth-token") }
            // M4 contract: token must come from env, not CLI. Consume but reject to avoid accidental insecure usage.
            throw DriverError.invalidArgs("--auth-token is not supported; set GAOVM_AUTH_TOKEN")
        case "--help":
            print("Usage: gaovm-driver-vz --socket-path PATH")
            print("Required env: GAOVM_AUTH_TOKEN")
            Foundation.exit(0)
        default:
            throw DriverError.invalidArgs("unknown argument: \(arg)")
        }
        idx += 1
    }
    guard let socketPath else {
        throw DriverError.invalidArgs("--socket-path is required")
    }
    guard let authToken = ProcessInfo.processInfo.environment["GAOVM_AUTH_TOKEN"], !authToken.isEmpty else {
        throw DriverError.authMissing
    }
    let logPath = ProcessInfo.processInfo.environment["GAOVM_DRIVER_LOG_PATH"] ?? "\(NSTemporaryDirectory())/gaovm-driver-vz.log"
    return Config(socketPath: socketPath, authToken: authToken, logPath: logPath)
}

do {
    let config = try parseArgs(CommandLine.arguments)
    let logger = RotatingLogger(path: config.logPath)
    logger.log(.info, "driver bootstrap")
    let driver = Driver(config: config, logger: logger)
#if canImport(AppKit)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try driver.run()
        } catch {
            fputs("[gaovm-driver-vz] fatal: \(error)\n", stderr)
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            Foundation.exit(1)
        }
    }
    app.run()
#else
    try driver.run()
#endif
} catch {
    fputs("[gaovm-driver-vz] fatal: \(error)\n", stderr)
    Foundation.exit(1)
}
