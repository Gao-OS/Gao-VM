import Darwin
import Foundation
import XCTest

@testable import vz_macos

final class DriverSessionLifetimeTests: XCTestCase {
  private let token = "test-only-driver-lifetime-authentication"

  func testGuestDevelopmentIsDisabledByDefault() throws {
    try withDriver(privateGeneration: true) { process, exited, control, _ in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let codec = DriverProtocolV2Codec()
      let hello = try authenticate(connection, codec)
      let correlation = DriverProtocolV2.Correlation(
        vmId: hello.vmId, driverGeneration: hello.driverGeneration, operationId: nil)
      let pingID = try DriverProtocolV2.JSONRPCID(string: "default-guest-disabled")
      try write(.commandRequest(pingID, .sessionPing(correlation)), connection, codec)
      guard case .commandSuccessResponse(let receivedID, _) = try read(connection, codec) else {
        return XCTFail("disabled Guest development must preserve generic driver commands")
      }
      XCTAssertEqual(receivedID, pingID)
      XCTAssertFalse(hello.offeredCapabilities.contains(.guestStatus))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: control.deletingLastPathComponent().appendingPathComponent("guest.sock").path))
      connection.close()
      XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
      XCTAssertEqual(process.terminationStatus, 0)
    }
  }

  func testGuestDevelopmentOptInOffersAnOptionalCapability() throws {
    try withDriver(privateGeneration: true, guestDevelopmentAcceptance: true) {
      process, exited, control, _ in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let hello = try authenticate(connection, DriverProtocolV2Codec())
      XCTAssertTrue(hello.offeredCapabilities.contains(.guestStatus))
      XCTAssertFalse(hello.requiredCapabilities.contains(.guestStatus))
      connection.close()
      XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
      XCTAssertEqual(process.terminationStatus, 0)
    }
  }

  func testGuestDevelopmentStatusDoesNotClaimUnconfiguredGuestReadiness() throws {
    try withDriver(privateGeneration: true, guestDevelopmentAcceptance: true) {
      process, exited, control, _ in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let codec = DriverProtocolV2Codec()
      let hello = try authenticate(connection, codec)
      let correlation = DriverProtocolV2.Correlation(
        vmId: hello.vmId, driverGeneration: hello.driverGeneration, operationId: nil)
      let id = try DriverProtocolV2.JSONRPCID(string: "development-guest-status")
      try write(.commandRequest(id, .guestStatus(correlation)), connection, codec)
      guard case .commandSuccessResponse(let receivedID, let result) = try read(connection, codec)
      else { return XCTFail("negotiated Guest development must implement guest.status") }
      XCTAssertEqual(receivedID, id)
      XCTAssertEqual(result.vmId, hello.vmId)
      XCTAssertEqual(result.driverGeneration, hello.driverGeneration)
      XCTAssertEqual(result.data?["bridge_protocol_version"], .string(GuestBridgeProtocol.version))
      XCTAssertEqual(result.data?["available"], .bool(false))
      XCTAssertEqual(result.data?["vsock_port"], .null)
      connection.close()
      XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
      XCTAssertEqual(process.terminationStatus, 0)
    }
  }

  func testV2ConsoleStatusIsOptionalAndReportsNoCaptureWithoutStartingAVm() throws {
    try withDriver { process, exited, control, _ in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let codec = DriverProtocolV2Codec()
      let hello = try authenticate(connection, codec)
      XCTAssertTrue(hello.offeredCapabilities.contains(.consoleStatus))
      XCTAssertFalse(hello.requiredCapabilities.contains(.consoleStatus))
      let correlation = DriverProtocolV2.Correlation(
        vmId: hello.vmId, driverGeneration: hello.driverGeneration, operationId: nil)
      for index in 0..<2 {
        let id = try DriverProtocolV2.JSONRPCID(string: "console-status-\(index)")
        try write(.commandRequest(id, .consoleStatus(correlation)), connection, codec)
        guard
          case .commandSuccessResponse(let receivedID, let snapshot) = try read(connection, codec)
        else { return XCTFail("negotiated console.status must return its capture snapshot") }
        XCTAssertEqual(receivedID, id)
        XCTAssertEqual(snapshot.vmId, hello.vmId)
        XCTAssertEqual(snapshot.driverGeneration, hello.driverGeneration)
        XCTAssertNil(snapshot.operationId)
        XCTAssertEqual(snapshot.data?["ready"], .bool(false))
        XCTAssertEqual(snapshot.data?["log_path"], .null)
      }
      let id = try DriverProtocolV2.JSONRPCID(string: "console-status-ping")
      try write(.commandRequest(id, .sessionPing(correlation)), connection, codec)
      guard case .commandSuccessResponse(let receivedID, _) = try read(connection, codec)
      else { return XCTFail("console status must not stop the driver") }
      XCTAssertEqual(receivedID, id)
      connection.close()
      XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
      XCTAssertEqual(process.terminationStatus, 0)
    }
  }

  func testV2DisplayCommandsReportHeadlessStateAndDoNotStopTheDriver() throws {
    try withDriver { process, exited, control, _ in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let codec = DriverProtocolV2Codec()
      let hello = try authenticate(connection, codec)
      for capability in [DriverProtocolV2.Capability.displayOpen, .displayClose, .displayStatus] {
        XCTAssertTrue(hello.offeredCapabilities.contains(capability))
        XCTAssertFalse(hello.requiredCapabilities.contains(capability))
      }
      let correlation = DriverProtocolV2.Correlation(
        vmId: hello.vmId, driverGeneration: hello.driverGeneration, operationId: nil)
      let statusID = try DriverProtocolV2.JSONRPCID(string: "display-snapshot")
      try write(.commandRequest(statusID, .displayStatus(correlation)), connection, codec)
      guard case .commandSuccessResponse(let receivedID, let snapshot) = try read(connection, codec)
      else {
        return XCTFail("authenticated display.status did not return a closed snapshot")
      }
      XCTAssertEqual(receivedID, statusID)
      XCTAssertEqual(snapshot.data?["display_state"], .string("closed"))
      XCTAssertNil(snapshot.operationId)

      let operationID = try DriverProtocolV2.OperationID("op_01J00000000000000000000002")
      for index in 0..<2 {
        let closeID = try DriverProtocolV2.JSONRPCID(string: "display-close-\(index)")
        try write(
          .commandRequest(
            closeID,
            .displayClose(
              .init(
                vmId: hello.vmId, driverGeneration: hello.driverGeneration, operationId: operationID
              ))),
          connection, codec)
        guard case .commandSuccessResponse(let receivedID, let result) = try read(connection, codec)
        else {
          return XCTFail("repeated display.close must succeed without stopping the VM or driver")
        }
        XCTAssertEqual(receivedID, closeID)
        XCTAssertEqual(result.operationId, operationID)
        XCTAssertEqual(result.data?["display_state"], .string("closed"))
      }
      let openID = try DriverProtocolV2.JSONRPCID(string: "display-open-without-vm")
      try write(
        .commandRequest(
          openID,
          .displayOpen(
            .init(
              vmId: hello.vmId, driverGeneration: hello.driverGeneration, operationId: operationID,
              display: .init(activate: false)))), connection, codec)
      guard case .errorResponse(let failedID, let error) = try read(connection, codec) else {
        return XCTFail("display.open must not create an unconfigured VM")
      }
      XCTAssertEqual(failedID, openID)
      XCTAssertEqual(error.data.code, .invalidRuntimeState)
      XCTAssertEqual(error.data.operationId, operationID)
      let pingID = try DriverProtocolV2.JSONRPCID(string: "after-display-ping")
      try write(.commandRequest(pingID, .sessionPing(correlation)), connection, codec)
      guard case .commandSuccessResponse(let pongID, _) = try read(connection, codec) else {
        return XCTFail("closing display terminated or blocked the driver session")
      }
      XCTAssertEqual(pongID, pingID)
      connection.close()
      XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
      XCTAssertEqual(process.terminationStatus, 0)
    }
  }

  func testRuntimeOnlyPeerCanAuthenticateButCannotUseOptionalPeripheralCommands() throws {
    try withDriver(privateGeneration: true, guestDevelopmentAcceptance: true) {
      process, exited, control, _ in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let codec = DriverProtocolV2Codec()
      let core: [DriverProtocolV2.Capability] = [
        .runtimeConfigure, .runtimeStart, .runtimeStop, .runtimeKill, .runtimeStatus,
      ]
      let hello = try authenticate(connection, codec, offered: core)
      let correlation = DriverProtocolV2.Correlation(
        vmId: hello.vmId, driverGeneration: hello.driverGeneration, operationId: nil)
      let peripheralCommands: [DriverProtocolV2.Command] = [
        .displayStatus(correlation), .consoleStatus(correlation), .guestStatus(correlation),
      ]
      for (index, command) in peripheralCommands.enumerated() {
        let deniedID = try DriverProtocolV2.JSONRPCID(string: "unnegotiated-peripheral-\(index)")
        try write(.commandRequest(deniedID, command), connection, codec)
        guard case .errorResponse(let receivedID, let error) = try read(connection, codec) else {
          return XCTFail("a runtime-only peer must not use an unnegotiated capability")
        }
        XCTAssertEqual(receivedID, deniedID)
        XCTAssertEqual(error.data.code, .capabilityNotNegotiated)
      }
      let statusID = try DriverProtocolV2.JSONRPCID(string: "core-runtime-status")
      try write(.commandRequest(statusID, .runtimeStatus(correlation)), connection, codec)
      guard case .commandSuccessResponse(let receivedID, let status) = try read(connection, codec)
      else {
        return XCTFail("optional peripheral support broke runtime-core compatibility")
      }
      XCTAssertEqual(receivedID, statusID)
      XCTAssertEqual(status.data?["state"], .string("not_created"))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: control.deletingLastPathComponent().appendingPathComponent("guest.sock").path))
      connection.close()
      XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
      XCTAssertEqual(process.terminationStatus, 0)
    }
  }

  func testInconsistentOptionalCapabilitiesBetweenHelloDirectionsFailClosed() throws {
    for peerHelloFirst in [false, true] {
      try withDriver(privateGeneration: true, guestDevelopmentAcceptance: true) {
        process, exited, control, _ in
        let connection = try connect(to: control.path)
        defer { connection.close() }
        let codec = DriverProtocolV2Codec()
        guard case .helloRequest(let id, let hello) = try read(connection, codec) else {
          return XCTFail("expected driver hello")
        }
        let acknowledgement = DriverProtocolV2.Message.helloSuccessResponse(
          id,
          .init(
            protocolVersion: DriverProtocolV2.version, vmId: hello.vmId,
            driverGeneration: hello.driverGeneration, operationId: nil,
            acceptedCapabilities: hello.offeredCapabilities))
        let request = DriverProtocolV2.Message.helloRequest(
          try .init(string: "inconsistent-daemon-hello"),
          .init(
            protocolVersion: DriverProtocolV2.version, peerRole: .daemon, vmId: hello.vmId,
            driverGeneration: hello.driverGeneration, operationId: nil, authToken: token,
            offeredCapabilities: hello.requiredCapabilities,
            requiredCapabilities: hello.requiredCapabilities, implementation: nil))
        if peerHelloFirst {
          try write(request, connection, codec)
          guard case .helloSuccessResponse = try read(connection, codec) else {
            return XCTFail("expected one-sided core negotiation")
          }
          try write(acknowledgement, connection, codec)
        } else {
          try write(acknowledgement, connection, codec)
          try write(request, connection, codec)
        }
        XCTAssertThrowsError(try read(connection, codec))
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertFalse(
          FileManager.default.fileExists(
            atPath: control.deletingLastPathComponent().appendingPathComponent("guest.sock").path))
      }
    }
  }

  func testGuestBridgeOpeningsCannotRefreshTheOriginalAuthenticationWatchdog() throws {
    try withDriver(privateGeneration: true, guestDevelopmentAcceptance: true) {
      process, exited, control, log in
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let hello = try authenticate(connection, DriverProtocolV2Codec())
      let guestPath = control.deletingLastPathComponent().appendingPathComponent("guest.sock").path
      let correlation = try GuestBridgeProtocol.Correlation(
        vmId: hello.vmId.rawValue, driverGeneration: hello.driverGeneration,
        requestId: "req_01J00000000000000000000002", operationId: nil, streamKind: .control)
      for _ in 0..<3 {
        guard exited.wait(timeout: .now() + 4) == .timedOut else {
          return XCTFail("driver exited before its original authenticated RPC budget")
        }
        let guest = try connect(to: guestPath)
        defer { guest.close() }
        try guest.writeAll(GuestBridgeFrameIO.encode(.open(correlation, authToken: token)))
        XCTAssertEqual(
          try GuestBridgeFrameIO.readResponse(
            from: guest, expecting: correlation, deadline: .now() + 1),
          .error(correlation, .unavailable))
      }
      try assertTimeoutExit(process, exited, control, log, timeout: 6)
      XCTAssertFalse(FileManager.default.fileExists(atPath: guestPath))
    }
  }

  func testGuestBridgeRequiresMutualHelloAndClosesWithOriginalControlSession() throws {
    try withDriver(privateGeneration: true, guestDevelopmentAcceptance: true) {
      process, exited, control, _ in
      let guestPath = control.deletingLastPathComponent().appendingPathComponent("guest.sock").path
      XCTAssertFalse(FileManager.default.fileExists(atPath: guestPath))
      let connection = try connect(to: control.path)
      defer { connection.close() }
      let codec = DriverProtocolV2Codec()
      guard case .helloRequest(let id, let hello) = try read(connection, codec) else {
        return XCTFail("expected driver hello")
      }
      XCTAssertTrue(hello.offeredCapabilities.contains(.guestStatus))
      try write(
        .helloSuccessResponse(
          id,
          .init(
            protocolVersion: DriverProtocolV2.version, vmId: hello.vmId,
            driverGeneration: hello.driverGeneration, operationId: nil,
            acceptedCapabilities: hello.offeredCapabilities)), connection, codec)
      let pingID = try DriverProtocolV2.JSONRPCID(string: "one-sided-ping")
      let ping = DriverProtocolV2.Command.sessionPing(
        .init(vmId: hello.vmId, driverGeneration: hello.driverGeneration, operationId: nil))
      try write(.commandRequest(pingID, ping), connection, codec)
      guard case .errorResponse(let deniedID, _) = try read(connection, codec) else {
        return XCTFail("one-sided hello must not authenticate the original session")
      }
      XCTAssertEqual(deniedID, pingID)
      XCTAssertFalse(FileManager.default.fileExists(atPath: guestPath))
      let helloID = try DriverProtocolV2.JSONRPCID(string: "original-daemon-hello")
      try write(
        .helloRequest(
          helloID,
          .init(
            protocolVersion: DriverProtocolV2.version, peerRole: .daemon, vmId: hello.vmId,
            driverGeneration: hello.driverGeneration, operationId: nil, authToken: token,
            offeredCapabilities: hello.offeredCapabilities,
            requiredCapabilities: hello.requiredCapabilities, implementation: nil)), connection,
        codec)
      guard case .helloSuccessResponse(let acceptedID, _) = try read(connection, codec) else {
        return XCTFail("expected authenticated daemon hello response")
      }
      XCTAssertEqual(acceptedID, helloID)
      let published = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: guestPath) },
        object: nil)
      guard XCTWaiter.wait(for: [published], timeout: 2) == .completed else {
        return XCTFail("authenticated driver did not publish its owned guest bridge")
      }
      for (generation, credential) in [
        (hello.driverGeneration, "wrong-" + token), (hello.driverGeneration + 1, token),
      ] {
        let rejected = try connect(to: guestPath)
        defer { rejected.close() }
        let stale = try GuestBridgeProtocol.Correlation(
          vmId: hello.vmId.rawValue, driverGeneration: generation,
          requestId: "req_01J00000000000000000000001", operationId: nil, streamKind: .control)
        try rejected.writeAll(GuestBridgeFrameIO.encode(.open(stale, authToken: credential)))
        XCTAssertThrowsError(
          try GuestBridgeFrameIO.readResponse(
            from: rejected, expecting: stale, deadline: .now() + 1))
      }
      let guest = try connect(to: guestPath)
      defer { guest.close() }
      let correlation = try GuestBridgeProtocol.Correlation(
        vmId: hello.vmId.rawValue, driverGeneration: hello.driverGeneration,
        requestId: "req_01J00000000000000000000001", operationId: nil, streamKind: .control)
      try guest.writeAll(GuestBridgeFrameIO.encode(.open(correlation, authToken: token)))
      XCTAssertEqual(
        try GuestBridgeFrameIO.readResponse(
          from: guest, expecting: correlation, deadline: .now() + 2),
        .error(correlation, .unavailable))
      let partial = try connect(to: guestPath)
      defer { partial.close() }
      try partial.writeAll(Data([0]))
      try write(.commandRequest(pingID, ping), connection, codec)
      guard case .commandSuccessResponse(let receivedID, _) = try read(connection, codec) else {
        return XCTFail("pending guest opening blocked the original heartbeat session")
      }
      XCTAssertEqual(receivedID, pingID)
      connection.close()
      guard exited.wait(timeout: .now() + 5) == .success else {
        return XCTFail("original control EOF did not terminate the driver")
      }
      XCTAssertEqual(process.terminationStatus, 0)
      XCTAssertFalse(FileManager.default.fileExists(atPath: guestPath))
      XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
      XCTAssertThrowsError(try partial.readExact(1, deadline: .now() + 1))
    }
  }

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

  private func withDriver(
    privateGeneration: Bool = false, guestDevelopmentAcceptance: Bool = false,
    _ body: (Process, DispatchGroup, URL, URL) throws -> Void
  ) throws {
    var template = Array("/private/tmp/gvl.XXXXXX".utf8CString)
    guard let directory = Darwin.mkdtemp(&template) else {
      throw DriverError.io("could not create private driver fixture")
    }
    let root = URL(fileURLWithPath: String(cString: directory))
    let generation = root.appendingPathComponent("vm_01J00000000000000000000000/7")
    if privateGeneration {
      try FileManager.default.createDirectory(
        at: generation, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard Darwin.chmod(generation.deletingLastPathComponent().path, 0o700) == 0 else {
        throw DriverError.io("could not protect private VM fixture")
      }
    }
    let control =
      privateGeneration
      ? generation.appendingPathComponent("driver.sock")
      : root.appendingPathComponent("control.sock")
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
    if guestDevelopmentAcceptance {
      process.arguments! += ["--guest-development-acceptance", "true"]
    }
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

  private func authenticate(
    _ socket: UnixSocket, _ codec: DriverProtocolV2Codec,
    offered: [DriverProtocolV2.Capability]? = nil
  ) throws
    -> DriverProtocolV2.Hello
  {
    guard case .helloRequest(let id, let hello) = try read(socket, codec) else {
      throw DriverError.protocolViolation("expected driver hello")
    }
    let capabilities = offered ?? hello.offeredCapabilities
    try write(
      .helloSuccessResponse(
        id,
        .init(
          protocolVersion: DriverProtocolV2.version, vmId: hello.vmId,
          driverGeneration: hello.driverGeneration, operationId: nil,
          acceptedCapabilities: capabilities)), socket, codec)
    let helloID = try DriverProtocolV2.JSONRPCID(string: "daemon-hello")
    try write(
      .helloRequest(
        helloID,
        .init(
          protocolVersion: DriverProtocolV2.version, peerRole: .daemon, vmId: hello.vmId,
          driverGeneration: hello.driverGeneration, operationId: nil, authToken: token,
          offeredCapabilities: capabilities,
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
