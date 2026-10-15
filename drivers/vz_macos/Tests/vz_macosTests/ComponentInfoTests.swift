import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class ComponentInfoTests: XCTestCase {
  func testExecutableProbeNeedsNoAuthAndCreatesNoRuntimeFiles() throws {
    let root = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("gvm-component-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let process = Process()
    let exited = DispatchGroup()
    exited.enter()
    process.terminationHandler = { _ in exited.leave() }
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("gaovm-driver-vz")
    process.arguments = ["--component-info"]
    process.environment = ["GAOVM_DRIVER_LOG_PATH": root.appendingPathComponent("driver.log").path]
    process.currentDirectoryURL = root
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    defer {
      if process.isRunning {
        process.terminate()
        if exited.wait(timeout: .now() + 1) != .success, process.isRunning {
          Darwin.kill(process.processIdentifier, SIGKILL)
          XCTAssertEqual(exited.wait(timeout: .now() + 2), .success)
        }
      }
      if !process.isRunning { try? FileManager.default.removeItem(at: root) }
    }
    try process.run()
    guard exited.wait(timeout: .now() + 5) == .success else {
      return XCTFail("component probe did not exit")
    }
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertTrue(error.fileHandleForReading.readDataToEndOfFile().isEmpty)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    XCTAssertEqual(json["format"] as? String, "gaovm.component.v1")
    XCTAssertEqual(json["role"] as? String, "driver-vz")
    XCTAssertEqual(json["version"] as? String, "0.1.0")
    XCTAssertEqual(json["driver_protocol"] as? String, DriverProtocolV2.version)
    let capabilities = try XCTUnwrap(json["capabilities"] as? [String: [String]])
    XCTAssertEqual(
      capabilities["required"]?.sorted(),
      [
        "runtime.configure", "runtime.kill", "runtime.start", "runtime.status", "runtime.stop",
      ])
    XCTAssertFalse(capabilities["offered"]?.contains("guest.status") ?? true)
    XCTAssertEqual(capabilities["development_only"], ["guest.status"])
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }
}
