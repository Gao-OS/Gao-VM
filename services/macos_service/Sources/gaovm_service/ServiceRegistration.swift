import Foundation

enum ServiceAction: String {
  case status, register, unregister
}

// Service Management is the external boundary; fixtures never register jobs.
protocol ServiceRegistrationBoundary: AnyObject {
  var state: ServiceState { get }
  func register() throws
  func unregister() async throws
}

struct ServiceRegistration {
  let bundleIdentifier: String
  let service: ServiceRegistrationBoundary

  func execute(_ action: ServiceAction) async -> ServiceResult {
    func result(
      _ state: ServiceState, _ outcome: String, _ error: ServiceFailure? = nil,
      _ code: Int32 = 0
    ) -> ServiceResult {
      ServiceResult(
        action: action.rawValue, bundleIdentifier: bundleIdentifier, state: state,
        outcome: outcome, error: error, exitCode: code)
    }
    let before = service.state
    switch action {
    case .status: return result(before, "observed")
    case .register:
      if before == .enabled { return result(before, "unchanged") }
      if before == .requiresApproval {
        return result(before, "approval_required", .approvalRequired, 3)
      }
      do { try service.register() } catch {
        return result(service.state, "failed", .registerFailed, 1)
      }
      let after = service.state
      if after == .enabled { return result(after, "registered") }
      if after == .requiresApproval {
        return result(after, "approval_required", .approvalRequired, 3)
      }
      return result(after, "unconfirmed", .unconfirmed, 1)
    case .unregister:
      if before == .notRegistered { return result(before, "unchanged") }
      do { try await service.unregister() } catch {
        return result(service.state, "failed", .unregisterFailed, 1)
      }
      let after = service.state
      if after == .notRegistered { return result(after, "unregistered") }
      return result(after, "unconfirmed", .unconfirmed, 1)
    }
  }
}
