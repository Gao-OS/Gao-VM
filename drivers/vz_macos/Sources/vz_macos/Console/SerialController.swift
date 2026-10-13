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
    try? finish()
  }

  func finish() throws {
    guard let handle else { return }
    self.handle = nil
    defer { try? handle.close() }
    try handle.synchronize()
    try handle.close()
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
    try finish()
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

struct SerialCaptureSnapshot: Equatable {
  let ready: Bool
  let logPath: String?
}

private final class SerialCaptureObservation {
  private let lock = NSLock()
  private let path: String
  private var ready = false

  init(path: String) { self.path = path }

  var snapshot: SerialCaptureSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return SerialCaptureSnapshot(ready: ready, logPath: ready ? path : nil)
  }

  func setReady(_ value: Bool) {
    lock.lock()
    ready = value
    lock.unlock()
  }
}

final class SerialController {
  private let queue = DispatchQueue(label: "gaovm.driver.serial-log", qos: .utility)
  private let pump: SerialLogPump
  private let observation: SerialCaptureObservation
  private let lock = NSLock()
  private var started = false
  private var closed = false

  init(path: String) throws {
    let observation = SerialCaptureObservation(path: path)
    self.observation = observation
    pump = try SerialLogPump(path: path, observation: observation)
  }

  static func prepare(path: String, completion: @escaping (Result<SerialController, Error>) -> Void)
  {
    DispatchQueue.global(qos: .utility).async {
      completion(Result { try SerialController(path: path) })
    }
  }

  var driverOutput: FileHandle { pump.pipe.fileHandleForWriting }

  var snapshot: SerialCaptureSnapshot { observation.snapshot }

  func start() {
    lock.lock()
    defer { lock.unlock() }
    guard !started, !closed else { return }
    startLocked()
  }

  private func startLocked() {
    started = true
    observation.setReady(true)
    queue.async { [pump] in pump.run() }
  }

  func close(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
    lock.lock()
    defer { lock.unlock() }
    if !started { startLocked() }
    if !closed {
      closed = true
      observation.setReady(false)
      try? pump.pipe.fileHandleForWriting.close()
    }
    // The pump owns the pipe and sink independently of this controller. Even
    // deinit must retain queued bytes until actual EOF, flush and descriptor close.
    queue.async { [pump] in completion(pump.result) }
  }

  deinit { close() }
}

private final class SerialLogPump {
  let pipe = Pipe()
  private let sink: RotatingByteSink
  private let observation: SerialCaptureObservation
  private(set) var result: Result<Void, Error> = .success(())

  init(path: String, observation: SerialCaptureObservation) throws {
    sink = try RotatingByteSink(path: path)
    self.observation = observation
  }

  func run() {
    let descriptor = pipe.fileHandleForReading.fileDescriptor
    // Read and write on the same private I/O queue: no unbounded queue of Data
    // jobs if rotation stalls. Kernel pipe buffering supplies backpressure.
    while true {
      var data = Data(count: 64 * 1024)
      let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        result = .failure(DriverError.io("serial pipe read failed: \(errno)"))
        observation.setReady(false)
        break
      }
      data.count = count
      if case .success = result {
        do { try sink.write(data) } catch {
          result = .failure(error)
          observation.setReady(false)
        }
      }
    }
    observation.setReady(false)
    do { try sink.finish() } catch { result = .failure(error) }
    do { try pipe.fileHandleForReading.close() } catch { result = .failure(error) }
  }
}
