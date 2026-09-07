import Darwin
import Foundation

struct DriverTerminalExitGate {
  private(set) var commandExpected = false
  private(set) var commandResponseSent = false
  private(set) var runtimeTerminalObserved = false
  private var requestedExitCode: Int32 = 0

  mutating func beginCommand(exitCode: Int32) {
    commandExpected = true
    commandResponseSent = false
    requestedExitCode = exitCode
  }

  mutating func completeCommand(succeeded: Bool) {
    if succeeded {
      commandResponseSent = true
    } else {
      commandExpected = false
      commandResponseSent = false
      requestedExitCode = 0
    }
  }

  mutating func observeRuntimeTerminal() {
    runtimeTerminalObserved = true
  }

  var readyExitCode: Int32? {
    guard runtimeTerminalObserved, !commandExpected || commandResponseSent else { return nil }
    return commandExpected ? requestedExitCode : 0
  }

  var acceptsTerminalState: Bool {
    commandExpected && requestedExitCode != 0
  }
}

final class DriverSessionV2 {
  let config: Config
  let logger: RotatingLogger
  private lazy var vmRuntime = VzRuntime(
    logger: logger,
    eventEnvelopeSink: { [weak self] envelope in self?.publish(envelope) })
  private lazy var runtimeDispatcher = RuntimeCommandDispatcher(runtime: vmRuntime) {
    [weak self] error in
    self?.recordFatal(error)
  }
  private let codec = DriverProtocolV2Codec()
  private let socketWriter = SerializedSocketWriter()
  private let stateQueue = DispatchQueue(label: "gaovm.driver.v2.state")
  private var listener: UnixListener?
  private var socket: UnixSocket?
  private var nextID = 0
  private var pendingHelloID: DriverProtocolV2.JSONRPCID?
  private var localHelloAccepted = false
  private var remoteHelloAccepted = false
  private var lastAuthenticatedDaemonRPC = Date()
  private var fatalError: Error?
  private var terminalExit = DriverTerminalExitGate()

  private static let capabilities: [DriverProtocolV2.Capability] = [
    .runtimeConfigure, .runtimeStart, .runtimeStop, .runtimeKill, .runtimeStatus,
  ]

  init(config: Config, logger: RotatingLogger) {
    self.config = config
    self.logger = logger
  }

  func run() throws {
    guard #available(macOS 14.0, *) else {
      throw DriverError.invalidArgs("gaovm-driver-vz requires macOS 14+")
    }
    let listener = UnixListener(path: config.socketPath)
    try listener.bindAndListen()
    guard Darwin.chmod(config.socketPath, mode_t(0o600)) == 0 else {
      listener.close()
      throw DriverError.socketBind("chmod(driver socket) failed")
    }
    self.listener = listener
    let socket = try listener.acceptOne()
    self.socket = socket
    try socketWriter.attach(socket)
    defer {
      socketWriter.close()
      listener.close()
    }
    stateQueue.sync { lastAuthenticatedDaemonRPC = Date() }
    try sendHello()

    while true {
      if let fatal = takeFatalError() { throw fatal }
      if heartbeatExpired() {
        try terminate(reason: "no authenticated daemon RPC within 15 seconds", code: 12)
      }
      if try !socket.pollReadable(timeoutMs: 500) { continue }
      do {
        try handle(readMessage())
      } catch DriverError.eof {
        if let fatal = takeFatalError() { throw fatal }
        try terminate(reason: "control socket EOF", code: 0)
      }
    }
  }

  private func readMessage() throws -> DriverProtocolV2.Message {
    guard let socket else { throw DriverError.io("driver socket is unavailable") }
    let header = try socket.readExact(4, context: "frame header")
    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length > 0, length <= UInt32(LengthPrefixedJsonRpc.maxFrameSize) else {
      throw DriverError.protocolViolation("invalid v2 frame length: \(length)")
    }
    return try codec.decode(socket.readExact(Int(length), context: "frame payload"))
  }

  private func send(_ message: DriverProtocolV2.Message) throws {
    let payload = try codec.encode(message)
    guard payload.count <= LengthPrefixedJsonRpc.maxFrameSize else {
      throw DriverError.protocolViolation("v2 frame is too large")
    }
    var length = UInt32(payload.count).bigEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(payload)
    try socketWriter.write(frame)
  }

  private func sendHello() throws {
    let id = try nextRequestID()
    pendingHelloID = id
    try send(.helloRequest(id, localHello(role: .driver)))
  }

  private func localHello(role: DriverProtocolV2.PeerRole) -> DriverProtocolV2.Hello {
    DriverProtocolV2.Hello(
      protocolVersion: DriverProtocolV2.version,
      peerRole: role,
      vmId: config.vmId,
      driverGeneration: config.generation,
      operationId: nil,
      authToken: config.authToken,
      offeredCapabilities: Self.capabilities,
      requiredCapabilities: Self.capabilities,
      implementation: .init(name: "gaovm-driver-vz", version: "0.1.0"))
  }

  private func handle(_ message: DriverProtocolV2.Message) throws {
    switch message {
    case .helloRequest(let id, let hello):
      try handleHello(id: id, hello: hello)
    case .helloSuccessResponse(let id, let result):
      guard id == pendingHelloID else {
        throw DriverError.protocolViolation("unexpected hello response")
      }
      guard result.protocolVersion == DriverProtocolV2.version,
        result.vmId == config.vmId,
        result.driverGeneration == config.generation,
        result.operationId == nil,
        Set(Self.capabilities).isSubset(of: Set(result.acceptedCapabilities))
      else {
        throw DriverError.handshakeFailed("daemon hello result mismatch")
      }
      localHelloAccepted = true
      markAuthenticatedRPC()
    case .commandRequest(let id, let command):
      guard authenticated else {
        try send(
          errorResponse(
            id: id,
            command: command,
            code: .capabilityNotNegotiated,
            message: "session.hello required",
            retryable: false))
        return
      }
      try requireSessionCorrelation(command)
      markAuthenticatedRPC()
      dispatch(id: id, command: command)
    case .errorResponse(_, let error):
      throw DriverError.handshakeFailed("daemon returned error: \(error.message)")
    case .commandSuccessResponse, .event:
      throw DriverError.protocolViolation("unexpected daemon v2 message")
    }
  }

  private func handleHello(
    id: DriverProtocolV2.JSONRPCID,
    hello: DriverProtocolV2.Hello
  ) throws {
    guard hello.peerRole == .daemon,
      hello.vmId == config.vmId,
      hello.driverGeneration == config.generation,
      hello.operationId == nil,
      constantTimeEqual(hello.authToken, config.authToken)
    else {
      throw DriverError.handshakeFailed("daemon hello identity/authentication mismatch")
    }
    let local = localHello(role: .driver)
    let accepted = try DriverProtocolV2.negotiateCapabilities(local: local, remote: hello)
    guard Set(Self.capabilities).isSubset(of: Set(accepted)) else {
      throw DriverError.handshakeFailed("daemon did not offer runtime core")
    }
    try send(
      .helloSuccessResponse(
        id,
        .init(
          protocolVersion: DriverProtocolV2.version,
          vmId: config.vmId,
          driverGeneration: config.generation,
          operationId: nil,
          acceptedCapabilities: accepted)))
    remoteHelloAccepted = true
    markAuthenticatedRPC()
  }

  private var authenticated: Bool { localHelloAccepted && remoteHelloAccepted }

  private func dispatch(
    id: DriverProtocolV2.JSONRPCID,
    command: DriverProtocolV2.Command
  ) {
    let correlation = commandCorrelation(command)
    let operationID = correlation.operationId?.rawValue
    if isTerminal(command) {
      stateQueue.sync { terminalExit.beginCommand(exitCode: isKill(command) ? 137 : 0) }
    }
    let completion: RuntimeCompletion = { [weak self] result in
      guard let self else { return }
      do {
        switch result {
        case .success:
          let status: DriverProtocolV2.CommandStatus =
            self.isLifecycle(command)
            ? .accepted : .succeeded
          try self.send(
            .commandSuccessResponse(
              id,
              .init(
                vmId: self.config.vmId,
                driverGeneration: self.config.generation,
                operationId: correlation.operationId,
                status: status,
                data: nil)))
          if self.isTerminal(command) {
            self.stateQueue.sync { self.terminalExit.completeCommand(succeeded: true) }
            self.exitIfTerminalReady()
          }
        case .failure(let error):
          try self.send(self.errorResponse(id: id, command: command, error: error))
          if self.isTerminal(command) {
            self.stateQueue.sync { self.terminalExit.completeCommand(succeeded: false) }
            self.exitIfTerminalReady()
          }
        }
      } catch {
        self.recordFatal(error)
      }
    }

    switch command {
    case .sessionPing:
      runtimeDispatcher.ping(completion: completion)
    case .runtimeConfigure(let value):
      do {
        runtimeDispatcher.configure(
          with: try NormalizedVmConfig(v2: value.configuration),
          operationID: operationID,
          completion: completion)
      } catch {
        completion(.failure(error))
      }
    case .runtimeStart:
      runtimeDispatcher.start(operationID: operationID, completion: completion)
    case .runtimeStop(let value):
      runtimeDispatcher.stop(
        operationID: operationID,
        gracePeriod: value.gracePeriodSeconds ?? 30,
        forceAfterTimeout: value.forceAfterTimeout ?? true,
        completion: completion)
    case .runtimeKill:
      runtimeDispatcher.kill(operationID: operationID, completion: completion)
    case .runtimeStatus:
      runtimeDispatcher.status(completion: completion)
    case .displayOpen, .displayClose, .displayStatus, .consoleStatus, .guestStatus:
      completion(.failure(DriverError.invalidArgs("capability not negotiated")))
    }
  }

  private func publish(_ envelope: RuntimeEventEnvelope) {
    do {
      let operationID = try envelope.operationID.map(DriverProtocolV2.OperationID.init)
      var state: DriverProtocolV2.RuntimeState?
      var clean: Bool?
      var error: DriverProtocolV2.DriverEventError?
      let occurredAt: Date
      let event: DriverProtocolV2.Event
      switch envelope.event {
      case .stateChanged(let date, let observed):
        occurredAt = date
        state = runtimeState(observed)
        event = .runtimeStateChanged(
          eventParameters(operationID: operationID, occurredAt: date, state: state))
        if observed == .stopped || observed == .error {
          stateQueue.sync {
            if terminalExit.acceptsTerminalState { terminalExit.observeRuntimeTerminal() }
          }
        }
      case .cleanShutdown(let date, let observed):
        occurredAt = date
        state = runtimeState(observed)
        clean = true
        event = .runtimeCleanShutdown(
          eventParameters(
            operationID: operationID, occurredAt: date, state: state, clean: clean))
        stateQueue.sync {
          terminalExit.observeRuntimeTerminal()
        }
      case .runtimeError(let date, let observed, let runtimeError):
        occurredAt = date
        state = runtimeState(observed)
        error = eventError(runtimeError)
        event = .runtimeError(
          eventParameters(
            operationID: operationID, occurredAt: date, state: state, error: error))
        if runtimeError.classification == .virtualMachineStopped {
          stateQueue.sync { terminalExit.observeRuntimeTerminal() }
        }
      }
      _ = occurredAt
      try send(.event(event))
      exitIfTerminalReady()
    } catch {
      recordFatal(error)
    }
  }

  private func eventParameters(
    operationID: DriverProtocolV2.OperationID?,
    occurredAt: Date,
    state: DriverProtocolV2.RuntimeState? = nil,
    clean: Bool? = nil,
    error: DriverProtocolV2.DriverEventError? = nil
  ) -> DriverProtocolV2.EventParameters {
    DriverProtocolV2.EventParameters(
      vmId: config.vmId,
      driverGeneration: config.generation,
      operationId: operationID,
      occurredAt: ISO8601DateFormatter().string(from: occurredAt),
      runtimeState: state,
      cleanShutdown: clean,
      error: error,
      displayState: nil,
      console: nil,
      guest: nil,
      warning: nil)
  }

  private func exitIfTerminalReady() {
    let exitCode = stateQueue.sync { terminalExit.readyExitCode }
    if let exitCode {
      vmRuntime.flushSerialOutput()
      socketWriter.close()
      listener?.close()
      Foundation.exit(exitCode)
    }
  }

  private func requireSessionCorrelation(_ command: DriverProtocolV2.Command) throws {
    let value = commandCorrelation(command)
    guard value.vmId == config.vmId, value.driverGeneration == config.generation else {
      throw DriverError.protocolViolation("command generation correlation mismatch")
    }
  }

  private func commandCorrelation(_ command: DriverProtocolV2.Command)
    -> DriverProtocolV2.Correlation
  {
    switch command {
    case .sessionPing(let value), .runtimeStatus(let value), .displayStatus(let value),
      .consoleStatus(let value), .guestStatus(let value):
      return value
    case .runtimeConfigure(let value):
      return .init(
        vmId: value.vmId, driverGeneration: value.driverGeneration,
        operationId: value.operationId)
    case .runtimeStart(let value), .runtimeKill(let value), .displayClose(let value):
      return .init(
        vmId: value.vmId, driverGeneration: value.driverGeneration,
        operationId: value.operationId)
    case .runtimeStop(let value):
      return .init(
        vmId: value.vmId, driverGeneration: value.driverGeneration,
        operationId: value.operationId)
    case .displayOpen(let value):
      return .init(
        vmId: value.vmId, driverGeneration: value.driverGeneration,
        operationId: value.operationId)
    }
  }

  private func errorResponse(
    id: DriverProtocolV2.JSONRPCID,
    command: DriverProtocolV2.Command,
    error: Error
  ) -> DriverProtocolV2.Message {
    let (code, retryable) = rpcErrorClassification(error, command: command)
    return errorResponse(
      id: id,
      command: command,
      code: code,
      message: String(describing: error),
      retryable: retryable)
  }

  private func errorResponse(
    id: DriverProtocolV2.JSONRPCID,
    command: DriverProtocolV2.Command,
    code: DriverProtocolV2.RPCErrorCode,
    message: String,
    retryable: Bool
  ) -> DriverProtocolV2.Message {
    let correlation = commandCorrelation(command)
    return .errorResponse(
      id,
      .init(
        code: code == .invalidRuntimeConfig || code == .invalidRuntimeState ? -32602 : -32603,
        message: message,
        data: .init(
          code: code,
          vmId: config.vmId,
          driverGeneration: config.generation,
          operationId: correlation.operationId,
          retryable: retryable,
          details: nil)))
  }

  private func rpcErrorClassification(
    _ error: Error,
    command: DriverProtocolV2.Command
  ) -> (DriverProtocolV2.RPCErrorCode, Bool) {
    if error is RuntimeDispatcherClosedError {
      return (.invalidRuntimeState, false)
    }
    let invalidKind: RuntimeErrorKind = {
      if case .runtimeConfigure = command { return .invalidConfiguration }
      return .invalidState
    }()
    let kind = runtimeErrorKind(
      for: error,
      invalidArgumentKind: invalidKind,
      defaultKind: .internalFailure)
    let code: DriverProtocolV2.RPCErrorCode
    switch kind {
    case .invalidConfiguration:
      code = .invalidRuntimeConfig
    case .invalidState:
      code = .invalidRuntimeState
    default:
      switch command {
      case .runtimeStart: code = .runtimeStartFailed
      case .runtimeStop: code = .runtimeStopFailed
      case .runtimeKill: code = .runtimeKillFailed
      case .displayOpen, .displayClose, .displayStatus: code = .displayUnavailable
      default: code = .driverInternalError
      }
    }
    return (code, kind.isRetryable)
  }

  private func runtimeState(_ value: RuntimeObservedState) -> DriverProtocolV2.RuntimeState {
    switch value {
    case .configured: .configured
    case .starting: .starting
    case .running: .running
    case .stopping: .stopping
    case .stopped: .stopped
    case .error: .error
    }
  }

  private func eventError(_ value: RuntimeEventError) -> DriverProtocolV2.DriverEventError {
    let code: DriverProtocolV2.DriverErrorCode
    switch value.classification {
    case .startFailed: code = .runtimeStartFailed
    case .stopFailed: code = .runtimeStopFailed
    case .killFailed: code = .runtimeKillFailed
    case .virtualMachineStopped: code = .driverUnhealthy
    case .internalFailure: code = .driverInternalError
    }
    return .init(code: code, message: value.message, retryable: value.retryable, details: nil)
  }

  private func isLifecycle(_ command: DriverProtocolV2.Command) -> Bool {
    switch command {
    case .runtimeStart, .runtimeStop, .runtimeKill: true
    default: false
    }
  }

  private func isTerminal(_ command: DriverProtocolV2.Command) -> Bool {
    switch command {
    case .runtimeStop, .runtimeKill: true
    default: false
    }
  }

  private func isKill(_ command: DriverProtocolV2.Command) -> Bool {
    if case .runtimeKill = command { return true }
    return false
  }

  private func nextRequestID() throws -> DriverProtocolV2.JSONRPCID {
    defer { nextID += 1 }
    return try .init(integer: nextID)
  }

  private func markAuthenticatedRPC() {
    stateQueue.sync { lastAuthenticatedDaemonRPC = Date() }
  }

  private func heartbeatExpired() -> Bool {
    stateQueue.sync {
      authenticationDeadlineExpired(since: lastAuthenticatedDaemonRPC)
    }
  }

  private func recordFatal(_ error: Error) {
    stateQueue.sync {
      if fatalError == nil { fatalError = error }
    }
    socketWriter.close()
  }

  private func takeFatalError() -> Error? {
    stateQueue.sync {
      let value = fatalError
      fatalError = nil
      return value
    }
  }

  private func terminate(reason: String, code: Int32) throws -> Never {
    logger.log(.warn, reason)
    let finished = DispatchGroup()
    finished.enter()
    runtimeDispatcher.closeAndShutdown(reason: reason) { _ in finished.leave() }
    _ = finished.wait(timeout: .now() + 10)
    socketWriter.close()
    listener?.close()
    Foundation.exit(code)
  }
}

private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
  let a = Array(left.utf8)
  let b = Array(right.utf8)
  guard !a.isEmpty, !b.isEmpty else { return false }
  var difference = a.count ^ b.count
  let count = max(a.count, b.count)
  for index in 0..<count { difference |= Int(a[index % a.count] ^ b[index % b.count]) }
  return difference == 0
}
