// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "gaovm_service",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "gaovm-service", targets: ["gaovm_service"])],
  targets: [
    .executableTarget(name: "gaovm_service"),
    .testTarget(name: "gaovm_serviceTests", dependencies: ["gaovm_service"]),
  ]
)
