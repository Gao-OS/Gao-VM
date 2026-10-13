import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class SerialControllerTests: XCTestCase {
  func testCaptureFailureIsVisibleBeforeEofWithoutWaitingForTheIoQueue() throws {
    guard Darwin.geteuid() != 0 else {
      throw XCTSkip("permission fault requires an unprivileged user")
    }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-failure-\(UUID().uuidString)")
    let path = root.appendingPathComponent("serial.log").path
    defer {
      _ = Darwin.chmod(root.path, mode_t(0o700))
      try? FileManager.default.removeItem(at: root)
    }
    let serial = try SerialController(path: path)
    serial.start()
    XCTAssertEqual(serial.snapshot, SerialCaptureSnapshot(ready: true, logPath: path))
    let producer = FileHandle(
      fileDescriptor: Darwin.dup(serial.driverOutput.fileDescriptor), closeOnDealloc: true)
    XCTAssertEqual(Darwin.chmod(root.path, mode_t(0o500)), 0)
    // The real rotation cannot rename its file in the read-only owned directory.
    // Bounded pipe writes cannot finish until the pump has reached that failure.
    let chunk = Data(repeating: 0x5A, count: 1024 * 1024)
    for _ in 0..<11 { try producer.write(contentsOf: chunk) }
    let snapshotBeforeEOF = serial.snapshot
    XCTAssertEqual(Darwin.chmod(root.path, mode_t(0o700)), 0)
    try producer.close()
    let closed = expectation(description: "failed capture actually drained")
    serial.close { result in
      guard case .failure = result else {
        return XCTFail("rotation failure must not become successful cleanup")
      }
      closed.fulfill()
    }
    wait(for: [closed], timeout: 2)
    XCTAssertFalse(
      snapshotBeforeEOF.ready, "capture failure must be observable while the producer is still open"
    )
    XCTAssertNil(snapshotBeforeEOF.logPath)
  }

  func testControllerDeallocationRetainsQueuedBytesAndRepeatedCloseWaiters() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-ownership-\(UUID().uuidString)")
    let path = root.appendingPathComponent("serial.log").path
    defer { try? FileManager.default.removeItem(at: root) }
    var serial: SerialController? = try SerialController(path: path)
    serial?.start()
    let output = try XCTUnwrap(serial?.driverOutput)
    let producer = FileHandle(
      fileDescriptor: Darwin.dup(output.fileDescriptor), closeOnDealloc: true)
    let bytes = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
    try producer.write(contentsOf: bytes)
    let drained = expectation(description: "both close waiters joined actual I/O")
    drained.expectedFulfillmentCount = 2
    for _ in 0..<2 {
      serial?.close { result in
        if case .failure(let error) = result { XCTFail("serial close failed: \(error)") }
        drained.fulfill()
      }
    }
    serial = nil
    try producer.close()
    wait(for: [drained], timeout: 2)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
  }

  func testRawSerialSinkRotatesAtBoundAndKeepsRequestedHistory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-\(UUID().uuidString)")
    let path = root.appendingPathComponent("serial.log").path
    defer { try? FileManager.default.removeItem(at: root) }
    let sink = try RotatingByteSink(path: path, maxBytes: 8, rotations: 2)

    try sink.write(Data("12345678".utf8))
    try sink.write(Data("abcdefgh".utf8))
    try sink.write(Data("ABCDEFGH".utf8))
    sink.close()

    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "ABCDEFGH")
    XCTAssertEqual(try String(contentsOfFile: "\(path).1", encoding: .utf8), "abcdefgh")
    XCTAssertEqual(try String(contentsOfFile: "\(path).2", encoding: .utf8), "12345678")
  }

  func testSingleOversizedWriteIsSegmentedAndKeepsExactlyThreeRotations() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-large-\(UUID().uuidString)")
    let path = root.appendingPathComponent("serial.log").path
    defer { try? FileManager.default.removeItem(at: root) }
    let sink = try RotatingByteSink(path: path, maxBytes: 8, rotations: 3)
    let bytes = Data((0..<36).map(UInt8.init))

    try sink.write(bytes)
    sink.close()

    let paths = ["\(path).3", "\(path).2", "\(path).1", path]
    let retained = try paths.reduce(into: Data()) { output, part in
      let data = try Data(contentsOf: URL(fileURLWithPath: part))
      XCTAssertLessThanOrEqual(data.count, 8)
      output.append(data)
    }
    XCTAssertEqual(retained, bytes.suffix(retained.count))
    XCTAssertEqual(retained.count, 28)
    XCTAssertFalse(FileManager.default.fileExists(atPath: "\(path).4"))
  }
}
