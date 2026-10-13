import Foundation

enum ServiceFailure: String, Error {
  case invalidInvocation = "INVALID_INVOCATION"
  case invalidBundle = "INVALID_BUNDLE"
  case invalidSignature = "INVALID_SIGNATURE"
  case relaunchFailed = "CANONICAL_LAUNCH_FAILED"
  case registerFailed = "NATIVE_REGISTER_FAILED"
  case unregisterFailed = "NATIVE_UNREGISTER_FAILED"
  case approvalRequired = "USER_APPROVAL_REQUIRED"
  case unconfirmed = "ACTION_UNCONFIRMED"
}

struct ServiceResult: Encodable {
  let action: String
  let bundleIdentifier: String?
  let state: ServiceState?
  let outcome: String
  let error: ServiceFailure?
  let exitCode: Int32

  enum CodingKeys: String, CodingKey {
    case action, outcome
    case bundleIdentifier = "bundle_identifier"
    case plistName = "plist_name"
    case authorizationState = "authorization_state"
    case nativeStatus = "native_status"
    case errorCode = "error_code"
    case nextAction = "next_action"
  }

  func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(action, forKey: .action)
    try fields.encode(bundleIdentifier, forKey: .bundleIdentifier)
    try fields.encode("gaovmd.plist", forKey: .plistName)
    try fields.encode(state?.name, forKey: .authorizationState)
    try fields.encode(state?.rawValue, forKey: .nativeStatus)
    try fields.encode(outcome, forKey: .outcome)
    try fields.encode(error?.rawValue, forKey: .errorCode)
    if state == .requiresApproval {
      try fields.encode("approve_in_system_settings", forKey: .nextAction)
    }
  }
}

struct ServiceState: Equatable {
  let rawValue: Int
  static let notRegistered = Self(rawValue: 0)
  static let enabled = Self(rawValue: 1)
  static let requiresApproval = Self(rawValue: 2)
  static let notFound = Self(rawValue: 3)

  var name: String {
    switch self {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    default: "unknown"
    }
  }
}
