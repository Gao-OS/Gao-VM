import Foundation

struct RuntimeLifecycleTimeoutError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

struct RuntimeShutdownDeadlineError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

final class VzRuntimeQueue {
  let dispatchQueue: DispatchQueue
  private let key = DispatchSpecificKey<UInt8>()

  init(label: String = "gaovm.driver.vz-runtime") {
    dispatchQueue = DispatchQueue(label: label, qos: .userInitiated)
    dispatchQueue.setSpecific(key: key, value: 1)
  }

  var isCurrent: Bool {
    DispatchQueue.getSpecific(key: key) != nil
  }

  func preconditionIsCurrent() {
    dispatchPrecondition(condition: .onQueue(dispatchQueue))
  }

  func async(_ work: @escaping () -> Void) {
    dispatchQueue.async(execute: work)
  }

  func asyncAfter(deadline: DispatchTime, execute work: @escaping () -> Void) {
    dispatchQueue.asyncAfter(deadline: deadline, execute: work)
  }

  func sync<T>(_ work: () throws -> T) rethrows -> T {
    if isCurrent {
      return try work()
    }
    return try dispatchQueue.sync(execute: work)
  }
}

enum RuntimeMachineState {
  case running
  case stopped
  case error
}

final class RuntimeStopCoordinator {
  typealias StopCompletion = (Result<Void, Error>) -> Void
  typealias ForceStop = (@escaping (Error?) -> Void) -> Void

  private let queue: VzRuntimeQueue
  private let pollInterval: TimeInterval

  init(queue: VzRuntimeQueue, pollInterval: TimeInterval = 0.2) {
    self.queue = queue
    self.pollInterval = pollInterval
  }

  func stop(
    gracePeriod: TimeInterval,
    forceTimeout: TimeInterval,
    allowForceStop: Bool = true,
    state: @escaping () -> RuntimeMachineState,
    canRequestStop: @escaping () -> Bool,
    requestStop: @escaping () throws -> Void,
    forceStop: @escaping ForceStop,
    completion: @escaping StopCompletion
  ) {
    let attempt = RuntimeStopAttempt(
      queue: queue,
      pollInterval: pollInterval,
      gracePeriod: gracePeriod,
      forceTimeout: forceTimeout,
      allowForceStop: allowForceStop,
      state: state,
      canRequestStop: canRequestStop,
      requestStop: requestStop,
      forceStop: forceStop,
      completion: completion
    )
    queue.async { attempt.begin() }
  }
}

private final class RuntimeStopAttempt {
  private let queue: VzRuntimeQueue
  private let pollInterval: TimeInterval
  private let gracePeriod: TimeInterval
  private let forceTimeout: TimeInterval
  private let allowForceStop: Bool
  private let state: () -> RuntimeMachineState
  private let canRequestStop: () -> Bool
  private let requestStop: () throws -> Void
  private let forceStop: RuntimeStopCoordinator.ForceStop
  private let completion: RuntimeStopCoordinator.StopCompletion
  private var finished = false
  private var graceDeadline: DispatchTime = .now()

  init(
    queue: VzRuntimeQueue,
    pollInterval: TimeInterval,
    gracePeriod: TimeInterval,
    forceTimeout: TimeInterval,
    allowForceStop: Bool,
    state: @escaping () -> RuntimeMachineState,
    canRequestStop: @escaping () -> Bool,
    requestStop: @escaping () throws -> Void,
    forceStop: @escaping RuntimeStopCoordinator.ForceStop,
    completion: @escaping RuntimeStopCoordinator.StopCompletion
  ) {
    self.queue = queue
    self.pollInterval = pollInterval
    self.gracePeriod = gracePeriod
    self.forceTimeout = forceTimeout
    self.allowForceStop = allowForceStop
    self.state = state
    self.canRequestStop = canRequestStop
    self.requestStop = requestStop
    self.forceStop = forceStop
    self.completion = completion
  }

  func begin() {
    switch state() {
    case .stopped:
      finish(.success(()))
    case .error:
      beginForceStop()
    case .running:
      if canRequestStop() {
        do {
          try requestStop()
          graceDeadline = .now() + gracePeriod
          pollGracefulStop()
        } catch {
          finish(.failure(error))
        }
      } else {
        beginForceStop()
      }
    }
  }

  private func pollGracefulStop() {
    guard !finished else { return }
    switch state() {
    case .stopped:
      finish(.success(()))
    case .error:
      beginForceStop()
    case .running:
      if DispatchTime.now() >= graceDeadline {
        beginForceStop()
      } else {
        queue.asyncAfter(deadline: .now() + pollInterval) { self.pollGracefulStop() }
      }
    }
  }

  private func beginForceStop() {
    guard allowForceStop else {
      finish(.failure(RuntimeLifecycleTimeoutError("vm did not stop before graceful deadline")))
      return
    }
    forceStop { error in
      self.queue.async {
        guard !self.finished else { return }
        if let error {
          self.finish(.failure(error))
        } else {
          self.finish(.success(()))
        }
      }
    }
    queue.asyncAfter(deadline: .now() + forceTimeout) {
      guard !self.finished else { return }
      self.finish(
        .failure(
          RuntimeLifecycleTimeoutError(
            "vm force stop callback timed out after \(self.forceTimeout)s"
          )))
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    guard !finished else { return }
    finished = true
    completion(result)
  }
}
