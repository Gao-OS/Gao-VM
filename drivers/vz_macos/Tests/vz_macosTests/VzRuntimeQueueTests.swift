import Foundation
import XCTest

@testable import vz_macos

final class VzRuntimeQueueTests: XCTestCase {
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
