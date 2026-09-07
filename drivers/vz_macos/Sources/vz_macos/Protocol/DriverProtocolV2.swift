import Foundation

/// Typed representation of the live internal
/// `schemas/driver-protocol/v2.schema.json` contract.
enum DriverProtocolV2 {
  static let version = "gaovm.driver.v2"

  enum Message: Equatable {
    case helloRequest(JSONRPCID, Hello)
    case commandRequest(JSONRPCID, Command)
    case event(Event)
    case helloSuccessResponse(JSONRPCID, HelloResult)
    case commandSuccessResponse(JSONRPCID, CommandResult)
    case errorResponse(JSONRPCID?, RPCError)
  }

  struct JSONRPCID: Equatable, Codable {
    static let maximumInteger = 9_007_199_254_740_991

    private enum Storage: Equatable {
      case integer(Int)
      case string(String)
    }

    private let storage: Storage

    init(integer: Int) throws {
      guard (0...Self.maximumInteger).contains(integer) else {
        throw DriverProtocolV2CodecError.invalidMessage(
          "JSON-RPC integer id must be in 0...\(Self.maximumInteger)")
      }
      storage = .integer(integer)
    }

    init(string: String) throws {
      guard (1...128).contains(string.unicodeScalars.count) else {
        throw DriverProtocolV2CodecError.invalidMessage(
          "JSON-RPC string id must contain 1...128 characters")
      }
      storage = .string(string)
    }

    var integerValue: Int? {
      guard case .integer(let value) = storage else { return nil }
      return value
    }

    var stringValue: String? {
      guard case .string(let value) = storage else { return nil }
      return value
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let value = try? container.decode(Int.self) {
        try self.init(integer: value)
        return
      }
      let value = try container.decode(String.self)
      try self.init(string: value)
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch storage {
      case .integer(let value): try container.encode(value)
      case .string(let value): try container.encode(value)
      }
    }
  }

  struct VMID: Equatable, Codable {
    let rawValue: String

    init(_ rawValue: String) throws {
      guard
        rawValue.range(of: #"^vm_[0-7][0-9A-HJKMNP-TV-Z]{25}$"#, options: .regularExpression) != nil
      else {
        throw DriverProtocolV2CodecError.invalidMessage("vm_id must be a vm_ prefixed ULID")
      }
      self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
      try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }
  }

  struct OperationID: Equatable, Codable {
    let rawValue: String

    init(_ rawValue: String) throws {
      guard
        rawValue.range(of: #"^op_[0-7][0-9A-HJKMNP-TV-Z]{25}$"#, options: .regularExpression) != nil
      else {
        throw DriverProtocolV2CodecError.invalidMessage("operation_id must be an op_ prefixed ULID")
      }
      self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
      try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }
  }

  enum PeerRole: String, Equatable, Codable {
    case daemon
    case driver
  }

  enum Capability: String, CaseIterable, Equatable, Codable {
    case runtimeConfigure = "runtime.configure"
    case runtimeStart = "runtime.start"
    case runtimeStop = "runtime.stop"
    case runtimeKill = "runtime.kill"
    case runtimeStatus = "runtime.status"
    case displayOpen = "display.open"
    case displayClose = "display.close"
    case displayStatus = "display.status"
    case consoleStatus = "console.status"
    case guestStatus = "guest.status"
  }

  struct Implementation: Equatable, Codable {
    let name: String
    let version: String
  }

  struct Hello: Equatable, Codable {
    let protocolVersion: String
    let peerRole: PeerRole
    let vmId: VMID
    let driverGeneration: Int
    let operationId: OperationID?
    let authToken: String
    let offeredCapabilities: [Capability]
    let requiredCapabilities: [Capability]
    let implementation: Implementation?
    var vmID: VMID { vmId }
    var operationID: OperationID? { operationId }

    private enum CodingKeys: String, CodingKey {
      case protocolVersion, peerRole, vmId, driverGeneration, operationId, authToken
      case offeredCapabilities, requiredCapabilities, implementation
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(protocolVersion, forKey: .protocolVersion)
      try container.encode(peerRole, forKey: .peerRole)
      try container.encode(vmId, forKey: .vmId)
      try container.encode(driverGeneration, forKey: .driverGeneration)
      try container.encode(operationId, forKey: .operationId)
      try container.encode(authToken, forKey: .authToken)
      try container.encode(offeredCapabilities, forKey: .offeredCapabilities)
      try container.encode(requiredCapabilities, forKey: .requiredCapabilities)
      try container.encodeIfPresent(implementation, forKey: .implementation)
    }
  }

  struct HelloResult: Equatable, Codable {
    let protocolVersion: String
    let vmId: VMID
    let driverGeneration: Int
    let operationId: OperationID?
    let acceptedCapabilities: [Capability]
    var vmID: VMID { vmId }
    var operationID: OperationID? { operationId }

    private enum CodingKeys: String, CodingKey {
      case protocolVersion, vmId, driverGeneration, operationId, acceptedCapabilities
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(protocolVersion, forKey: .protocolVersion)
      try container.encode(vmId, forKey: .vmId)
      try container.encode(driverGeneration, forKey: .driverGeneration)
      try container.encode(operationId, forKey: .operationId)
      try container.encode(acceptedCapabilities, forKey: .acceptedCapabilities)
    }
  }

  struct Correlation: Equatable, Codable {
    let vmId: VMID
    let driverGeneration: Int
    let operationId: OperationID?
    var vmID: VMID { vmId }
    var operationID: OperationID? { operationId }

    private enum CodingKeys: String, CodingKey { case vmId, driverGeneration, operationId }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(vmId, forKey: .vmId)
      try container.encode(driverGeneration, forKey: .driverGeneration)
      try container.encode(operationId, forKey: .operationId)
    }
  }

  struct OperationCorrelation: Equatable, Codable {
    let vmId: VMID
    let driverGeneration: Int
    let operationId: OperationID
    var vmID: VMID { vmId }
    var operationID: OperationID { operationId }
  }

  struct ConfigureParameters: Equatable, Codable {
    let vmId: VMID
    let driverGeneration: Int
    let operationId: OperationID
    let configuration: RuntimeConfiguration
    var vmID: VMID { vmId }
    var operationID: OperationID { operationId }
  }

  struct StopParameters: Equatable, Codable {
    let vmId: VMID
    let driverGeneration: Int
    let operationId: OperationID
    let gracePeriodSeconds: Double?
    let forceAfterTimeout: Bool?
    var vmID: VMID { vmId }
    var operationID: OperationID { operationId }
  }

  struct DisplayOpenParameters: Equatable, Codable {
    let vmId: VMID
    let driverGeneration: Int
    let operationId: OperationID
    let display: DisplayOptions?
    var vmID: VMID { vmId }
    var operationID: OperationID { operationId }
  }

  struct DisplayOptions: Equatable, Codable { let activate: Bool? }

  enum Command: Equatable {
    case sessionPing(Correlation)
    case runtimeConfigure(ConfigureParameters)
    case runtimeStart(OperationCorrelation)
    case runtimeStop(StopParameters)
    case runtimeKill(OperationCorrelation)
    case runtimeStatus(Correlation)
    case displayOpen(DisplayOpenParameters)
    case displayClose(OperationCorrelation)
    case displayStatus(Correlation)
    case consoleStatus(Correlation)
    case guestStatus(Correlation)
  }

  struct RuntimeConfiguration: Equatable, Codable {
    let architecture: String
    let cpu: Int
    let memoryBytes: UInt64
    let boot: Boot
    let disks: [RuntimeDisk]
    let networks: [RuntimeNetwork]
    let graphics: RuntimeGraphics
    let serial: RuntimeSerial
    let guestAgent: RuntimeGuestAgent
    let bundlePath: String
    let logPaths: LogPaths
  }

  enum Boot: Equatable, Codable {
    case linuxKernel(LinuxKernelBoot)
    case efi(EFIBoot)

    private enum Discriminator: String, Codable {
      case linuxKernel = "linux_kernel"
      case efi
    }
    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      switch try container.decode(Discriminator.self, forKey: .type) {
      case .linuxKernel: self = .linuxKernel(try LinuxKernelBoot(from: decoder))
      case .efi: self = .efi(try EFIBoot(from: decoder))
      }
    }

    func encode(to encoder: Encoder) throws {
      switch self {
      case .linuxKernel(let boot): try boot.encode(to: encoder)
      case .efi(let boot): try boot.encode(to: encoder)
      }
    }
  }

  struct LinuxKernelBoot: Equatable, Codable {
    let type: String
    let kernelPath: String
    let initrdPath: String?
    let commandLine: String
  }

  struct EFIBoot: Equatable, Codable {
    let type: String
    let variableStorePath: String
  }
  struct RuntimeDisk: Equatable, Codable {
    let id: String
    let path: String
    let writable: Bool
  }
  enum NetworkMode: String, Equatable, Codable {
    case shared
    case none
  }
  struct RuntimeNetwork: Equatable, Codable {
    let id: String
    let mode: NetworkMode
    let macAddress: String?
  }
  struct RuntimeGraphics: Equatable, Codable {
    let enabled: Bool
    let width: Int?
    let height: Int?
    let pixelsPerInch: Int?
  }
  struct RuntimeSerial: Equatable, Codable {
    let enabled: Bool
    let capture: Bool
    let logPath: String
  }
  struct RuntimeGuestAgent: Equatable, Codable {
    let enabled: Bool
    let vsockPort: UInt32
  }
  struct LogPaths: Equatable, Codable {
    let driver: String
    let serial: String
  }

  enum RuntimeState: String, Equatable, Codable {
    case configured, starting, running, stopping, stopped, error
  }
  enum DisplayState: String, Equatable, Codable { case closed, opening, open, closing, error }
  struct ConsoleReady: Equatable, Codable {
    let ready: Bool
    let logPath: String
  }
  struct GuestChannel: Equatable, Codable {
    let ready: Bool
    let vsockPort: Int?
  }
  struct Warning: Equatable, Codable {
    let code: String
    let message: String
    let details: [String: JSONValue]?
  }

  enum DriverErrorCode: String, Equatable, Codable {
    case invalidRuntimeConfig = "INVALID_RUNTIME_CONFIG"
    case invalidRuntimeState = "INVALID_RUNTIME_STATE"
    case runtimeStartFailed = "RUNTIME_START_FAILED"
    case runtimeStopFailed = "RUNTIME_STOP_FAILED"
    case runtimeKillFailed = "RUNTIME_KILL_FAILED"
    case driverUnhealthy = "DRIVER_UNHEALTHY"
    case driverInternalError = "DRIVER_INTERNAL_ERROR"
  }

  struct DriverEventError: Equatable, Codable {
    let code: DriverErrorCode
    let message: String
    let retryable: Bool
    let details: [String: JSONValue]?
  }

  struct EventParameters: Equatable, Codable {
    let vmId: VMID
    let driverGeneration: Int
    let operationId: OperationID?
    let occurredAt: String
    let runtimeState: RuntimeState?
    let cleanShutdown: Bool?
    let error: DriverEventError?
    let displayState: DisplayState?
    let console: ConsoleReady?
    let guest: GuestChannel?
    let warning: Warning?
    var vmID: VMID { vmId }
    var operationID: OperationID? { operationId }

    private enum CodingKeys: String, CodingKey {
      case vmId, driverGeneration, operationId, occurredAt, runtimeState, cleanShutdown
      case error, displayState, console, guest, warning
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(vmId, forKey: .vmId)
      try container.encode(driverGeneration, forKey: .driverGeneration)
      try container.encode(operationId, forKey: .operationId)
      try container.encode(occurredAt, forKey: .occurredAt)
      try container.encodeIfPresent(runtimeState, forKey: .runtimeState)
      try container.encodeIfPresent(cleanShutdown, forKey: .cleanShutdown)
      try container.encodeIfPresent(error, forKey: .error)
      try container.encodeIfPresent(displayState, forKey: .displayState)
      try container.encodeIfPresent(console, forKey: .console)
      try container.encodeIfPresent(guest, forKey: .guest)
      try container.encodeIfPresent(warning, forKey: .warning)
    }
  }

  enum Event: Equatable {
    case runtimeStateChanged(EventParameters)
    case runtimeCleanShutdown(EventParameters)
    case runtimeError(EventParameters)
    case displayStateChanged(EventParameters)
    case consoleReady(EventParameters)
    case guestChannelReady(EventParameters)
    case driverWarning(EventParameters)
  }

  enum CommandStatus: String, Equatable, Codable { case accepted, succeeded, noop }
  struct CommandResult: Equatable, Codable {
    let vmId: VMID
    let driverGeneration: Int
    let operationId: OperationID?
    let status: CommandStatus
    let data: [String: JSONValue]?
    var vmID: VMID { vmId }
    var operationID: OperationID? { operationId }

    private enum CodingKeys: String, CodingKey {
      case vmId, driverGeneration, operationId, status, data
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(vmId, forKey: .vmId)
      try container.encode(driverGeneration, forKey: .driverGeneration)
      try container.encode(operationId, forKey: .operationId)
      try container.encode(status, forKey: .status)
      try container.encodeIfPresent(data, forKey: .data)
    }
  }

  enum RPCErrorCode: String, Equatable, Codable {
    case protocolVersionMismatch = "PROTOCOL_VERSION_MISMATCH"
    case authenticationFailed = "AUTHENTICATION_FAILED"
    case capabilityMismatch = "CAPABILITY_MISMATCH"
    case capabilityNotNegotiated = "CAPABILITY_NOT_NEGOTIATED"
    case generationMismatch = "GENERATION_MISMATCH"
    case invalidRuntimeConfig = "INVALID_RUNTIME_CONFIG"
    case invalidRuntimeState = "INVALID_RUNTIME_STATE"
    case runtimeStartFailed = "RUNTIME_START_FAILED"
    case runtimeStopFailed = "RUNTIME_STOP_FAILED"
    case runtimeKillFailed = "RUNTIME_KILL_FAILED"
    case displayUnavailable = "DISPLAY_UNAVAILABLE"
    case driverInternalError = "DRIVER_INTERNAL_ERROR"
  }

  struct RPCErrorData: Equatable, Codable {
    let code: RPCErrorCode
    let vmId: VMID
    let driverGeneration: Int
    let operationId: OperationID?
    let retryable: Bool
    let details: [String: JSONValue]?
    var vmID: VMID { vmId }
    var operationID: OperationID? { operationId }

    private enum CodingKeys: String, CodingKey {
      case code, vmId, driverGeneration, operationId, retryable, details
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(code, forKey: .code)
      try container.encode(vmId, forKey: .vmId)
      try container.encode(driverGeneration, forKey: .driverGeneration)
      try container.encode(operationId, forKey: .operationId)
      try container.encode(retryable, forKey: .retryable)
      try container.encodeIfPresent(details, forKey: .details)
    }
  }

  struct RPCError: Equatable, Codable {
    let code: Int
    let message: String
    let data: RPCErrorData
  }

  enum JSONValue: Equatable, Codable {
    private static let maximumNumber = Decimal(9_007_199_254_740_991)

    case null
    case bool(Bool)
    case integer(Int)
    case decimal(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() {
        self = .null
      } else if let value = try? container.decode(Bool.self) {
        self = .bool(value)
      } else if let value = try? container.decode(Int.self) {
        self = .integer(value)
      } else if let value = try? container.decode(Decimal.self) {
        self = .decimal(value)
      } else if let value = try? container.decode(String.self) {
        self = .string(value)
      } else if let value = try? container.decode([JSONValue].self) {
        self = .array(value)
      } else {
        self = .object(try container.decode([String: JSONValue].self))
      }
      try validateRecursively()
    }

    func encode(to encoder: Encoder) throws {
      try validateRecursively()
      var container = encoder.singleValueContainer()
      switch self {
      case .null: try container.encodeNil()
      case .bool(let value): try container.encode(value)
      case .integer(let value): try container.encode(value)
      case .decimal(let value): try container.encode(value)
      case .string(let value): try container.encode(value)
      case .array(let value): try container.encode(value)
      case .object(let value): try container.encode(value)
      }
    }

    private func validateRecursively() throws {
      switch self {
      case .integer(let value):
        try Self.validateNumber(Decimal(value))
      case .decimal(let value):
        try Self.validateNumber(value)
      case .array(let values):
        for value in values { try value.validateRecursively() }
      case .object(let values):
        for value in values.values { try value.validateRecursively() }
      case .null, .bool, .string:
        break
      }
    }

    private static func validateNumber(_ value: Decimal) throws {
      guard value >= -maximumNumber, value <= maximumNumber else {
        throw DriverProtocolV2CodecError.invalidMessage(
          "opaque JSON numbers must be in -9007199254740991...9007199254740991")
      }
      guard value == 0 || value.exponent >= -9 else {
        throw DriverProtocolV2CodecError.invalidMessage(
          "opaque JSON numbers may contain at most 9 fractional decimal places")
      }
    }
  }

  /// Negotiates only the capability intersection after each hello has been decoded.
  /// Authentication is deliberately left to the future v2 session integration.
  static func negotiateCapabilities(local: Hello, remote: Hello) throws -> [Capability] {
    guard local.protocolVersion == version, remote.protocolVersion == version else {
      throw DriverProtocolV2CodecError.invalidMessage("protocol version mismatch")
    }
    guard local.peerRole != remote.peerRole else {
      throw DriverProtocolV2CodecError.invalidMessage("hello peers must have opposite roles")
    }
    guard local.vmID == remote.vmID, local.driverGeneration == remote.driverGeneration else {
      throw DriverProtocolV2CodecError.invalidMessage("hello generation correlation mismatch")
    }
    let localOffered = Set(local.offeredCapabilities)
    let remoteOffered = Set(remote.offeredCapabilities)
    guard Set(remote.requiredCapabilities).isSubset(of: localOffered),
      Set(local.requiredCapabilities).isSubset(of: remoteOffered)
    else {
      throw DriverProtocolV2CodecError.invalidMessage("required capability is not offered by peer")
    }
    return local.offeredCapabilities.filter(remoteOffered.contains)
  }
}

enum DriverProtocolV2CodecError: Error, Equatable, CustomStringConvertible {
  case malformedJSON(String)
  case batchNotSupported
  case topLevelMustBeObject
  case invalidMessage(String)

  var description: String {
    switch self {
    case .malformedJSON(let message), .invalidMessage(let message): return message
    case .batchNotSupported: return "JSON-RPC batch is not supported"
    case .topLevelMustBeObject: return "top-level JSON must be an object"
    }
  }
}

struct DriverProtocolV2Codec {
  private let decoder: JSONDecoder = {
    let value = JSONDecoder()
    value.keyDecodingStrategy = .convertFromSnakeCase
    return value
  }()
  private let encoder: JSONEncoder = {
    let value = JSONEncoder()
    value.keyEncodingStrategy = .convertToSnakeCase
    value.outputFormatting = [.sortedKeys]
    return value
  }()

  func decode(_ data: Data) throws -> DriverProtocolV2.Message {
    let raw: Any
    do { raw = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) } catch {
      throw DriverProtocolV2CodecError.malformedJSON(error.localizedDescription)
    }
    if raw is [Any] { throw DriverProtocolV2CodecError.batchNotSupported }
    guard let object = raw as? [String: Any] else {
      throw DriverProtocolV2CodecError.topLevelMustBeObject
    }
    guard object["jsonrpc"] as? String == "2.0" else {
      throw invalid("jsonrpc must be exactly 2.0")
    }

    if let method = object["method"] as? String {
      if object["id"] != nil {
        try requireKeys(
          object, required: ["jsonrpc", "id", "method", "params"], context: "request")
        if method == "session.hello" {
          try validateHelloObject(try dictionary(object["params"], "hello params"))
          let request: Request<DriverProtocolV2.Hello> = try decodeType(from: data)
          try validate(request.params)
          return .helloRequest(request.id, request.params)
        }
        return try decodeCommand(method: method, object: object, data: data)
      }
      try requireKeys(object, required: ["jsonrpc", "method", "params"], context: "event")
      return try decodeEvent(method: method, object: object, data: data)
    }

    if object["result"] != nil {
      try requireKeys(object, required: ["jsonrpc", "id", "result"], context: "success response")
      let result = try dictionary(object["result"], "result")
      if result["protocol_version"] != nil {
        try validateHelloResultObject(result)
        let response: SuccessResponse<DriverProtocolV2.HelloResult> = try decodeType(from: data)
        try validate(response.result)
        return .helloSuccessResponse(response.id, response.result)
      }
      try validateCommandResultObject(result)
      let response: SuccessResponse<DriverProtocolV2.CommandResult> = try decodeType(from: data)
      try validate(response.result)
      return .commandSuccessResponse(response.id, response.result)
    }
    if object["error"] != nil {
      try requireKeys(object, required: ["jsonrpc", "id", "error"], context: "error response")
      try validateRPCErrorObject(try dictionary(object["error"], "error"))
      let response: ErrorResponse = try decodeType(from: data)
      try validate(response.error)
      return .errorResponse(response.id, response.error)
    }
    throw invalid("object is not a v2 request, event, or response")
  }

  func encode(_ message: DriverProtocolV2.Message) throws -> Data {
    switch message {
    case .helloRequest(let id, let value):
      try validate(value)
      return try encoder.encode(
        Request(jsonrpc: "2.0", id: id, method: "session.hello", params: value))
    case .commandRequest(let id, let value): return try encodeCommand(id: id, command: value)
    case .event(let value): return try encodeEvent(value)
    case .helloSuccessResponse(let id, let value):
      try validate(value)
      return try encoder.encode(SuccessResponse(jsonrpc: "2.0", id: id, result: value))
    case .commandSuccessResponse(let id, let value):
      try validate(value)
      return try encoder.encode(SuccessResponse(jsonrpc: "2.0", id: id, result: value))
    case .errorResponse(let id, let value):
      try validate(value)
      return try encoder.encode(ErrorResponse(jsonrpc: "2.0", id: id, error: value))
    }
  }

  private func decodeCommand(method: String, object: [String: Any], data: Data) throws
    -> DriverProtocolV2.Message
  {
    let params = try dictionary(object["params"], "command params")
    switch method {
    case "session.ping", "runtime.status", "display.status", "console.status", "guest.status":
      try validateCorrelationObject(params, operationRequired: false)
      let request: Request<DriverProtocolV2.Correlation> = try decodeType(from: data)
      try validate(request.params)
      let command: DriverProtocolV2.Command
      switch method {
      case "session.ping": command = .sessionPing(request.params)
      case "runtime.status": command = .runtimeStatus(request.params)
      case "display.status": command = .displayStatus(request.params)
      case "console.status": command = .consoleStatus(request.params)
      default: command = .guestStatus(request.params)
      }
      return .commandRequest(request.id, command)
    case "runtime.start", "runtime.kill", "display.close":
      try validateCorrelationObject(params, operationRequired: true)
      let request: Request<DriverProtocolV2.OperationCorrelation> = try decodeType(from: data)
      try validate(request.params)
      let command: DriverProtocolV2.Command =
        method == "runtime.start"
        ? .runtimeStart(request.params)
        : method == "runtime.kill" ? .runtimeKill(request.params) : .displayClose(request.params)
      return .commandRequest(request.id, command)
    case "runtime.configure":
      try validateConfigureObject(params)
      let request: Request<DriverProtocolV2.ConfigureParameters> = try decodeType(from: data)
      try validate(request.params)
      return .commandRequest(request.id, .runtimeConfigure(request.params))
    case "runtime.stop":
      try validateStopObject(params)
      let request: Request<DriverProtocolV2.StopParameters> = try decodeType(from: data)
      try validate(request.params)
      return .commandRequest(request.id, .runtimeStop(request.params))
    case "display.open":
      try validateDisplayOpenObject(params)
      let request: Request<DriverProtocolV2.DisplayOpenParameters> = try decodeType(from: data)
      try validate(request.params)
      return .commandRequest(request.id, .displayOpen(request.params))
    default: throw invalid("unknown command method: \(method)")
    }
  }

  private func decodeEvent(method: String, object: [String: Any], data: Data) throws
    -> DriverProtocolV2.Message
  {
    try validateEventObject(try dictionary(object["params"], "event params"), method: method)
    let notification: Notification<DriverProtocolV2.EventParameters> = try decodeType(from: data)
    try validate(notification.params, method: method)
    let event: DriverProtocolV2.Event
    switch method {
    case "runtime.state_changed": event = .runtimeStateChanged(notification.params)
    case "runtime.clean_shutdown": event = .runtimeCleanShutdown(notification.params)
    case "runtime.error": event = .runtimeError(notification.params)
    case "display.state_changed": event = .displayStateChanged(notification.params)
    case "console.ready": event = .consoleReady(notification.params)
    case "guest.channel_ready": event = .guestChannelReady(notification.params)
    case "driver.warning": event = .driverWarning(notification.params)
    default: throw invalid("unknown event method: \(method)")
    }
    return .event(event)
  }

  private func encodeCommand(id: DriverProtocolV2.JSONRPCID, command: DriverProtocolV2.Command)
    throws -> Data
  {
    switch command {
    case .sessionPing(let value):
      try validate(value)
      return try encodeRequest(id, "session.ping", value)
    case .runtimeConfigure(let value):
      try validate(value)
      return try encodeRequest(id, "runtime.configure", value)
    case .runtimeStart(let value):
      try validate(value)
      return try encodeRequest(id, "runtime.start", value)
    case .runtimeStop(let value):
      try validate(value)
      return try encodeRequest(id, "runtime.stop", value)
    case .runtimeKill(let value):
      try validate(value)
      return try encodeRequest(id, "runtime.kill", value)
    case .runtimeStatus(let value):
      try validate(value)
      return try encodeRequest(id, "runtime.status", value)
    case .displayOpen(let value):
      try validate(value)
      return try encodeRequest(id, "display.open", value)
    case .displayClose(let value):
      try validate(value)
      return try encodeRequest(id, "display.close", value)
    case .displayStatus(let value):
      try validate(value)
      return try encodeRequest(id, "display.status", value)
    case .consoleStatus(let value):
      try validate(value)
      return try encodeRequest(id, "console.status", value)
    case .guestStatus(let value):
      try validate(value)
      return try encodeRequest(id, "guest.status", value)
    }
  }

  private func encodeRequest<P: Codable>(
    _ id: DriverProtocolV2.JSONRPCID, _ method: String, _ params: P
  ) throws -> Data {
    try encoder.encode(Request(jsonrpc: "2.0", id: id, method: method, params: params))
  }

  private func encodeEvent(_ event: DriverProtocolV2.Event) throws -> Data {
    let method: String
    let params: DriverProtocolV2.EventParameters
    switch event {
    case .runtimeStateChanged(let value):
      method = "runtime.state_changed"
      params = value
    case .runtimeCleanShutdown(let value):
      method = "runtime.clean_shutdown"
      params = value
    case .runtimeError(let value):
      method = "runtime.error"
      params = value
    case .displayStateChanged(let value):
      method = "display.state_changed"
      params = value
    case .consoleReady(let value):
      method = "console.ready"
      params = value
    case .guestChannelReady(let value):
      method = "guest.channel_ready"
      params = value
    case .driverWarning(let value):
      method = "driver.warning"
      params = value
    }
    try validate(params, method: method)
    return try encoder.encode(Notification(jsonrpc: "2.0", method: method, params: params))
  }

  private func decodeType<T: Decodable>(from data: Data) throws -> T {
    do { return try decoder.decode(T.self, from: data) } catch let error
      as DriverProtocolV2CodecError
    { throw error } catch { throw invalid(error.localizedDescription) }
  }

  private func validate(_ value: DriverProtocolV2.Hello) throws {
    guard value.protocolVersion == DriverProtocolV2.version else {
      throw invalid("protocol_version must be exactly \(DriverProtocolV2.version)")
    }
    try validateGeneration(value.driverGeneration)
    guard value.operationID == nil else { throw invalid("hello operation_id must be null") }
    guard (32...1024).contains(value.authToken.unicodeScalars.count) else {
      throw invalid("auth_token must contain 32...1024 characters")
    }
    try validateCapabilities(value.offeredCapabilities)
    try validateCapabilities(value.requiredCapabilities)
    if let implementation = value.implementation {
      guard (1...128).contains(implementation.name.unicodeScalars.count),
        (1...128).contains(implementation.version.unicodeScalars.count)
      else { throw invalid("implementation fields must contain 1...128 characters") }
    }
  }
  private func validate(_ value: DriverProtocolV2.HelloResult) throws {
    guard value.protocolVersion == DriverProtocolV2.version else {
      throw invalid("protocol_version must be exactly \(DriverProtocolV2.version)")
    }
    try validateGeneration(value.driverGeneration)
    guard value.operationID == nil else { throw invalid("hello result operation_id must be null") }
    try validateCapabilities(value.acceptedCapabilities)
  }
  private func validate(_ value: DriverProtocolV2.Correlation) throws {
    try validateGeneration(value.driverGeneration)
  }
  private func validate(_ value: DriverProtocolV2.OperationCorrelation) throws {
    try validateGeneration(value.driverGeneration)
  }
  private func validate(_ value: DriverProtocolV2.ConfigureParameters) throws {
    try validateGeneration(value.driverGeneration)
    try validate(value.configuration)
  }
  private func validate(_ value: DriverProtocolV2.StopParameters) throws {
    try validateGeneration(value.driverGeneration)
    if let seconds = value.gracePeriodSeconds, !(0...300).contains(seconds) {
      throw invalid("grace_period_seconds must be in 0...300")
    }
  }
  private func validate(_ value: DriverProtocolV2.DisplayOpenParameters) throws {
    try validateGeneration(value.driverGeneration)
  }

  private func validate(_ value: DriverProtocolV2.RuntimeConfiguration) throws {
    guard value.architecture == "arm64" else { throw invalid("runtime architecture must be arm64") }
    guard (1...64).contains(value.cpu) else { throw invalid("cpu must be in 1...64") }
    guard (268_435_456...9_007_199_254_740_992).contains(value.memoryBytes),
      value.memoryBytes % 1_048_576 == 0
    else {
      throw invalid("memory_bytes must be 256 MiB...2^53 and MiB-aligned")
    }
    switch value.boot {
    case .linuxKernel(let boot):
      guard boot.type == "linux_kernel", !boot.kernelPath.unicodeScalars.isEmpty,
        boot.commandLine.unicodeScalars.count <= 8192
      else { throw invalid("invalid Linux kernel boot") }
    case .efi(let boot):
      guard boot.type == "efi", !boot.variableStorePath.unicodeScalars.isEmpty else {
        throw invalid("invalid EFI boot")
      }
    }
    guard (1...32).contains(value.disks.count) else {
      throw invalid("disks must contain 1...32 entries")
    }
    for disk in value.disks {
      guard disk.id.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil,
        !disk.path.unicodeScalars.isEmpty
      else { throw invalid("invalid runtime disk") }
    }
    guard (1...8).contains(value.networks.count) else {
      throw invalid("networks must contain 1...8 entries")
    }
    for network in value.networks {
      guard network.id.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil
      else { throw invalid("invalid runtime network id") }
      if network.mode == .shared {
        guard let mac = network.macAddress, validMAC(mac) else {
          throw invalid("shared network requires a valid MAC address")
        }
      } else if let mac = network.macAddress, !validMAC(mac) {
        throw invalid("invalid MAC address")
      }
    }
    if value.graphics.enabled {
      guard let width = value.graphics.width, (320...8192).contains(width),
        let height = value.graphics.height, (200...8192).contains(height),
        let ppi = value.graphics.pixelsPerInch, (72...600).contains(ppi)
      else { throw invalid("enabled graphics requires valid dimensions and pixels_per_inch") }
    }
    if let width = value.graphics.width, !(320...8192).contains(width) {
      throw invalid("invalid graphics width")
    }
    if let height = value.graphics.height, !(200...8192).contains(height) {
      throw invalid("invalid graphics height")
    }
    if let ppi = value.graphics.pixelsPerInch, !(72...600).contains(ppi) {
      throw invalid("invalid graphics pixels_per_inch")
    }
    guard !value.serial.logPath.unicodeScalars.isEmpty, value.guestAgent.vsockPort >= 1024,
      !value.bundlePath.unicodeScalars.isEmpty, !value.logPaths.driver.unicodeScalars.isEmpty,
      !value.logPaths.serial.unicodeScalars.isEmpty
    else { throw invalid("invalid runtime paths or guest port") }
  }

  private func validate(_ value: DriverProtocolV2.EventParameters, method: String) throws {
    try validateGeneration(value.driverGeneration)
    guard isDateTime(value.occurredAt) else {
      throw invalid("occurred_at must be an RFC 3339 date-time")
    }
    switch method {
    case "runtime.state_changed":
      guard value.runtimeState != nil else {
        throw invalid("runtime.state_changed requires runtime_state")
      }
    case "runtime.error":
      guard value.error != nil else { throw invalid("runtime.error requires error") }
    case "display.state_changed":
      guard value.displayState != nil else {
        throw invalid("display.state_changed requires display_state")
      }
    case "console.ready":
      guard value.console != nil else { throw invalid("console.ready requires console") }
    case "guest.channel_ready":
      guard value.guest != nil else { throw invalid("guest.channel_ready requires guest") }
    case "driver.warning":
      guard value.warning != nil else { throw invalid("driver.warning requires warning") }
    case "runtime.clean_shutdown": break
    default: throw invalid("unknown event method: \(method)")
    }
    if let error = value.error, error.message.unicodeScalars.isEmpty {
      throw invalid("driver error message must not be empty")
    }
    if let console = value.console, !console.ready || console.logPath.unicodeScalars.isEmpty {
      throw invalid("invalid console ready payload")
    }
    if let guest = value.guest, let port = guest.vsockPort,
      !(1...4_294_967_295).contains(port)
    {
      throw invalid("guest vsock_port must be in 1...4294967295")
    }
    if let warning = value.warning,
      warning.code.range(of: #"^[A-Z][A-Z0-9_]*$"#, options: .regularExpression) == nil
        || warning.message.unicodeScalars.isEmpty
    {
      throw invalid("invalid driver warning")
    }
  }
  private func validate(_ value: DriverProtocolV2.CommandResult) throws {
    try validateGeneration(value.driverGeneration)
  }
  private func validate(_ value: DriverProtocolV2.RPCError) throws {
    guard !value.message.unicodeScalars.isEmpty else {
      throw invalid("RPC error message must not be empty")
    }
    guard (Int(Int32.min)...Int(Int32.max)).contains(value.code) else {
      throw invalid("RPC error code must fit a signed 32-bit integer")
    }
    try validateGeneration(value.data.driverGeneration)
  }
  private func validateGeneration(_ value: Int) throws {
    guard (1...DriverProtocolV2.JSONRPCID.maximumInteger).contains(value) else {
      throw invalid(
        "driver_generation must be in 1...\(DriverProtocolV2.JSONRPCID.maximumInteger)")
    }
  }
  private func validateCapabilities(_ value: [DriverProtocolV2.Capability]) throws {
    guard Set(value).count == value.count else {
      throw invalid("capability arrays must contain unique values")
    }
  }
  private func validMAC(_ value: String) -> Bool {
    value.range(of: #"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil
  }
  private func isDateTime(_ value: String) -> Bool {
    let pattern =
      #"^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?([Zz]|[+-]([0-9]{2}):([0-9]{2}))$"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = expression.firstMatch(in: value, range: range), match.range == range else {
      return false
    }

    func integer(at index: Int) -> Int? {
      let range = match.range(at: index)
      guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
        return nil
      }
      return Int(value[swiftRange])
    }

    guard let year = integer(at: 1),
      let month = integer(at: 2), (1...12).contains(month),
      let day = integer(at: 3),
      let hour = integer(at: 4), (0...23).contains(hour),
      let minute = integer(at: 5), (0...59).contains(minute),
      let second = integer(at: 6), (0...59).contains(second)
    else { return false }

    let isLeapYear =
      year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let daysInMonth = [31, isLeapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard (1...daysInMonth[month - 1]).contains(day) else { return false }

    if let offsetHour = integer(at: 8), !(0...23).contains(offsetHour) { return false }
    if let offsetMinute = integer(at: 9), !(0...59).contains(offsetMinute) { return false }
    return true
  }

  private func requireKeys(
    _ object: [String: Any], required: Set<String>, allowed: Set<String>? = nil, context: String
  ) throws {
    let allowed = allowed ?? required
    let keys = Set(object.keys)
    guard required.isSubset(of: keys) else {
      throw invalid(
        "\(context) is missing required keys: \(required.subtracting(keys).sorted().joined(separator: ", "))"
      )
    }
    guard keys.isSubset(of: allowed) else {
      throw invalid(
        "\(context) has unknown keys: \(keys.subtracting(allowed).sorted().joined(separator: ", "))"
      )
    }
  }
  private func dictionary(_ value: Any?, _ context: String) throws -> [String: Any] {
    guard let value = value as? [String: Any] else { throw invalid("\(context) must be an object") }
    return value
  }
  private func rejectExplicitNulls(
    _ object: [String: Any], keys: Set<String>, context: String
  ) throws {
    let nullKeys = keys.filter { object[$0] is NSNull }
    guard nullKeys.isEmpty else {
      throw invalid(
        "\(context) keys cannot be null: \(nullKeys.sorted().joined(separator: ", "))")
    }
  }
  private func validateHelloObject(_ object: [String: Any]) throws {
    let required: Set<String> = [
      "protocol_version", "peer_role", "vm_id", "driver_generation", "operation_id", "auth_token",
      "offered_capabilities", "required_capabilities",
    ]
    try requireKeys(
      object, required: required, allowed: required.union(["implementation"]),
      context: "hello params")
    guard object["operation_id"] is NSNull else { throw invalid("hello operation_id must be null") }
    try rejectExplicitNulls(object, keys: ["implementation"], context: "hello params")
    if let value = object["implementation"] {
      try requireKeys(
        try dictionary(value, "implementation"), required: ["name", "version"],
        context: "implementation")
    }
  }
  private func validateCorrelationObject(_ object: [String: Any], operationRequired: Bool) throws {
    try requireKeys(
      object, required: ["vm_id", "driver_generation", "operation_id"], context: "correlation")
    if operationRequired, object["operation_id"] is NSNull {
      throw invalid("operation_id must not be null")
    }
  }
  private func validateConfigureObject(_ object: [String: Any]) throws {
    try requireKeys(
      object, required: ["vm_id", "driver_generation", "operation_id", "configuration"],
      context: "runtime.configure params")
    try validateRuntimeConfigurationObject(
      try dictionary(object["configuration"], "runtime configuration"))
  }
  private func validateStopObject(_ object: [String: Any]) throws {
    let required: Set<String> = ["vm_id", "driver_generation", "operation_id"]
    try requireKeys(
      object, required: required,
      allowed: required.union(["grace_period_seconds", "force_after_timeout"]),
      context: "runtime.stop params")
    try rejectExplicitNulls(
      object, keys: ["grace_period_seconds", "force_after_timeout"],
      context: "runtime.stop params")
  }
  private func validateDisplayOpenObject(_ object: [String: Any]) throws {
    let required: Set<String> = ["vm_id", "driver_generation", "operation_id"]
    try requireKeys(
      object, required: required, allowed: required.union(["display"]),
      context: "display.open params")
    try rejectExplicitNulls(object, keys: ["display"], context: "display.open params")
    if let value = object["display"] {
      let display = try dictionary(value, "display options")
      try requireKeys(
        display, required: [], allowed: ["activate"], context: "display options")
      try rejectExplicitNulls(display, keys: ["activate"], context: "display options")
    }
  }
  private func validateRuntimeConfigurationObject(_ object: [String: Any]) throws {
    try requireKeys(
      object,
      required: [
        "architecture", "cpu", "memory_bytes", "boot", "disks", "networks", "graphics", "serial",
        "guest_agent", "bundle_path", "log_paths",
      ], context: "runtime configuration")
    let boot = try dictionary(object["boot"], "boot")
    switch boot["type"] as? String {
    case "linux_kernel":
      try requireKeys(
        boot, required: ["type", "kernel_path", "command_line"],
        allowed: ["type", "kernel_path", "initrd_path", "command_line"], context: "Linux boot")
    case "efi":
      try requireKeys(boot, required: ["type", "variable_store_path"], context: "EFI boot")
    default: throw invalid("unknown boot type")
    }
    guard let disks = object["disks"] as? [Any] else { throw invalid("disks must be an array") }
    for value in disks {
      try requireKeys(
        try dictionary(value, "disk"), required: ["id", "path", "writable"], context: "disk")
    }
    guard let networks = object["networks"] as? [Any] else {
      throw invalid("networks must be an array")
    }
    for raw in networks {
      let value = try dictionary(raw, "network")
      try requireKeys(
        value, required: ["id", "mode"], allowed: ["id", "mode", "mac_address"], context: "network")
      try rejectExplicitNulls(value, keys: ["mac_address"], context: "network")
      if value["mode"] as? String == "shared", value["mac_address"] == nil {
        throw invalid("shared network requires mac_address")
      }
    }
    let graphics = try dictionary(object["graphics"], "graphics")
    try requireKeys(
      graphics, required: ["enabled"],
      allowed: ["enabled", "width", "height", "pixels_per_inch"], context: "graphics")
    try rejectExplicitNulls(
      graphics, keys: ["width", "height", "pixels_per_inch"], context: "graphics")
    try requireKeys(
      try dictionary(object["serial"], "serial"), required: ["enabled", "capture", "log_path"],
      context: "serial")
    try requireKeys(
      try dictionary(object["guest_agent"], "guest_agent"), required: ["enabled", "vsock_port"],
      context: "guest_agent")
    try requireKeys(
      try dictionary(object["log_paths"], "log_paths"), required: ["driver", "serial"],
      context: "log_paths")
  }
  private func validateEventObject(_ object: [String: Any], method: String) throws {
    let required: Set<String> = ["vm_id", "driver_generation", "operation_id", "occurred_at"]
    try requireKeys(
      object, required: required,
      allowed: required.union([
        "runtime_state", "clean_shutdown", "error", "display_state", "console", "guest", "warning",
      ]), context: "event params")
    try rejectExplicitNulls(
      object,
      keys: [
        "runtime_state", "clean_shutdown", "error", "display_state", "console", "guest", "warning",
      ], context: "event params")
    switch method {
    case "runtime.state_changed":
      guard object["runtime_state"] != nil else {
        throw invalid("runtime.state_changed requires runtime_state")
      }
    case "runtime.error":
      guard object["error"] != nil else { throw invalid("runtime.error requires error") }
    case "display.state_changed":
      guard object["display_state"] != nil else {
        throw invalid("display.state_changed requires display_state")
      }
    case "console.ready":
      guard object["console"] != nil else { throw invalid("console.ready requires console") }
    case "guest.channel_ready":
      guard object["guest"] != nil else { throw invalid("guest.channel_ready requires guest") }
    case "driver.warning":
      guard object["warning"] != nil else { throw invalid("driver.warning requires warning") }
    case "runtime.clean_shutdown": break
    default: throw invalid("unknown event method: \(method)")
    }
    if let value = object["error"] {
      try validateDriverErrorObject(try dictionary(value, "driver error"))
    }
    if let value = object["console"] {
      try requireKeys(
        try dictionary(value, "console"), required: ["ready", "log_path"], context: "console")
    }
    if let value = object["guest"] {
      let guest = try dictionary(value, "guest")
      try requireKeys(
        guest, required: ["ready"], allowed: ["ready", "vsock_port"], context: "guest")
      try rejectExplicitNulls(guest, keys: ["vsock_port"], context: "guest")
    }
    if let value = object["warning"] {
      let warning = try dictionary(value, "warning")
      try requireKeys(
        warning, required: ["code", "message"], allowed: ["code", "message", "details"],
        context: "warning")
      try rejectExplicitNulls(warning, keys: ["details"], context: "warning")
      if let details = warning["details"] { _ = try dictionary(details, "warning details") }
    }
  }
  private func validateDriverErrorObject(_ object: [String: Any]) throws {
    try requireKeys(
      object, required: ["code", "message", "retryable"],
      allowed: ["code", "message", "retryable", "details"], context: "driver error")
    try rejectExplicitNulls(object, keys: ["details"], context: "driver error")
    if let details = object["details"] { _ = try dictionary(details, "driver error details") }
  }
  private func validateHelloResultObject(_ object: [String: Any]) throws {
    try requireKeys(
      object,
      required: [
        "protocol_version", "vm_id", "driver_generation", "operation_id", "accepted_capabilities",
      ], context: "hello result")
    guard object["operation_id"] is NSNull else {
      throw invalid("hello result operation_id must be null")
    }
  }
  private func validateCommandResultObject(_ object: [String: Any]) throws {
    let required: Set<String> = ["vm_id", "driver_generation", "operation_id", "status"]
    try requireKeys(
      object, required: required, allowed: required.union(["data"]), context: "command result")
    if let data = object["data"], !(data is NSNull) {
      _ = try dictionary(data, "command result data")
    }
  }
  private func validateRPCErrorObject(_ object: [String: Any]) throws {
    try requireKeys(object, required: ["code", "message", "data"], context: "RPC error")
    let data = try dictionary(object["data"], "RPC error data")
    try requireKeys(
      data, required: ["code", "vm_id", "driver_generation", "operation_id", "retryable"],
      allowed: ["code", "vm_id", "driver_generation", "operation_id", "retryable", "details"],
      context: "RPC error data")
    try rejectExplicitNulls(data, keys: ["details"], context: "RPC error data")
    if let details = data["details"] { _ = try dictionary(details, "RPC error details") }
  }
  private func invalid(_ message: String) -> DriverProtocolV2CodecError { .invalidMessage(message) }
}

private struct Request<Parameters: Codable>: Codable {
  let jsonrpc: String
  let id: DriverProtocolV2.JSONRPCID
  let method: String
  let params: Parameters
}
private struct Notification<Parameters: Codable>: Codable {
  let jsonrpc: String
  let method: String
  let params: Parameters
}
private struct SuccessResponse<Result: Codable>: Codable {
  let jsonrpc: String
  let id: DriverProtocolV2.JSONRPCID
  let result: Result
}
private struct ErrorResponse: Codable {
  let jsonrpc: String
  let id: DriverProtocolV2.JSONRPCID?
  let error: DriverProtocolV2.RPCError

  private enum CodingKeys: String, CodingKey { case jsonrpc, id, error }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(jsonrpc, forKey: .jsonrpc)
    try container.encode(id, forKey: .id)
    try container.encode(error, forKey: .error)
  }
}
