import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class DriverLiveV2Tests: XCTestCase {
  func testConsoleReadinessCapturesStartContextAndFencesRetiredObservations() {
    let queue = VzRuntimeQueue(label: "test.v2.console-generation")
    let delivered = expectation(description: "event delivery barrier")
    let lock = NSLock()
    var events: [RuntimeEventEnvelope] = []
    let delivery = RuntimeEventDelivery(envelopeSink: { envelope in
      XCTAssertFalse(queue.isCurrent)
      lock.lock()
      events.append(envelope)
      lock.unlock()
      if case .stateChanged = envelope.event { delivered.fulfill() }
    })
    let date = Date(timeIntervalSince1970: 1)
    let first = "op_01J00000000000000000000001"
    let second = "op_01J00000000000000000000002"
    let generation = RuntimeEventGeneration(queue: queue, now: { date }, delivery: delivery)
    queue.sync { generation.setOperationID(first) }
    generation.observeConsoleReady(logPath: "/vm/applied.log")
    queue.sync { generation.setOperationID(second) }
    queue.sync {
      generation.observeConsoleReady(logPath: "/vm/unapplied.log")
      generation.close()
    }
    generation.observeConsoleReady(logPath: "/vm/retired.log")
    let poisoned = RuntimeEventGeneration(queue: queue, now: { date }, delivery: delivery)
    poisoned.poison()
    poisoned.observeConsoleReady(logPath: "/vm/poisoned.log")
    queue.sync {}
    let barrier = RuntimeEvent.stateChanged(occurredAt: date, state: .configured)
    delivery.deliver(barrier)
    wait(for: [delivered], timeout: 1)
    lock.lock()
    let snapshot = events
    lock.unlock()
    XCTAssertEqual(snapshot.map(\.operationID), [first, nil])
    XCTAssertEqual(
      snapshot.map(\.event), [.consoleReady(occurredAt: date, logPath: "/vm/applied.log"), barrier])
  }

  func testRuntimeRetirementFencesDisplayObservationsStillWaitingOnItsQueue() {
    let queue = VzRuntimeQueue(label: "test.v2.display-retirement")
    let delivered = expectation(description: "delivery barrier only")
    delivered.assertForOverFulfill = true
    let lock = NSLock()
    var events: [RuntimeEvent] = []
    let delivery = RuntimeEventDelivery(envelopeSink: {
      lock.lock()
      events.append($0.event)
      lock.unlock()
      if case .stateChanged = $0.event { delivered.fulfill() }
    })
    let date = Date(timeIntervalSince1970: 1)
    let generation = RuntimeEventGeneration(queue: queue, now: { date }, delivery: delivery)
    queue.sync {
      generation.observeDisplayState(.open, operationID: "old-display")
      generation.close()
    }
    queue.sync {}
    let barrier = RuntimeEvent.stateChanged(occurredAt: date, state: .configured)
    delivery.deliver(barrier)
    wait(for: [delivered], timeout: 1)
    lock.lock()
    let snapshot = events
    lock.unlock()
    XCTAssertEqual(
      snapshot, [barrier], "a retired generation cannot publish queued UI observations")
  }

  func testDisplayEventsKeepExplicitCorrelationAndIgnoreReleasedGenerations() {
    let queue = VzRuntimeQueue(label: "test.v2.display-event-context")
    let delivered = expectation(description: "three active display observations")
    delivered.expectedFulfillmentCount = 3
    delivered.assertForOverFulfill = true
    let lock = NSLock()
    var envelopes: [RuntimeEventEnvelope] = []
    let delivery = RuntimeEventDelivery(envelopeSink: {
      XCTAssertFalse(queue.isCurrent)
      lock.lock()
      envelopes.append($0)
      lock.unlock()
      delivered.fulfill()
    })
    let date = Date(timeIntervalSince1970: 1)
    let generation = RuntimeEventGeneration(queue: queue, now: { date }, delivery: delivery)
    queue.sync { generation.setOperationID("vm-start") }
    generation.observeDisplayState(.opening, operationID: "display-open")
    queue.sync { generation.setOperationID("vm-stop") }
    generation.observeDisplayState(.open, operationID: "display-open")
    generation.observeDisplayState(.closing, operationID: nil)
    generation.close()
    generation.observeDisplayState(.closed, operationID: nil)
    wait(for: [delivered], timeout: 1)
    queue.sync {}
    lock.lock()
    let snapshot = envelopes
    lock.unlock()
    XCTAssertEqual(snapshot.map(\.operationID), ["display-open", "display-open", nil])
    XCTAssertEqual(
      snapshot.map(\.event),
      [
        .displayStateChanged(occurredAt: date, state: .opening),
        .displayStateChanged(occurredAt: date, state: .open),
        .displayStateChanged(occurredAt: date, state: .closing),
      ])
  }

  func testLaunchIdentityIsBoundToTheLoggerWithoutIncludingAuthentication() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-launch-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("driver.log")
    let vmID = "vm_01J00000000000000000000000"
    let token = "test-only-logging-secret-not-a-real-token"
    let launch = DriverLaunchMode.v2(
      Config(
        vmId: try DriverProtocolV2.VMID(vmID), generation: 7,
        socketPath: root.appendingPathComponent("control.sock").path,
        bundlePath: root.appendingPathComponent("vm.gaovm").path,
        authToken: token, logPath: file.path))
    let logger = launch.makeLogger()
    XCTAssertTrue(logger.log(.info, "driver bootstrap"))
    XCTAssertTrue(logger.flush(timeout: 3))
    let contents = try Data(contentsOf: file)
    let record = try XCTUnwrap(JSONSerialization.jsonObject(with: contents) as? [String: Any])
    XCTAssertEqual(record["vm_id"] as? String, vmID)
    XCTAssertEqual(record["driver_generation"] as? Int, 7)
    XCTAssertTrue(record["operation_id"] is NSNull)
    XCTAssertTrue(record["request_id"] is NSNull)
    XCTAssertFalse(String(decoding: contents, as: UTF8.self).contains(token))
  }

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

  func testCommittedKillExitCannotBeOverwrittenByControlSocketShutdown() {
    var gate = DriverTerminalExitGate()
    gate.beginCommand(exitCode: 137)
    gate.observeRuntimeTerminal()
    gate.completeCommand(succeeded: true)
    XCTAssertEqual(gate.commitControlClose(exitCode: 137), 137)
    XCTAssertEqual(gate.committedExitCode, 137)
    XCTAssertEqual(gate.commitControlClose(exitCode: 0), 137)
    gate.beginCommand(exitCode: 0)
    XCTAssertEqual(gate.readyExitCode, 137)
  }
}
