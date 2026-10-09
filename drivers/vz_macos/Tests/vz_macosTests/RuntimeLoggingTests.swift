import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class RuntimeLoggingTests: XCTestCase {
  func testConfiguredLogsCaptureOperationsBeforeDelayedWritesAndLaterContextChanges() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-runtime-log-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("driver.log")
    XCTAssertEqual(Darwin.mkfifo(file.path, mode_t(0o600)), 0)
    let vmID = "vm_01J00000000000000000000000"
    let logger = RotatingLogger(
      path: file.path,
      identity: .init(vmID: try DriverProtocolV2.VMID(vmID), driverGeneration: 7))
    let firstOperation = "op_01J00000000000000000000000"
    let secondOperation = "op_01J00000000000000000000001"
    let laterOperation = "op_01J00000000000000000000002"
    let submitted = expectation(
      description: "two configure commands completed with a stalled logger")
    submitted.expectedFulfillmentCount = 2
    let runtime = VzRuntime(logger: logger)
    let commands = RuntimeCommandDispatcher(runtime: runtime)
    let configuration = NormalizedVmConfig(
      cpu: 2, memoryBytes: 1_073_741_824,
      boot: .linux(.init(kernelPath: "/unused/kernel", initrdPath: nil, commandLine: "")),
      disks: [], networks: [], graphicsEnabled: false, graphicsWidth: 1280,
      graphicsHeight: 800, serial: nil, guestAgent: nil, bundlePath: nil)
    XCTAssertTrue(logger.log(.debug, "hold writer"))
    for operation in [firstOperation, secondOperation] {
      commands.configure(with: configuration, operationID: operation) { result in
        if case .failure(let error) = result { XCTFail("configure failed: \(error)") }
        submitted.fulfill()
      }
    }
    let commandResult = XCTWaiter.wait(for: [submitted], timeout: 1)
    let contextChanged = expectation(description: "later operation reached the runtime queue")
    runtime.setOperationContext(laterOperation)
    runtime.vzRuntimeQueue.async { contextChanged.fulfill() }
    let contextResult = XCTWaiter.wait(for: [contextChanged], timeout: 1)
    XCTAssertFalse(logger.flush(timeout: 0.05))

    let reader = Darwin.open(file.path, O_RDONLY | O_NONBLOCK)
    XCTAssertGreaterThanOrEqual(reader, 0)
    defer { if reader >= 0 { Darwin.close(reader) } }
    try FileManager.default.removeItem(at: file)
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
    XCTAssertEqual(commandResult, .completed)
    XCTAssertEqual(contextResult, .completed)
    runtime.vzRuntimeQueue.sync {}
    XCTAssertTrue(logger.flush(timeout: 3))
    let records = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    let configured = records.filter { $0["message"] as? String == "vm configured" }
    XCTAssertEqual(configured.count, 2)
    XCTAssertEqual(
      configured.compactMap { $0["operation_id"] as? String }, [firstOperation, secondOperation])
    for record in configured {
      XCTAssertEqual(record["vm_id"] as? String, vmID)
      XCTAssertEqual(record["driver_generation"] as? Int, 7)
      XCTAssertEqual(record["event_type"] as? String, "runtime.configured")
      XCTAssertTrue(record["request_id"] is NSNull)
    }
  }
}
