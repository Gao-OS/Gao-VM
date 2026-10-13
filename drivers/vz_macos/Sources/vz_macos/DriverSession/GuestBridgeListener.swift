import Darwin
import Foundation

enum GuestBridgeListenerError: Error { case unavailable }

/// A disposable owner; the worker keeps cleanup alive after abandonment.
final class GuestBridgeListener {
  typealias OpenNative = (
    GuestBridgeProtocol.StreamKind, DispatchTime,
    @escaping GuestNativeConnector.BeforeNativeClose,
    @escaping GuestNativeConnector.Opened, @escaping () -> Void
  ) -> GuestNativeOpening

  private let worker: GuestBridgeListenerWorker

  init(
    config: Config, isSessionActive: @escaping () -> Bool,
    expectedPeerUID: uid_t = geteuid(), openNative: @escaping OpenNative
  ) throws {
    worker = try GuestBridgeListenerWorker(
      config: config, isSessionActive: isSessionActive,
      expectedPeerUID: expectedPeerUID, openNative: openNative)
    worker.start()
  }

  func close(completion: (() -> Void)? = nil) { worker.close(completion: completion) }
  deinit { worker.close() }
}

private final class GuestBridgeListenerWorker {
  private enum Phase { case opening, connecting, reply, handoff, relay, closing }

  private final class Entry {
    let identity = UUID()
    let deadline: DispatchTime
    let factoryQueue = DispatchQueue(label: "gaovm.driver.guest-connect")
    var descriptor: Int32
    var phase = Phase.opening
    var header = Data()
    var target = 4
    var readingPayload = false
    var correlation: GuestBridgeProtocol.Correlation?
    var response = Data()
    var offset = 0
    var ready = false
    var reader: DispatchSourceRead?
    var writer: DispatchSourceWrite?
    var timer: DispatchSourceTimer?
    var readPaused = false
    var writePaused = true
    var cancellations = 0
    var factoryLive = false
    var nativeStarted = false
    var nativeClosed = false
    var opening: GuestNativeOpening?
    var channel: GuestNativeChannel?
    var relayLive = false
    var pending = true
    var rawCloseCallbacks: [() -> Void] = []

    init(descriptor: Int32, deadline: DispatchTime) {
      self.descriptor = descriptor
      self.deadline = deadline
    }
  }

  private let queue = DispatchQueue(label: "gaovm.driver.guest-listener")
  private let config: Config
  private let isSessionActive: () -> Bool
  private let expectedPeerUID: uid_t
  private let openNative: GuestBridgeListener.OpenNative
  private let listener: UnixListener
  private var source: DispatchSourceRead?
  private var entries: [UUID: Entry] = [:]
  private var closing = false
  private var listenerClosed = false
  private var completions: [() -> Void] = []
  private var lifetime: GuestBridgeListenerWorker?

  init(
    config: Config, isSessionActive: @escaping () -> Bool,
    expectedPeerUID: uid_t, openNative: @escaping GuestBridgeListener.OpenNative
  ) throws {
    self.config = config
    self.isSessionActive = isSessionActive
    self.expectedPeerUID = expectedPeerUID
    self.openNative = openNative
    let path = URL(fileURLWithPath: config.socketPath)
    let generation = path.deletingLastPathComponent()
    let vm = generation.deletingLastPathComponent()
    guard config.socketPath.hasPrefix("/"), path.lastPathComponent == "driver.sock",
      generation.lastPathComponent == String(config.generation),
      vm.lastPathComponent == config.vmId.rawValue,
      !config.authToken.isEmpty, config.authToken.utf8.count <= 512,
      Self.privateDirectory(generation.path), Self.privateDirectory(vm.path)
    else { throw GuestBridgeListenerError.unavailable }
    let guestPath = generation.appendingPathComponent("guest.sock").path
    listener = UnixListener(path: guestPath)
    try listener.bindAndListen()
    guard Self.privateDirectory(generation.path), Self.privateDirectory(vm.path),
      Darwin.chmod(guestPath, 0o600) == 0, Self.configure(listener.fd)
    else {
      listener.close()
      throw GuestBridgeListenerError.unavailable
    }
  }

  private static func privateDirectory(_ path: String) -> Bool {
    var status = stat()
    return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
      && status.st_uid == geteuid() && status.st_mode & 0o7777 == 0o700
  }

  private static func configure(_ descriptor: Int32) -> Bool {
    let flags = Darwin.fcntl(descriptor, F_GETFL)
    let fdFlags = Darwin.fcntl(descriptor, F_GETFD)
    var enabled: Int32 = 1
    return flags >= 0 && fdFlags >= 0
      && Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
      && Darwin.fcntl(descriptor, F_SETFD, fdFlags | FD_CLOEXEC) == 0
      && Darwin.setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
        socklen_t(MemoryLayout.size(ofValue: enabled))) == 0
  }

  func start() {
    queue.async {
      self.lifetime = self
      let source = DispatchSource.makeReadSource(
        fileDescriptor: self.listener.fd, queue: self.queue)
      source.setEventHandler { [weak self] in self?.accept() }
      source.setCancelHandler { [weak self] in
        guard let self else { return }
        self.listener.close()
        self.source = nil
        self.listenerClosed = true
        self.finishIfClosed()
      }
      self.source = source
      source.resume()
    }
  }

  func close(completion: (() -> Void)? = nil) {
    queue.async {
      if let completion { self.completions.append(completion) }
      self.closing = true
      self.source?.cancel()
      for entry in Array(self.entries.values) { self.closeEntry(entry) }
      self.finishIfClosed()
    }
  }

  private func accept() {
    guard !closing else { return }
    for _ in 0..<16 {
      let descriptor = Darwin.accept(listener.fd, nil, nil)
      if descriptor < 0 {
        if errno == EINTR { continue }
        return
      }
      let deadline = DispatchTime.now() + 5
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard isSessionActive(), Darwin.getpeereid(descriptor, &uid, &gid) == 0,
        uid == expectedPeerUID, entries.values.filter({ $0.pending }).count < 8,
        Self.configure(descriptor)
      else {
        Darwin.close(descriptor)
        continue
      }
      let entry = Entry(descriptor: descriptor, deadline: deadline)
      entries[entry.identity] = entry
      installSources(entry)
    }
  }

  private func installSources(_ entry: Entry) {
    let reader = DispatchSource.makeReadSource(fileDescriptor: entry.descriptor, queue: queue)
    let writer = DispatchSource.makeWriteSource(fileDescriptor: entry.descriptor, queue: queue)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    reader.setEventHandler { [weak self] in self?.read(entry) }
    writer.setEventHandler { [weak self] in self?.write(entry) }
    timer.setEventHandler { [weak self] in self?.expire(entry) }
    for source in [reader as DispatchSourceProtocol, writer, timer] {
      source.setCancelHandler { [weak self] in
        entry.cancellations -= 1
        if entry.cancellations == 0 { self?.sourcesDrained(entry) }
      }
    }
    entry.reader = reader
    entry.writer = writer
    entry.timer = timer
    entry.cancellations = 3
    timer.schedule(deadline: entry.deadline)
    reader.resume()
    writer.resume()
    writer.suspend()
    timer.resume()
  }

  private func read(_ entry: Entry) {
    guard entry.phase != .closing, entry.phase != .handoff else { return }
    if entry.phase != .opening {
      var byte: UInt8 = 0
      let count = Darwin.recv(entry.descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
      if count == 0 {
        closeEntry(entry)
      } else if count > 0 {
        entry.reader?.suspend()
        entry.readPaused = true
      } else if errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
        closeEntry(entry)
      }
      return
    }
    for _ in 0..<4 {
      guard isSessionActive(), DispatchTime.now() < entry.deadline else { return closeEntry(entry) }
      var bytes = [UInt8](repeating: 0, count: entry.target - entry.header.count)
      let count = Darwin.read(entry.descriptor, &bytes, bytes.count)
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { return }
        return closeEntry(entry)
      }
      guard count > 0 else { return closeEntry(entry) }
      entry.header.append(contentsOf: bytes.prefix(count))
      guard entry.header.count == entry.target else { continue }
      if !entry.readingPayload {
        let length = entry.header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (1...4096).contains(length) else { return closeEntry(entry) }
        entry.header = Data()
        entry.target = Int(length)
        entry.readingPayload = true
      } else {
        authorize(entry)
        return
      }
    }
  }

  private func authorize(_ entry: Entry) {
    guard let message = try? GuestBridgeProtocolCodec().decode(entry.header),
      case .open(let correlation, let token) = message,
      correlation.vmId == config.vmId.rawValue, correlation.driverGeneration == config.generation,
      constantTimeEqual(token, config.authToken), isSessionActive(),
      DispatchTime.now() < entry.deadline
    else { return closeEntry(entry) }
    entry.header = Data()
    entry.correlation = correlation
    entry.phase = .connecting
    schedulePeerCheck(entry)
    entry.factoryLive = true
    entry.nativeStarted = true
    entry.factoryQueue.async {
      let opening = self.openNative(
        correlation.streamKind, entry.deadline,
        { done in
          self.queue.async {
            entry.rawCloseCallbacks.append(done)
            self.closeEntry(entry)
            self.acknowledgeRawClose(entry)
          }
        },
        { result in self.queue.async { self.nativeOpened(entry, result) } },
        {
          self.queue.async {
            entry.nativeClosed = true
            self.finishEntryIfClosed(entry)
          }
        })
      self.queue.async {
        entry.factoryLive = false
        entry.opening = opening
        if entry.phase == .closing, entry.descriptor < 0 { opening.cancel() }
        self.finishEntryIfClosed(entry)
      }
    }
  }

  private func nativeOpened(_ entry: Entry, _ result: Result<GuestNativeChannel, GuestNativeError>)
  {
    if case .success(let channel) = result { entry.channel = channel }
    guard entry.phase != .closing, isSessionActive(), DispatchTime.now() < entry.deadline else {
      return closeEntry(entry)
    }
    guard let correlation = entry.correlation else { return closeEntry(entry) }
    let message: GuestBridgeProtocol.Message
    switch result {
    case .success:
      entry.ready = true
      message = .ready(correlation)
    case .failure(.unavailable): message = .error(correlation, .unavailable)
    case .failure(.limitExceeded): message = .error(correlation, .limitExceeded)
    default: return closeEntry(entry)
    }
    guard let response = try? GuestBridgeFrameIO.encode(message) else { return closeEntry(entry) }
    entry.response = response
    entry.phase = .reply
    entry.writer?.resume()
    entry.writePaused = false
    write(entry)
  }

  private func write(_ entry: Entry) {
    guard entry.phase == .reply else { return }
    guard isSessionActive(), DispatchTime.now() < entry.deadline else { return closeEntry(entry) }
    let count = entry.response.withUnsafeBytes { bytes in
      Darwin.write(
        entry.descriptor, bytes.baseAddress?.advanced(by: entry.offset), bytes.count - entry.offset)
    }
    if count < 0 {
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
      return closeEntry(entry)
    }
    guard count > 0 else { return closeEntry(entry) }
    entry.offset += count
    if entry.offset == entry.response.count {
      if !entry.ready { return closeEntry(entry) }
      entry.phase = .handoff
      cancelSources(entry)
    }
  }

  private func expire(_ entry: Entry) {
    guard entry.phase != .closing, entry.phase != .handoff else { return }
    guard isSessionActive(), DispatchTime.now() < entry.deadline else { return closeEntry(entry) }
    if entry.phase == .connecting || entry.phase == .reply {
      // A suspended reader preserves early guest bytes; poll observes a full peer
      // close without consuming them or spinning on their readability.
      var status = pollfd(fd: entry.descriptor, events: Int16(POLLIN), revents: 0)
      let result = Darwin.poll(&status, 1, 0)
      if result > 0, status.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
        return closeEntry(entry)
      }
      if result < 0, errno != EINTR { return closeEntry(entry) }
      schedulePeerCheck(entry)
    } else {
      entry.timer?.schedule(deadline: entry.deadline)
    }
  }

  private func schedulePeerCheck(_ entry: Entry) {
    entry.timer?.schedule(deadline: min(entry.deadline, .now() + .milliseconds(20)))
  }

  private func cancelSources(_ entry: Entry) {
    entry.reader?.cancel()
    entry.writer?.cancel()
    entry.timer?.cancel()
    if entry.readPaused {
      entry.reader?.resume()
      entry.readPaused = false
    }
    if entry.writePaused {
      entry.writer?.resume()
      entry.writePaused = false
    }
  }

  private func sourcesDrained(_ entry: Entry) {
    entry.reader = nil
    entry.writer = nil
    entry.timer = nil
    entry.header = Data()
    entry.response = Data()
    if entry.phase == .handoff, isSessionActive(), DispatchTime.now() < entry.deadline,
      let channel = entry.channel
    {
      let descriptor = entry.descriptor
      entry.descriptor = -1
      entry.phase = .relay
      entry.pending = false
      entry.relayLive = true
      channel.startRelay(clientDescriptor: descriptor) { _ in
        self.queue.async {
          entry.relayLive = false
          self.closeEntry(entry)
        }
      }
    } else {
      entry.phase = .closing
      if entry.descriptor >= 0 {
        Darwin.shutdown(entry.descriptor, SHUT_RDWR)
        Darwin.close(entry.descriptor)
        entry.descriptor = -1
      }
      entry.opening?.cancel()
      entry.channel?.cancel()
      acknowledgeRawClose(entry)
      finishEntryIfClosed(entry)
    }
  }

  private func closeEntry(_ entry: Entry) {
    guard entries[entry.identity] != nil else { return }
    entry.phase = .closing
    if entry.cancellations > 0 { cancelSources(entry) } else { sourcesDrained(entry) }
  }

  private func finishEntryIfClosed(_ entry: Entry) {
    guard entry.phase == .closing, entry.descriptor < 0, entry.cancellations == 0,
      !entry.factoryLive, !entry.relayLive, !entry.nativeStarted || entry.nativeClosed
    else { return }
    entries.removeValue(forKey: entry.identity)
    finishIfClosed()
  }

  private func acknowledgeRawClose(_ entry: Entry) {
    guard entry.descriptor < 0, entry.cancellations == 0, !entry.relayLive else { return }
    let callbacks = entry.rawCloseCallbacks
    entry.rawCloseCallbacks = []
    for callback in callbacks { callback() }
  }

  private func finishIfClosed() {
    guard closing, listenerClosed, entries.isEmpty else { return }
    let callbacks = completions
    completions = []
    for callback in callbacks { callback() }
    lifetime = nil
  }
}
