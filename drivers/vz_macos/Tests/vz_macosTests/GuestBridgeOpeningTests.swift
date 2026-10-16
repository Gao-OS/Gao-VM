import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class GuestBridgeOpeningTests: XCTestCase {
  func testFragmentedOpeningLeavesCoalescedGuestBytesOnTheSocket() throws {
    let deadline = DispatchTime.now() + 2
    let (server, client) = try socketPair(deadline: deadline)
    defer {
      server.close()
      client.close()
    }
    let frame = fixtureFrame(openHeader)
    let sent = expectation(description: "fragmented frame and guest preface sent")
    DispatchQueue.global().async {
      defer { sent.fulfill() }
      do {
        try client.writeAll(frame.prefix(1))
        Thread.sleep(forTimeInterval: 0.01)
        try client.writeAll(frame[1..<6])
        Thread.sleep(forTimeInterval: 0.01)
        try client.writeAll(frame.dropFirst(6) + Data("GAB1".utf8))
      } catch { XCTFail("fixture send failed") }
    }
    let message = try GuestBridgeFrameIO.readOpening(from: server, deadline: deadline)
    guard case .open(let correlation, _) = message else { return XCTFail("expected opening") }
    XCTAssertEqual(correlation.driverGeneration, 8)
    XCTAssertEqual(correlation.streamKind, .control)
    XCTAssertEqual(try server.readExact(4, deadline: deadline), Data("GAB1".utf8))
    wait(for: [sent], timeout: 3)
  }

  func testResponseMustMatchEveryOpeningFieldBeforeGuestBytesAreUsable() throws {
    let expected = try GuestBridgeProtocolCodec().decode(Data(openHeader.utf8)).correlation
    let ready = readyHeader
    let replies = [
      (ready, true),
      (ready.replacingOccurrences(of: "gaovm.bridge.v1", with: "gaovm.bridge.v2"), false),
      (
        ready.replacingOccurrences(
          of: "vm_01J00000000000000000000000", with: "vm_01J00000000000000000000001"), false
      ),
      (
        ready.replacingOccurrences(of: #""driver_generation":8"#, with: #""driver_generation":9"#),
        false
      ),
      (
        ready.replacingOccurrences(
          of: "req_01J00000000000000000000001", with: "req_01J00000000000000000000002"), false
      ),
      (
        ready.replacingOccurrences(
          of: #""operation_id":null"#, with: #""operation_id":"op_01J00000000000000000000001""#),
        false
      ),
      (
        ready.replacingOccurrences(
          of: #""operation_id":null"#, with: #""operation_id":"op_01J00000000000000000000001""#
        )
        .replacingOccurrences(of: #""stream_kind":"control""#, with: #""stream_kind":"binary""#),
        false
      ),
      (openHeader, false),
    ]
    for (reply, matches) in replies {
      let deadline = DispatchTime.now() + 2
      let (reader, writer) = try socketPair(deadline: deadline)
      defer {
        reader.close()
        writer.close()
      }
      try writer.writeAll(fixtureFrame(reply) + Data("RAW".utf8))
      if matches {
        guard
          case .ready = try GuestBridgeFrameIO.readResponse(
            from: reader, expecting: expected, deadline: deadline)
        else { return XCTFail("matching ready was not accepted") }
        XCTAssertEqual(try reader.readExact(3, deadline: deadline), Data("RAW".utf8))
      } else {
        XCTAssertThrowsError(
          try GuestBridgeFrameIO.readResponse(
            from: reader, expecting: expected, deadline: deadline))
        XCTAssertEqual(reader.fd, -1)
        // The reader reflects no response bytes; unread attacker bytes may yield
        // a reset rather than orderly EOF when the rejected socket is closed.
        XCTAssertThrowsError(try writer.readExact(1, deadline: deadline))
      }
    }
  }

  func testBadLengthsAndNonOpeningFramesCloseSilentlyBeforeReadingUnboundedPayloads() throws {
    for length in [UInt32(0), 4097, UInt32.max] {
      let deadline = DispatchTime.now() + 1
      let (server, client) = try socketPair(deadline: deadline)
      defer {
        server.close()
        client.close()
      }
      var prefix = length.bigEndian
      try client.writeAll(Data(bytes: &prefix, count: 4))
      XCTAssertThrowsError(try GuestBridgeFrameIO.readOpening(from: server, deadline: deadline)) {
        XCTAssertEqual($0 as? GuestBridgeProtocolError, .invalidLength)
      }
      XCTAssertEqual(server.fd, -1)
      XCTAssertThrowsError(try client.readExact(1, deadline: deadline))
    }
    for json in [readyHeader, "[]", openHeader.dropLast() + #", "unknown":null}"#] {
      let deadline = DispatchTime.now() + 1
      let (server, client) = try socketPair(deadline: deadline)
      defer {
        server.close()
        client.close()
      }
      try client.writeAll(fixtureFrame(json))
      XCTAssertThrowsError(try GuestBridgeFrameIO.readOpening(from: server, deadline: deadline))
      XCTAssertEqual(server.fd, -1)
      XCTAssertThrowsError(try client.readExact(1, deadline: deadline))
    }
  }

  func testOpeningDeadlineIsNotRestartedAfterAFragmentedLengthPrefix() throws {
    let (server, client) = try socketPair(deadline: .now() + 2)
    defer {
      server.close()
      client.close()
    }
    let frame = fixtureFrame(openHeader)
    try client.writeAll(frame.prefix(2))
    let ready = expectation(description: "prefix sender ready")
    let sent = expectation(description: "remaining prefix sent")
    let sendPrefix = DispatchSemaphore(value: 0)
    DispatchQueue(label: "gaovm.test.fragmented-opening").async {
      defer { sent.fulfill() }
      ready.fulfill()
      guard sendPrefix.wait(timeout: .now() + 2) == .success else {
        return XCTFail("fixture prefix sender was not released")
      }
      Thread.sleep(forTimeInterval: 0.2)
      do {
        try client.writeAll(frame[2..<4])
      } catch { XCTFail("fixture prefix send failed: \(error)") }
    }
    // Socket setup and worker scheduling must not consume the opening budget.
    wait(for: [ready], timeout: 2)
    let started = DispatchTime.now().uptimeNanoseconds
    let deadline = DispatchTime(uptimeNanoseconds: started) + .milliseconds(300)
    sendPrefix.signal()
    XCTAssertThrowsError(try GuestBridgeFrameIO.readOpening(from: server, deadline: deadline)) {
      XCTAssertEqual($0 as? GuestBridgeProtocolError, .deadlineExpired)
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    XCTAssertLessThan(elapsed, 0.45)
    XCTAssertEqual(server.fd, -1)
    XCTAssertThrowsError(try client.readExact(1, deadline: .now() + 1))
    wait(for: [sent], timeout: 2)
  }

  func testMatchedErrorResponseClosesTheSocketInsteadOfReturningRawGuestBytes() throws {
    let expected = try GuestBridgeProtocolCodec().decode(Data(openHeader.utf8)).correlation
    for code in ["GUEST_CHANNEL_UNAVAILABLE", "CHANNEL_LIMIT_EXCEEDED"] {
      let deadline = DispatchTime.now() + 1
      let (reader, writer) = try socketPair(deadline: deadline)
      defer {
        reader.close()
        writer.close()
      }
      let error =
        readyHeader.replacingOccurrences(of: #""kind":"ready""#, with: #""kind":"error""#)
        .dropLast() + #", "code":"\#(code)"}"#
      try writer.writeAll(fixtureFrame(String(error)) + Data("MUST-NOT-BECOME-GUEST-BYTES".utf8))
      guard
        case .error = try GuestBridgeFrameIO.readResponse(
          from: reader, expecting: expected, deadline: deadline)
      else { return XCTFail("matched error response was not returned") }
      XCTAssertEqual(reader.fd, -1)
      XCTAssertThrowsError(try writer.readExact(1, deadline: deadline))
    }
  }

  func testTypedOpeningAndResponseFramesUseTheBoundedBigEndianPrefix() throws {
    let codec = GuestBridgeProtocolCodec()
    let open = try codec.decode(Data(openHeader.utf8))
    for message in [open, .ready(open.correlation), .error(open.correlation, .unavailable)] {
      let frame = try GuestBridgeFrameIO.encode(message)
      let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      XCTAssertEqual(Int(length), frame.count - 4)
      XCTAssertLessThanOrEqual(length, 4096)
      XCTAssertEqual(try codec.decode(frame.dropFirst(4)), message)
    }
    XCTAssertThrowsError(try GuestBridgeFrameIO.encode(.open(open.correlation, authToken: "")))
  }

  private var readyHeader: String {
    #"{"protocol_version":"gaovm.bridge.v1","kind":"ready","vm_id":"vm_01J00000000000000000000000","driver_generation":8,"request_id":"req_01J00000000000000000000001","operation_id":null,"stream_kind":"control"}"#
  }

  private var openHeader: String {
    #"{"protocol_version":"gaovm.bridge.v1","kind":"open","vm_id":"vm_01J00000000000000000000000","driver_generation":8,"request_id":"req_01J00000000000000000000001","operation_id":null,"stream_kind":"control","auth_token":"test-only-generation-token"}"#
  }

  private func fixtureFrame(_ json: String) -> Data {
    let payload = Data(json.utf8)
    var length = UInt32(payload.count).bigEndian
    return Data(bytes: &length, count: 4) + payload
  }

  private func socketPair(deadline: DispatchTime) throws -> (UnixSocket, UnixSocket) {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw DriverError.io("fixture socketpair failed")
    }
    let server: UnixSocket
    do { server = try UnixSocket(fd: descriptors[0], writeDeadline: { deadline }) } catch {
      Darwin.close(descriptors[1])
      throw error
    }
    let client = try UnixSocket(fd: descriptors[1], writeDeadline: { deadline })
    return (server, client)
  }
}
