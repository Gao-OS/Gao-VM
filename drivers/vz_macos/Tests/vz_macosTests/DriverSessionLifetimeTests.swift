import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class DriverSessionLifetimeTests: XCTestCase {
  private let token = "test-only-driver-lifetime-authentication"

  func testDriverExitsWhenDaemonNeverConnects() throws {
    try withDriver { process, exited, control, log in
      try assertTimeoutExit(process, exited, control, log)
    }
  }

  func testPartialFrameHeaderCannotSuspendAuthenticationDeadline() throws {
    try withDriver { process, exited, control, log in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      try connection.writeAll(Data([0]))
      try assertTimeoutExit(process, exited, control, log)
    }
  }

  func testPartialFramePayloadCannotSuspendAuthenticationDeadline() throws {
    try withDriver { process, exited, control, log in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      // A complete length prefix, but only one of the 1024 promised bytes.
      try connection.writeAll(Data([0, 0, 4, 0, 0x7b]))
      try assertTimeoutExit(process, exited, control, log)
    }
  }

  func testLateConnectionDoesNotRestartAuthenticationBudget() throws {
    try withDriver { process, exited, control, log in
      guard exited.wait(timeout: .now() + 8) == .timedOut else {
        return XCTFail("driver exited before its authentication deadline")
      }
      let connection = try connect(to: control.path)
      defer { connection.close() }
      try assertTimeoutExit(process, exited, control, log, timeout: 10)
    }
  }

  func testHelloResultAloneCannotRefreshAuthenticationDeadline() throws {
    try withDriver { process, exited, control, log in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let codec = DriverProtocolV2Codec()
      guard case .helloRequest(let id, let hello) = try read(connection, codec) else {
        return XCTFail("expected driver hello")
      }
      guard exited.wait(timeout: .now() + 8) == .timedOut else {
        return XCTFail("driver exited before its authentication deadline")
      }
      // This is a valid response to the driver hello, but supplies no daemon
      // token and cannot complete the bidirectional authenticated handshake.
      try write(
        .helloSuccessResponse(
          id,
          .init(
            protocolVersion: DriverProtocolV2.version, vmId: hello.vmId,
            driverGeneration: hello.driverGeneration, operationId: nil,
            acceptedCapabilities: hello.offeredCapabilities)), connection, codec)
      try assertTimeoutExit(process, exited, control, log, timeout: 10)
    }
  }

  func testAuthenticatedPingRefreshesDeadlineAndEOFCleansUp() throws {
    try withDriver { process, exited, control, log in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let codec = DriverProtocolV2Codec()
      let hello = try authenticate(connection, codec)
      guard exited.wait(timeout: .now() + 8) == .timedOut else {
        return XCTFail("authenticated driver exited before its deadline")
      }
      let pingID = try DriverProtocolV2.JSONRPCID(string: "keepalive")
      try write(
        .commandRequest(
          pingID,
          .sessionPing(
            .init(vmId: hello.vmId, driverGeneration: hello.driverGeneration, operationId: nil))),
        connection, codec)
      guard case .commandSuccessResponse(let id, _) = try read(connection, codec) else {
        return XCTFail("expected authenticated ping response")
      }
      XCTAssertEqual(id, pingID)
      guard exited.wait(timeout: .now() + 8) == .timedOut else {
        return XCTFail("authenticated ping did not extend the initial deadline")
      }
      connection.close()
      guard exited.wait(timeout: .now() + 5) == .success else {
        return XCTFail("driver did not exit after authenticated control EOF")
      }
      XCTAssertEqual(process.terminationReason, .exit)
      XCTAssertEqual(process.terminationStatus, 0)
      XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
      let contents = try String(contentsOf: log, encoding: .utf8)
      XCTAssertTrue(contents.contains("control socket EOF"))
      XCTAssertFalse(contents.contains(token))
    }
  }

  func testConfiguredDriverTimesOutOnIncompleteAuthenticatedFrame() throws {
    try withDriver { process, exited, control, log in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let codec = DriverProtocolV2Codec()
      let hello = try authenticate(connection, codec)
      let operationID = try DriverProtocolV2.OperationID("op_01J00000000000000000000000")
      let configureID = try DriverProtocolV2.JSONRPCID(string: "configure")
      let root = control.deletingLastPathComponent()
      // Configure stores the normalized spec; no start command or VZ VM is used.
      let configuration = DriverProtocolV2.RuntimeConfiguration(
        architecture: "arm64", cpu: 2, memoryBytes: 1_073_741_824,
        boot: .linuxKernel(
          .init(
            type: "linux_kernel", kernelPath: "/unused/kernel", initrdPath: nil, commandLine: "")),
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
              vmId: hello.vmId, driverGeneration: hello.driverGeneration,
              operationId: operationID, configuration: configuration))), connection, codec)
      var responseReceived = false
      var eventReceived = false
      for _ in 0..<2 {
        switch try read(connection, codec) {
        case .commandSuccessResponse(let id, _):
          XCTAssertEqual(id, configureID)
          responseReceived = true
        case .event(.runtimeStateChanged): eventReceived = true
        default: XCTFail("unexpected configure response")
        }
      }
      XCTAssertTrue(responseReceived && eventReceived)
      try connection.writeAll(Data([0]))
      try assertTimeoutExit(process, exited, control, log)
    }
  }

  func testUnreadResponsesCannotSuspendAuthenticationDeadline() throws {
    try withDriver { process, exited, control, log in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let flags = Darwin.fcntl(connection.fd, F_GETFL)
      guard flags >= 0, Darwin.fcntl(connection.fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw DriverError.io("test could not enable nonblocking flood writes")
      }
      let codec = DriverProtocolV2Codec()
      let payload = try codec.encode(
        .commandRequest(
          .init(integer: 1),
          .sessionPing(
            .init(
              vmId: try .init("vm_01J00000000000000000000000"), driverGeneration: 7,
              operationId: nil))))
      var size = UInt32(payload.count).bigEndian
      var frame = Data(bytes: &size, count: 4)
      frame.append(payload)
      var flood = Data()
      for _ in 0..<10_000 { flood.append(frame) }
      var offset = 0
      var backpressureObserved = false
      let floodDeadline = DispatchTime.now() + 2
      while offset < flood.count,
        DispatchTime.now().uptimeNanoseconds < floodDeadline.uptimeNanoseconds
      {
        let sent = flood.withUnsafeBytes { buffer in
          Darwin.write(
            connection.fd, buffer.baseAddress!.advanced(by: offset), flood.count - offset)
        }
        if sent > 0 {
          offset += sent
          continue
        }
        if sent < 0, errno == EINTR { continue }
        guard sent < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
          throw DriverError.io("test flood failed before reaching socket backpressure")
        }
        backpressureObserved = true
        var writable = pollfd(fd: connection.fd, events: Int16(POLLOUT), revents: 0)
        _ = Darwin.poll(&writable, 1, 20)
      }
      XCTAssertGreaterThan(offset, frame.count)
      XCTAssertTrue(backpressureObserved, "probe did not reach real socket backpressure")
      // The frames are individual valid requests, not a JSON-RPC batch. They
      // have no authenticated hello; deliberately never drain their responses.
      try assertTimeoutExit(process, exited, control, log)
    }
  }

  private func withDriver(_ body: (Process, DispatchGroup, URL, URL) throws -> Void) throws {
    let root = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("gaovm-life-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let control = root.appendingPathComponent("control.sock")
    let log = root.appendingPathComponent("driver.log")
    let process = Process()
    let exited = DispatchGroup()
    exited.enter()
    process.terminationHandler = { _ in exited.leave() }
    process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("gaovm-driver-vz")
    process.arguments = [
      "--vm-id", "vm_01J00000000000000000000000", "--generation", "7",
      "--socket-path", control.path,
      "--bundle-path", root.appendingPathComponent("vm.gaovm").path, "--backend", "vz",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["GAOVM_AUTH_TOKEN"] = token
    environment["GAOVM_DRIVER_LOG_PATH"] = log.path
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    var launched = false
    defer {
      var exitConfirmed = !launched
      if launched {
        if process.isRunning { process.terminate() }
        exitConfirmed = exited.wait(timeout: .now() + 1) == .success
        if !exitConfirmed, process.isRunning {
          Darwin.kill(process.processIdentifier, SIGKILL)
          exitConfirmed = exited.wait(timeout: .now() + 2) == .success
        }
      }
      // A signal is not proof of exit. Retain fixtures if the child is live.
      if exitConfirmed {
        do {
          try FileManager.default.removeItem(at: root)
          XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        } catch {
          XCTFail("could not remove exited driver fixture: \(root.path)")
        }
      } else {
        XCTFail("retaining live driver fixture: \(root.path)")
      }
    }
    try process.run()
    launched = true
    let listening = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: control.path) },
      object: nil)
    guard XCTWaiter.wait(for: [listening], timeout: 5) == .completed else {
      return XCTFail("compiled driver did not publish its owned control socket")
    }
    try body(process, exited, control, log)
  }

  private func assertTimeoutExit(
    _ process: Process, _ exited: DispatchGroup, _ control: URL, _ log: URL,
    timeout: TimeInterval = 18
  ) throws {
    guard exited.wait(timeout: .now() + timeout) == .success else {
      return XCTFail("driver survived past its authentication deadline")
    }
    XCTAssertEqual(process.terminationReason, .exit)
    XCTAssertEqual(process.terminationStatus, 12)
    XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
    let contents = try String(contentsOf: log, encoding: .utf8)
    XCTAssertTrue(contents.contains("driver.control_lost"))
    XCTAssertTrue(contents.contains("no authenticated daemon RPC within 15 seconds"))
    XCTAssertFalse(contents.contains(token))
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
    return try UnixSocket(fd: descriptor)
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

  private func authenticate(_ socket: UnixSocket, _ codec: DriverProtocolV2Codec) throws
    -> DriverProtocolV2.Hello
  {
    guard case .helloRequest(let id, let hello) = try read(socket, codec) else {
      throw DriverError.protocolViolation("expected driver hello")
    }
    try write(
      .helloSuccessResponse(
        id,
        .init(
          protocolVersion: DriverProtocolV2.version, vmId: hello.vmId,
          driverGeneration: hello.driverGeneration, operationId: nil,
          acceptedCapabilities: hello.offeredCapabilities)), socket, codec)
    let helloID = try DriverProtocolV2.JSONRPCID(string: "daemon-hello")
    try write(
      .helloRequest(
        helloID,
        .init(
          protocolVersion: DriverProtocolV2.version, peerRole: .daemon, vmId: hello.vmId,
          driverGeneration: hello.driverGeneration, operationId: nil, authToken: token,
          offeredCapabilities: hello.offeredCapabilities,
          requiredCapabilities: hello.requiredCapabilities, implementation: nil)), socket, codec)
    guard case .helloSuccessResponse(let acceptedID, _) = try read(socket, codec),
      acceptedID == helloID
    else {
      throw DriverError.protocolViolation("expected authenticated daemon hello response")
    }
    return hello
  }

  private func read(_ socket: UnixSocket, _ codec: DriverProtocolV2Codec) throws
    -> DriverProtocolV2.Message
  {
    let deadline = DispatchTime.now() + 2
    let header = try socket.readExact(4, deadline: deadline)
    let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard size > 0, size <= UInt32(LengthPrefixedJsonRpc.maxFrameSize) else {
      throw DriverError.protocolViolation("test driver returned an invalid frame size")
    }
    return try codec.decode(socket.readExact(Int(size), deadline: deadline))
  }
}
