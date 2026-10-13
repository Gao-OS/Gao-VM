import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class GuestNativeConnectorTests: XCTestCase {
  func testOriginalDeadlineRetainsNativeAndSlotUntilClientCloseAcknowledged() throws {
    let queue = VzRuntimeQueue(label: "fixture.guest-native.client-close-barrier")
    let nativePair = try socketPair()
    let clientPair = try socketPair()
    let native = NativeSocketFixture(descriptor: nativePair.0, queue: queue)
    let guest = try UnixSocket(fd: nativePair.1)
    let ownedClient = try UnixSocket(fd: clientPair.0)
    let client = try UnixSocket(fd: clientPair.1, writeDeadline: { .now() + 1 })
    defer {
      guest.close()
      ownedClient.close()
      client.close()
    }
    var calls = 0
    let connector = GuestNativeConnector(queue: queue) { callback in
      calls += 1
      callback(.success(native))
    }
    let prepared = expectation(description: "native connection prepared")
    let requested = expectation(description: "original deadline requests raw client cleanup")
    let closed = expectation(description: "native closes only after actual raw client cleanup")
    var channel: GuestNativeChannel?
    var acknowledge: (() -> Void)?
    let opening = connector.open(
      streamKind: .control, deadline: .now() + 0.1,
      beforeNativeClose: { done in
        XCTAssertFalse(native.isClosed)
        acknowledge = done
        requested.fulfill()
      },
      opened: { result in
        channel = try? result.get()
        XCTAssertNotNil(channel)
        prepared.fulfill()
      },
      closed: {
        XCTAssertEqual(ownedClient.fd, -1)
        XCTAssertEqual(native.closeCount, 1)
        closed.fulfill()
      })
    wait(for: [prepared, requested], timeout: 1)
    queue.sync { XCTAssertEqual(native.closeCount, 0) }
    try client.writeAll(Data([7]))
    XCTAssertEqual(try ownedClient.readExact(1, deadline: .now() + 1), Data([7]))
    let denied = expectation(description: "unacknowledged cleanup retains the control slot")
    let deniedClosed = expectation(description: "excess connection owns no native resource")
    let excess = connector.open(
      streamKind: .control, deadline: .now() + 1,
      opened: { result in
        XCTAssertEqual(result.failure, .limitExceeded)
        denied.fulfill()
      }, closed: { deniedClosed.fulfill() })
    wait(for: [denied, deniedClosed], timeout: 1)
    ownedClient.close()
    queue.sync {
      XCTAssertEqual(calls, 1)
      acknowledge?()
      acknowledge?()
    }
    wait(for: [closed], timeout: 1)
    XCTAssertThrowsError(try guest.readExact(1, deadline: .now() + 1))
    XCTAssertThrowsError(try client.readExact(1, deadline: .now() + 1))
    queue.sync { channel = nil }
    withExtendedLifetime([opening, excess]) {}
  }

  func testHealthyRelayOutlivesItsCompletedOpeningDeadline() throws {
    let queue = VzRuntimeQueue(label: "fixture.guest-native.established")
    let nativePair = try socketPair()
    let clientPair = try socketPair()
    let native = NativeSocketFixture(descriptor: nativePair.0, queue: queue)
    let ioDeadline = DispatchTime.now() + 2
    let guest = try UnixSocket(fd: nativePair.1, writeDeadline: { ioDeadline })
    let client = try UnixSocket(fd: clientPair.1, writeDeadline: { ioDeadline })
    defer {
      guest.close()
      client.close()
    }
    let connector = GuestNativeConnector(queue: queue) { $0(.success(native)) }
    let deadline = DispatchTime.now() + 0.1
    let established = expectation(description: "relay starts before opening deadline")
    let closed = expectation(description: "established native channel closed")
    let relayed = expectation(description: "established relay completed")
    var channel: GuestNativeChannel?
    let opening = connector.open(
      streamKind: .control, deadline: deadline,
      opened: { result in
        channel = try? result.get()
        XCTAssertNotNil(channel)
        channel?.startRelay(clientDescriptor: clientPair.0) { result in
          XCTAssertEqual(try? result.get(), .peerClosed)
          relayed.fulfill()
        }
        established.fulfill()
      }, closed: { closed.fulfill() })
    wait(for: [established], timeout: 1)
    try client.writeAll(Data([1]))
    XCTAssertEqual(try guest.readExact(1, deadline: ioDeadline), Data([1]))
    let elapsed = expectation(description: "original opening deadline passed")
    queue.asyncAfter(deadline: deadline + 0.02) { elapsed.fulfill() }
    wait(for: [elapsed], timeout: 1)
    queue.sync { XCTAssertFalse(native.isClosed) }
    try guest.writeAll(Data([2]))
    XCTAssertEqual(try client.readExact(1, deadline: ioDeadline), Data([2]))
    guest.close()
    wait(for: [closed, relayed], timeout: 1)
    queue.sync { channel = nil }
    withExtendedLifetime(opening) {}
  }

  func testClosingOneRuntimeConnectorDoesNotCloseAnotherRuntimeControlRelay() throws {
    let queueA = VzRuntimeQueue(label: "fixture.guest-native.vm-a")
    let queueB = VzRuntimeQueue(label: "fixture.guest-native.vm-b")
    let guestPairA = try socketPair()
    let guestPairB = try socketPair()
    let clientPairA = try socketPair()
    let clientPairB = try socketPair()
    let nativeA = NativeSocketFixture(descriptor: guestPairA.0, queue: queueA)
    let nativeB = NativeSocketFixture(descriptor: guestPairB.0, queue: queueB)
    let deadline = DispatchTime.now() + 3
    let guestA = try UnixSocket(fd: guestPairA.1, writeDeadline: { deadline })
    let guestB = try UnixSocket(fd: guestPairB.1, writeDeadline: { deadline })
    let clientA = try UnixSocket(fd: clientPairA.1, writeDeadline: { deadline })
    let clientB = try UnixSocket(fd: clientPairB.1, writeDeadline: { deadline })
    defer {
      guestA.close()
      guestB.close()
      clientA.close()
      clientB.close()
    }
    let connectorA = GuestNativeConnector(queue: queueA) { $0(.success(nativeA)) }
    let connectorB = GuestNativeConnector(queue: queueB) { $0(.success(nativeB)) }
    let admittedA = expectation(description: "VM-A control admitted")
    let admittedB = expectation(description: "VM-B independent control admitted")
    let closedA = expectation(description: "VM-A native closed")
    let closedB = expectation(description: "VM-B native closed")
    let relayedA = expectation(description: "VM-A relay completed")
    let relayedB = expectation(description: "VM-B relay completed")
    var channelA: GuestNativeChannel?
    var channelB: GuestNativeChannel?
    let openingA = connectorA.open(
      streamKind: .control, deadline: deadline,
      opened: { result in
        channelA = try? result.get()
        XCTAssertNotNil(channelA)
        channelA?.startRelay(clientDescriptor: clientPairA.0) { result in
          XCTAssertEqual(try? result.get(), .cancelled)
          relayedA.fulfill()
        }
        admittedA.fulfill()
      }, closed: { closedA.fulfill() })
    let openingB = connectorB.open(
      streamKind: .control, deadline: deadline,
      opened: { result in
        channelB = try? result.get()
        XCTAssertNotNil(channelB)
        channelB?.startRelay(clientDescriptor: clientPairB.0) { result in
          XCTAssertNil(result.failure)
          relayedB.fulfill()
        }
        admittedB.fulfill()
      }, closed: { closedB.fulfill() })
    wait(for: [admittedA, admittedB], timeout: 1)
    try clientA.writeAll(Data([1]))
    XCTAssertEqual(try guestA.readExact(1, deadline: deadline), Data([1]))
    try clientB.writeAll(Data([2]))
    XCTAssertEqual(try guestB.readExact(1, deadline: deadline), Data([2]))
    connectorA.shutdown()
    wait(for: [closedA, relayedA], timeout: 1)
    XCTAssertThrowsError(try clientA.readExact(1, deadline: deadline))
    XCTAssertThrowsError(try guestA.readExact(1, deadline: deadline))
    queueB.sync { XCTAssertFalse(nativeB.isClosed) }
    try guestB.writeAll(Data([3]))
    XCTAssertEqual(try clientB.readExact(1, deadline: deadline), Data([3]))
    try clientB.writeAll(Data([4]))
    XCTAssertEqual(try guestB.readExact(1, deadline: deadline), Data([4]))
    queueA.sync { channelA = nil }
    queueB.sync { channelB = nil }
    wait(for: [closedB, relayedB], timeout: 1)
    queueA.sync { XCTAssertEqual(nativeA.closeCount, 1) }
    queueB.sync { XCTAssertEqual(nativeB.closeCount, 1) }
    withExtendedLifetime([openingA, openingB]) {}
  }

  func testPreparedConnectionStillUsesTheOriginalOpeningDeadlineAndRejectsLateRelay() throws {
    let queue = VzRuntimeQueue(label: "fixture.guest-native.prepared-timeout")
    let pair = try socketPair()
    let clientPair = try socketPair()
    let native = NativeSocketFixture(descriptor: pair.0, queue: queue)
    let peer = try UnixSocket(fd: pair.1)
    let client = try UnixSocket(fd: clientPair.1)
    defer {
      peer.close()
      client.close()
    }
    let connector = GuestNativeConnector(queue: queue) { $0(.success(native)) }
    let prepared = expectation(description: "native connected without a flushed ready response")
    let closed = expectation(description: "prepared native channel expired")
    var channel: GuestNativeChannel?
    let opening = connector.open(
      streamKind: .control, deadline: .now() + 0.05,
      opened: { result in
        channel = try? result.get()
        XCTAssertNotNil(channel)
        prepared.fulfill()
      },
      closed: {
        XCTAssertTrue(native.isClosed)
        closed.fulfill()
      })
    wait(for: [prepared, closed], timeout: 1)
    let denied = expectation(description: "late ready cannot turn an expired channel into a relay")
    queue.sync {
      channel?.startRelay(clientDescriptor: clientPair.0) { result in
        XCTAssertEqual(result.failure, .deadlineExpired)
        denied.fulfill()
      }
    }
    wait(for: [denied], timeout: 1)
    XCTAssertThrowsError(try peer.readExact(1, deadline: .now() + 1))
    XCTAssertThrowsError(try client.readExact(1, deadline: .now() + 1))
    queue.sync {
      XCTAssertEqual(native.closeCount, 1)
      channel = nil
    }
    withExtendedLifetime(opening) {}
  }

  func testDroppingAnUnresolvedOpeningCancelsButDoesNotReleaseItsLiveNativeWork() throws {
    let queue = VzRuntimeQueue(label: "fixture.guest-native.abandoned-opening")
    let pair = try socketPair()
    let native = NativeSocketFixture(descriptor: pair.0, queue: queue)
    let peer = try UnixSocket(fd: pair.1)
    defer { peer.close() }
    let gate = NativeConnectGate()
    let pending = expectation(description: "actual native connect pending")
    let cancelled = expectation(description: "abandoned opening cancelled")
    let closed = expectation(description: "abandoned native work really cleaned")
    let connector = GuestNativeConnector(queue: queue) { callback in
      gate.hold(callback)
      pending.fulfill()
    }
    var opening: GuestNativeOpening? = connector.open(
      streamKind: .control, deadline: .now() + 2,
      opened: { result in
        XCTAssertEqual(result.failure, .cancelled)
        cancelled.fulfill()
      },
      closed: {
        XCTAssertTrue(native.isClosed)
        closed.fulfill()
      })
    XCTAssertNotNil(opening)
    wait(for: [pending], timeout: 1)
    opening = nil
    wait(for: [cancelled], timeout: 1)
    queue.sync { XCTAssertFalse(native.isClosed) }
    gate.complete(.success(native))
    wait(for: [closed], timeout: 1)
    XCTAssertThrowsError(try peer.readExact(1, deadline: .now() + 1))
    queue.sync { XCTAssertEqual(native.closeCount, 1) }
  }

  func testUnconfiguredRuntimeCannotOpenAGuestChannel() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logger = RotatingLogger(path: directory.appendingPathComponent("driver.log").path)
    let runtime = VzRuntime(logger: logger)
    let rejected = expectation(description: "unconfigured runtime cannot reach a native guest port")
    let closed = expectation(description: "failed native opening owns no live resources")
    let opening = runtime.openGuestChannel(
      streamKind: .control, deadline: .now() + 1,
      opened: { result in
        XCTAssertEqual(result.failure, .unavailable)
        rejected.fulfill()
      }, closed: { closed.fulfill() })
    wait(for: [rejected, closed], timeout: 1)
    withExtendedLifetime(opening) {}
  }

  func testShutdownFencesNewOpeningsAndClosesLateNativeSuccess() throws {
    let queue = VzRuntimeQueue(label: "fixture.guest-native.shutdown")
    let pair = try socketPair()
    let native = NativeSocketFixture(descriptor: pair.0, queue: queue)
    let peer = try UnixSocket(fd: pair.1)
    defer { peer.close() }
    let gate = NativeConnectGate()
    let requested = expectation(description: "native connect pending")
    var calls = 0
    let connector = GuestNativeConnector(queue: queue) { callback in
      calls += 1
      if calls == 1 {
        gate.hold(callback)
        requested.fulfill()
      } else {
        callback(.failure(NSError(domain: "GuestNativeFixture", code: 1)))
      }
    }
    let cancelled = expectation(description: "pending opening cancelled by teardown")
    let cleaned = expectation(description: "late native connection closed")
    let opening = connector.open(
      streamKind: .control, deadline: .now() + 3,
      opened: { result in
        XCTAssertEqual(result.failure, .cancelled)
        cancelled.fulfill()
      },
      closed: {
        XCTAssertTrue(native.isClosed)
        cleaned.fulfill()
      })
    wait(for: [requested], timeout: 1)
    connector.shutdown()
    connector.shutdown()
    wait(for: [cancelled], timeout: 0.25)
    let denied = expectation(description: "teardown rejects new binary opening")
    let deniedClosed = expectation(description: "rejected binary closed without native work")
    let later = connector.open(
      streamKind: .binary, deadline: .now() + 3,
      opened: { result in
        XCTAssertEqual(result.failure, .unavailable)
        denied.fulfill()
      }, closed: { deniedClosed.fulfill() })
    wait(for: [denied, deniedClosed], timeout: 1)
    queue.sync { XCTAssertEqual(calls, 1) }
    gate.complete(.success(native))
    wait(for: [cleaned], timeout: 1)
    let stillDenied = expectation(description: "late completion cannot restore native admission")
    let stillClosed = expectation(description: "late retry has no native ownership")
    let retry = connector.open(
      streamKind: .control, deadline: .now() + 1,
      opened: { result in
        XCTAssertEqual(result.failure, .unavailable)
        stillDenied.fulfill()
      }, closed: { stillClosed.fulfill() })
    wait(for: [stillDenied, stillClosed], timeout: 1)
    XCTAssertThrowsError(try peer.readExact(1, deadline: .now() + 1))
    queue.sync {
      XCTAssertEqual(calls, 1)
      XCTAssertEqual(native.closeCount, 1)
    }
    withExtendedLifetime([opening, later, retry]) {}
  }

  func testOneControlAndTwoBinaryRelaysProgressWithoutAdmittingAThirdBinary() throws {
    let queue = VzRuntimeQueue(label: "fixture.guest-native.parallel")
    let deadline = DispatchTime.now() + 3
    var natives: [NativeSocketFixture] = []
    var guests: [UnixSocket] = []
    var clients: [UnixSocket] = []
    var ownedClients: [Int32] = []
    for _ in 0..<3 {
      let guestPair = try socketPair()
      let clientPair = try socketPair()
      natives.append(NativeSocketFixture(descriptor: guestPair.0, queue: queue))
      guests.append(try UnixSocket(fd: guestPair.1, writeDeadline: { deadline }))
      clients.append(try UnixSocket(fd: clientPair.1, writeDeadline: { deadline }))
      ownedClients.append(clientPair.0)
    }
    defer {
      for guest in guests { guest.close() }
      for client in clients { client.close() }
    }
    var calls = 0
    let connector = GuestNativeConnector(queue: queue) { callback in
      if calls < natives.count {
        let native = natives[calls]
        calls += 1
        callback(.success(native))
      } else {
        XCTFail("excess native connection requested")
        callback(.failure(NSError(domain: "GuestNativeFixture", code: 1)))
      }
    }
    let admitted = expectation(description: "one control and two binary connections admitted")
    admitted.expectedFulfillmentCount = 3
    let closed = expectation(description: "all three native ownerships closed")
    closed.expectedFulfillmentCount = 3
    let relayed = expectation(description: "all three relays finished")
    relayed.expectedFulfillmentCount = 3
    var channels: [GuestNativeChannel] = []
    var openings: [GuestNativeOpening] = []
    for index in 0..<3 {
      openings.append(
        connector.open(
          streamKind: index == 0 ? .control : .binary, deadline: deadline,
          opened: { result in
            do {
              let channel = try result.get()
              channels.append(channel)
              channel.startRelay(clientDescriptor: ownedClients[index]) { result in
                XCTAssertNil(result.failure)
                XCTAssertTrue(natives[index].isClosed)
                relayed.fulfill()
              }
            } catch { XCTFail("valid parallel admission failed") }
            admitted.fulfill()
          }, closed: { closed.fulfill() }))
    }
    wait(for: [admitted], timeout: 1)
    let rejected = expectation(description: "third binary rejected")
    let rejectedClosed = expectation(description: "third binary owns no native resources")
    openings.append(
      connector.open(
        streamKind: .binary, deadline: deadline,
        opened: { result in
          XCTAssertEqual(result.failure, .limitExceeded)
          rejected.fulfill()
        }, closed: { rejectedClosed.fulfill() }))
    wait(for: [rejected, rejectedClosed], timeout: 1)
    for index in 0..<3 {
      let outward = Data([UInt8(index), 42])
      try clients[index].writeAll(outward)
      XCTAssertEqual(try guests[index].readExact(2, deadline: deadline), outward)
      let inward = Data([UInt8(index), 67])
      try guests[index].writeAll(inward)
      XCTAssertEqual(try clients[index].readExact(2, deadline: deadline), inward)
    }
    queue.sync {
      XCTAssertEqual(calls, 3)
      for channel in channels { channel.cancel() }
      channels = []
    }
    wait(for: [relayed, closed], timeout: 1)
    queue.sync { for native in natives { XCTAssertEqual(native.closeCount, 1) } }
    withExtendedLifetime(openings) {}
  }

  func testTimedOutControlReservesItsSlotUntilLateNativeCleanup() throws {
    let queue = VzRuntimeQueue(label: "fixture.guest-native.control-slot")
    let oldPair = try socketPair()
    let newPair = try socketPair()
    let oldNative = NativeSocketFixture(descriptor: oldPair.0, queue: queue)
    let newNative = NativeSocketFixture(descriptor: newPair.0, queue: queue)
    let oldPeer = try UnixSocket(fd: oldPair.1)
    let newPeer = try UnixSocket(fd: newPair.1)
    defer {
      oldPeer.close()
      newPeer.close()
    }
    let gate = NativeConnectGate()
    var calls = 0
    let connector = GuestNativeConnector(queue: queue) { callback in
      calls += 1
      if calls == 1 {
        gate.hold(callback)
      } else if calls == 2 {
        callback(.success(newNative))
      } else {
        callback(.failure(NSError(domain: "GuestNativeFixture", code: 1)))
      }
    }
    let timedOut = expectation(description: "original control open timed out")
    let oldClosed = expectation(description: "old native cleanup completed")
    let first = connector.open(
      streamKind: .control, deadline: .now() + 0.03,
      opened: { result in
        XCTAssertEqual(result.failure, .deadlineExpired)
        timedOut.fulfill()
      },
      closed: {
        XCTAssertTrue(oldNative.isClosed)
        oldClosed.fulfill()
      })
    wait(for: [timedOut], timeout: 1)
    let rejected = expectation(description: "replacement denied while actual native connect lives")
    let rejectedClosed = expectation(description: "denied opening cleanup completed")
    let second = connector.open(
      streamKind: .control, deadline: .now() + 2,
      opened: { result in
        XCTAssertEqual(result.failure, .limitExceeded)
        rejected.fulfill()
      }, closed: { rejectedClosed.fulfill() })
    wait(for: [rejected, rejectedClosed], timeout: 1)
    queue.sync { XCTAssertEqual(calls, 1) }
    gate.complete(.success(oldNative))
    wait(for: [oldClosed], timeout: 1)
    let admitted = expectation(description: "control slot usable after actual cleanup")
    let newClosed = expectation(description: "new control native connection closed")
    var channel: GuestNativeChannel?
    let third = connector.open(
      streamKind: .control, deadline: .now() + 2,
      opened: { result in
        channel = try? result.get()
        XCTAssertNotNil(channel)
        admitted.fulfill()
      }, closed: { newClosed.fulfill() })
    wait(for: [admitted], timeout: 1)
    queue.sync {
      XCTAssertEqual(calls, 2)
      channel?.cancel()
      channel = nil
    }
    wait(for: [newClosed], timeout: 1)
    XCTAssertThrowsError(try oldPeer.readExact(1, deadline: .now() + 1))
    XCTAssertThrowsError(try newPeer.readExact(1, deadline: .now() + 1))
    withExtendedLifetime([first, second, third]) {}
  }

  func testOpeningTimeoutFencesLateSuccessAndWaitsForActualNativeCleanup() throws {
    let queue = VzRuntimeQueue(label: "fixture.guest-native.late")
    let pair = try socketPair()
    let native = NativeSocketFixture(descriptor: pair.0, queue: queue)
    let peer = try UnixSocket(fd: pair.1)
    defer { peer.close() }
    let gate = NativeConnectGate()
    let entered = expectation(description: "native connect requested")
    let rejected = expectation(description: "original opening deadline elapsed")
    let premature = expectation(description: "slot released before late native cleanup")
    premature.isInverted = true
    let closed = expectation(description: "late connection closed before ownership release")
    let connector = GuestNativeConnector(queue: queue) { callback in
      XCTAssertTrue(queue.isCurrent)
      gate.hold(callback)
      entered.fulfill()
    }
    let opening = connector.open(
      streamKind: .control, deadline: .now() + 0.03,
      opened: { result in
        XCTAssertEqual(result.failure, .deadlineExpired)
        rejected.fulfill()
      },
      closed: {
        XCTAssertTrue(queue.isCurrent)
        if native.isClosed { closed.fulfill() } else { premature.fulfill() }
      })
    wait(for: [entered, rejected], timeout: 0.25)
    let responsive = expectation(
      description: "native queue responsive during uncancellable connect")
    queue.async { responsive.fulfill() }
    wait(for: [responsive], timeout: 0.25)
    wait(for: [premature], timeout: 0.02)
    gate.complete(.success(native))
    wait(for: [closed], timeout: 1)
    XCTAssertThrowsError(try peer.readExact(1, deadline: .now() + 1))
    queue.sync { XCTAssertEqual(native.closeCount, 1) }
    opening.cancel()
  }

  func testNativeDescriptorIsRetainedUntilRelayCleanupOnRuntimeQueue() throws {
    let queue = VzRuntimeQueue(label: "fixture.guest-native")
    let clientPair = try socketPair()
    let guestPair = try socketPair()
    let native = NativeSocketFixture(descriptor: guestPair.0, queue: queue)
    let deadline = DispatchTime.now() + 3
    let client = try UnixSocket(fd: clientPair.1, writeDeadline: { deadline })
    let guest = try UnixSocket(fd: guestPair.1, writeDeadline: { deadline })
    defer {
      client.close()
      guest.close()
    }
    let connector = GuestNativeConnector(queue: queue) { callback in
      XCTAssertTrue(queue.isCurrent)
      callback(.success(native))
    }
    let opened = expectation(description: "native connection admitted")
    let relayed = expectation(description: "relay finished after native release")
    let closed = expectation(description: "native ownership released")
    var channel: GuestNativeChannel?
    let opening = connector.open(
      streamKind: .control, deadline: deadline,
      opened: { result in
        XCTAssertTrue(queue.isCurrent)
        do {
          channel = try result.get()
          channel?.startRelay(clientDescriptor: clientPair.0) { result in
            XCTAssertTrue(queue.isCurrent)
            XCTAssertTrue(native.isClosed)
            XCTAssertEqual(try? result.get(), .peerClosed)
            relayed.fulfill()
          }
        } catch {
          XCTFail("native fixture admission failed")
        }
        opened.fulfill()
      },
      closed: {
        XCTAssertTrue(queue.isCurrent)
        XCTAssertTrue(native.isClosed)
        closed.fulfill()
      })
    wait(for: [opened], timeout: 1)
    try client.writeAll(Data([1, 2, 3]))
    XCTAssertEqual(try guest.readExact(3, deadline: deadline), Data([1, 2, 3]))
    try guest.writeAll(Data([4, 5]))
    XCTAssertEqual(try client.readExact(2, deadline: deadline), Data([4, 5]))
    queue.sync {
      XCTAssertFalse(native.isClosed)
      XCTAssertGreaterThanOrEqual(Darwin.fcntl(native.fileDescriptor, F_GETFD), 0)
    }
    guest.close()
    wait(for: [relayed, closed], timeout: 1)
    XCTAssertThrowsError(try client.readExact(1, deadline: deadline))
    queue.sync {
      XCTAssertEqual(native.closeCount, 1)
      channel = nil
    }
    withExtendedLifetime(opening) {}
  }

  private func socketPair() throws -> (Int32, Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw NSError(domain: "GuestNativeFixture", code: 1)
    }
    return (descriptors[0], descriptors[1])
  }
}

extension Result {
  fileprivate var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}

private final class NativeConnectGate {
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

// Only the external VZ connection boundary is substituted. Transport is real UDS.
private final class NativeSocketFixture: GuestNativeSocket {
  private var descriptor: Int32
  private let queue: VzRuntimeQueue
  private(set) var closeCount = 0

  init(descriptor: Int32, queue: VzRuntimeQueue) {
    self.descriptor = descriptor
    self.queue = queue
  }

  var fileDescriptor: Int32 {
    queue.preconditionIsCurrent()
    return descriptor
  }

  var isClosed: Bool {
    queue.preconditionIsCurrent()
    return descriptor < 0
  }

  func close() {
    queue.preconditionIsCurrent()
    closeCount += 1
    if descriptor >= 0 { Darwin.close(descriptor) }
    descriptor = -1
  }
}
