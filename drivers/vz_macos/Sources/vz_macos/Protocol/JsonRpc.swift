import Foundation

enum DriverError: Error, CustomStringConvertible {
    case invalidArgs(String)
    case socketBind(String)
    case socketAccept(String)
    case io(String)
    case eof
    case protocolViolation(String)
    case handshakeFailed(String)
    case authMissing

    var description: String {
        switch self {
        case .invalidArgs(let s), .socketBind(let s), .socketAccept(let s), .io(let s), .protocolViolation(let s), .handshakeFailed(let s):
            return s
        case .eof:
            return "socket EOF"
        case .authMissing:
            return "GAOVM_AUTH_TOKEN is required"
        }
    }
}
