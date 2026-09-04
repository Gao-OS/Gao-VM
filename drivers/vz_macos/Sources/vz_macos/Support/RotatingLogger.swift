import Foundation

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
