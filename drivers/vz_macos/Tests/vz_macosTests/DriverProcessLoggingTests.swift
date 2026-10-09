import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class DriverProcessLoggingTests: XCTestCase {
  func testAuthenticatedDriverCorrelatesCommandLogsAndDrainsOnControlEOF() throws {
    let root = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("gaovm-log-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let log = root.appendingPathComponent("driver.log")
    let control = root.appendingPathComponent("control.sock")
    let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("gaovm-driver-vz")
    let vmID = try DriverProtocolV2.VMID("vm_01J00000000000000000000000")
    let operationID = try DriverProtocolV2.OperationID("op_01J00000000000000000000000")
    let failedOperation = try DriverProtocolV2.OperationID("op_01J00000000000000000000001")
    let token = "test-only-driver-logging-authentication"
    let process = Process()
    let exited = DispatchGroup()
    exited.enter()
    process.terminationHandler = { _ in exited.leave() }
    process.executableURL = binary
    process.arguments = [
      "--vm-id", vmID.rawValue, "--generation", "7", "--socket-path", control.path,
      "--bundle-path", root.appendingPathComponent("vm.gaovm").path, "--backend", "vz",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["GAOVM_AUTH_TOKEN"] = token
    environment["GAOVM_DRIVER_LOG_PATH"] = log.path
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    var socket: UnixSocket?
    defer {
      socket?.close()
      if process.isRunning {
        process.terminate()
        if exited.wait(timeout: .now() + 1) != .success, process.isRunning {
          Darwin.kill(process.processIdentifier, SIGKILL)
          XCTAssertEqual(exited.wait(timeout: .now() + 2), .success)
        }
      }
      // Never unlink an executable or remove a live writer's fixture.
      if !process.isRunning { try? FileManager.default.removeItem(at: root) }
    }
    try process.run()
    let listening = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: control.path) },
      object: nil)
    guard XCTWaiter.wait(for: [listening], timeout: 5) == .completed else {
      return XCTFail("compiled driver did not publish its owned control socket")
    }
    let connection = try connect(to: control.path)
    socket = connection
    let codec = DriverProtocolV2Codec()
    guard case .helloRequest(let driverHelloID, let hello) = try read(connection, codec) else {
      return XCTFail("expected driver hello")
    }
    XCTAssertTrue(hello.authToken == token)
    try write(
      .helloSuccessResponse(
        driverHelloID,
        .init(
          protocolVersion: DriverProtocolV2.version, vmId: vmID, driverGeneration: 7,
          operationId: nil, acceptedCapabilities: hello.offeredCapabilities)),
      connection, codec)
    let daemonHelloID = try DriverProtocolV2.JSONRPCID(string: "daemon-hello")
    try write(
      .helloRequest(
        daemonHelloID,
        .init(
          protocolVersion: DriverProtocolV2.version, peerRole: .daemon, vmId: vmID,
          driverGeneration: 7, operationId: nil, authToken: token,
          offeredCapabilities: hello.offeredCapabilities,
          requiredCapabilities: hello.requiredCapabilities, implementation: nil)),
      connection, codec)
    guard case .helloSuccessResponse(let acceptedID, _) = try read(connection, codec) else {
      return XCTFail("expected authenticated daemon hello response")
    }
    XCTAssertEqual(acceptedID, daemonHelloID)
    let configureID = try DriverProtocolV2.JSONRPCID(string: "configure")
    let configuration = DriverProtocolV2.RuntimeConfiguration(
      architecture: "arm64", cpu: 2, memoryBytes: 1_073_741_824,
      boot: .linuxKernel(
        .init(type: "linux_kernel", kernelPath: "/unused/kernel", initrdPath: nil, commandLine: "")),
      disks: [
        .init(id: "root", path: root.appendingPathComponent("root.img").path, writable: true)
      ],
      networks: [.init(id: "net0", mode: .none, macAddress: nil)],
      graphics: .init(enabled: false, width: nil, height: nil, pixelsPerInch: nil),
      serial: .init(
        enabled: false, capture: false, logPath: root.appendingPathComponent("serial.log").path),
      guestAgent: .init(enabled: false, vsockPort: 1024),
      bundlePath: root.appendingPathComponent("vm.gaovm").path,
      logPaths: .init(driver: log.path, serial: root.appendingPathComponent("serial.log").path))
    try write(
      .commandRequest(
        configureID,
        .runtimeConfigure(
          .init(
            vmId: vmID, driverGeneration: 7, operationId: operationID, configuration: configuration)
        )),
      connection, codec)
    var responseReceived = false
    var eventReceived = false
    for _ in 0..<2 {
      switch try read(connection, codec) {
      case .commandSuccessResponse(let id, let response):
        XCTAssertEqual(id, configureID)
        XCTAssertEqual(response.operationId, operationID)
        responseReceived = true
      case .event(.runtimeStateChanged(let event)):
        XCTAssertEqual(event.operationId, operationID)
        eventReceived = true
      default: XCTFail("unexpected configure response")
      }
    }
    XCTAssertTrue(responseReceived && eventReceived)
    let invalidID = try DriverProtocolV2.JSONRPCID(string: "invalid-configure")
    let invalidConfiguration = DriverProtocolV2.RuntimeConfiguration(
      architecture: configuration.architecture, cpu: configuration.cpu,
      memoryBytes: configuration.memoryBytes,
      boot: .linuxKernel(
        .init(type: "linux_kernel", kernelPath: "relative-kernel", initrdPath: nil, commandLine: "")
      ),
      disks: configuration.disks, networks: configuration.networks,
      graphics: configuration.graphics,
      serial: configuration.serial, guestAgent: configuration.guestAgent,
      bundlePath: configuration.bundlePath, logPaths: configuration.logPaths)
    try write(
      .commandRequest(
        invalidID,
        .runtimeConfigure(
          .init(
            vmId: vmID, driverGeneration: 7, operationId: failedOperation,
            configuration: invalidConfiguration))),
      connection, codec)
    guard case .errorResponse(let id, let error) = try read(connection, codec) else {
      return XCTFail("expected a relative-kernel configuration error")
    }
    XCTAssertEqual(id, invalidID)
    XCTAssertEqual(error.data.code, .invalidRuntimeConfig)
    XCTAssertEqual(error.data.operationId, failedOperation)
    XCTAssertFalse(error.data.retryable)
    connection.close()
    guard exited.wait(timeout: .now() + 5) == .success else {
      return XCTFail("driver did not exit after control EOF")
    }
    XCTAssertEqual(process.terminationStatus, 0)
    let contents = try String(contentsOf: log, encoding: .utf8)
    XCTAssertFalse(contents.contains(token))
    let records = try contents.split(separator: "\n").map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    XCTAssertTrue(records.contains { $0["event_type"] as? String == "driver.authenticated" })
    for (eventType, operation) in [
      ("driver.command.succeeded", operationID.rawValue),
      ("driver.command.failed", failedOperation.rawValue),
      ("runtime.configured", operationID.rawValue),
    ] {
      let record = try XCTUnwrap(records.first { $0["event_type"] as? String == eventType })
      XCTAssertEqual(record["operation_id"] as? String, operation)
    }
    XCTAssertTrue(records.contains { $0["event_type"] as? String == "driver.control_lost" })
    for record in records {
      XCTAssertEqual(
        Set(record.keys),
        Set([
          "timestamp", "level", "component", "vm_id", "operation_id", "driver_generation",
          "request_id", "event_type", "message",
        ]))
      XCTAssertEqual(record["vm_id"] as? String, vmID.rawValue)
      XCTAssertEqual(record["driver_generation"] as? Int, 7)
      XCTAssertTrue(record["request_id"] is NSNull)
    }
  }

  private func connect(to path: String) throws -> UnixSocket {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw DriverError.io("test socket creation failed") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      Darwin.close(descriptor)
      throw DriverError.io("test socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(descriptor)
      throw DriverError.io("test driver connection failed")
    }
    let connection = try UnixSocket(fd: descriptor)
    var deadline = timeval(tv_sec: 2, tv_usec: 0)
    guard
      Darwin.setsockopt(
        descriptor, SOL_SOCKET, SO_RCVTIMEO, &deadline,
        socklen_t(MemoryLayout.size(ofValue: deadline))) == 0
    else {
      connection.close()
      throw DriverError.io("test socket deadline failed")
    }
    return connection
  }

  private func write(
    _ message: DriverProtocolV2.Message, _ socket: UnixSocket, _ codec: DriverProtocolV2Codec
  ) throws {
    let payload = try codec.encode(message)
    var size = UInt32(payload.count).bigEndian
    var frame = Data(bytes: &size, count: 4)
    frame.append(payload)
    try socket.writeAll(frame)
  }

  private func read(_ socket: UnixSocket, _ codec: DriverProtocolV2Codec) throws
    -> DriverProtocolV2.Message
  {
    let header = try socket.readExact(4)
    let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard size > 0, size <= UInt32(LengthPrefixedJsonRpc.maxFrameSize) else {
      throw DriverError.protocolViolation("test driver returned an invalid frame size")
    }
    return try codec.decode(socket.readExact(Int(size)))
  }
}
