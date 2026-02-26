// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "vz_macos",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "gaovm-driver-vz", targets: ["vz_macos"])
    ],
    targets: [
        .executableTarget(
            name: "vz_macos",
            path: "Sources/vz_macos"
        )
    ]
)
