import Foundation

enum LogLevel: String {
    case error, warn, info, debug
}

enum DriverLogEvent: String {
    case log = "driver.log"
    case bootstrap = "driver.bootstrap"
    case authenticated = "driver.authenticated"
    case commandSucceeded = "driver.command.succeeded"
    case commandFailed = "driver.command.failed"
    case controlLost = "driver.control_lost"
    case fatal = "driver.fatal"
    case runtimeConfigured = "runtime.configured"
    case runtimeStarted = "runtime.started"
    case runtimeStopRequested = "runtime.stop_requested"
    case runtimeForceStop = "runtime.force_stop"
    case runtimeStopped = "runtime.stopped"
    case runtimeStateChanged = "runtime.state_changed"
    case runtimeCleanShutdown = "runtime.clean_shutdown"
    case runtimeError = "runtime.error"
    case diskCreated = "runtime.disk_created"
    case logDropped = "driver.log_dropped"
}

final class RotatingLogger {
    struct Identity {
        let vmID: DriverProtocolV2.VMID
        let driverGeneration: Int
    }

    private let path: String
    private let identity: Identity?
    private let maxBytes = 10 * 1024 * 1024
    private let maxRotations = 3
    private let queue = DispatchQueue(label: "gaovm.driver.logger")
    private let pendingWrites = DispatchGroup()
    private let admission = NSLock()
    private var queuedBytes = 0
    private var queuedRecords = 0
    private var droppedRecords = 0
    private static let maxQueuedBytes = 1024 * 1024
    private static let maxQueuedRecords = 256
    private static let maxMessageBytes = 16 * 1024

    init(path: String, identity: Identity? = nil) {
        self.path = path
        self.identity = identity
    }

    /// Teardown-only drain, never called on the VZ or logging queue. A timeout
    /// does not confirm persistence and must not hold driver shutdown forever.
    func flush(timeout: TimeInterval = 1) -> Bool {
        precondition(timeout.isFinite && timeout >= 0)
        dispatchPrecondition(condition: .notOnQueue(queue))
        return pendingWrites.wait(timeout: .now() + timeout) == .success
    }

    @discardableResult
    func log(
        _ level: LogLevel, _ message: String,
        operationID: DriverProtocolV2.OperationID? = nil,
        eventType: DriverLogEvent = .log
    ) -> Bool {
        // Never retain an unbounded caller string or enqueue an unbounded number
        // of closures behind a stalled filesystem. No I/O occurs under this lock.
        let payload = Data(message.utf8.prefix(Self.maxMessageBytes + 1))
        let acceptedAt = Date()
        admission.lock()
        defer { admission.unlock() }
        let reservedBytes = payload.count + 1024  // Structured metadata and loss notice.
        guard payload.count <= Self.maxMessageBytes,
            queuedRecords < Self.maxQueuedRecords,
            reservedBytes <= Self.maxQueuedBytes - queuedBytes
        else {
            if droppedRecords < Int.max { droppedRecords += 1 }
            return false
        }
        queuedBytes += reservedBytes
        queuedRecords += 1
        queue.async(group: pendingWrites) { [self] in
            defer {
                admission.lock()
                queuedBytes -= reservedBytes
                queuedRecords -= 1
                admission.unlock()
            }
            do {
                try append(
                    level, payload: payload, at: acceptedAt,
                    operationID: operationID, eventType: eventType)
                admission.lock()
                let dropped = droppedRecords
                droppedRecords = 0
                admission.unlock()
                if dropped > 0 {
                    let notice = "dropped \(dropped) log records (queue or record limit)"
                    try append(
                        .warn, payload: Data(notice.utf8), at: Date(),
                        operationID: nil, eventType: .logDropped)
                }
            } catch {
                fputs("[gaovm-driver-vz][logger] \(error)\n", stderr)
            }
        }
        return true
    }

    private func append(
        _ level: LogLevel, payload: Data, at date: Date,
        operationID: DriverProtocolV2.OperationID?, eventType: DriverLogEvent
    ) throws {
        try rotateIfNeeded()
        try ensureParentDir()
        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: date),
            "level": level.rawValue,
            "component": "gaovm-driver-vz",
            "vm_id": identity?.vmID.rawValue as Any? ?? NSNull(),
            "operation_id": operationID?.rawValue as Any? ?? NSNull(),
            "driver_generation": identity?.driverGeneration as Any? ?? NSNull(),
            "request_id": NSNull(),
            "event_type": eventType.rawValue,
            "message": String(decoding: payload, as: UTF8.self),
        ]
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0a)
        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else if !FileManager.default.createFile(atPath: path, contents: data) {
            throw DriverError.io("failed to create driver log")
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
