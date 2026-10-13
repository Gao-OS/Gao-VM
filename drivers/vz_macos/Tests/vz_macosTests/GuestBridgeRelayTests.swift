import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class GuestBridgeRelayTests: XCTestCase {
  func testRelayForwardsBothDirectionsAndClosesRawDescriptorsBeforeNativeCleanup() throws {
    let clientPair = try socketPair()
    let guestPair = try socketPair()
    let deadline = DispatchTime.now() + 3
    let client = try UnixSocket(fd: clientPair.1, writeDeadline: { deadline })
    let guest = try UnixSocket(fd: guestPair.1, writeDeadline: { deadline })
    defer {
      client.close()
      guest.close()
    }
    let nativeQueue = VzRuntimeQueue(label: "fixture.native-release")
    let cleaned = expectation(description: "native cleanup completed")
    let completed = expectation(description: "relay completed")
    let relay = GuestBridgeRelay.start(
      clientDescriptor: clientPair.0, guestDescriptor: guestPair.0,
      releaseNative: { done in
        XCTAssertEqual(Darwin.fcntl(clientPair.0, F_GETFD), -1)
        XCTAssertEqual(Darwin.fcntl(guestPair.0, F_GETFD), -1)
        nativeQueue.async {
          nativeQueue.preconditionIsCurrent()
          cleaned.fulfill()
          done()
        }
      },
      completion: { end in
        XCTAssertEqual(end, .peerClosed)
        completed.fulfill()
      })
    let towardGuest = Data((0..<32771).map { UInt8($0 % 251) })
    let towardClient = Data((0..<32773).map { UInt8($0 % 239) })
    let sent = expectation(description: "client bytes sent")
    DispatchQueue.global().async {
      do { try client.writeAll(towardGuest) } catch { XCTFail("fixture send failed") }
      sent.fulfill()
    }
    XCTAssertEqual(try guest.readExact(towardGuest.count, deadline: deadline), towardGuest)
    let returned = expectation(description: "guest bytes sent")
    DispatchQueue.global().async {
      do { try guest.writeAll(towardClient) } catch { XCTFail("fixture send failed") }
      returned.fulfill()
    }
    XCTAssertEqual(try client.readExact(towardClient.count, deadline: deadline), towardClient)
    wait(for: [sent, returned], timeout: 3)
    guest.close()
    XCTAssertThrowsError(try client.readExact(1, deadline: deadline))
    wait(for: [cleaned, completed], timeout: 3)
    relay.cancel()  // Late cancellation cannot run cleanup a second time.
  }

  func testCancellationOfBackpressuredBytesWaitsForAsynchronousNativeCleanup() throws {
    let clientPair = try socketPair()
    let guestPair = try socketPair()
    try fillSendBuffer(guestPair.0)
    let deadline = DispatchTime.now() + 3
    let client = try UnixSocket(fd: clientPair.1, writeDeadline: { deadline })
    let guest = try UnixSocket(fd: guestPair.1, writeDeadline: { deadline })
    defer {
      client.close()
      guest.close()
    }
    let native = NativeCleanupGate()
    let nativeQueue = VzRuntimeQueue(label: "fixture.native-release")
    let entered = expectation(description: "raw cleanup reached native owner")
    let premature = expectation(description: "completion before native cleanup")
    premature.isInverted = true
    let finished = expectation(description: "completion after native cleanup")
    let relay = GuestBridgeRelay.start(
      clientDescriptor: clientPair.0, guestDescriptor: guestPair.0,
      releaseNative: { done in
        XCTAssertEqual(Darwin.fcntl(clientPair.0, F_GETFD), -1)
        XCTAssertEqual(Darwin.fcntl(guestPair.0, F_GETFD), -1)
        native.hold(done)
        entered.fulfill()
      },
      completion: { end in
        XCTAssertEqual(end, .cancelled)
        if native.isHeld { premature.fulfill() } else { finished.fulfill() }
      })
    try client.writeAll(Data(repeating: 7, count: 8192))
    let responsive = expectation(description: "native queue remains responsive")
    nativeQueue.async { responsive.fulfill() }
    wait(for: [responsive], timeout: 1)
    relay.cancel()
    relay.cancel()
    wait(for: [entered], timeout: 1)
    XCTAssertThrowsError(try client.readExact(1, deadline: deadline))
    wait(for: [premature], timeout: 0.05)
    let done = try XCTUnwrap(native.take())
    nativeQueue.async {
      nativeQueue.preconditionIsCurrent()
      done()
      done()  // Even a duplicated external completion cannot release twice.
    }
    wait(for: [finished], timeout: 1)
  }

  func testDroppingTheOwningHandleCancelsAnOtherwiseIdleRelay() throws {
    let clientPair = try socketPair()
    let guestPair = try socketPair()
    let deadline = DispatchTime.now() + 2
    let client = try UnixSocket(fd: clientPair.1, writeDeadline: { deadline })
    let guest = try UnixSocket(fd: guestPair.1, writeDeadline: { deadline })
    defer {
      client.close()
      guest.close()
    }
    let finished = expectation(description: "abandoned relay cleaned")
    var relay: GuestBridgeRelay? = GuestBridgeRelay.start(
      clientDescriptor: clientPair.0, guestDescriptor: guestPair.0,
      releaseNative: { done in done() },
      completion: { end in
        XCTAssertEqual(end, .cancelled)
        finished.fulfill()
      })
    XCTAssertNotNil(relay)
    // Observe actual forwarding before abandoning the handle, not a start race.
    try client.writeAll(Data([42]))
    XCTAssertEqual(try guest.readExact(1, deadline: deadline), Data([42]))
    relay = nil
    wait(for: [finished], timeout: 1)
    XCTAssertThrowsError(try client.readExact(1, deadline: deadline))
    XCTAssertThrowsError(try guest.readExact(1, deadline: deadline))
  }

  func testPartialWriteProgressDoesNotRestartThePendingBuffersFiveSecondBudget() throws {
    let clientPair = try socketPair()
    let guestPair = try socketPair()
    let filler = try fillSendBuffer(guestPair.0)
    var capacity: Int32 = 32768
    XCTAssertEqual(
      Darwin.setsockopt(
        clientPair.1, SOL_SOCKET, SO_SNDBUF, &capacity,
        socklen_t(MemoryLayout.size(ofValue: capacity))), 0)
    let deadline = DispatchTime.now() + 9
    let client = try UnixSocket(fd: clientPair.1, writeDeadline: { deadline })
    let guest = try UnixSocket(fd: guestPair.1, writeDeadline: { deadline })
    defer {
      client.close()
      guest.close()
    }
    // Queue a complete 8 KiB source chunk before starting the reader. The native
    // destination is saturated and has only 4 KiB of send capacity when drained.
    try client.writeAll(Data(repeating: 7, count: 8192))
    let finished = expectation(description: "stalled pending write expires")
    let started = DispatchTime.now().uptimeNanoseconds
    let relay = GuestBridgeRelay.start(
      clientDescriptor: clientPair.0, guestDescriptor: guestPair.0,
      releaseNative: { done in done() },
      completion: { end in
        XCTAssertEqual(end, .stalledWrite)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertGreaterThan(elapsed, 4.5)
        XCTAssertLessThan(elapsed, 6.75)
        finished.fulfill()
      })
    let progressed = expectation(description: "some buffered output progressed")
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2500)) {
      defer { progressed.fulfill() }
      do {
        let bytes = try guest.readExact(filler + 1, deadline: deadline)
        XCTAssertEqual(bytes.last, 7)
      } catch { XCTFail("fixture partial progress failed") }
    }
    wait(for: [progressed, finished], timeout: 7)
    XCTAssertThrowsError(try client.readExact(1, deadline: deadline))
    relay.cancel()
  }

  func testInvalidDescriptorSetupClosesTheOtherOwnedDescriptorAndReleasesNative() throws {
    let pair = try socketPair()
    let deadline = DispatchTime.now() + 1
    let client = try UnixSocket(fd: pair.1, writeDeadline: { deadline })
    defer { client.close() }
    let finished = expectation(description: "failed setup completed")
    let released = expectation(description: "native owner released on failed setup")
    let relay = GuestBridgeRelay.start(
      clientDescriptor: pair.0, guestDescriptor: -1,
      releaseNative: { done in
        XCTAssertEqual(Darwin.fcntl(pair.0, F_GETFD), -1)
        released.fulfill()
        done()
      },
      completion: { end in
        XCTAssertEqual(end, .transportFailure)
        finished.fulfill()
      })
    wait(for: [released, finished], timeout: 1)
    XCTAssertThrowsError(try client.readExact(1, deadline: deadline))
    relay.cancel()
  }

  @discardableResult
  private func fillSendBuffer(_ descriptor: Int32) throws -> Int {
    let flags = Darwin.fcntl(descriptor, F_GETFL)
    guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw DriverError.io("fixture nonblocking setup failed")
    }
    var size: Int32 = 4096
    guard
      Darwin.setsockopt(
        descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout.size(ofValue: size))) == 0
    else { throw DriverError.io("fixture send-buffer setup failed") }
    var byte: UInt8 = 85
    for count in 0..<65536 {
      if Darwin.write(descriptor, &byte, 1) == 1 { continue }
      guard errno == EAGAIN || errno == EWOULDBLOCK else {
        throw DriverError.io("fixture send-buffer fill failed")
      }
      return count
    }
    throw DriverError.io("fixture failed to saturate its bounded send buffer")
  }

  private func socketPair() throws -> (Int32, Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw DriverError.io("fixture socketpair failed")
    }
    return (descriptors[0], descriptors[1])
  }
}

/// A gate at the external native-cleanup boundary, not a mock of relay internals.
private final class NativeCleanupGate {
  private let lock = NSLock()
  private var callback: (() -> Void)?

  var isHeld: Bool {
    lock.lock()
    defer { lock.unlock() }
    return callback != nil
  }

  func hold(_ callback: @escaping () -> Void) {
    lock.lock()
    defer { lock.unlock() }
    XCTAssertNil(self.callback)
    self.callback = callback
  }

  func take() -> (() -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    let value = callback
    callback = nil
    return value
  }
}
