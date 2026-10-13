import Darwin
import Foundation

/// Consumes two owned raw descriptors, never a borrowed VZ descriptor. The caller
/// retains the native connection and its slot until asynchronous release finishes.
/// This byte pump neither authenticates an opening nor stops/inspects a VM.
final class GuestBridgeRelay {
  enum End: Equatable {
    case peerClosed, cancelled, stalledWrite, transportFailure
  }

  private let worker: GuestBridgeRelayWorker

  static func start(
    clientDescriptor: Int32, guestDescriptor: Int32,
    releaseNative: @escaping (@escaping () -> Void) -> Void,
    completion: @escaping (End) -> Void
  ) -> GuestBridgeRelay {
    let worker = GuestBridgeRelayWorker(
      clientDescriptor: clientDescriptor, guestDescriptor: guestDescriptor,
      releaseNative: releaseNative, completion: completion)
    let relay = GuestBridgeRelay(worker: worker)
    worker.start()
    return relay
  }

  private init(worker: GuestBridgeRelayWorker) { self.worker = worker }

  func cancel() { worker.cancel() }

  deinit { worker.cancel() }
}

private final class GuestBridgeRelayWorker {
  typealias End = GuestBridgeRelay.End

  private struct Direction {
    let input: Int32
    let output: Int32
    var buffer = [UInt8](repeating: 0, count: 8192)
    var count = 0
    var offset = 0
    var deadline: DispatchTime?
    var reader: DispatchSourceRead?
    var writer: DispatchSourceWrite?
    var readPaused = false
    var writePaused = true
  }

  private let queue = DispatchQueue(label: "gaovm.driver.guest-relay")
  private let clientDescriptor: Int32
  private let guestDescriptor: Int32
  private let releaseNative: (@escaping () -> Void) -> Void
  private var completion: ((End) -> Void)?
  private var directions: [Direction]
  private var timer: DispatchSourceTimer?
  private var pendingCancellations = 0
  private var closing = false
  private var end: End?
  private var nativeReleased = false
  private var lifetime: GuestBridgeRelayWorker?

  init(
    clientDescriptor: Int32, guestDescriptor: Int32,
    releaseNative: @escaping (@escaping () -> Void) -> Void,
    completion: @escaping (End) -> Void
  ) {
    self.clientDescriptor = clientDescriptor
    self.guestDescriptor = guestDescriptor
    self.releaseNative = releaseNative
    self.completion = completion
    directions = [
      Direction(input: clientDescriptor, output: guestDescriptor),
      Direction(input: guestDescriptor, output: clientDescriptor),
    ]
  }

  func start() { queue.async { self.begin() } }

  func cancel() { queue.async { self.close(.cancelled) } }

  private func begin() {
    lifetime = self
    guard clientDescriptor != guestDescriptor,
      configure(clientDescriptor), configure(guestDescriptor)
    else {
      close(.transportFailure)
      return
    }
    for index in directions.indices {
      let reader = DispatchSource.makeReadSource(
        fileDescriptor: directions[index].input, queue: queue)
      let writer = DispatchSource.makeWriteSource(
        fileDescriptor: directions[index].output, queue: queue)
      reader.setEventHandler { [weak self] in self?.read(index) }
      writer.setEventHandler { [weak self] in self?.write(index) }
      reader.setCancelHandler { [weak self] in self?.sourceCancelled() }
      writer.setCancelHandler { [weak self] in self?.sourceCancelled() }
      directions[index].reader = reader
      directions[index].writer = writer
      pendingCancellations += 2
      reader.resume()
      writer.resume()
      writer.suspend()
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.setEventHandler { [weak self] in self?.deadlineReached() }
    timer.setCancelHandler { [weak self] in self?.sourceCancelled() }
    timer.schedule(deadline: .distantFuture)
    pendingCancellations += 1
    self.timer = timer
    timer.resume()
  }

  private func configure(_ descriptor: Int32) -> Bool {
    guard descriptor >= 0 else { return false }
    let status = Darwin.fcntl(descriptor, F_GETFL)
    let flags = Darwin.fcntl(descriptor, F_GETFD)
    guard status >= 0, flags >= 0,
      Darwin.fcntl(descriptor, F_SETFL, status | O_NONBLOCK) == 0,
      Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    else { return false }
    var enabled: Int32 = 1
    return Darwin.setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
      socklen_t(MemoryLayout.size(ofValue: enabled))) == 0
  }

  private func read(_ index: Int) {
    guard !closing, directions[index].count == 0 else { return }
    let descriptor = directions[index].input
    let count = directions[index].buffer.withUnsafeMutableBytes { buffer in
      Darwin.read(descriptor, buffer.baseAddress, buffer.count)
    }
    if count < 0 {
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
      close(.transportFailure)
      return
    }
    guard count > 0 else {
      close(.peerClosed)
      return
    }
    directions[index].count = count
    directions[index].offset = 0
    directions[index].deadline = .now() + 5
    directions[index].reader?.suspend()
    directions[index].readPaused = true
    directions[index].writer?.resume()
    directions[index].writePaused = false
    armTimer()
    write(index)
  }

  private func write(_ index: Int) {
    guard !closing, directions[index].count > 0 else { return }
    guard let deadline = directions[index].deadline,
      DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds
    else {
      close(.stalledWrite)
      return
    }
    let descriptor = directions[index].output
    let offset = directions[index].offset
    let remaining = directions[index].count - offset
    let count = directions[index].buffer.withUnsafeBytes { buffer in
      Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), remaining)
    }
    if count < 0 {
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
      close(.transportFailure)
      return
    }
    guard count > 0 else {
      close(.transportFailure)
      return
    }
    directions[index].offset += count
    // Partial progress never renews this pending buffer's absolute write budget.
    if directions[index].offset == directions[index].count {
      directions[index].count = 0
      directions[index].offset = 0
      directions[index].deadline = nil
      directions[index].writer?.suspend()
      directions[index].writePaused = true
      directions[index].reader?.resume()
      directions[index].readPaused = false
      armTimer()
    }
  }

  private func armTimer() {
    let next =
      directions.compactMap { $0.deadline }.min {
        $0.uptimeNanoseconds < $1.uptimeNanoseconds
      } ?? .distantFuture
    timer?.schedule(deadline: next)
  }

  private func deadlineReached() {
    guard !closing else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    if directions.contains(where: { $0.deadline.map { $0.uptimeNanoseconds <= now } ?? false }) {
      close(.stalledWrite)
    } else {
      armTimer()
    }
  }

  private func close(_ end: End) {
    guard !closing else { return }
    closing = true
    self.end = end
    for index in directions.indices {
      directions[index].reader?.cancel()
      directions[index].writer?.cancel()
      // Suspended sources must be resumed to deliver their cancellation barriers.
      if directions[index].readPaused { directions[index].reader?.resume() }
      if directions[index].writePaused { directions[index].writer?.resume() }
    }
    timer?.cancel()
    if pendingCancellations == 0 { closeDescriptors() }
  }

  private func sourceCancelled() {
    pendingCancellations -= 1
    if pendingCancellations == 0 { closeDescriptors() }
  }

  private func closeDescriptors() {
    directions = []
    timer = nil
    let descriptors = Set([clientDescriptor, guestDescriptor]).filter { $0 >= 0 }
    for descriptor in descriptors { Darwin.shutdown(descriptor, SHUT_RDWR) }
    for descriptor in descriptors { Darwin.close(descriptor) }
    releaseNative {
      self.queue.async {
        guard !self.nativeReleased, let end = self.end else { return }
        self.nativeReleased = true
        let completion = self.completion
        self.completion = nil
        completion?(end)
        self.lifetime = nil
      }
    }
  }
}
