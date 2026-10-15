import Foundation

/// Read-only executable identity. No bundle lookup or Service Management call.
enum ServiceComponentInfo {
  static let version = "0.1.0"

  static func encoded() throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "format": "gaovm.component.v1", "role": "service", "version": version,
        "public_api": NSNull(), "vm_spec": NSNull(), "driver_protocol": NSNull(),
        "catalog_schema": NSNull(),
        "capabilities": ["offered": [], "required": [], "development_only": []],
        "service_actions": ServiceAction.allCases.map(\.rawValue).sorted(),
      ], options: [.sortedKeys])
  }
}
