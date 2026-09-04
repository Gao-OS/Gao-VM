import Darwin
import Foundation
import SocketWriteTestSupport
import XCTest

@testable import vz_macos

final class SerializedSocketWriterTests: XCTestCase {
  func testClosePromptlyInterruptsInFlightWriteAndRejectsLaterWrites() throws {
    let transport = BlockingSocketTransport()
    let writer = SerializedSocketWriter(transport: transport)
    let writeFinished = expectation(description: "write finished")
    let closeFinished = expectation(description: "close finished")
    let transportClosed = expectation(description: "transport closed")
    transport.onClose = { transportClosed.fulfill() }

    DispatchQueue.global().async {
      do {
        try writer.write(Data("frame".utf8))
      } catch {
        XCTFail("write failed: \(error)")
      }
      writeFinished.fulfill()
    }
    transport.waitUntilWriteStarted()

    DispatchQueue.global().async {
      writer.close()
      closeFinished.fulfill()
    }
    wait(for: [closeFinished], timeout: 0.1)
    transport.releaseWrite()
    wait(for: [writeFinished, transportClosed], timeout: 1)
    XCTAssertEqual(transport.events, ["write.begin", "interrupt", "write.end", "close"])
    XCTAssertThrowsError(try writer.write(Data("late".utf8)))
  }

  func testInterruptedRealSocketWriteReturnsControlledErrorInsteadOfSIGPIPE() throws {
    var socketFDs = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(
      socketFDs.withUnsafeMutableBufferPointer {
        Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress)
      },
      0
    )
    var sendBufferSize: Int32 = 4_096
    XCTAssertEqual(
      Darwin.setsockopt(
        socketFDs[0], SOL_SOCKET, SO_SNDBUF, &sendBufferSize,
        socklen_t(MemoryLayout.size(ofValue: sendBufferSize))),
      0
    )
    let socket = try UnixSocket(fd: socketFDs[0])
    let result = gaovm_run_sigpipe_regression(socketFDs[0], socketFDs[1])
    socketFDs[1] = -1
    socket.close()

    XCTAssertEqual(result.setup_error, 0)
    XCTAssertEqual(result.observed_blocked_write, 1)
    XCTAssertEqual(result.child_result, 69)
    XCTAssertEqual(
      result.child_status, 0, "child terminated by signal \(result.child_status & 0x7f)")
  }
}

private final class BlockingSocketTransport: SocketWriteTransport {
  private let condition = NSCondition()
  private var writeReleased = false
  private var recordedEvents: [String] = []
  var onClose: (() -> Void)?

  var events: [String] {
    condition.lock()
    defer { condition.unlock() }
    return recordedEvents
  }

  func writeAll(_ data: Data) throws {
    condition.lock()
    recordedEvents.append("write.begin")
    condition.broadcast()
    while !writeReleased {
      condition.wait()
    }
    recordedEvents.append("write.end")
    condition.unlock()
  }

  func close() {
    condition.lock()
    recordedEvents.append("close")
    let callback = onClose
    condition.unlock()
    callback?()
  }

  func interrupt() {
    condition.lock()
    recordedEvents.append("interrupt")
    writeReleased = true
    condition.broadcast()
    condition.unlock()
  }

  func waitUntilWriteStarted() {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(1)
    while recordedEvents.isEmpty, condition.wait(until: deadline) {}
  }

  func releaseWrite() {
    condition.lock()
    writeReleased = true
    condition.broadcast()
    condition.unlock()
  }
}
