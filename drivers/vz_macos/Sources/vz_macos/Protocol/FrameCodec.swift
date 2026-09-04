import Foundation

final class LengthPrefixedJsonRpc {
    static let maxFrameSize = 16 * 1024 * 1024

    func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DriverError.protocolViolation("invalid JSON object")
        }
        let payload = try JSONSerialization.data(withJSONObject: object, options: [])
        if payload.count > Self.maxFrameSize {
            throw DriverError.protocolViolation("frame length \(payload.count) exceeds maxFrameSize \(Self.maxFrameSize)")
        }
        var len = UInt32(payload.count).bigEndian
        var data = Data(bytes: &len, count: 4)
        data.append(payload)
        return data
    }

    func decode(_ payload: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: payload, options: [])
        if obj is [Any] {
            throw DriverError.protocolViolation("JSON-RPC batch is not supported")
        }
        guard let map = obj as? [String: Any] else {
            throw DriverError.protocolViolation("top-level JSON must be object")
        }
        return map
    }
}
