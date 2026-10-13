import Foundation

/// The separate private bridge opening contract, not driver JSON-RPC or guest readiness.
enum GuestBridgeProtocol {
  static let version = "gaovm.bridge.v1"
  static let maximumHeaderBytes = 4096

  enum StreamKind: String, Codable {
    case control, binary
  }

  enum FailureCode: String, Codable {
    case unavailable = "GUEST_CHANNEL_UNAVAILABLE"
    case limitExceeded = "CHANNEL_LIMIT_EXCEEDED"
  }

  struct Correlation: Equatable {
    let vmId: String
    let driverGeneration: Int
    let requestId: String
    let operationId: String?
    let streamKind: StreamKind

    init(
      vmId: String, driverGeneration: Int, requestId: String,
      operationId: String?, streamKind: StreamKind
    ) throws {
      guard Self.validID(vmId, prefix: "vm_"), Self.validID(requestId, prefix: "req_"),
        (1...9_007_199_254_740_991).contains(driverGeneration),
        operationId.map({ Self.validID($0, prefix: "op_") }) ?? (streamKind == .control)
      else { throw GuestBridgeProtocolError.invalidHeader }
      self.vmId = vmId
      self.driverGeneration = driverGeneration
      self.requestId = requestId
      self.operationId = operationId
      self.streamKind = streamKind
    }

    private static func validID(_ value: String, prefix: String) -> Bool {
      let bytes = Array(value.utf8)
      let prefixBytes = Array(prefix.utf8)
      guard bytes.count == prefixBytes.count + 26, bytes.starts(with: prefixBytes),
        (48...55).contains(bytes[prefixBytes.count])
      else { return false }
      let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8
      return bytes.dropFirst(prefixBytes.count + 1).allSatisfy { alphabet.contains($0) }
    }
  }

  enum Message: Equatable, CustomStringConvertible {
    case open(Correlation, authToken: String)
    case ready(Correlation)
    case error(Correlation, FailureCode)

    var correlation: Correlation {
      switch self {
      case .open(let value, _), .ready(let value), .error(let value, _): return value
      }
    }

    // A parsed opening is not authenticated. Never include its secret in diagnostics.
    var description: String {
      switch self {
      case .open: return "GuestBridgeProtocol.open(redacted)"
      case .ready: return "GuestBridgeProtocol.ready"
      case .error: return "GuestBridgeProtocol.error"
      }
    }
  }
}

enum GuestBridgeProtocolError: Error, Equatable, CustomStringConvertible {
  case invalidHeader
  case invalidLength
  case deadlineExpired
  case transportFailure

  var description: String { "invalid private bridge opening" }
}

struct GuestBridgeProtocolCodec {
  func decode(_ payload: Data) throws -> GuestBridgeProtocol.Message {
    guard (1...GuestBridgeProtocol.maximumHeaderBytes).contains(payload.count),
      String(data: payload, encoding: .utf8) != nil
    else { throw GuestBridgeProtocolError.invalidLength }
    do {
      var keysReader = BridgeObjectKeys(payload)
      let rawKeys = try keysReader.read()
      let generation = try keysReader.generation()
      let kind = try keysReader.kind()
      var keys: Set<String> = [
        "protocol_version", "kind", "vm_id", "driver_generation", "request_id",
        "operation_id", "stream_kind",
      ]
      switch kind {
      case "open": keys.insert("auth_token")
      case "ready": break
      case "error": keys.insert("code")
      default: throw GuestBridgeProtocolError.invalidHeader
      }
      guard rawKeys == keys else { throw GuestBridgeProtocolError.invalidHeader }
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let wire = try decoder.decode(IncomingFields.self, from: payload)
      guard wire.protocolVersion == GuestBridgeProtocol.version,
        let streamKind = GuestBridgeProtocol.StreamKind(rawValue: wire.streamKind)
      else { throw GuestBridgeProtocolError.invalidHeader }
      let correlation = try GuestBridgeProtocol.Correlation(
        vmId: wire.vmId, driverGeneration: generation, requestId: wire.requestId,
        operationId: wire.operationId, streamKind: streamKind)
      switch kind {
      case "open":
        guard let token = wire.authToken else { throw GuestBridgeProtocolError.invalidHeader }
        try validateToken(token)
        return .open(correlation, authToken: token)
      case "ready": return .ready(correlation)
      default:
        guard let code = wire.code, let failure = GuestBridgeProtocol.FailureCode(rawValue: code)
        else { throw GuestBridgeProtocolError.invalidHeader }
        return .error(correlation, failure)
      }
    } catch {
      // Foundation decoding errors may contain untrusted keys/values. Do not expose them.
      throw GuestBridgeProtocolError.invalidHeader
    }
  }

  func encode(_ message: GuestBridgeProtocol.Message) throws -> Data {
    let kind: String
    let token: String?
    let code: String?
    switch message {
    case .open(_, let value):
      try validateToken(value)
      kind = "open"
      token = value
      code = nil
    case .ready:
      kind = "ready"
      token = nil
      code = nil
    case .error(_, let value):
      kind = "error"
      token = nil
      code = value.rawValue
    }
    let value = message.correlation
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(
      WireHeader(
        protocolVersion: GuestBridgeProtocol.version, kind: kind, vmId: value.vmId,
        driverGeneration: value.driverGeneration, requestId: value.requestId,
        operationId: value.operationId, streamKind: value.streamKind.rawValue,
        authToken: token, code: code))
    guard (1...GuestBridgeProtocol.maximumHeaderBytes).contains(payload.count) else {
      throw GuestBridgeProtocolError.invalidLength
    }
    return payload
  }

  private func validateToken(_ value: String) throws {
    guard (1...512).contains(value.utf8.count) else {
      throw GuestBridgeProtocolError.invalidHeader
    }
  }

  // The generation is read exactly from its original number token, not through
  // Foundation Int/Double conversion (which can round or reject valid numbers).
  private struct IncomingFields: Decodable {
    let protocolVersion: String
    let vmId: String
    let requestId: String
    let operationId: String?
    let streamKind: String
    let authToken: String?
    let code: String?
  }

  private struct WireHeader: Encodable {
    let protocolVersion: String
    let kind: String
    let vmId: String
    let driverGeneration: Int
    let requestId: String
    let operationId: String?
    let streamKind: String
    let authToken: String?
    let code: String?

    private enum CodingKeys: String, CodingKey {
      case protocolVersion, kind, vmId, driverGeneration, requestId, operationId, streamKind
      case authToken, code
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(protocolVersion, forKey: .protocolVersion)
      try container.encode(kind, forKey: .kind)
      try container.encode(vmId, forKey: .vmId)
      try container.encode(driverGeneration, forKey: .driverGeneration)
      try container.encode(requestId, forKey: .requestId)
      try container.encode(operationId, forKey: .operationId)
      try container.encode(streamKind, forKey: .streamKind)
      try container.encodeIfPresent(authToken, forKey: .authToken)
      try container.encodeIfPresent(code, forKey: .code)
    }
  }
}

/// Bridge headers are flat objects with scalar values. Scan their original member
/// names before Foundation can collapse duplicates, including escaped names.
private struct BridgeObjectKeys {
  private let bytes: [UInt8]
  private var offset = 0
  private var generationToken: Data?
  private var kindToken: Data?

  init(_ payload: Data) { bytes = Array(payload) }

  mutating func read() throws -> Set<String> {
    skipSpace()
    try consume(123)  // {
    skipSpace()
    var keys: Set<String> = []
    if take(125) {  // }
      try finish()
      return keys
    }
    while true {
      let key = try JSONDecoder().decode(String.self, from: stringToken())
      guard keys.insert(key).inserted else { throw GuestBridgeProtocolError.invalidHeader }
      skipSpace()
      try consume(58)  // :
      skipSpace()
      guard offset < bytes.count else { throw GuestBridgeProtocolError.invalidHeader }
      let valueStart = offset
      if bytes[offset] == 34 {
        _ = try stringToken()
      } else {
        // Arrays/objects cannot occur in the opening contract. JSON decoding below
        // validates number/bool/null syntax and the exact type of each scalar.
        guard
          bytes[offset] == 45 || (48...57).contains(bytes[offset])
            || [102, 110, 116].contains(bytes[offset])
        else { throw GuestBridgeProtocolError.invalidHeader }
        while offset < bytes.count, bytes[offset] != 44, bytes[offset] != 125 { offset += 1 }
      }
      if key == "driver_generation" { generationToken = Data(bytes[valueStart..<offset]) }
      if key == "kind" { kindToken = Data(bytes[valueStart..<offset]) }
      skipSpace()
      if take(125) {
        try finish()
        return keys
      }
      try consume(44)  // ,
      skipSpace()
    }
  }

  func kind() throws -> String {
    guard let kindToken else { throw GuestBridgeProtocolError.invalidHeader }
    return try JSONDecoder().decode(String.self, from: kindToken)
  }

  func generation() throws -> Int {
    guard let generationToken, let text = String(data: generationToken, encoding: .utf8) else {
      throw GuestBridgeProtocolError.invalidHeader
    }
    let number = text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
    let pattern = try NSRegularExpression(
      pattern: #"^(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$"#)
    guard
      let match = pattern.firstMatch(
        in: number as String, range: NSRange(location: 0, length: number.length)),
      match.range.length == number.length
    else { throw GuestBridgeProtocolError.invalidHeader }
    let whole = number.substring(with: match.range(at: 1))
    let fraction =
      match.range(at: 2).location == NSNotFound
      ? "" : number.substring(with: match.range(at: 2))
    let exponentText =
      match.range(at: 3).location == NSNotFound
      ? "0" : number.substring(with: match.range(at: 3))
    guard let exponent = Int(exponentText), (-4096...4096).contains(exponent) else {
      // No nonzero 4096-byte coefficient with a larger exponent can be in range.
      throw GuestBridgeProtocolError.invalidHeader
    }
    var digits = Array((whole + fraction).utf8.drop(while: { $0 == 48 }))
    guard !digits.isEmpty else { throw GuestBridgeProtocolError.invalidHeader }
    let shift = exponent - fraction.utf8.count
    if shift < 0 {
      let cut = -shift
      guard digits.count > cut, digits.suffix(cut).allSatisfy({ $0 == 48 }) else {
        throw GuestBridgeProtocolError.invalidHeader
      }
      digits.removeLast(cut)
    } else {
      guard digits.count + shift <= 16 else { throw GuestBridgeProtocolError.invalidHeader }
      digits.append(contentsOf: repeatElement(48, count: shift))
    }
    guard digits.count <= 16 else { throw GuestBridgeProtocolError.invalidHeader }
    let value = digits.reduce(0) { $0 * 10 + Int($1 - 48) }
    guard value <= 9_007_199_254_740_991 else { throw GuestBridgeProtocolError.invalidHeader }
    return value
  }

  private mutating func stringToken() throws -> Data {
    let start = offset
    try consume(34)
    while offset < bytes.count {
      let byte = bytes[offset]
      offset += 1
      if byte == 34 { return Data(bytes[start..<offset]) }
      guard byte >= 32 else { throw GuestBridgeProtocolError.invalidHeader }
      if byte == 92 {
        guard offset < bytes.count else { throw GuestBridgeProtocolError.invalidHeader }
        offset += 1
      }
    }
    throw GuestBridgeProtocolError.invalidHeader
  }

  private mutating func consume(_ byte: UInt8) throws {
    guard take(byte) else { throw GuestBridgeProtocolError.invalidHeader }
  }

  private mutating func take(_ byte: UInt8) -> Bool {
    guard offset < bytes.count, bytes[offset] == byte else { return false }
    offset += 1
    return true
  }

  private mutating func skipSpace() {
    while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
  }

  private mutating func finish() throws {
    skipSpace()
    guard offset == bytes.count else { throw GuestBridgeProtocolError.invalidHeader }
  }
}
