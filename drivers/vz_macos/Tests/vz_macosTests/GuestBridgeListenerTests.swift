import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class GuestBridgeListenerTests: XCTestCase {
  func testSlowNativeFactoryDoesNotBlockPeerRejectionOrRawClientClose() throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let queue = VzRuntimeQueue(label: "fixture.bridge.slow-factory")
    let connector = GuestNativeConnector(queue: queue) {
      $0(.failure(GuestNativeError.unavailable))
    }
    let requested = expectation(description: "native factory blocked outside the listener queue")
    let release = DispatchSemaphore(value: 0)
    let listener = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true },
      openNative: { kind, deadline, beforeClose, opened, closed in
        requested.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        return connector.open(
          streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
          opened: opened, closed: closed)
      })
    let client = try fixture.connect()
    defer { client.close() }
    let correlation = try fixture.correlation()
    try client.writeAll(
      GuestBridgeFrameIO.encode(.open(correlation, authToken: fixture.config.authToken)))
    wait(for: [requested], timeout: 1)
    let unauthorized = try fixture.connect()
    defer { unauthorized.close() }
    try unauthorized.writeAll(
      GuestBridgeFrameIO.encode(.open(correlation, authToken: "wrong-token")))
    expectEOF(unauthorized, deadline: .now() + 1)
    let joined = expectation(description: "close joins the blocked factory")
    let joinedFlag = BridgeFlag()
    listener.close {
      joinedFlag.set()
      joined.fulfill()
    }
    expectEOF(client, deadline: .now() + 1)
    XCTAssertFalse(joinedFlag.value)
    release.signal()
    wait(for: [joined], timeout: 1)
  }

  func testFragmentedHeaderAndNativeConnectShareOneOriginalFiveSecondDeadline() throws {
    let fixture = try BridgeFixture()
    let queue = VzRuntimeQueue(label: "fixture.bridge.original-deadline")
    let gate = BridgeConnectGate()
    let requested = expectation(description: "fragmented header reaches native connect")
    let connector = GuestNativeConnector(queue: queue) { callback in
      gate.hold(callback)
      requested.fulfill()
    }
    let listener = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true },
      openNative: { kind, deadline, beforeClose, opened, closed in
        connector.open(
          streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
          opened: opened, closed: closed)
      })
    let client = try fixture.connect()
    defer {
      client.close()
      gate.complete(.failure(GuestNativeError.unavailable))
      let joined = expectation(description: "timed-out native work cleaned")
      listener.close { joined.fulfill() }
      wait(for: [joined], timeout: 2)
      fixture.remove()
    }
    let frame = try GuestBridgeFrameIO.encode(
      .open(try fixture.correlation(), authToken: fixture.config.authToken))
    let original = DispatchTime.now()
    try client.writeAll(frame.prefix(1))
    DispatchQueue.global().asyncAfter(deadline: original + 3) {
      do { try client.writeAll(frame.dropFirst()) } catch {
        XCTFail("could not finish opening header")
      }
    }
    wait(for: [requested], timeout: 4)
    expectEOF(client, deadline: original + 5.8)
  }

  func testExistingNodeAndReplacedSocketAreNeverUnlinkedByTheListener() throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let queue = VzRuntimeQueue(label: "fixture.bridge.endpoint-ownership")
    let connector = GuestNativeConnector(queue: queue) {
      $0(.failure(GuestNativeError.unavailable))
    }
    let open: GuestBridgeListener.OpenNative = { kind, deadline, beforeClose, opened, closed in
      connector.open(
        streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
        opened: opened, closed: closed)
    }
    let path = URL(fileURLWithPath: fixture.guestPath)
    let preserved = Data("foreign node".utf8)
    try preserved.write(to: path)
    XCTAssertThrowsError(
      try GuestBridgeListener(config: fixture.config, isSessionActive: { true }, openNative: open))
    XCTAssertEqual(try Data(contentsOf: path), preserved)
    try FileManager.default.removeItem(at: path)
    let listener = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true }, openNative: open)
    var status = stat()
    XCTAssertEqual(Darwin.lstat(fixture.guestPath, &status), 0)
    XCTAssertEqual(status.st_mode & 0o7777, 0o600)
    XCTAssertEqual(status.st_mode & S_IFMT, S_IFSOCK)
    XCTAssertEqual(Darwin.unlink(fixture.guestPath), 0)
    try preserved.write(to: path)
    let joined = expectation(description: "owned listener FD closed")
    listener.close { joined.fulfill() }
    wait(for: [joined], timeout: 1)
    XCTAssertEqual(try Data(contentsOf: path), preserved)
  }

  func testListenerRejectsNonPrivateAndSymlinkGenerationDirectories() throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let queue = VzRuntimeQueue(label: "fixture.bridge.directory-ownership")
    let connector = GuestNativeConnector(queue: queue) {
      $0(.failure(GuestNativeError.unavailable))
    }
    let open: GuestBridgeListener.OpenNative = { kind, deadline, beforeClose, opened, closed in
      connector.open(
        streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
        opened: opened, closed: closed)
    }
    let directory = URL(fileURLWithPath: fixture.guestPath).deletingLastPathComponent()
    XCTAssertEqual(Darwin.chmod(directory.path, 0o755), 0)
    XCTAssertThrowsError(
      try GuestBridgeListener(config: fixture.config, isSessionActive: { true }, openNative: open))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.guestPath))
    XCTAssertEqual(Darwin.chmod(directory.path, 0o700), 0)
    let displaced = directory.path + "-owned"
    try FileManager.default.moveItem(atPath: directory.path, toPath: displaced)
    try FileManager.default.createSymbolicLink(
      atPath: directory.path, withDestinationPath: displaced)
    XCTAssertThrowsError(
      try GuestBridgeListener(config: fixture.config, isSessionActive: { true }, openNative: open))
    XCTAssertFalse(FileManager.default.fileExists(atPath: displaced + "/guest.sock"))
  }

  func testDroppingTheListenerClosesClientBeforeLateNativeCleanup() throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let queue = VzRuntimeQueue(label: "fixture.bridge.abandoned-owner")
    let pair = try socketPair()
    let native = BridgeNativeSocket(descriptor: pair.0, queue: queue)
    let guest = try UnixSocket(fd: pair.1)
    defer { guest.close() }
    let gate = BridgeConnectGate()
    let requested = expectation(description: "native work pending before owner is dropped")
    let cleaned = expectation(description: "abandoned listener joins actual native cleanup")
    let connector = GuestNativeConnector(queue: queue) { callback in
      gate.hold(callback)
      requested.fulfill()
    }
    var listener: GuestBridgeListener? = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true },
      openNative: { kind, deadline, beforeClose, opened, closed in
        connector.open(
          streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
          opened: opened,
          closed: {
            closed()
            cleaned.fulfill()
          })
      })
    XCTAssertNotNil(listener)
    let client = try fixture.connect()
    defer { client.close() }
    try client.writeAll(
      GuestBridgeFrameIO.encode(
        .open(try fixture.correlation(), authToken: fixture.config.authToken)))
    wait(for: [requested], timeout: 1)
    listener = nil
    expectEOF(client, deadline: .now() + 1)
    queue.sync { XCTAssertEqual(native.closeCount, 0) }
    gate.complete(.success(native))
    wait(for: [cleaned], timeout: 1)
    queue.sync { XCTAssertEqual(native.closeCount, 1) }
    expectEOF(guest, deadline: .now() + 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.guestPath))
  }

  func testInvalidOrUnauthenticatedFramesCloseSilentlyWithoutNativeCalls() throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let queue = VzRuntimeQueue(label: "fixture.bridge.reject")
    var calls = 0
    let connector = GuestNativeConnector(queue: queue) { callback in
      calls += 1
      callback(.failure(GuestNativeError.unavailable))
    }
    let listener = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true },
      openNative: { kind, deadline, beforeClose, opened, closed in
        connector.open(
          streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
          opened: opened, closed: closed)
      })
    defer { listener.close() }
    let correlation = try fixture.correlation()
    let payload = String(
      decoding: try GuestBridgeProtocolCodec().encode(
        .open(correlation, authToken: fixture.config.authToken)), as: UTF8.self)
    let invalid = [
      payload.replacingOccurrences(of: fixture.config.authToken, with: "wrong-token"),
      payload.replacingOccurrences(of: correlation.vmId, with: "vm_01J00000000000000000000001"),
      payload.replacingOccurrences(of: "\"driver_generation\":8", with: "\"driver_generation\":9"),
      payload.replacingOccurrences(of: "gaovm.bridge.v1", with: "gaovm.bridge.v2"),
      payload.replacingOccurrences(of: "\"control\"", with: "\"binary\""),
      "{\"unexpected\":null," + payload.dropFirst(),
      "{\"auth_token\":\"duplicate\"," + payload.dropFirst(),
      payload.replacingOccurrences(
        of: "\"driver_generation\":8", with: "\"driver_generation\":8.01"),
    ]
    for text in invalid {
      XCTAssertNotEqual(text, payload)
      let client = try fixture.connect()
      defer { client.close() }
      try client.writeAll(frame(Data(text.utf8)))
      expectEOF(client, deadline: .now() + 1)
    }
    for bytes in [Data([0, 0, 0, 0]), Data([0, 0, 16, 1])] {
      let client = try fixture.connect()
      defer { client.close() }
      try client.writeAll(bytes)
      expectEOF(client, deadline: .now() + 1)
    }
    queue.sync { XCTAssertEqual(calls, 0) }
  }

  func testCredentialMismatchAndInactiveOriginalSessionCloseWithoutNativeCalls() throws {
    for active in [false, true] {
      let fixture = try BridgeFixture()
      defer { fixture.remove() }
      let queue = VzRuntimeQueue(label: "fixture.bridge.peer")
      var calls = 0
      let connector = GuestNativeConnector(queue: queue) { callback in
        calls += 1
        callback(.failure(GuestNativeError.unavailable))
      }
      // getpeereid is real; the expected UID mismatch is a fixture, not a
      // demonstration using a separately logged-in macOS user.
      let listener = try GuestBridgeListener(
        config: fixture.config, isSessionActive: { active },
        expectedPeerUID: active ? geteuid() + 1 : geteuid(),
        openNative: { kind, deadline, beforeClose, opened, closed in
          connector.open(
            streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
            opened: opened, closed: closed)
        })
      let client = try fixture.connect()
      defer { client.close() }
      expectEOF(client, deadline: .now() + 1)
      let joined = expectation(description: "credential rejection cleaned")
      listener.close { joined.fulfill() }
      wait(for: [joined], timeout: 1)
      queue.sync { XCTAssertEqual(calls, 0) }
    }
  }

  func testAuthenticatedUnavailableResponseIsCorrelatedAndContainsNoSecret() throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let queue = VzRuntimeQueue(label: "fixture.bridge.unavailable")
    let connector = GuestNativeConnector(queue: queue) {
      $0(.failure(GuestNativeError.unavailable))
    }
    let listener = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true },
      openNative: { kind, deadline, beforeClose, opened, closed in
        connector.open(
          streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
          opened: opened, closed: closed)
      })
    defer { listener.close() }
    let client = try fixture.connect()
    defer { client.close() }
    let correlation = try fixture.correlation(kind: .binary)
    try client.writeAll(
      GuestBridgeFrameIO.encode(.open(correlation, authToken: fixture.config.authToken)))
    let length = try client.readExact(4, deadline: .now() + 1)
      .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    XCTAssertLessThanOrEqual(length, 4096)
    let payload = try client.readExact(Int(length), deadline: .now() + 1)
    XCTAssertEqual(
      try GuestBridgeProtocolCodec().decode(payload), .error(correlation, .unavailable))
    let text = String(decoding: payload, as: UTF8.self)
    XCTAssertFalse(text.contains(fixture.config.authToken))
    XCTAssertFalse(text.contains(fixture.root))
    expectEOF(client, deadline: .now() + 1)
  }

  func testCloseJoinsTheLateNativeCallbackAfterClosingTheRawClient() throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let queue = VzRuntimeQueue(label: "fixture.bridge.close-join")
    let pair = try socketPair()
    let native = BridgeNativeSocket(descriptor: pair.0, queue: queue)
    let guest = try UnixSocket(fd: pair.1)
    defer { guest.close() }
    let gate = BridgeConnectGate()
    let requested = expectation(description: "native connect in flight")
    let connector = GuestNativeConnector(queue: queue) { callback in
      gate.hold(callback)
      requested.fulfill()
    }
    let listener = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true },
      openNative: { kind, deadline, beforeClose, opened, closed in
        connector.open(
          streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
          opened: opened, closed: closed)
      })
    let client = try fixture.connect()
    defer { client.close() }
    try client.writeAll(
      GuestBridgeFrameIO.encode(
        .open(try fixture.correlation(), authToken: fixture.config.authToken)))
    wait(for: [requested], timeout: 1)
    let joined = expectation(description: "listener really closed")
    let joinedFlag = BridgeFlag()
    listener.close {
      joinedFlag.set()
      joined.fulfill()
    }
    expectEOF(client, deadline: .now() + 1)
    let observed = expectation(description: "observe held SDK cleanup")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { observed.fulfill() }
    wait(for: [observed], timeout: 1)
    XCTAssertFalse(joinedFlag.value)
    queue.sync { XCTAssertEqual(native.closeCount, 0) }
    gate.complete(.success(native))
    wait(for: [joined], timeout: 1)
    queue.sync { XCTAssertEqual(native.closeCount, 1) }
    expectEOF(guest, deadline: .now() + 1)
  }

  func testTimedOutOpeningKeepsItsPendingPermitUntilLateNativeCleanup() throws {
    let fixture = try BridgeFixture()
    let queue = VzRuntimeQueue(label: "fixture.bridge.late-permit")
    let gate = BridgeConnectGate()
    let requested = expectation(description: "native connect in flight")
    let connector = GuestNativeConnector(queue: queue) { callback in
      gate.hold(callback)
      requested.fulfill()
    }
    let listener = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true },
      openNative: { kind, deadline, beforeClose, opened, closed in
        connector.open(
          streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
          opened: opened, closed: closed)
      })
    var clients: [UnixSocket] = []
    defer {
      for client in clients { client.close() }
      gate.complete(.failure(GuestNativeError.unavailable))
      let joined = expectation(description: "late work and all pending permits cleaned")
      listener.close { joined.fulfill() }
      wait(for: [joined], timeout: 2)
      fixture.remove()
    }
    let timedOut = try fixture.connect()
    clients.append(timedOut)
    try timedOut.writeAll(
      GuestBridgeFrameIO.encode(
        .open(try fixture.correlation(), authToken: fixture.config.authToken)))
    wait(for: [requested], timeout: 1)
    expectEOF(timedOut, deadline: .now() + 6)
    for _ in 0..<7 {
      let client = try fixture.connect()
      clients.append(client)
      try client.writeAll(Data([0]))
    }
    let excess = try fixture.connect()
    clients.append(excess)
    expectEOF(excess, deadline: .now() + 1)
  }

  func testPeerEOFWithQueuedGuestBytesCancelsPendingNativeAttemptPromptly() throws {
    let fixture = try BridgeFixture()
    let queue = VzRuntimeQueue(label: "fixture.bridge.queued-eof")
    let pair = try socketPair()
    let native = BridgeNativeSocket(descriptor: pair.0, queue: queue)
    let guest = try UnixSocket(fd: pair.1)
    let gate = BridgeConnectGate()
    let requested = expectation(description: "native SDK completion is still pending")
    let cancelled = expectation(
      description: "peer EOF cancels without waiting for the SDK callback")
    let connector = GuestNativeConnector(queue: queue) { callback in
      gate.hold(callback)
      requested.fulfill()
    }
    let listener = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true },
      openNative: { kind, deadline, beforeClose, opened, closed in
        connector.open(
          streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
          opened: { result in
            if case .failure(.cancelled) = result { cancelled.fulfill() }
            opened(result)
          }, closed: closed)
      })
    let client = try fixture.connect()
    defer {
      client.close()
      gate.complete(.success(native))
      let joined = expectation(description: "late native completion and raw sockets cleaned")
      listener.close { joined.fulfill() }
      wait(for: [joined], timeout: 2)
      guest.close()
      fixture.remove()
    }
    let correlation = try fixture.correlation()
    try client.writeAll(
      GuestBridgeFrameIO.encode(.open(correlation, authToken: fixture.config.authToken))
        + Data("queued guest bytes".utf8))
    wait(for: [requested], timeout: 1)
    client.close()
    wait(for: [cancelled], timeout: 1)
    queue.sync { XCTAssertEqual(native.closeCount, 0) }
  }

  func testOnlyEightPartialOpeningsMayRemainPending() throws {
    let fixture = try BridgeFixture()
    let queue = VzRuntimeQueue(label: "fixture.bridge.pending-limit")
    var calls = 0
    let connector = GuestNativeConnector(queue: queue) { callback in
      calls += 1
      callback(.failure(GuestNativeError.unavailable))
    }
    let listener = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true },
      openNative: { kind, deadline, beforeClose, opened, closed in
        connector.open(
          streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
          opened: opened, closed: closed)
      })
    var clients: [UnixSocket] = []
    defer {
      for client in clients { client.close() }
      let joined = expectation(description: "all partial opening resources cleaned")
      listener.close { joined.fulfill() }
      wait(for: [joined], timeout: 2)
      fixture.remove()
    }
    for _ in 0..<8 {
      let client = try fixture.connect()
      clients.append(client)
      try client.writeAll(Data([0, 0]))
    }
    let excess = try fixture.connect()
    clients.append(excess)
    expectEOF(excess, deadline: .now() + 1)
    for client in clients.prefix(8) { XCTAssertFalse(try client.pollReadable(timeoutMs: 0)) }
    queue.sync { XCTAssertEqual(calls, 0) }
  }

  func testAuthenticatedOpeningStripsBothFramesBeforeRawGuestTraffic() throws {
    let fixture = try BridgeFixture()
    defer { fixture.remove() }
    let queue = VzRuntimeQueue(label: "fixture.bridge.native")
    let pair = try socketPair()
    let native = BridgeNativeSocket(descriptor: pair.0, queue: queue)
    let guest = try UnixSocket(fd: pair.1, writeDeadline: { .now() + 2 })
    defer { guest.close() }
    let connector = GuestNativeConnector(queue: queue) { $0(.success(native)) }
    let listener = try GuestBridgeListener(
      config: fixture.config, isSessionActive: { true },
      openNative: { kind, deadline, beforeClose, opened, closed in
        connector.open(
          streamKind: kind, deadline: deadline, beforeNativeClose: beforeClose,
          opened: opened, closed: closed)
      })
    let client = try fixture.connect()
    defer { client.close() }
    let correlation = try fixture.correlation()
    let frame = try GuestBridgeFrameIO.encode(
      .open(correlation, authToken: fixture.config.authToken))
    try client.writeAll(frame + Data("GAB1".utf8))
    XCTAssertEqual(
      try GuestBridgeFrameIO.readResponse(
        from: client, expecting: correlation, deadline: .now() + 2),
      .ready(correlation))
    XCTAssertEqual(try guest.readExact(4, deadline: .now() + 2), Data("GAB1".utf8))
    try guest.writeAll(Data("RAW".utf8))
    XCTAssertEqual(try client.readExact(3, deadline: .now() + 2), Data("RAW".utf8))
    let closed = expectation(description: "listener and native transport cleaned")
    listener.close { closed.fulfill() }
    wait(for: [closed], timeout: 2)
    XCTAssertThrowsError(try client.readExact(1, deadline: .now() + 1))
    XCTAssertThrowsError(try guest.readExact(1, deadline: .now() + 1))
    queue.sync { XCTAssertEqual(native.closeCount, 1) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.guestPath))
  }

  private func socketPair() throws -> (Int32, Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw GuestBridgeProtocolError.transportFailure
    }
    return (descriptors[0], descriptors[1])
  }

  private func expectEOF(_ socket: UnixSocket, deadline: DispatchTime) {
    do {
      _ = try socket.readExact(1, deadline: deadline)
      XCTFail("rejected opening returned data")
    } catch DriverError.eof {
    } catch {
      XCTFail("expected silent EOF, got \(error)")
    }
  }

  private func frame(_ payload: Data) -> Data {
    var length = UInt32(payload.count).bigEndian
    return Data(bytes: &length, count: 4) + payload
  }
}

private final class BridgeFixture {
  let root: String
  let config: Config
  let guestPath: String

  init() throws {
    var template = Array("/private/tmp/gvb.XXXXXX".utf8CString)
    guard let directory = Darwin.mkdtemp(&template) else {
      throw GuestBridgeProtocolError.transportFailure
    }
    root = String(cString: directory)
    let vm = "vm_01J00000000000000000000000"
    let generation = root + "/" + vm + "/8"
    try FileManager.default.createDirectory(atPath: generation, withIntermediateDirectories: true)
    guard Darwin.chmod(root + "/" + vm, 0o700) == 0, Darwin.chmod(generation, 0o700) == 0 else {
      throw GuestBridgeProtocolError.transportFailure
    }
    guestPath = generation + "/guest.sock"
    config = Config(
      vmId: try DriverProtocolV2.VMID(vm), generation: 8, socketPath: generation + "/driver.sock",
      bundlePath: root + "/unused.gaovm", authToken: "test-only-bridge-token",
      logPath: root + "/driver.log")
  }

  func correlation(kind: GuestBridgeProtocol.StreamKind = .control) throws
    -> GuestBridgeProtocol.Correlation
  {
    try .init(
      vmId: config.vmId.rawValue, driverGeneration: config.generation,
      requestId: "req_01J00000000000000000000001",
      operationId: kind == .binary ? "op_01J00000000000000000000001" : nil, streamKind: kind)
  }

  func connect() throws -> UnixSocket {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw GuestBridgeProtocolError.transportFailure }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(guestPath.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(descriptor)
      throw GuestBridgeProtocolError.transportFailure
    }
    return try UnixSocket(fd: descriptor, writeDeadline: { .now() + 2 })
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }
}

private final class BridgeNativeSocket: GuestNativeSocket {
  private let queue: VzRuntimeQueue
  private var descriptor: Int32
  private(set) var closeCount = 0
  init(descriptor: Int32, queue: VzRuntimeQueue) {
    self.descriptor = descriptor
    self.queue = queue
  }
  var fileDescriptor: Int32 {
    queue.preconditionIsCurrent()
    return descriptor
  }
  func close() {
    queue.preconditionIsCurrent()
    closeCount += 1
    if descriptor >= 0 { Darwin.close(descriptor) }
    descriptor = -1
  }
}

private final class BridgeConnectGate {
  private let lock = NSLock()
  private var callback: ((Result<GuestNativeSocket, Error>) -> Void)?

  func hold(_ callback: @escaping (Result<GuestNativeSocket, Error>) -> Void) {
    lock.lock()
    self.callback = callback
    lock.unlock()
  }

  func complete(_ result: Result<GuestNativeSocket, Error>) {
    lock.lock()
    let callback = self.callback
    self.callback = nil
    lock.unlock()
    callback?(result)
  }
}

private final class BridgeFlag {
  private let lock = NSLock()
  private var stored = false

  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set() {
    lock.lock()
    stored = true
    lock.unlock()
  }
}
