import Foundation

typealias RuntimeResult = Result<[String: Any], Error>
typealias RuntimeCompletion = (RuntimeResult) -> Void

struct RuntimeDispatcherClosedError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

protocol RuntimeServicing: AnyObject {
  func setOperationContext(_ operationID: String?)
  func configure(with config: [String: Any], completion: @escaping RuntimeCompletion)
  func configure(with config: NormalizedVmConfig, completion: @escaping RuntimeCompletion)
  func start(completion: @escaping RuntimeCompletion)
  func stop(completion: @escaping RuntimeCompletion)
  func stop(
    gracePeriod: TimeInterval,
    forceAfterTimeout: Bool,
    completion: @escaping RuntimeCompletion)
  func kill(completion: @escaping RuntimeCompletion)
  func status(completion: @escaping RuntimeCompletion)
  func shutdown(completion: @escaping RuntimeCompletion)
}

extension RuntimeServicing {
  func configure(with config: NormalizedVmConfig, completion: @escaping RuntimeCompletion) {
    completion(.failure(DriverError.invalidArgs("typed v2 configuration is unsupported")))
  }

  func stop(
    gracePeriod: TimeInterval,
    forceAfterTimeout: Bool,
    completion: @escaping RuntimeCompletion
  ) {
    stop(completion: completion)
  }
}

final class RuntimeCommandDispatcher {
  private typealias Command = (@escaping RuntimeCompletion) -> Void

  private struct PendingCommand {
    let run: Command
    let completion: RuntimeCompletion
  }

  private struct ActiveCommand {
    let id: UUID
    let command: PendingCommand
  }

  private enum State {
    case open
    case closed(Error)
  }

  private let runtime: RuntimeServicing
  private let commandQueue = DispatchQueue(label: "gaovm.driver.runtime-commands")
  private let responseQueue = DispatchQueue(label: "gaovm.driver.runtime-responses")
  private let fatalErrorHandler: (Error) -> Void
  private let shutdownDeadline: TimeInterval
  private var pending: [PendingCommand] = []
  private var active: ActiveCommand?
  private var state: State = .open
  private var shutdownStarted = false
  private var shutdownDeadlineScheduled = false
  private var shutdownResult: RuntimeResult?
  private var shutdownWaiters: [RuntimeCompletion] = []
  private var poisonError: Error?

  init(
    runtime: RuntimeServicing,
    shutdownDeadline: TimeInterval = 10,
    onFatalError: @escaping (Error) -> Void = { _ in }
  ) {
    self.runtime = runtime
    self.shutdownDeadline = shutdownDeadline
    fatalErrorHandler = onFatalError
  }

  func configure(
    with config: [String: Any], operationID: String? = nil,
    completion: @escaping RuntimeCompletion
  ) {
    enqueue(
      { [runtime] in
        runtime.setOperationContext(operationID)
        runtime.configure(with: config, completion: $0)
      }, completion: completion)
  }

  func configure(
    with config: NormalizedVmConfig, operationID: String? = nil,
    completion: @escaping RuntimeCompletion
  ) {
    enqueue(
      { [runtime] in
        runtime.setOperationContext(operationID)
        runtime.configure(with: config, completion: $0)
      }, completion: completion)
  }

  func start(operationID: String? = nil, completion: @escaping RuntimeCompletion) {
    enqueue(
      { [runtime] in
        runtime.setOperationContext(operationID)
        runtime.start(completion: $0)
      }, completion: completion)
  }

  func stop(operationID: String? = nil, completion: @escaping RuntimeCompletion) {
    enqueue(
      { [runtime] in
        runtime.setOperationContext(operationID)
        runtime.stop(completion: $0)
      }, completion: completion)
  }

  func stop(
    operationID: String? = nil,
    gracePeriod: TimeInterval,
    forceAfterTimeout: Bool,
    completion: @escaping RuntimeCompletion
  ) {
    enqueue(
      { [runtime] in
        runtime.setOperationContext(operationID)
        runtime.stop(
          gracePeriod: gracePeriod,
          forceAfterTimeout: forceAfterTimeout,
          completion: $0)
      }, completion: completion)
  }

  func kill(operationID: String? = nil, completion: @escaping RuntimeCompletion) {
    enqueue(
      { [runtime] in
        runtime.setOperationContext(operationID)
        runtime.kill(completion: $0)
      }, completion: completion)
  }

  func status(completion: @escaping RuntimeCompletion) {
    commandQueue.async {
      self.runtime.status { result in
        self.responseQueue.async { completion(result) }
      }
    }
  }

  func ping(at date: Date = Date(), completion: @escaping RuntimeCompletion) {
    completion(
      .success([
        "ok": true,
        "ts": ISO8601DateFormatter().string(from: date),
      ]))
  }

  func closeAndShutdown(reason: String, completion: @escaping RuntimeCompletion) {
    commandQueue.async {
      if let poisonError = self.poisonError {
        self.responseQueue.async { completion(.failure(poisonError)) }
        return
      }
      if case .open = self.state {
        self.close(reason: reason)
      }
      if let result = self.shutdownResult {
        self.responseQueue.async { completion(result) }
        return
      }
      self.shutdownWaiters.append(completion)
      if self.active == nil {
        self.beginShutdown()
      } else {
        self.scheduleShutdownDeadline()
      }
    }
  }

  private func enqueue(_ command: @escaping Command, completion: @escaping RuntimeCompletion) {
    commandQueue.async {
      guard case .open = self.state else {
        self.rejectClosed(completion, error: self.closedError())
        return
      }
      self.pending.append(PendingCommand(run: command, completion: completion))
      self.runNextIfIdle()
    }
  }

  private func runNextIfIdle() {
    guard case .open = state, active == nil, !pending.isEmpty else { return }
    let command = pending.removeFirst()
    let commandID = UUID()
    active = ActiveCommand(id: commandID, command: command)
    command.run { result in
      self.commandQueue.async {
        guard self.active?.id == commandID else { return }
        self.active = nil
        self.responseQueue.async { command.completion(result) }
        if case .failure(let error) = result, error is RuntimeLifecycleTimeoutError {
          self.poison(with: error)
          return
        }
        if case .closed = self.state {
          self.beginShutdown()
          return
        }
        self.runNextIfIdle()
      }
    }
  }

  private func poison(with error: Error) {
    poisonError = error
    close(reason: String(describing: error))
    finishShutdown(.failure(error))
    responseQueue.async { self.fatalErrorHandler(error) }
  }

  private func close(reason: String) {
    let closedError = RuntimeDispatcherClosedError(reason)
    state = .closed(closedError)
    let queued = pending
    pending.removeAll()
    for command in queued {
      rejectClosed(command.completion, error: closedError)
    }
  }

  private func rejectClosed(_ completion: @escaping RuntimeCompletion, error: Error) {
    responseQueue.async { completion(.failure(error)) }
  }

  private func closedError() -> Error {
    if case .closed(let error) = state {
      return error
    }
    return RuntimeDispatcherClosedError("runtime command dispatcher is closed")
  }

  private func scheduleShutdownDeadline() {
    guard !shutdownDeadlineScheduled else { return }
    shutdownDeadlineScheduled = true
    commandQueue.asyncAfter(deadline: .now() + shutdownDeadline) {
      guard let active = self.active, self.shutdownResult == nil else { return }
      self.active = nil
      let error = RuntimeShutdownDeadlineError(
        "active runtime command did not reach a safe point within \(self.shutdownDeadline)s")
      self.rejectClosed(active.command.completion, error: error)
      self.finishShutdown(.failure(error))
    }
  }

  private func beginShutdown() {
    guard !shutdownStarted, shutdownResult == nil else { return }
    shutdownStarted = true
    runtime.shutdown { result in
      self.commandQueue.async {
        self.finishShutdown(result)
      }
    }
  }

  private func finishShutdown(_ result: RuntimeResult) {
    guard shutdownResult == nil else { return }
    shutdownResult = result
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll()
    for waiter in waiters {
      responseQueue.async { waiter(result) }
    }
  }
}
