import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class RotatingLoggerTests: XCTestCase {
  func testRecordsAreSingleLineStructuredJSONWithExplicitUnknownContext() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-logger-structured-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("driver.log")
    let logger = RotatingLogger(path: file.path)
    let message = "line one\nline two\t\"quoted\" 🧪"
    XCTAssertTrue(logger.log(.info, message))
    XCTAssertTrue(logger.flush(timeout: 3))
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 1)
    let record = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    XCTAssertEqual(
      Set(record.keys),
      Set([
        "timestamp", "level", "component", "vm_id", "operation_id", "driver_generation",
        "request_id", "event_type", "message",
      ]))
    XCTAssertNotNil(
      ISO8601DateFormatter().date(from: try XCTUnwrap(record["timestamp"] as? String)))
    XCTAssertEqual(record["level"] as? String, "info")
    XCTAssertEqual(record["component"] as? String, "gaovm-driver-vz")
    XCTAssertEqual(record["event_type"] as? String, "driver.log")
    XCTAssertEqual(record["message"] as? String, message)
    for key in ["vm_id", "operation_id", "driver_generation", "request_id"] {
      XCTAssertTrue(record[key] is NSNull, key)
    }
  }

  func testFlushDrainsAcceptedRecordsInOrder() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-logger-drain-\(UUID().uuidString)")
    let file = root.appendingPathComponent("driver.log")
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = RotatingLogger(path: file.path)
    for index in 0..<32 { logger.log(.info, "record-\(index)") }

    XCTAssertTrue(logger.flush(timeout: 3))
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 32)
    for (index, line) in lines.enumerated() {
      let record = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      XCTAssertEqual(record["level"] as? String, "info")
      XCTAssertEqual(record["message"] as? String, "record-\(index)")
    }
  }

  func testConcurrentLoggersKeepVmGenerationAndOperationContextIsolated() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-logger-context-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let firstVM = try DriverProtocolV2.VMID("vm_01J00000000000000000000000")
    let secondVM = try DriverProtocolV2.VMID("vm_01J00000000000000000000001")
    let firstOperation = try DriverProtocolV2.OperationID("op_01J00000000000000000000000")
    let secondOperation = try DriverProtocolV2.OperationID("op_01J00000000000000000000001")
    let first = RotatingLogger(
      path: root.appendingPathComponent("first.log").path,
      identity: .init(vmID: firstVM, driverGeneration: 7))
    let second = RotatingLogger(
      path: root.appendingPathComponent("second.log").path,
      identity: .init(vmID: secondVM, driverGeneration: 11))
    DispatchQueue.concurrentPerform(iterations: 32) { index in
      XCTAssertTrue(first.log(.info, "first-\(index)", operationID: firstOperation))
      XCTAssertTrue(second.log(.info, "second-\(index)", operationID: secondOperation))
    }
    XCTAssertTrue(first.log(.info, "unscoped"))
    XCTAssertTrue(second.log(.info, "unscoped"))
    for (logger, name, vmID, generation, operation) in [
      (first, "first", firstVM, 7, firstOperation),
      (second, "second", secondVM, 11, secondOperation),
    ] {
      XCTAssertTrue(logger.flush(timeout: 3))
      let lines = try String(
        contentsOf: root.appendingPathComponent("\(name).log"), encoding: .utf8
      ).split(separator: "\n")
      XCTAssertEqual(lines.count, 33)
      var messages = Set<String>()
      for line in lines {
        let record = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let message = try XCTUnwrap(record["message"] as? String)
        messages.insert(message)
        XCTAssertEqual(record["vm_id"] as? String, vmID.rawValue)
        XCTAssertEqual(record["driver_generation"] as? Int, generation)
        XCTAssertTrue(record["request_id"] is NSNull)
        if message == "unscoped" {
          XCTAssertTrue(record["operation_id"] is NSNull)
        } else {
          XCTAssertEqual(record["operation_id"] as? String, operation.rawValue)
        }
      }
      XCTAssertEqual(messages, Set((0..<32).map { "\(name)-\($0)" } + ["unscoped"]))
    }
  }

  func testNewStructuredRecordsAppendWithoutRewritingHistoricalText() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-logger-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("driver.log")
    let historical = "[2026-10-01T00:00:00Z] [info] historical record\n"
    try Data(historical.utf8).write(to: file)
    let logger = RotatingLogger(path: file.path)
    XCTAssertTrue(logger.log(.warn, "new record"))
    XCTAssertTrue(logger.flush(timeout: 3))
    let contents = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(contents.hasPrefix(historical))
    let lines = contents.split(separator: "\n")
    XCTAssertEqual(lines.count, 2)
    let record = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.last).utf8)) as? [String: Any])
    XCTAssertEqual(record["level"] as? String, "warn")
    XCTAssertEqual(record["message"] as? String, "new record")
  }

  func testStalledLogFileDoesNotBlockItsCaller() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-logger-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("driver.log")
    // Opening this owned FIFO for writing cannot finish until a reader exists.
    XCTAssertEqual(Darwin.mkfifo(file.path, mode_t(0o600)), 0)
    let logger = RotatingLogger(path: file.path)
    let returned = expectation(description: "logging caller remains responsive")
    DispatchQueue(label: "gaovm.tests.log-caller").async {
      logger.log(.info, "stalled record")
      returned.fulfill()
    }
    let callerResult = XCTWaiter.wait(for: [returned], timeout: 0.5)
    XCTAssertFalse(logger.flush(timeout: 0.05))

    // Always release the real writer before checking the result. A regular-file
    // marker proves that its serial queue has drained before fixture cleanup.
    let reader = Darwin.open(file.path, O_RDONLY | O_NONBLOCK)
    XCTAssertGreaterThanOrEqual(reader, 0)
    defer { if reader >= 0 { Darwin.close(reader) } }
    try FileManager.default.removeItem(at: file)
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
    logger.log(.info, "drain marker")
    let drained = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        (try? String(contentsOf: file, encoding: .utf8))?.contains("drain marker") == true
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [drained], timeout: 3), .completed)
    XCTAssertEqual(callerResult, .completed)
  }

  func testStalledSinkHasBoundedAdmissionAndRecoversAfterDraining() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-logger-bound-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("driver.log")
    XCTAssertEqual(Darwin.mkfifo(file.path, mode_t(0o600)), 0)
    let logger = RotatingLogger(path: file.path)
    XCTAssertTrue(logger.log(.info, "stalled"))
    let payload = String(repeating: "x", count: 16 * 1024)
    var accepted = 0
    for _ in 0..<256 {
      if logger.log(.info, payload) { accepted += 1 }
    }
    XCTAssertGreaterThan(accepted, 0)
    XCTAssertLessThan(accepted, 256)
    XCTAssertLessThanOrEqual(accepted * payload.utf8.count, 1024 * 1024)
    XCTAssertFalse(logger.flush(timeout: 0.05))

    let reader = Darwin.open(file.path, O_RDONLY | O_NONBLOCK)
    XCTAssertGreaterThanOrEqual(reader, 0)
    defer { if reader >= 0 { Darwin.close(reader) } }
    try FileManager.default.removeItem(at: file)
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
    XCTAssertTrue(logger.flush(timeout: 3))
    XCTAssertTrue(logger.log(.info, "admission recovered"))
    XCTAssertTrue(logger.flush(timeout: 3))
    let contents = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(contents.contains("admission recovered"))
    XCTAssertTrue(contents.contains("log records (queue or record limit)"))
  }

  func testOversizedMessagesAreRejectedWithoutBreakingUTF8OrLaterWrites() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-logger-unicode-\(UUID().uuidString)")
    let file = root.appendingPathComponent("driver.log")
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = RotatingLogger(path: file.path)
    let maximum = String(repeating: "🧪", count: 4096)
    let oversized = maximum + "🧪"
    XCTAssertFalse(logger.log(.info, oversized))
    XCTAssertTrue(logger.log(.info, maximum))
    XCTAssertTrue(logger.flush(timeout: 3))
    let contents = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(contents.contains(maximum))
    XCTAssertFalse(contents.contains(oversized))
    XCTAssertTrue(contents.contains("dropped 1 log records"))
  }

  func testSmallRecordsCannotBypassThePendingRecordLimit() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-logger-count-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("driver.log")
    XCTAssertEqual(Darwin.mkfifo(file.path, mode_t(0o600)), 0)
    let logger = RotatingLogger(path: file.path)
    XCTAssertTrue(logger.log(.info, "stalled"))
    var accepted = 0
    for _ in 0..<256 {
      if logger.log(.info, "q") { accepted += 1 }
    }
    XCTAssertEqual(accepted, 255)
    XCTAssertFalse(logger.flush(timeout: 0.05))

    let reader = Darwin.open(file.path, O_RDONLY | O_NONBLOCK)
    XCTAssertGreaterThanOrEqual(reader, 0)
    defer { if reader >= 0 { Darwin.close(reader) } }
    try FileManager.default.removeItem(at: file)
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
    XCTAssertTrue(logger.flush(timeout: 3))
    XCTAssertTrue(logger.log(.info, "record capacity recovered"))
    XCTAssertTrue(logger.flush(timeout: 3))
    let contents = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(contents.contains("record capacity recovered"))
    XCTAssertTrue(contents.contains("dropped 1 log records"))
  }

  func testDefaultRotationKeepsExactlyThreeHistoryFiles() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-logger-rotation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("driver.log")
    let fullLog = Data(repeating: 0x78, count: 10 * 1024 * 1024)
    try fullLog.write(to: file)
    for index in 1...3 {
      try Data("history-\(index)".utf8).write(
        to: root.appendingPathComponent("driver.log.\(index)"))
    }
    let logger = RotatingLogger(path: file.path)
    XCTAssertTrue(logger.log(.info, "after rotation"))
    XCTAssertTrue(logger.flush(timeout: 3))
    XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("after rotation"))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("driver.log.1")), fullLog)
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("driver.log.2"), encoding: .utf8),
      "history-1")
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("driver.log.3"), encoding: .utf8),
      "history-2")
    XCTAssertEqual(
      Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
      Set(["driver.log", "driver.log.1", "driver.log.2", "driver.log.3"]))
  }
}
