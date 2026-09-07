import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class DriverLiveV2Tests: XCTestCase {
  func testCLIRequiresAndCapturesV2IdentityWithoutTokenArgument() throws {
    setenv("GAOVM_AUTH_TOKEN", String(repeating: "x", count: 32), 1)
    defer { unsetenv("GAOVM_AUTH_TOKEN") }
    let launch = try parseArgs([
      "driver",
      "--vm-id", "vm_01J00000000000000000000000",
      "--generation", "7",
      "--socket-path", "/private/tmp/gaovm-driver.sock",
      "--bundle-path", "/private/tmp/vm.gaovm",
      "--backend", "vz",
    ])
    guard case .v2(let config) = launch else { return XCTFail("expected v2 launch") }
    XCTAssertEqual(config.vmId.rawValue, "vm_01J00000000000000000000000")
    XCTAssertEqual(config.generation, 7)
    XCTAssertEqual(config.bundlePath, "/private/tmp/vm.gaovm")
  }

  func testExactLegacyArgumentsSelectOnlyTransitionalV12Session() throws {
    setenv("GAOVM_AUTH_TOKEN", String(repeating: "x", count: 32), 1)
    defer { unsetenv("GAOVM_AUTH_TOKEN") }
    let launch = try parseArgs([
      "driver", "--socket-path", "/private/tmp/gaovm-driver-legacy.sock",
    ])
    guard case .legacy(let config) = launch else {
      return XCTFail("expected transitional legacy launch")
    }
    XCTAssertEqual(config.socketPath, "/private/tmp/gaovm-driver-legacy.sock")
    XCTAssertThrowsError(
      try parseArgs([
        "driver", "--socket-path", "/private/tmp/mixed.sock", "--vm-id",
        "vm_01J00000000000000000000000",
      ]))
  }

  func testRuntimeEventCapturesOperationBeforeDeferredDelivery() throws {
    let queue = VzRuntimeQueue(label: "test.v2.event-context")
    let delivered = expectation(description: "event delivered")
    var envelope: RuntimeEventEnvelope?
    let delivery = RuntimeEventDelivery(envelopeSink: {
      envelope = $0
      delivered.fulfill()
    })
    let generation = RuntimeEventGeneration(
      queue: queue,
      now: { Date(timeIntervalSince1970: 1) },
      delivery: delivery)

    queue.sync {
      generation.setOperationID("op_01J00000000000000000000000")
      generation.observeConfiguration(currentRuntimeState: nil)
      generation.setOperationID("op_01J00000000000000000000001")
    }
    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(envelope?.operationID, "op_01J00000000000000000000000")
  }

  func testUnixListenerRefusesToUnlinkExistingSocket() throws {
    let path = "/private/tmp/gaovm-v2-listener-\(UUID().uuidString).sock"
    let first = UnixListener(path: path)
    let second = UnixListener(path: path)
    defer {
      first.close()
      second.close()
    }
    try first.bindAndListen()
    XCTAssertThrowsError(try second.bindAndListen())
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
  }

  func testTerminalExitGateWaitsForStopResponseButAllowsSpontaneousExit() {
    var requested = DriverTerminalExitGate()
    requested.beginCommand(exitCode: 137)
    requested.observeRuntimeTerminal()
    XCTAssertNil(requested.readyExitCode)
    requested.completeCommand(succeeded: true)
    XCTAssertEqual(requested.readyExitCode, 137)

    var spontaneous = DriverTerminalExitGate()
    spontaneous.observeRuntimeTerminal()
    XCTAssertEqual(spontaneous.readyExitCode, 0)

    var failed = DriverTerminalExitGate()
    failed.beginCommand(exitCode: 0)
    failed.observeRuntimeTerminal()
    failed.completeCommand(succeeded: false)
    XCTAssertEqual(failed.readyExitCode, 0)
  }
}
