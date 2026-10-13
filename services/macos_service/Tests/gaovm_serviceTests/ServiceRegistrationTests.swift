import Foundation
import XCTest

@testable import gaovm_service

final class ServiceRegistrationTests: XCTestCase {
  func testStatusPreservesAllAuthorizationStatesWithoutMutation() async throws {
    for state in [
      ServiceState.notRegistered, .enabled, .requiresApproval, .notFound,
      ServiceState(rawValue: 100),
    ] {
      let service = RegistrationFixture(state: state)
      let result = await execute(.status, service)
      XCTAssertEqual(result.exitCode, 0)
      XCTAssertEqual(result.state, state)
      XCTAssertEqual(result.outcome, "observed")
      XCTAssertTrue(service.actions.isEmpty)
      let json = try resultJSON(result)
      XCTAssertEqual(json["native_status"] as? Int, state.rawValue)
      XCTAssertEqual(json["authorization_state"] as? String, state.name)
    }
  }

  func testAlreadyEnabledOrUnregisteredActionsAreNoOps() async {
    for (action, state) in [
      (ServiceAction.register, ServiceState.enabled),
      (.unregister, .notRegistered),
    ] {
      let service = RegistrationFixture(state: state)
      let result = await execute(action, service)
      XCTAssertEqual(result.exitCode, 0)
      XCTAssertEqual(result.outcome, "unchanged")
      XCTAssertEqual(result.state, state)
      XCTAssertTrue(service.actions.isEmpty)
    }
  }

  func testConsentIsActionableAndNeverBypassed() async throws {
    for before in [ServiceState.requiresApproval, .notRegistered] {
      let service = RegistrationFixture(state: before)
      service.afterAction = .requiresApproval
      let result = await execute(.register, service)
      XCTAssertEqual(result.exitCode, 3)
      XCTAssertEqual(result.error, .approvalRequired)
      XCTAssertEqual(try resultJSON(result)["next_action"] as? String, "approve_in_system_settings")
      XCTAssertEqual(service.actions, before == .requiresApproval ? [] : ["register"])
    }
  }

  func testUnexpectedPostActionStatesAreUnconfirmedNotSuccessful() async {
    for action in [ServiceAction.register, .unregister] {
      for after in [ServiceState.notFound, ServiceState(rawValue: 100)] {
        let service = RegistrationFixture(state: .notFound)
        service.afterAction = after
        let result = await execute(action, service)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.error, .unconfirmed)
        XCTAssertEqual(result.state, after)
        XCTAssertEqual(service.actions, [action.rawValue])
      }
    }
  }

  func testNativeFailuresCannotBecomeSuccessOrLeakNativeUserInfo() async throws {
    for (action, after, errorCode) in [
      (ServiceAction.register, ServiceState.enabled, ServiceFailure.registerFailed),
      (.unregister, .notRegistered, .unregisterFailed),
      (.unregister, .notFound, .unregisterFailed),
    ] {
      let service = RegistrationFixture(state: .notFound)
      service.afterAction = after
      service.actionError = NSError(
        domain: "sensitive-domain", code: 7,
        userInfo: [NSLocalizedDescriptionKey: "native-secret-marker"])
      let result = await execute(action, service)
      XCTAssertEqual(result.exitCode, 1)
      XCTAssertEqual(result.outcome, "failed")
      XCTAssertEqual(result.error, errorCode)
      XCTAssertEqual(result.state, after)
      XCTAssertEqual(service.actions, [action.rawValue])
      let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
      XCTAssertFalse(json.contains("sensitive-domain"))
      XCTAssertFalse(json.contains("native-secret-marker"))
    }
  }

  func testReportedOutcomeUsesTheSameAuthorizationSnapshotThatConfirmedIt() async {
    let service = ChangingAuthorizationFixture()
    let result = await ServiceRegistration(
      bundleIdentifier: "org.gaovm.tests.Service.Policy", service: service
    ).execute(.register)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.outcome, "registered")
    XCTAssertEqual(result.state, .enabled)
    XCTAssertEqual(service.afterActionReads, 1)
  }

  func testUnregisterDoesNotCompleteUntilTheNativeAsyncCallback() async {
    let service = RegistrationFixture(state: .enabled)
    service.afterAction = .notRegistered
    let started = expectation(description: "native unregister entered")
    let gate = RegistrationGate()
    service.unregisterStarted = { started.fulfill() }
    service.unregisterGate = gate
    let observer = RegistrationResultObserver()
    let task = Task {
      let result = await self.execute(.unregister, service)
      await observer.record(result)
      return result
    }
    let began = await XCTWaiter().fulfillment(of: [started], timeout: 1)
    let premature = await observer.result
    gate.release()
    let result = await task.value
    XCTAssertEqual(began, .completed)
    XCTAssertNil(
      premature, "unregister must await the native callback, not just request submission")
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.outcome, "unregistered")
    XCTAssertEqual(result.state, .notRegistered)
    XCTAssertEqual(service.actions, ["unregister"])
  }

  func testRegisterAttemptsNotFoundOnceAndRequiresAnEnabledOutcome() async {
    let service = RegistrationFixture(state: .notFound)
    service.afterAction = .enabled
    let result = await execute(.register, service)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.outcome, "registered")
    XCTAssertEqual(result.state, .enabled)
    XCTAssertEqual(service.actions, ["register"])
  }

  private func execute(_ action: ServiceAction, _ service: RegistrationFixture) async
    -> ServiceResult
  {
    await ServiceRegistration(bundleIdentifier: "org.gaovm.tests.Service.Policy", service: service)
      .execute(action)
  }
}

func resultJSON(_ value: ServiceResult) throws -> [String: Any] {
  try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

final class ChangingAuthorizationFixture: ServiceRegistrationBoundary {
  private var registered = false
  private(set) var afterActionReads = 0
  var state: ServiceState {
    guard registered else { return .notFound }
    afterActionReads += 1
    return afterActionReads == 1 ? .enabled : .requiresApproval
  }
  func register() throws { registered = true }
  func unregister() async throws { XCTFail("unexpected unregister") }
}

final class RegistrationFixture: ServiceRegistrationBoundary {
  var state: ServiceState
  var afterAction: ServiceState?
  var actionError: Error?
  var actions: [String] = []
  var unregisterStarted: (() -> Void)?
  var unregisterGate: RegistrationGate?

  init(state: ServiceState) { self.state = state }
  func register() throws {
    actions.append("register")
    if let afterAction { state = afterAction }
    if let actionError { throw actionError }
  }
  func unregister() async throws {
    actions.append("unregister")
    unregisterStarted?()
    if let unregisterGate { await unregisterGate.wait() }
    if let afterAction { state = afterAction }
    if let actionError { throw actionError }
  }
}

actor RegistrationResultObserver {
  private(set) var result: ServiceResult?
  func record(_ result: ServiceResult) { self.result = result }
}

final class RegistrationGate {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if released {
        lock.unlock()
        continuation.resume()
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  func release() {
    lock.lock()
    released = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume()
  }
}
