import XCTest

@testable import vz_macos

final class VzConfigurationV2Tests: XCTestCase {
  func testV2ConfigurationPreservesEveryRuntimeDeviceAndPath() throws {
    let value = DriverProtocolV2.RuntimeConfiguration(
      architecture: "arm64",
      cpu: 4,
      memoryBytes: 1_073_741_824,
      boot: .linuxKernel(
        .init(
          type: "linux_kernel", kernelPath: "/runtime/kernel", initrdPath: "/runtime/initrd",
          commandLine: "console=hvc0")),
      disks: [
        .init(id: "root", path: "/runtime/root.img", writable: true),
        .init(id: "seed", path: "/runtime/seed.img", writable: false),
      ],
      networks: [
        .init(id: "net0", mode: .shared, macAddress: "02:00:00:00:00:01"),
        .init(id: "offline", mode: .none, macAddress: nil),
      ],
      graphics: .init(enabled: true, width: 1280, height: 800, pixelsPerInch: 144),
      serial: .init(enabled: true, capture: true, logPath: "/runtime/serial.log"),
      guestAgent: .init(enabled: true, vsockPort: 1024),
      bundlePath: "/runtime/vm.gaovm",
      logPaths: .init(driver: "/runtime/driver.log", serial: "/runtime/serial.log"))

    let normalized = try NormalizedVmConfig(v2: value)

    XCTAssertEqual(normalized.disks.map(\.path), ["/runtime/root.img", "/runtime/seed.img"])
    XCTAssertEqual(normalized.disks.map(\.writable), [true, false])
    XCTAssertEqual(normalized.networks.map(\.mode), [.shared, .none])
    XCTAssertEqual(normalized.networks.first?.macAddress, "02:00:00:00:00:01")
    XCTAssertEqual(normalized.serial?.logPath, "/runtime/serial.log")
    XCTAssertEqual(normalized.guestAgent?.vsockPort, 1024)
    XCTAssertEqual(normalized.bundlePath, "/runtime/vm.gaovm")
  }

  func testV2EFIConfigurationRemainsTyped() throws {
    let value = DriverProtocolV2.RuntimeConfiguration(
      architecture: "arm64",
      cpu: 2,
      memoryBytes: 536_870_912,
      boot: .efi(.init(type: "efi", variableStorePath: "/runtime/nvram")),
      disks: [.init(id: "root", path: "/runtime/root.img", writable: true)],
      networks: [.init(id: "offline", mode: .none, macAddress: nil)],
      graphics: .init(enabled: false, width: nil, height: nil, pixelsPerInch: nil),
      serial: .init(enabled: false, capture: false, logPath: "/runtime/serial.log"),
      guestAgent: .init(enabled: false, vsockPort: 1024),
      bundlePath: "/runtime/vm.gaovm",
      logPaths: .init(driver: "/runtime/driver.log", serial: "/runtime/serial.log"))

    let normalized = try NormalizedVmConfig(v2: value)
    guard case .efi(let path) = normalized.boot else {
      return XCTFail("expected EFI boot")
    }
    XCTAssertEqual(path, "/runtime/nvram")
  }
}
