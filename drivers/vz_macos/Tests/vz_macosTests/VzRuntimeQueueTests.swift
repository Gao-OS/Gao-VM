import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class VzRuntimeQueueTests: XCTestCase {
  func testConsoleStatusUsesItsLiveCaptureAndDoesNotOpenAStagedLog() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-console-applied-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let appliedPath = root.appendingPathComponent("applied.log").path
    let stagedPath = root.appendingPathComponent("staged.log").path
    let serial = try SerialController(path: appliedPath)
    serial.start()
    let producer = FileHandle(
      fileDescriptor: Darwin.dup(serial.driverOutput.fileDescriptor), closeOnDealloc: true)
    let runtime = VzRuntime(
      logger: RotatingLogger(path: root.appendingPathComponent("driver.log").path))
    defer { XCTAssertTrue(runtime.logger.flush(timeout: 3)) }
    // Real capture ownership at the native attachment boundary, without a VZ VM.
    runtime.vzRuntimeQueue.sync { runtime.serialController = serial }
    let dispatcher = RuntimeCommandDispatcher(runtime: runtime)
    let configured = expectation(description: "future serial configuration staged")
    dispatcher.configure(with: serialFixtureConfiguration(stagedPath)) { _ in configured.fulfill() }
    wait(for: [configured], timeout: 1)
    let observed = expectation(description: "live capture snapshot without I/O queue progress")
    dispatcher.consoleStatus { result in
      guard case .success(let snapshot) = result else { return XCTFail("console status failed") }
      XCTAssertEqual(snapshot["ready"] as? Bool, true)
      XCTAssertEqual(snapshot["log_path"] as? String, appliedPath)
      do { _ = try JSONSerialization.data(withJSONObject: snapshot) } catch {
        XCTFail("console snapshot is not JSON serializable: \(error)")
      }
      observed.fulfill()
    }
    wait(for: [observed], timeout: 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPath))
    let cleaned = expectation(description: "serial drain joined")
    runtime.shutdown { _ in cleaned.fulfill() }
    let retired = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in !serial.snapshot.ready }, object: nil)
    // Predicate expectations poll once per second; allow a subsequent sample
    // after asynchronous retirement, rather than racing the first poll.
    let retiredResult = XCTWaiter.wait(for: [retired], timeout: 3)
    let inactive = expectation(
      description: "inactive is observable while cleanup still waits for EOF")
    dispatcher.consoleStatus { result in
      guard case .success(let snapshot) = result else {
        return XCTFail("console status failed during drain")
      }
      XCTAssertEqual(snapshot["ready"] as? Bool, false)
      XCTAssertTrue(snapshot["log_path"] is NSNull)
      inactive.fulfill()
    }
    wait(for: [inactive], timeout: 1)
    try producer.close()
    wait(for: [cleaned], timeout: 2)
    XCTAssertEqual(retiredResult, .completed)
  }

  func testPreparedSerialCaptureReportsReadyWithStartCorrelationBeforeAnyVmBoot() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-console-ready-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let logPath = root.appendingPathComponent("serial.log").path
    let operationID = "op_01J00000000000000000000002"
    let blockedParent = root.appendingPathComponent("not-a-directory")
    XCTAssertTrue(FileManager.default.createFile(atPath: blockedParent.path, contents: nil))
    let ready = expectation(description: "real prepared capture reports ready")
    ready.assertForOverFulfill = true
    let runtime = VzRuntime(
      logger: RotatingLogger(path: root.appendingPathComponent("driver.log").path),
      eventEnvelopeSink: { envelope in
        if case .consoleReady(_, let path) = envelope.event {
          XCTAssertEqual(path, logPath)
          XCTAssertEqual(envelope.operationID, operationID)
          ready.fulfill()
        }
      })
    defer { XCTAssertTrue(runtime.logger.flush(timeout: 3)) }
    let configured = expectation(description: "configured")
    runtime.configure(
      with: serialFixtureConfiguration(
        logPath,
        disks: [
          .init(
            id: "blocked", path: blockedParent.appendingPathComponent("disk.img").path,
            writable: true, createSizeMiB: 1)
        ])
    ) { _ in configured.fulfill() }
    wait(for: [configured], timeout: 1)
    runtime.setOperationContext(operationID)
    let failed = expectation(description: "disk failure prevents VZ configuration")
    runtime.start { result in
      guard case .failure = result else { return XCTFail("fixture must never start a VM") }
      failed.fulfill()
    }
    wait(for: [failed], timeout: 2)
    let observed = XCTWaiter.wait(for: [ready], timeout: 1)
    let cleaned = expectation(description: "all real serial I/O joined")
    runtime.shutdown { _ in cleaned.fulfill() }
    wait(for: [cleaned], timeout: 2)
    XCTAssertEqual(observed, .completed)
    runtime.vzRuntimeQueue.sync { XCTAssertNil(runtime.virtualMachine) }
  }

  func testStartDeadlineIncludesAStalledSerialOpenAndFencesItsLateReturn() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-deadline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("serial.log").path
    XCTAssertEqual(Darwin.mkfifo(path, mode_t(0o600)), 0)
    let runtime = VzRuntime(
      logger: RotatingLogger(path: root.appendingPathComponent("driver.log").path))
    defer { XCTAssertTrue(runtime.logger.flush(timeout: 3)) }
    let configured = expectation(description: "configured")
    runtime.configure(with: serialFixtureConfiguration(path)) { _ in configured.fulfill() }
    wait(for: [configured], timeout: 1)
    let timedOut = expectation(description: "existing 30-second start deadline")
    var startResult: RuntimeResult?
    runtime.start { result in
      startResult = result
      timedOut.fulfill()
    }
    let deadlineResult = XCTWaiter.wait(for: [timedOut], timeout: 32)
    // Release and join the owned setup even if the deadline regression is RED.
    let reader = Darwin.open(path, O_RDONLY | O_NONBLOCK)
    XCTAssertGreaterThanOrEqual(reader, 0)
    defer { if reader >= 0 { Darwin.close(reader) } }
    let stopped = expectation(description: "late setup returned and was fenced")
    runtime.shutdown { _ in stopped.fulfill() }
    wait(for: [stopped], timeout: 2)
    XCTAssertEqual(deadlineResult, .completed)
    guard case .failure(let error) = startResult else {
      return XCTFail("stalled start did not fail")
    }
    XCTAssertTrue(error is RuntimeLifecycleTimeoutError)
    runtime.vzRuntimeQueue.sync {
      XCTAssertNil(runtime.serialController)
      XCTAssertNil(runtime.virtualMachine)
    }
  }

  func testNewSerialSinkIsNotOpenedUntilTheRetiredWriterHasActuallyDrained() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-replacement-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let serial = try SerialController(path: root.appendingPathComponent("retired.log").path)
    serial.start()
    let producer = FileHandle(
      fileDescriptor: Darwin.dup(serial.driverOutput.fileDescriptor), closeOnDealloc: true)
    let path = root.appendingPathComponent("new.log").path
    let blockedParent = root.appendingPathComponent("not-a-directory")
    XCTAssertTrue(FileManager.default.createFile(atPath: blockedParent.path, contents: nil))
    let runtime = VzRuntime(
      logger: RotatingLogger(path: root.appendingPathComponent("driver.log").path))
    defer { XCTAssertTrue(runtime.logger.flush(timeout: 3)) }
    runtime.vzRuntimeQueue.sync { runtime.serialController = serial }
    let configured = expectation(description: "new configuration persisted in runtime")
    runtime.configure(
      with: serialFixtureConfiguration(
        path,
        disks: [
          .init(
            id: "blocked", path: blockedParent.appendingPathComponent("disk.img").path,
            writable: true, createSizeMiB: 1)
        ])
    ) { _ in configured.fulfill() }
    wait(for: [configured], timeout: 1)
    let started = expectation(description: "disk setup rejected before any VZ configuration")
    runtime.start { result in
      guard case .failure = result else { return XCTFail("fixture cannot start a VM") }
      started.fulfill()
    }
    let status = expectation(description: "status while old writer drains")
    runtime.status { _ in status.fulfill() }
    wait(for: [status], timeout: 1)
    runtime.vzRuntimeQueue.sync {}
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: path), "old and new log owners must not overlap")
    try producer.close()
    wait(for: [started], timeout: 2)
    let stopped = expectation(description: "all fixture serial work joined")
    runtime.shutdown { _ in stopped.fulfill() }
    wait(for: [stopped], timeout: 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    runtime.vzRuntimeQueue.sync { XCTAssertNil(runtime.virtualMachine) }
  }

  func testShutdownCancelsStalledSerialPreparationButWaitsForItsActualReturn() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("serial.log").path
    XCTAssertEqual(Darwin.mkfifo(path, mode_t(0o600)), 0)
    let runtime = VzRuntime(
      logger: RotatingLogger(path: root.appendingPathComponent("driver.log").path))
    defer { XCTAssertTrue(runtime.logger.flush(timeout: 3)) }
    let configured = expectation(description: "configured")
    runtime.configure(with: serialFixtureConfiguration(path)) { _ in configured.fulfill() }
    wait(for: [configured], timeout: 1)
    let cancelled = expectation(description: "pending start cancelled once")
    runtime.start { result in
      guard case .failure(let error) = result else {
        return XCTFail("stalled start cannot succeed")
      }
      XCTAssertTrue(String(describing: error).contains("cancelled by shutdown"))
      cancelled.fulfill()
    }
    let responsive = expectation(description: "status remains responsive")
    runtime.status { _ in responsive.fulfill() }
    wait(for: [responsive], timeout: 1)
    runtime.vzRuntimeQueue.sync {}
    let received = NSCondition()
    var result: RuntimeResult?
    runtime.shutdown { value in
      received.lock()
      result = value
      received.signal()
      received.unlock()
    }
    wait(for: [cancelled], timeout: 1)
    received.lock()
    let expires = Date(timeIntervalSinceNow: 0.1)
    while result == nil, received.wait(until: expires) {}
    let returnedBeforeSetup = result != nil
    received.unlock()
    let reader = Darwin.open(path, O_RDONLY | O_NONBLOCK)
    XCTAssertGreaterThanOrEqual(reader, 0)
    defer { if reader >= 0 { Darwin.close(reader) } }
    received.lock()
    let finishedBy = Date(timeIntervalSinceNow: 2)
    while result == nil, received.wait(until: finishedBy) {}
    let shutdown = result
    received.unlock()
    XCTAssertFalse(returnedBeforeSetup, "cancellation is not proof that the I/O job returned")
    guard case .success = shutdown else {
      return XCTFail("shutdown did not join late serial preparation")
    }
    runtime.vzRuntimeQueue.sync {
      XCTAssertNil(runtime.serialController)
      XCTAssertNil(runtime.virtualMachine)
    }
  }

  private func serialFixtureConfiguration(_ path: String, disks: [NormalizedDisk] = [])
    -> NormalizedVmConfig
  {
    NormalizedVmConfig(
      cpu: 2, memoryBytes: 1_073_741_824,
      boot: .linux(.init(kernelPath: "/unused/kernel", initrdPath: nil, commandLine: "")),
      disks: disks, networks: [], graphicsEnabled: false, graphicsWidth: 1280,
      graphicsHeight: 800, serial: .init(capture: true, logPath: path), guestAgent: nil,
      bundlePath: nil)
  }

  func testStalledSerialPreparationLeavesRuntimeStatusResponsiveAndCannotCreateAVm() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-prepare-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("serial.log").path
    XCTAssertEqual(Darwin.mkfifo(path, mode_t(0o600)), 0)
    let logger = RotatingLogger(path: root.appendingPathComponent("driver.log").path)
    let runtime = VzRuntime(logger: logger)
    let dispatcher = RuntimeCommandDispatcher(runtime: runtime)
    defer { XCTAssertTrue(logger.flush(timeout: 3)) }
    let configured = expectation(description: "configured without file I/O")
    let configuration = NormalizedVmConfig(
      cpu: 2, memoryBytes: 1_073_741_824,
      boot: .linux(.init(kernelPath: "/unused/kernel", initrdPath: nil, commandLine: "")),
      disks: [], networks: [], graphicsEnabled: false, graphicsWidth: 1280,
      graphicsHeight: 800, serial: .init(capture: true, logPath: path), guestAgent: nil,
      bundlePath: nil)
    dispatcher.configure(with: configuration) { _ in configured.fulfill() }
    wait(for: [configured], timeout: 1)
    let startFinished = expectation(description: "serial setup failure joined")
    var startResult: RuntimeResult?
    dispatcher.start { result in
      startResult = result
      startFinished.fulfill()
    }
    let statusReceived = NSCondition()
    var status: RuntimeResult?
    dispatcher.status { result in
      statusReceived.lock()
      status = result
      statusReceived.signal()
      statusReceived.unlock()
    }
    statusReceived.lock()
    let expires = Date(timeIntervalSinceNow: 0.5)
    while status == nil, statusReceived.wait(until: expires) {}
    let responsive = status != nil
    statusReceived.unlock()
    let consoleReceived = expectation(description: "console status bypasses the pending start lane")
    dispatcher.consoleStatus { result in
      guard case .success(let snapshot) = result else { return XCTFail("console snapshot failed") }
      XCTAssertEqual(snapshot["ready"] as? Bool, false)
      XCTAssertTrue(snapshot["log_path"] is NSNull)
      consoleReceived.fulfill()
    }
    let consoleResult = XCTWaiter.wait(for: [consoleReceived], timeout: 1)
    XCTAssertNil(startResult, "the serial setup must still be pending before its FIFO is released")
    // This fixture releases its stalled open, then seekToEnd fails on the FIFO.
    // No valid VZ configuration or VM is constructed in either RED or GREEN.
    let reader = Darwin.open(path, O_RDONLY | O_NONBLOCK)
    XCTAssertGreaterThanOrEqual(reader, 0)
    defer { if reader >= 0 { Darwin.close(reader) } }
    wait(for: [startFinished], timeout: 2)
    runtime.vzRuntimeQueue.sync {}
    XCTAssertTrue(responsive, "serial sink preparation must not hold the VZ control queue")
    XCTAssertEqual(consoleResult, .completed)
    guard case .failure = startResult else { return XCTFail("FIFO serial sink must fail start") }
    let finalStatus = expectation(description: "VM was not created")
    runtime.status { result in
      if case .success(let snapshot) = result {
        XCTAssertEqual(snapshot["state"] as? String, "not_created")
      } else {
        XCTFail("status failed after rejected serial preparation")
      }
      finalStatus.fulfill()
    }
    wait(for: [finalStatus], timeout: 1)
  }

  func testShutdownWaitsForActualSerialDrainWithoutHoldingTheRuntimeQueue() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-shutdown-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("serial.log").path
    let serial = try SerialController(path: path)
    serial.start()
    let producer = FileHandle(
      fileDescriptor: Darwin.dup(serial.driverOutput.fileDescriptor), closeOnDealloc: true)
    let bytes = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
    try producer.write(contentsOf: bytes)
    let logger = RotatingLogger(path: root.appendingPathComponent("driver.log").path)
    let runtime = VzRuntime(logger: logger)
    defer { XCTAssertTrue(logger.flush(timeout: 3)) }
    runtime.vzRuntimeQueue.sync { runtime.serialController = serial }
    let shutdownReceived = NSCondition()
    var shutdown: RuntimeResult?
    runtime.shutdown { result in
      shutdownReceived.lock()
      shutdown = result
      shutdownReceived.signal()
      shutdownReceived.unlock()
    }
    let status = expectation(description: "status while serial drain is pending")
    runtime.status { _ in status.fulfill() }
    wait(for: [status], timeout: 1)
    shutdownReceived.lock()
    let expires = Date(timeIntervalSinceNow: 0.1)
    while shutdown == nil, shutdownReceived.wait(until: expires) {}
    let completedBeforeEOF = shutdown != nil
    shutdownReceived.unlock()
    try producer.close()
    let drained = expectation(description: "owned serial fixture fully drained")
    serial.close { _ in drained.fulfill() }
    wait(for: [drained], timeout: 2)
    shutdownReceived.lock()
    let shutdownExpires = Date(timeIntervalSinceNow: 1)
    while shutdown == nil, shutdownReceived.wait(until: shutdownExpires) {}
    let result = shutdown
    shutdownReceived.unlock()
    XCTAssertFalse(
      completedBeforeEOF, "shutdown completion must include actual serial EOF and flush")
    guard case .success = result else { return XCTFail("shutdown did not finish after serial EOF") }
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
  }

  func testSerialDrainDoesNotBlockRuntimeStatusWhileAProducerStillOwnsThePipe() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-status-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("serial.log").path
    let serial = try SerialController(path: path)
    let producer = Darwin.dup(serial.driverOutput.fileDescriptor)
    XCTAssertGreaterThanOrEqual(producer, 0)
    let logger = RotatingLogger(path: root.appendingPathComponent("driver.log").path)
    let runtime = VzRuntime(logger: logger)
    defer { XCTAssertTrue(logger.flush(timeout: 3)) }
    runtime.vzRuntimeQueue.sync { runtime.serialController = serial }
    let drainRequested = expectation(description: "serial drain requested")
    let drainReturned = expectation(description: "serial drain returned")
    let statusReceived = NSCondition()
    var status: RuntimeResult?
    runtime.vzRuntimeQueue.async {
      drainRequested.fulfill()
      runtime.flushSerialOutput()
      drainReturned.fulfill()
    }
    wait(for: [drainRequested], timeout: 1)
    runtime.status { result in
      statusReceived.lock()
      status = result
      statusReceived.signal()
      statusReceived.unlock()
    }
    statusReceived.lock()
    let expires = Date(timeIntervalSinceNow: 0.5)
    while status == nil, statusReceived.wait(until: expires) {}
    let responsive = status != nil
    statusReceived.unlock()
    // Release only this fixture's duplicate, then join cleanup even on RED.
    XCTAssertEqual(Darwin.close(producer), 0)
    wait(for: [drainReturned], timeout: 2)
    let drained = expectation(description: "owned serial fixture fully drained")
    serial.close { _ in drained.fulfill() }
    wait(for: [drained], timeout: 2)
    runtime.vzRuntimeQueue.sync {}
    XCTAssertTrue(responsive, "serial EOF/drain must not hold the VZ control queue")
  }

  func testHeadlessDisplayCommandsDoNotWaitForAppKitOrCreateAVm() throws {
    XCTAssertTrue(Thread.isMainThread)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-headless-display-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = RotatingLogger(path: root.appendingPathComponent("driver.log").path)
    let runtime = VzRuntime(logger: logger)
    let received = NSCondition()
    var results: [String: RuntimeResult] = [:]
    let record: (String) -> RuntimeCompletion = { name in
      { result in
        received.lock()
        results[name] = result
        received.signal()
        received.unlock()
      }
    }
    runtime.displayStatus(completion: record("status"))
    runtime.closeDisplay(operationID: nil, completion: record("close"))
    runtime.openDisplay(activate: false, operationID: nil, completion: record("open"))
    received.lock()
    let deadline = Date(timeIntervalSinceNow: 1)
    while results.count < 3, received.wait(until: deadline) {}
    let snapshots = results
    received.unlock()
    XCTAssertEqual(snapshots.count, 3, "headless commands must not require the main run loop")
    for command in ["status", "close"] {
      guard case .success(let result) = snapshots[command] else {
        XCTFail("headless \(command) did not return its closed display snapshot")
        continue
      }
      XCTAssertEqual(result["display_state"] as? String, "closed")
      XCTAssertEqual(result["open"] as? Bool, false)
    }
    guard case .failure(let error) = snapshots["open"] else {
      return XCTFail("display open must not create a VM")
    }
    XCTAssertTrue(String(describing: error).contains("vm is not created"))
  }

  func testRuntimeStatusDoesNotWaitForTheAppKitMainActor() throws {
    XCTAssertTrue(Thread.isMainThread)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-display-status-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = RotatingLogger(path: root.appendingPathComponent("driver.log").path)
    let runtime = VzRuntime(logger: logger)
    let received = NSCondition()
    var result: RuntimeResult?
    runtime.status { value in
      received.lock()
      result = value
      received.signal()
      received.unlock()
    }
    // Deliberately do not pump the main run loop: a status snapshot must read
    // the VZ queue's observation, not synchronously ask AppKit about its window.
    received.lock()
    let expires = Date(timeIntervalSinceNow: 1)
    while result == nil, received.wait(until: expires) {}
    let snapshot = result
    received.unlock()
    guard case .success(let status) = snapshot else {
      return XCTFail("runtime status waited for AppKit instead of completing on its own queue")
    }
    XCTAssertEqual(status["graphicsWindowOpen"] as? Bool, false)
    XCTAssertEqual(status["state"] as? String, "not_created")
  }

  func testShutdownRequestsGracefulStopBeforeForceEscalationOnRuntimeQueue() {
    let queue = VzRuntimeQueue(label: "test.gaovm.vz-runtime")
    let coordinator = RuntimeStopCoordinator(queue: queue, pollInterval: 0.005)
    let completed = expectation(description: "stop completed")
    let lock = NSLock()
    var calls: [String] = []

    coordinator.stop(
      gracePeriod: 0.02,
      forceTimeout: 0.1,
      state: {
        XCTAssertTrue(queue.isCurrent)
        return .running
      },
      canRequestStop: {
        XCTAssertTrue(queue.isCurrent)
        return true
      },
      requestStop: {
        XCTAssertTrue(queue.isCurrent)
        lock.lock()
        calls.append("requestStop")
        lock.unlock()
      },
      forceStop: { callback in
        XCTAssertTrue(queue.isCurrent)
        lock.lock()
        calls.append("forceStop")
        lock.unlock()
        callback(nil)
      },
      completion: { result in
        if case .failure(let error) = result {
          XCTFail("stop failed: \(error)")
        }
        completed.fulfill()
      }
    )

    wait(for: [completed], timeout: 1)
    lock.lock()
    XCTAssertEqual(calls, ["requestStop", "forceStop"])
    lock.unlock()
  }

  func testForceStopTimesOutWhenCompletionNeverArrives() {
    let queue = VzRuntimeQueue(label: "test.gaovm.vz-runtime.force-timeout")
    let coordinator = RuntimeStopCoordinator(queue: queue, pollInterval: 0.005)
    let completed = expectation(description: "force stop timed out")

    coordinator.stop(
      gracePeriod: 0,
      forceTimeout: 0.02,
      state: { .running },
      canRequestStop: { false },
      requestStop: {},
      forceStop: { _ in },
      completion: { result in
        guard case .failure(let error) = result else {
          return XCTFail("expected force-stop timeout")
        }
        XCTAssertTrue(String(describing: error).contains("force stop callback timed out"))
        completed.fulfill()
      }
    )

    wait(for: [completed], timeout: 1)
  }

  func testRuntimeSourcesContainNoBlockingSemaphoreOrSleepPolling() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcesDirectory = packageRoot.appendingPathComponent("Sources/vz_macos")
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil))
    let sources = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }

    for source in sources {
      let text = try String(contentsOf: source, encoding: .utf8)
      XCTAssertFalse(text.contains("DispatchSemaphore"), source.lastPathComponent)
      XCTAssertFalse(text.contains("usleep("), source.lastPathComponent)
      XCTAssertFalse(text.contains("sleep("), source.lastPathComponent)
    }
  }
}
