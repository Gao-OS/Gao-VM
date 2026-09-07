import Foundation
import XCTest

@testable import vz_macos

final class RuntimeCommandDispatcherTests: XCTestCase {
  func testLifecycleCommandsRunInSubmissionOrder() {
    let runtime = ControllableRuntime()
    let dispatcher = RuntimeCommandDispatcher(runtime: runtime)

    dispatcher.configure(with: ["cpu": 2]) { _ in }
    dispatcher.start { _ in }
    dispatcher.stop { _ in }
    dispatcher.kill { _ in }

    XCTAssertEqual(runtime.waitForCalls(count: 1), ["configure"])

    runtime.completeNext()
    XCTAssertEqual(runtime.waitForCalls(count: 2), ["configure", "start"])

    runtime.completeNext()
    XCTAssertEqual(runtime.waitForCalls(count: 3), ["configure", "start", "stop"])

    runtime.completeNext()
    XCTAssertEqual(runtime.waitForCalls(count: 4), ["configure", "start", "stop", "kill"])
    runtime.completeNext()
  }

  func testLifecycleTimeoutPoisonsDispatcherAndDoesNotStartNextCommand() {
    let runtime = ControllableRuntime()
    let startFailed = expectation(description: "start failed")
    let stopCancelled = expectation(description: "queued stop cancelled")
    let fatalTeardown = expectation(description: "fatal teardown")
    let futureCommandRejected = expectation(description: "future command rejected")
    let poisonedCloseRejected = expectation(description: "poisoned close rejected")
    let dispatcher = RuntimeCommandDispatcher(runtime: runtime) { error in
      XCTAssertTrue(error is RuntimeLifecycleTimeoutError)
      fatalTeardown.fulfill()
    }

    dispatcher.start { result in
      guard case .failure(let error) = result else {
        return XCTFail("expected start timeout")
      }
      XCTAssertTrue(error is RuntimeLifecycleTimeoutError)
      startFailed.fulfill()
    }
    dispatcher.stop { result in
      guard case .failure(let error) = result else {
        return XCTFail("expected queued stop cancellation")
      }
      XCTAssertTrue(error is RuntimeDispatcherClosedError)
      stopCancelled.fulfill()
    }

    XCTAssertEqual(runtime.waitForCalls(count: 1), ["start"])
    runtime.completeNext(
      with: .failure(RuntimeLifecycleTimeoutError("vm start timed out after 30s")))
    wait(for: [startFailed, stopCancelled, fatalTeardown], timeout: 1)

    dispatcher.kill { result in
      guard case .failure(let error) = result else {
        return XCTFail("expected future kill rejection")
      }
      XCTAssertTrue(error is RuntimeDispatcherClosedError)
      futureCommandRejected.fulfill()
    }
    wait(for: [futureCommandRejected], timeout: 1)
    dispatcher.closeAndShutdown(reason: "control socket EOF") { result in
      guard case .failure(let error) = result else {
        return XCTFail("poisoned dispatcher must not issue another runtime command")
      }
      XCTAssertTrue(error is RuntimeLifecycleTimeoutError)
      poisonedCloseRejected.fulfill()
    }
    wait(for: [poisonedCloseRejected], timeout: 1)
    runtime.repeatLastCompletion(with: .success(["state": "running"]))
    XCTAssertEqual(runtime.waitForCalls(count: 1), ["start"])
  }

  func testCloseDrainsQueueAndWaitsForActiveCompletionBeforeShutdown() {
    let runtime = ControllableRuntime()
    let dispatcher = RuntimeCommandDispatcher(runtime: runtime, shutdownDeadline: 1)
    let activeFinished = expectation(description: "active start finished")
    let configureCancelled = expectation(description: "queued configure cancelled")
    let queuedStartCancelled = expectation(description: "queued start cancelled")
    let futureCommandRejected = expectation(description: "future command rejected")
    let shutdownFinished = expectation(description: "shutdown finished")

    dispatcher.start { result in
      if case .failure(let error) = result {
        XCTFail("active start failed: \(error)")
      }
      activeFinished.fulfill()
    }
    dispatcher.configure(with: ["cpu": 4]) { result in
      if case .failure(let error) = result, error is RuntimeDispatcherClosedError {
        configureCancelled.fulfill()
      }
    }
    dispatcher.start { result in
      if case .failure(let error) = result, error is RuntimeDispatcherClosedError {
        queuedStartCancelled.fulfill()
      }
    }

    XCTAssertEqual(runtime.waitForCalls(count: 1), ["start"])
    dispatcher.closeAndShutdown(reason: "control socket EOF") { result in
      if case .failure(let error) = result {
        XCTFail("shutdown failed: \(error)")
      }
      shutdownFinished.fulfill()
    }
    dispatcher.kill { result in
      if case .failure(let error) = result, error is RuntimeDispatcherClosedError {
        futureCommandRejected.fulfill()
      }
    }

    wait(
      for: [configureCancelled, queuedStartCancelled, futureCommandRejected], timeout: 1)
    XCTAssertEqual(runtime.callsSnapshot, ["start"])

    runtime.completeNext()
    XCTAssertEqual(runtime.waitForCalls(count: 2), ["start", "shutdown"])
    runtime.completeShutdown()
    wait(for: [activeFinished], timeout: 1)
    wait(for: [shutdownFinished], timeout: 1)
  }

  func testCloseFailsAtDeadlineWithoutOverlappingUnresolvedActiveCommand() {
    let runtime = ControllableRuntime()
    let dispatcher = RuntimeCommandDispatcher(runtime: runtime, shutdownDeadline: 0.02)
    let shutdownFailed = expectation(description: "shutdown deadline failed")

    dispatcher.start { _ in }
    XCTAssertEqual(runtime.waitForCalls(count: 1), ["start"])
    dispatcher.closeAndShutdown(reason: "heartbeat timeout") { result in
      guard case .failure(let error) = result else {
        return XCTFail("expected shutdown deadline failure")
      }
      XCTAssertTrue(error is RuntimeShutdownDeadlineError)
      shutdownFailed.fulfill()
    }

    wait(for: [shutdownFailed], timeout: 1)
    XCTAssertEqual(runtime.callsSnapshot, ["start"])
    runtime.completeNext()
    XCTAssertEqual(runtime.callsSnapshot, ["start"])
  }

  func testPingRemainsResponsiveWhileStartIsPending() throws {
    let runtime = ControllableRuntime()
    let dispatcher = RuntimeCommandDispatcher(runtime: runtime)
    let pingResponded = expectation(description: "ping responded")

    dispatcher.start { _ in }
    XCTAssertEqual(runtime.waitForCalls(count: 1), ["start"])

    dispatcher.ping(at: Date(timeIntervalSince1970: 1_000)) { result in
      let response = try? result.get()
      XCTAssertEqual(response?["ok"] as? Bool, true)
      XCTAssertEqual(response?["ts"] as? String, "1970-01-01T00:16:40Z")
      pingResponded.fulfill()
    }

    wait(for: [pingResponded], timeout: 0.1)
    XCTAssertEqual(runtime.waitForCalls(count: 1), ["start"])
    runtime.completeNext()
  }

  func testStopWaitsForPendingStartToComplete() {
    let runtime = ControllableRuntime()
    let dispatcher = RuntimeCommandDispatcher(runtime: runtime)

    dispatcher.start { _ in }
    XCTAssertEqual(runtime.waitForCalls(count: 1), ["start"])

    dispatcher.stop { _ in }
    XCTAssertEqual(runtime.waitForCalls(count: 1), ["start"])

    runtime.completeNext()
    XCTAssertEqual(runtime.waitForCalls(count: 2), ["start", "stop"])
    runtime.completeNext()
  }

  func testStatusRemainsResponsiveWhileStartIsPending() {
    let runtime = ControllableRuntime()
    let dispatcher = RuntimeCommandDispatcher(runtime: runtime)
    let statusResponded = expectation(description: "status responded")

    dispatcher.start { _ in }
    XCTAssertEqual(runtime.waitForCalls(count: 1), ["start"])

    dispatcher.status { result in
      let response = try? result.get()
      XCTAssertEqual(response?["state"] as? String, "starting")
      statusResponded.fulfill()
    }

    wait(for: [statusResponded], timeout: 0.1)
    runtime.completeNext()
  }

  func testImmediateStatusSubmissionIsOrderedAfterStartSubmission() {
    let runtime = ControllableRuntime()
    let dispatcher = RuntimeCommandDispatcher(runtime: runtime)
    let statusResponded = expectation(description: "status responded")

    dispatcher.start { _ in }
    dispatcher.status { result in
      let response = try? result.get()
      XCTAssertEqual(response?["state"] as? String, "starting")
      statusResponded.fulfill()
    }

    XCTAssertEqual(runtime.waitForCalls(count: 2), ["start", "status"])
    wait(for: [statusResponded], timeout: 1)
    runtime.completeNext()
  }
}

private final class ControllableRuntime: RuntimeServicing {
  func setOperationContext(_ operationID: String?) {}
  private let condition = NSCondition()
  private var calls: [String] = []
  private var completions: [RuntimeCompletion] = []
  private var shutdownCompletions: [RuntimeCompletion] = []
  private var lastCompletion: RuntimeCompletion?
  private var runtimeState = "test"

  func configure(with config: [String: Any], completion: @escaping RuntimeCompletion) {
    record("configure", completion: completion)
  }

  func start(completion: @escaping RuntimeCompletion) {
    record("start", completion: completion)
  }

  func stop(completion: @escaping RuntimeCompletion) {
    record("stop", completion: completion)
  }

  func kill(completion: @escaping RuntimeCompletion) {
    record("kill", completion: completion)
  }

  func status(completion: @escaping RuntimeCompletion) {
    condition.lock()
    calls.append("status")
    let state = runtimeState
    condition.broadcast()
    condition.unlock()
    completion(.success(["state": state]))
  }

  func shutdown(completion: @escaping RuntimeCompletion) {
    condition.lock()
    calls.append("shutdown")
    shutdownCompletions.append(completion)
    condition.broadcast()
    condition.unlock()
  }

  func waitForCalls(count: Int) -> [String] {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(1)
    while calls.count < count, condition.wait(until: deadline) {}
    return calls
  }

  var callsSnapshot: [String] {
    condition.lock()
    defer { condition.unlock() }
    return calls
  }

  func completeNext(with result: RuntimeResult = .success(["ok": true])) {
    condition.lock()
    let completion = completions.removeFirst()
    lastCompletion = completion
    condition.unlock()
    completion(result)
  }

  func repeatLastCompletion(with result: RuntimeResult) {
    condition.lock()
    let completion = lastCompletion
    condition.unlock()
    completion?(result)
  }

  func completeShutdown(with result: RuntimeResult = .success(["ok": true])) {
    condition.lock()
    let completion = shutdownCompletions.removeFirst()
    condition.unlock()
    completion(result)
  }

  private func record(_ name: String, completion: @escaping RuntimeCompletion) {
    condition.lock()
    calls.append(name)
    if name == "start" {
      runtimeState = "starting"
    }
    completions.append(completion)
    condition.broadcast()
    condition.unlock()
  }
}
