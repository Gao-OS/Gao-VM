import Foundation

/// Static executable diagnostics, not an authenticated session or VM readiness.
enum DriverComponentInfo {
  static let version = "0.1.0"

  static func encoded() throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "format": "gaovm.component.v1", "role": "driver-vz", "version": version,
        "public_api": NSNull(), "vm_spec": NSNull(),
        "driver_protocol": DriverProtocolV2.version, "catalog_schema": NSNull(),
        "capabilities": [
          "offered": DriverSessionV2.runtimeCapabilities.map(\.rawValue).sorted(),
          "required": DriverSessionV2.requiredCapabilities.map(\.rawValue).sorted(),
          "development_only": DriverSessionV2.developmentCapabilities.map(\.rawValue).sorted(),
        ],
        "service_actions": [],
      ], options: [.sortedKeys])
  }
}
