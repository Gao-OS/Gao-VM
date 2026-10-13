import Foundation

/// Bounded synchronous opening I/O for an owned socket worker, never the VZ queue.
/// Parsing does not authenticate UID/token/session or prove a native connection.
enum GuestBridgeFrameIO {
  static func encode(_ message: GuestBridgeProtocol.Message) throws -> Data {
    let payload = try GuestBridgeProtocolCodec().encode(message)
    var length = UInt32(payload.count).bigEndian
    return Data(bytes: &length, count: 4) + payload
  }

  static func readResponse(
    from socket: UnixSocket, expecting correlation: GuestBridgeProtocol.Correlation,
    deadline: DispatchTime
  ) throws -> GuestBridgeProtocol.Message {
    try read(from: socket, deadline: deadline) { message in
      guard message.correlation == correlation else { throw GuestBridgeProtocolError.invalidHeader }
      switch message {
      case .ready: break
      case .error: socket.close()
      case .open: throw GuestBridgeProtocolError.invalidHeader
      }
    }
  }

  static func readOpening(from socket: UnixSocket, deadline: DispatchTime) throws
    -> GuestBridgeProtocol.Message
  {
    try read(from: socket, deadline: deadline) { message in
      guard case .open = message else { throw GuestBridgeProtocolError.invalidHeader }
    }
  }

  private static func read(
    from socket: UnixSocket, deadline: DispatchTime,
    accepting: (GuestBridgeProtocol.Message) throws -> Void
  ) throws -> GuestBridgeProtocol.Message {
    do {
      let prefix = try socket.readExact(4, deadline: deadline)
      let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      guard (1...UInt32(GuestBridgeProtocol.maximumHeaderBytes)).contains(length) else {
        throw GuestBridgeProtocolError.invalidLength
      }
      let payload = try socket.readExact(Int(length), deadline: deadline)
      let message = try GuestBridgeProtocolCodec().decode(payload)
      try accepting(message)
      guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else {
        throw GuestBridgeProtocolError.deadlineExpired
      }
      return message
    } catch {
      socket.close()
      if let error = error as? GuestBridgeProtocolError { throw error }
      if error is ControlSocketDeadlineExpired { throw GuestBridgeProtocolError.deadlineExpired }
      throw GuestBridgeProtocolError.transportFailure
    }
  }
}
