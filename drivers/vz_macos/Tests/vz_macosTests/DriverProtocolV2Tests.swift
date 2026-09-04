import Foundation
import XCTest

@testable import vz_macos

final class DriverProtocolV2Tests: XCTestCase {
  private let codec = DriverProtocolV2Codec()
  private let vmID = "vm_01J00000000000000000000000"
  private let operationID = "op_01J00000000000000000000001"

  func testDecodesGoldenDaemonHelloRequest() throws {
    let data = Data(
      #"""
      {
        "jsonrpc": "2.0",
        "id": "hello-daemon-1",
        "method": "session.hello",
        "params": {
          "protocol_version": "gaovm.driver.v2",
          "peer_role": "daemon",
          "vm_id": "vm_01J00000000000000000000000",
          "driver_generation": 8,
          "operation_id": null,
          "auth_token": "0123456789abcdef0123456789abcdef",
          "offered_capabilities": ["runtime.configure", "runtime.start", "runtime.stop"],
          "required_capabilities": ["runtime.configure", "runtime.start", "runtime.stop"]
        }
      }
      """#.utf8)

    let message = try codec.decode(data)

    guard case .helloRequest(let id, let hello) = message else {
      return XCTFail("expected a session.hello request")
    }
    XCTAssertEqual(id, try DriverProtocolV2.JSONRPCID(string: "hello-daemon-1"))
    XCTAssertEqual(hello.protocolVersion, DriverProtocolV2.version)
    XCTAssertEqual(hello.peerRole, .daemon)
    XCTAssertEqual(hello.vmID.rawValue, "vm_01J00000000000000000000000")
    XCTAssertEqual(hello.driverGeneration, 8)
    XCTAssertNil(hello.operationID)
    XCTAssertEqual(hello.requiredCapabilities, [.runtimeConfigure, .runtimeStart, .runtimeStop])
  }

  func testDecodesGoldenRuntimeStartRequestWithCorrelation() throws {
    let data = Data(
      #"""
      {
        "jsonrpc": "2.0",
        "id": "start-1",
        "method": "runtime.start",
        "params": {
          "vm_id": "vm_01J00000000000000000000000",
          "driver_generation": 8,
          "operation_id": "op_01J00000000000000000000001"
        }
      }
      """#.utf8)

    let message = try codec.decode(data)

    guard case .commandRequest(let id, let command) = message,
      case .runtimeStart(let correlation) = command
    else {
      return XCTFail("expected a runtime.start request")
    }
    XCTAssertEqual(id, try DriverProtocolV2.JSONRPCID(string: "start-1"))
    XCTAssertEqual(correlation.vmID.rawValue, "vm_01J00000000000000000000000")
    XCTAssertEqual(correlation.driverGeneration, 8)
    XCTAssertEqual(correlation.operationID.rawValue, "op_01J00000000000000000000001")
  }

  func testDecodesAllCommandFamiliesIncludingRuntimeConfiguration() throws {
    let query = #"{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":null}"#
    let operation = #"{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":"\#(operationID)"}"#
    let commands: [(String, String)] = [
      ("session.ping", query),
      ("runtime.configure", configureParameters),
      ("runtime.start", operation),
      (
        "runtime.stop",
        operation.dropLast() + #", "grace_period_seconds":10.5,"force_after_timeout":true}"#
      ),
      ("runtime.kill", operation),
      ("runtime.status", query),
      ("display.open", operation.dropLast() + #", "display":{"activate":true}}"#),
      ("display.close", operation),
      ("display.status", query),
      ("console.status", query),
      ("guest.status", query),
    ]

    for (method, params) in commands {
      let message = try codec.decode(request(method: method, params: String(params)))
      guard case .commandRequest(_, let command) = message else {
        return XCTFail("expected command for \(method)")
      }
      XCTAssertEqual(commandMethod(command), method)
      XCTAssertEqual(try codec.decode(codec.encode(message)), message)
    }
  }

  func testDecodesAllDriverEventFamiliesAndRoundTrips() throws {
    let base =
      #""vm_id":"\#(vmID)","driver_generation":8,"operation_id":"\#(operationID)","occurred_at":"2026-09-04T08:10:00Z""#
    let events: [(String, String)] = [
      ("runtime.state_changed", "{\(base),\"runtime_state\":\"running\"}"),
      ("runtime.clean_shutdown", "{\(base),\"clean_shutdown\":true}"),
      (
        "runtime.error",
        "{\(base),\"error\":{\"code\":\"RUNTIME_START_FAILED\",\"message\":\"boot failed\",\"retryable\":true}}"
      ),
      ("display.state_changed", "{\(base),\"display_state\":\"open\"}"),
      ("console.ready", "{\(base),\"console\":{\"ready\":true,\"log_path\":\"/tmp/serial.log\"}}"),
      ("guest.channel_ready", "{\(base),\"guest\":{\"ready\":true,\"vsock_port\":1024}}"),
      (
        "driver.warning",
        "{\(base),\"warning\":{\"code\":\"DISPLAY_DEGRADED\",\"message\":\"fallback\",\"details\":{\"attempt\":1}}}"
      ),
    ]

    for (method, params) in events {
      let data = Data("{\"jsonrpc\":\"2.0\",\"method\":\"\(method)\",\"params\":\(params)}".utf8)
      let message = try codec.decode(data)
      guard case .event(let event) = message else { return XCTFail("expected event for \(method)") }
      XCTAssertEqual(eventMethod(event), method)
      XCTAssertEqual(try codec.decode(codec.encode(message)), message)
    }
  }

  func testDecodesHelloCommandAndErrorResponses() throws {
    let messages = [
      #"{"jsonrpc":"2.0","id":"hello-1","result":{"protocol_version":"gaovm.driver.v2","vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"accepted_capabilities":["runtime.start","runtime.stop"]}}"#,
      #"{"jsonrpc":"2.0","id":2,"result":{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":"\#(operationID)","status":"succeeded","data":{"runtime_state":"running"}}}"#,
      #"{"jsonrpc":"2.0","id":null,"error":{"code":-32010,"message":"capability mismatch","data":{"code":"CAPABILITY_MISMATCH","vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"retryable":false,"details":{"missing":"runtime.start"}}}}"#,
    ]

    for json in messages {
      let message = try codec.decode(Data(json.utf8))
      XCTAssertEqual(try codec.decode(codec.encode(message)), message)
    }

    guard case .helloSuccessResponse = try codec.decode(Data(messages[0].utf8)),
      case .commandSuccessResponse = try codec.decode(Data(messages[1].utf8)),
      case .errorResponse(nil, let error) = try codec.decode(Data(messages[2].utf8))
    else {
      return XCTFail("response family was decoded incorrectly")
    }
    XCTAssertEqual(error.data.code, .capabilityMismatch)
  }

  func testNegotiatesBidirectionalHelloCapabilities() throws {
    let daemon = try hello(
      peerRole: "daemon", offered: ["runtime.start", "runtime.stop"], required: ["runtime.start"])
    let driver = try hello(
      peerRole: "driver", offered: ["runtime.start", "runtime.status"], required: ["runtime.start"])

    XCTAssertEqual(
      try DriverProtocolV2.negotiateCapabilities(local: daemon, remote: driver), [.runtimeStart])

    let incompatible = try hello(peerRole: "driver", offered: ["runtime.status"], required: [])
    XCTAssertThrowsError(
      try DriverProtocolV2.negotiateCapabilities(local: daemon, remote: incompatible))
  }

  func testRejectsBatchAndTopLevelNonObject() {
    XCTAssertThrowsError(try codec.decode(Data("[]".utf8))) { error in
      XCTAssertEqual(error as? DriverProtocolV2CodecError, .batchNotSupported)
    }
    for json in ["null", "true", "1", "\"message\""] {
      XCTAssertThrowsError(try codec.decode(Data(json.utf8))) { error in
        XCTAssertEqual(error as? DriverProtocolV2CodecError, .topLevelMustBeObject)
      }
    }
  }

  func testRejectsMessagesOutsideAcceptedV2Schema() {
    let validStart = String(
      decoding: request(
        method: "runtime.start",
        params: #"{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":"\#(operationID)"}"#
      ), as: UTF8.self)
    let invalidMessages = [
      validStart.replacingOccurrences(of: #""jsonrpc":"2.0""#, with: #""jsonrpc":"1.0""#),
      validStart.replacingOccurrences(of: vmID, with: "vm_default"),
      validStart.replacingOccurrences(of: operationID, with: "op_invalid"),
      validStart.replacingOccurrences(
        of: #""driver_generation":8"#, with: #""driver_generation":0"#),
      String(validStart.dropLast()) + ",\"extra\":true}",
      #"{"jsonrpc":"2.0","id":"x","method":"runtime.start","params":{"vm_id":"\#(vmID)","driver_generation":8}}"#,
      #"{"jsonrpc":"2.0","id":"x","method":"runtime.unknown","params":{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":null}}"#,
      #"{"jsonrpc":"2.0","id":"x","method":"session.hello","params":{"protocol_version":"gaovm.driver.v1","peer_role":"daemon","vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"auth_token":"0123456789abcdef0123456789abcdef","offered_capabilities":[],"required_capabilities":[]}}"#,
      #"{"jsonrpc":"2.0","id":"x","method":"session.hello","params":{"protocol_version":"gaovm.driver.v2","peer_role":"daemon","vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"auth_token":"short","offered_capabilities":["runtime.start"],"required_capabilities":[]}}"#,
      #"{"jsonrpc":"2.0","id":"x","method":"session.hello","params":{"protocol_version":"gaovm.driver.v2","peer_role":"daemon","vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"auth_token":"0123456789abcdef0123456789abcdef","offered_capabilities":["runtime.start","runtime.start"],"required_capabilities":[]}}"#,
      #"{"jsonrpc":"2.0","method":"runtime.state_changed","params":{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"occurred_at":"2026-09-04T08:10:00Z"}}"#,
    ]

    for json in invalidMessages {
      XCTAssertThrowsError(try codec.decode(Data(json.utf8)), "accepted invalid message: \(json)")
    }
  }

  func testV2ContractDoesNotSwitchLiveV12Adapter() {
    XCTAssertEqual(DriverProtocolV2.version, "gaovm.driver.v2")
    XCTAssertEqual(DriverProtocol.protocolVersion, "gaovm.v1.2")
  }

  func testConstructsOnlyCanonicalResourceAndJSONRPCIDs() throws {
    XCTAssertNoThrow(try DriverProtocolV2.VMID("vm_7ZZZZZZZZZZZZZZZZZZZZZZZZZ"))
    XCTAssertThrowsError(try DriverProtocolV2.VMID("vm_8ZZZZZZZZZZZZZZZZZZZZZZZZZ"))
    XCTAssertNoThrow(try DriverProtocolV2.OperationID("op_0ZZZZZZZZZZZZZZZZZZZZZZZZZ"))
    XCTAssertThrowsError(try DriverProtocolV2.OperationID("op_AZZZZZZZZZZZZZZZZZZZZZZZZZ"))

    XCTAssertEqual(try DriverProtocolV2.JSONRPCID(integer: 0).integerValue, 0)
    XCTAssertEqual(
      try DriverProtocolV2.JSONRPCID(integer: 9_007_199_254_740_991).integerValue,
      9_007_199_254_740_991)
    XCTAssertThrowsError(try DriverProtocolV2.JSONRPCID(integer: -1))
    XCTAssertThrowsError(try DriverProtocolV2.JSONRPCID(integer: 9_007_199_254_740_992))
    XCTAssertEqual(try DriverProtocolV2.JSONRPCID(string: "request-1").stringValue, "request-1")
    XCTAssertThrowsError(try DriverProtocolV2.JSONRPCID(string: ""))
    let tooManyCodePoints = String(repeating: "e\u{301}", count: 65)
    XCTAssertThrowsError(try DriverProtocolV2.JSONRPCID(string: tooManyCodePoints))
    XCTAssertThrowsError(
      try codec.decode(
        requestWithRawID(
          "\"\(tooManyCodePoints)\"", method: "runtime.status",
          params: #"{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":null}"#)))
  }

  func testDistinguishesNullableFromOptionalNonNullableKeys() throws {
    let operation = #"{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":"\#(operationID)"}"#
    let cleanEventBase =
      #"{"jsonrpc":"2.0","method":"runtime.clean_shutdown","params":{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"occurred_at":"2026-09-04T08:10:00Z""#
    let configuration = String(
      decoding: request(method: "runtime.configure", params: configureParameters), as: UTF8.self)
    let invalidMessages = [
      String(
        decoding: request(
          method: "runtime.stop", params: operation.dropLast() + #", "grace_period_seconds":null}"#),
        as: UTF8.self),
      String(
        decoding: request(
          method: "runtime.stop", params: operation.dropLast() + #", "force_after_timeout":null}"#),
        as: UTF8.self),
      String(
        decoding: request(
          method: "display.open", params: operation.dropLast() + #", "display":null}"#),
        as: UTF8.self),
      String(
        decoding: request(
          method: "display.open", params: operation.dropLast() + #", "display":{"activate":null}}"#),
        as: UTF8.self),
      configuration.replacingOccurrences(
        of: #""mode":"shared","mac_address":"02:00:00:00:00:01""#,
        with: #""mode":"none","mac_address":null"#),
      configuration.replacingOccurrences(
        of: #""graphics":{"enabled":true,"width":1280,"height":800,"pixels_per_inch":144}"#,
        with: #""graphics":{"enabled":false,"width":null}"#),
      configuration.replacingOccurrences(
        of: #""graphics":{"enabled":true,"width":1280,"height":800,"pixels_per_inch":144}"#,
        with: #""graphics":{"enabled":false,"height":null}"#),
      configuration.replacingOccurrences(
        of: #""graphics":{"enabled":true,"width":1280,"height":800,"pixels_per_inch":144}"#,
        with: #""graphics":{"enabled":false,"pixels_per_inch":null}"#),
      cleanEventBase + #", "runtime_state":null}}"#,
      cleanEventBase + #", "clean_shutdown":null}}"#,
      cleanEventBase + #", "display_state":null}}"#,
      cleanEventBase + #", "error":null}}"#,
      cleanEventBase + #", "console":null}}"#,
      cleanEventBase + #", "guest":null}}"#,
      cleanEventBase + #", "warning":null}}"#,
      cleanEventBase + #", "guest":{"ready":false,"vsock_port":null}}}"#,
      cleanEventBase + #", "warning":{"code":"TEST_WARNING","message":"warning","details":null}}}"#,
      cleanEventBase
        + #", "error":{"code":"DRIVER_INTERNAL_ERROR","message":"error","retryable":false,"details":null}}}"#,
      #"{"jsonrpc":"2.0","id":"hello","method":"session.hello","params":{"protocol_version":"gaovm.driver.v2","peer_role":"daemon","vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"auth_token":"0123456789abcdef0123456789abcdef","offered_capabilities":[],"required_capabilities":[],"implementation":null}}"#,
      #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"error","data":{"code":"DRIVER_INTERNAL_ERROR","vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"retryable":false,"details":null}}}"#,
    ]

    for json in invalidMessages {
      XCTAssertThrowsError(try codec.decode(Data(json.utf8)), "accepted explicit null: \(json)")
    }

    XCTAssertNoThrow(
      try codec.decode(request(method: "runtime.configure", params: configureParameters)))
    XCTAssertNoThrow(
      try codec.decode(
        Data(
          #"{"jsonrpc":"2.0","id":1,"result":{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"status":"succeeded","data":null}}"#
            .utf8)))
  }

  func testEnforcesWireSafeIntegerBounds() throws {
    let maximumSafeInteger = 9_007_199_254_740_991
    let correlatedParams = { (generation: Int) in
      #"{"vm_id":"\#(self.vmID)","driver_generation":\#(generation),"operation_id":"\#(self.operationID)"}"#
    }
    XCTAssertNoThrow(
      try codec.decode(
        request(method: "runtime.start", params: correlatedParams(maximumSafeInteger))))
    XCTAssertThrowsError(
      try codec.decode(
        request(method: "runtime.start", params: correlatedParams(maximumSafeInteger + 1))))

    let guestEvent = { (port: UInt64) in
      Data(
        #"{"jsonrpc":"2.0","method":"guest.channel_ready","params":{"vm_id":"\#(self.vmID)","driver_generation":8,"operation_id":null,"occurred_at":"2026-09-04T08:10:00Z","guest":{"ready":true,"vsock_port":\#(port)}}}"#
          .utf8)
    }
    XCTAssertNoThrow(try codec.decode(guestEvent(4_294_967_295)))
    XCTAssertThrowsError(try codec.decode(guestEvent(4_294_967_296)))

    let runtimeConfiguration = String(
      decoding: request(method: "runtime.configure", params: configureParameters), as: UTF8.self)
    XCTAssertNoThrow(
      try codec.decode(
        Data(
          runtimeConfiguration.replacingOccurrences(
            of: #""vsock_port":1024"#, with: #""vsock_port":4294967295"#
          ).utf8)))
    XCTAssertThrowsError(
      try codec.decode(
        Data(
          runtimeConfiguration.replacingOccurrences(
            of: #""vsock_port":1024"#, with: #""vsock_port":4294967296"#
          ).utf8)))

    let errorResponse = { (code: Int64) in
      Data(
        #"{"jsonrpc":"2.0","id":null,"error":{"code":\#(code),"message":"error","data":{"code":"DRIVER_INTERNAL_ERROR","vm_id":"\#(self.vmID)","driver_generation":8,"operation_id":null,"retryable":false}}}"#
          .utf8)
    }
    XCTAssertNoThrow(try codec.decode(errorResponse(Int64(Int32.min))))
    XCTAssertNoThrow(try codec.decode(errorResponse(Int64(Int32.max))))
    XCTAssertThrowsError(try codec.decode(errorResponse(Int64(Int32.min) - 1)))
    XCTAssertThrowsError(try codec.decode(errorResponse(Int64(Int32.max) + 1)))

    XCTAssertThrowsError(
      try codec.decode(
        requestWithRawID(
          "-1", method: "runtime.start",
          params: #"{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":"\#(operationID)"}"#
        )))
    XCTAssertThrowsError(
      try codec.decode(
        requestWithRawID(
          "9007199254740992", method: "runtime.start",
          params: #"{"vm_id":"\#(vmID)","driver_generation":8,"operation_id":"\#(operationID)"}"#
        )))
  }

  func testEnforcesWireSafeMemoryUpperBound() {
    let configuration = String(
      decoding: request(method: "runtime.configure", params: configureParameters), as: UTF8.self)
    let withMemory = { (memory: UInt64) in
      Data(
        configuration.replacingOccurrences(
          of: #""memory_bytes":536870912"#, with: #""memory_bytes":\#(memory)"#
        ).utf8)
    }

    XCTAssertNoThrow(try codec.decode(withMemory(9_007_199_254_740_992)))
    XCTAssertThrowsError(try codec.decode(withMemory(9_007_199_255_789_568)))
    XCTAssertThrowsError(try codec.decode(withMemory(9_007_199_254_740_991)))
  }

  func testMeasuresSchemaStringLengthsInUnicodeCodePoints() {
    let scalarPair = "e\u{301}"
    let hello = { (authToken: String, name: String, version: String) in
      Data(
        #"{"jsonrpc":"2.0","id":"hello","method":"session.hello","params":{"protocol_version":"gaovm.driver.v2","peer_role":"daemon","vm_id":"\#(self.vmID)","driver_generation":8,"operation_id":null,"auth_token":"\#(authToken)","offered_capabilities":[],"required_capabilities":[],"implementation":{"name":"\#(name)","version":"\#(version)"}}}"#
          .utf8)
    }

    XCTAssertNoThrow(
      try codec.decode(
        hello(
          String(repeating: scalarPair, count: 16),
          String(repeating: scalarPair, count: 64),
          String(repeating: scalarPair, count: 64))))
    XCTAssertThrowsError(
      try codec.decode(
        hello(
          String(repeating: scalarPair, count: 513),
          "driver",
          "1.0")))
    XCTAssertThrowsError(
      try codec.decode(
        hello(
          "0123456789abcdef0123456789abcdef",
          String(repeating: scalarPair, count: 65),
          "1.0")))
    XCTAssertThrowsError(
      try codec.decode(
        hello(
          "0123456789abcdef0123456789abcdef",
          "driver",
          String(repeating: scalarPair, count: 65))))

    let configuration = String(
      decoding: request(method: "runtime.configure", params: configureParameters), as: UTF8.self)
    let withCommandLine = { (value: String) in
      Data(
        configuration.replacingOccurrences(
          of: #""command_line":"console=hvc0""#, with: #""command_line":"\#(value)""#
        ).utf8)
    }
    XCTAssertNoThrow(
      try codec.decode(withCommandLine(String(repeating: scalarPair, count: 4_096))))
    XCTAssertThrowsError(
      try codec.decode(withCommandLine(String(repeating: scalarPair, count: 4_097))))
  }

  func testValidatesAndRoundTripsContractBoundOpaqueNumbers() throws {
    let response = { (data: String) in
      Data(
        #"{"jsonrpc":"2.0","id":1,"result":{"vm_id":"\#(self.vmID)","driver_generation":8,"operation_id":null,"status":"succeeded","data":\#(data)}}"#
          .utf8)
    }
    let validData =
      #"{"maximum":9007199254740991,"minimum":-9007199254740991,"precise_decimal":123456.123456789,"nested":{"values":[0.000000001,-0.000000001]}}"#
    let message = try codec.decode(response(validData))
    guard case .commandSuccessResponse(_, let result) = message else {
      return XCTFail("expected command success response")
    }
    let locale = Locale(identifier: "en_US_POSIX")
    XCTAssertEqual(result.data?["maximum"], .integer(9_007_199_254_740_991))
    XCTAssertEqual(result.data?["minimum"], .integer(-9_007_199_254_740_991))
    XCTAssertEqual(
      result.data?["precise_decimal"],
      .decimal(try XCTUnwrap(Decimal(string: "123456.123456789", locale: locale))))

    let encoded = try codec.encode(message)
    let encodedJSON = try XCTUnwrap(String(data: encoded, encoding: .utf8))
    XCTAssertTrue(encodedJSON.contains("9007199254740991"))
    XCTAssertTrue(encodedJSON.contains("123456.123456789"))
    XCTAssertEqual(try codec.decode(encoded), message)

    let invalidData = [
      #"{"out_of_range":9007199254740992}"#,
      #"{"out_of_range":-9007199254740992}"#,
      #"{"too_precise":0.1234567891}"#,
      #"{"nested":{"values":[{"reviewer_probe":12345678901234567890123456789012345678901234567890}]}}"#,
    ]
    for data in invalidData {
      XCTAssertThrowsError(try codec.decode(response(data)), "accepted opaque number: \(data)")
    }
  }

  func testValidatesRFC3339EventTimestamps() {
    let event = { (timestamp: String) in
      Data(
        #"{"jsonrpc":"2.0","method":"runtime.clean_shutdown","params":{"vm_id":"\#(self.vmID)","driver_generation":8,"operation_id":null,"occurred_at":"\#(timestamp)"}}"#
          .utf8)
    }

    for timestamp in [
      "2026-09-04T08:10:00Z",
      "2026-09-04t08:10:00z",
      "2026-09-04T08:10:00.123456+08:00",
      "2026-09-04T08:10:00-07:30",
      "0000-02-29T00:00:00Z",
    ] {
      XCTAssertNoThrow(try codec.decode(event(timestamp)), "rejected RFC 3339: \(timestamp)")
    }

    for timestamp in [
      "2026-09-04",
      "2026-09-04T08:10:00",
      "2026-09-04T24:00:00Z",
      "2026-09-04T23:59:60Z",
      "2026-02-29T08:10:00Z",
      "2026-09-04T08:10:00+24:00",
    ] {
      XCTAssertThrowsError(
        try codec.decode(event(timestamp)), "accepted invalid RFC 3339: \(timestamp)")
    }
  }

  func testEncodedOutputKeepsRequiredNullsAndEnforcesNumericBounds() throws {
    let vmID = try DriverProtocolV2.VMID(self.vmID)
    let id = try DriverProtocolV2.JSONRPCID(integer: 9_007_199_254_740_991)
    let message = DriverProtocolV2.Message.commandRequest(
      id,
      .runtimeStatus(
        .init(vmId: vmID, driverGeneration: 9_007_199_254_740_991, operationId: nil)))

    let encoded = try codec.encode(message)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual((object["id"] as? NSNumber)?.int64Value, 9_007_199_254_740_991)
    let params = try XCTUnwrap(object["params"] as? [String: Any])
    XCTAssertTrue(params["operation_id"] is NSNull)

    let invalidGeneration = DriverProtocolV2.Message.commandRequest(
      try DriverProtocolV2.JSONRPCID(string: "status"),
      .runtimeStatus(
        .init(vmId: vmID, driverGeneration: 9_007_199_254_740_992, operationId: nil)))
    XCTAssertThrowsError(try codec.encode(invalidGeneration))

    let errorData = DriverProtocolV2.RPCErrorData(
      code: .driverInternalError, vmId: vmID, driverGeneration: 1, operationId: nil,
      retryable: false, details: nil)
    let validError = DriverProtocolV2.Message.errorResponse(
      nil,
      .init(code: -32_603, message: "internal error", data: errorData))
    let encodedError = try codec.encode(validError)
    let errorObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encodedError) as? [String: Any])
    XCTAssertTrue(errorObject["id"] is NSNull)
    let wireError = try XCTUnwrap(errorObject["error"] as? [String: Any])
    let wireErrorData = try XCTUnwrap(wireError["data"] as? [String: Any])
    XCTAssertTrue(wireErrorData["operation_id"] is NSNull)

    let invalidError = DriverProtocolV2.Message.errorResponse(
      nil,
      .init(code: Int(Int32.max) + 1, message: "invalid code", data: errorData))
    XCTAssertThrowsError(try codec.encode(invalidError))
  }

  private var configureParameters: String {
    #"""
    {
      "vm_id":"\#(vmID)",
      "driver_generation":8,
      "operation_id":"\#(operationID)",
      "configuration":{
        "architecture":"arm64",
        "cpu":4,
        "memory_bytes":536870912,
        "boot":{"type":"linux_kernel","kernel_path":"/images/vmlinuz","initrd_path":null,"command_line":"console=hvc0"},
        "disks":[{"id":"root","path":"/vms/root.raw","writable":true}],
        "networks":[{"id":"eth0","mode":"shared","mac_address":"02:00:00:00:00:01"}],
        "graphics":{"enabled":true,"width":1280,"height":800,"pixels_per_inch":144},
        "serial":{"enabled":true,"capture":true,"log_path":"/logs/serial.log"},
        "guest_agent":{"enabled":true,"vsock_port":1024},
        "bundle_path":"/vms/example",
        "log_paths":{"driver":"/logs/driver.log","serial":"/logs/serial.log"}
      }
    }
    """#
  }

  private func request(method: String, params: String) -> Data {
    Data(
      "{\"jsonrpc\":\"2.0\",\"id\":\"request-1\",\"method\":\"\(method)\",\"params\":\(params)}"
        .utf8)
  }

  private func requestWithRawID(_ id: String, method: String, params: String) -> Data {
    Data(
      "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(params)}"
        .utf8)
  }

  private func commandMethod(_ command: DriverProtocolV2.Command) -> String {
    switch command {
    case .sessionPing: return "session.ping"
    case .runtimeConfigure: return "runtime.configure"
    case .runtimeStart: return "runtime.start"
    case .runtimeStop: return "runtime.stop"
    case .runtimeKill: return "runtime.kill"
    case .runtimeStatus: return "runtime.status"
    case .displayOpen: return "display.open"
    case .displayClose: return "display.close"
    case .displayStatus: return "display.status"
    case .consoleStatus: return "console.status"
    case .guestStatus: return "guest.status"
    }
  }

  private func eventMethod(_ event: DriverProtocolV2.Event) -> String {
    switch event {
    case .runtimeStateChanged: return "runtime.state_changed"
    case .runtimeCleanShutdown: return "runtime.clean_shutdown"
    case .runtimeError: return "runtime.error"
    case .displayStateChanged: return "display.state_changed"
    case .consoleReady: return "console.ready"
    case .guestChannelReady: return "guest.channel_ready"
    case .driverWarning: return "driver.warning"
    }
  }

  private func hello(peerRole: String, offered: [String], required: [String]) throws
    -> DriverProtocolV2.Hello
  {
    let encode: ([String]) -> String = { values in values.map { "\"\($0)\"" }.joined(separator: ",")
    }
    let json =
      #"{"jsonrpc":"2.0","id":"hello","method":"session.hello","params":{"protocol_version":"gaovm.driver.v2","peer_role":"\#(peerRole)","vm_id":"\#(vmID)","driver_generation":8,"operation_id":null,"auth_token":"0123456789abcdef0123456789abcdef","offered_capabilities":[\#(encode(offered))],"required_capabilities":[\#(encode(required))]}}"#
    guard case .helloRequest(_, let value) = try codec.decode(Data(json.utf8)) else {
      throw DriverProtocolV2CodecError.invalidMessage("expected hello")
    }
    return value
  }
}
