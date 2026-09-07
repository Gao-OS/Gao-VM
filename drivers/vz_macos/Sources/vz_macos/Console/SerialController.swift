import Darwin
import Foundation

final class RotatingByteSink {
  private let path: String
  private let maxBytes: UInt64
  private let rotations: Int
  private var handle: FileHandle?
  private var size: UInt64 = 0

  init(path: String, maxBytes: UInt64 = 10 * 1024 * 1024, rotations: Int = 3) throws {
    guard path.hasPrefix("/"), maxBytes > 0, rotations >= 0 else {
      throw DriverError.invalidArgs("invalid serial log rotation configuration")
    }
    self.path = path
    self.maxBytes = maxBytes
    self.rotations = rotations
    try open()
  }

  func write(_ data: Data) throws {
    guard !data.isEmpty else { return }
    var offset = 0
    while offset < data.count {
      if size >= maxBytes { try rotate() }
      guard let handle else { throw DriverError.io("serial log is closed") }
      let capacity = Int(min(maxBytes - size, UInt64(Int.max)))
      let count = min(capacity, data.count - offset)
      try handle.write(contentsOf: data.subdata(in: offset..<(offset + count)))
      size += UInt64(count)
      offset += count
    }
  }

  func close() {
    try? handle?.synchronize()
    try? handle?.close()
    handle = nil
  }

  private func open() throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) {
      guard FileManager.default.createFile(atPath: path, contents: nil) else {
        throw DriverError.io("failed to create serial log: \(path)")
      }
      guard Darwin.chmod(path, mode_t(0o600)) == 0 else {
        throw DriverError.io("failed to chmod serial log: \(path)")
      }
    }
    let handle = try FileHandle(forWritingTo: url)
    size = try handle.seekToEnd()
    self.handle = handle
  }

  private func rotate() throws {
    close()
    let files = FileManager.default
    if rotations == 0 {
      try? files.removeItem(atPath: path)
    } else {
      try? files.removeItem(atPath: "\(path).\(rotations)")
      if rotations > 1 {
        for index in stride(from: rotations - 1, through: 1, by: -1) {
          let source = "\(path).\(index)"
          if files.fileExists(atPath: source) {
            try files.moveItem(atPath: source, toPath: "\(path).\(index + 1)")
          }
        }
      }
      if files.fileExists(atPath: path) {
        try files.moveItem(atPath: path, toPath: "\(path).1")
      }
    }
    try open()
  }
}

final class SerialController {
  private let pipe = Pipe()
  private let queue = DispatchQueue(label: "gaovm.driver.serial-log", qos: .utility)
  private let sink: RotatingByteSink
  private var started = false
  private var closed = false

  init(path: String) throws {
    sink = try RotatingByteSink(path: path)
  }

  var driverOutput: FileHandle { pipe.fileHandleForWriting }

  func start() {
    guard !started, !closed else { return }
    started = true
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.queue.async {
        guard let self else { return }
        try? self.sink.write(data)
      }
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    pipe.fileHandleForReading.readabilityHandler = nil
    try? pipe.fileHandleForWriting.close()
    let remaining = try? pipe.fileHandleForReading.readToEnd()
    queue.sync {
      if let remaining { try? sink.write(remaining) }
      sink.close()
    }
    try? pipe.fileHandleForReading.close()
  }

  deinit { close() }
}
