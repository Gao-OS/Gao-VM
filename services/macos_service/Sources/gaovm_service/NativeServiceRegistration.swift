import Foundation
import ServiceManagement

final class NativeServiceRegistration: ServiceRegistrationBoundary {
  private let service = SMAppService.agent(plistName: "gaovmd.plist")

  var state: ServiceState { ServiceState(rawValue: service.status.rawValue) }

  func register() throws { try service.register() }

  func unregister() async throws {
    try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
      service.unregister { error in
        if let error { completion.resume(throwing: error) } else { completion.resume() }
      }
    }
  }
}
