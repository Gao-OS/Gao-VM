import Foundation

#if canImport(Virtualization)
  import Virtualization
#endif

enum RuntimeObservedState: String, Equatable {
  case configured
  case starting
  case running
  case stopping
  case stopped
  case error
}

enum RuntimeErrorClassification: String, Equatable {
  case startFailed
  case stopFailed
  case killFailed
  case virtualMachineStopped
  case internalFailure
}

enum RuntimeErrorKind: String, Equatable {
  case invalidConfiguration
  case invalidState
  case protocolViolation
  case virtualization
  case io
  case timeout
  case internalFailure

  var isRetryable: Bool {
    switch self {
    case .virtualization, .io, .timeout:
      return true
    case .invalidConfiguration, .invalidState, .protocolViolation, .internalFailure:
      return false
    }
  }
}

func runtimeErrorKind(
  for error: Error,
  invalidArgumentKind: RuntimeErrorKind,
  defaultKind: RuntimeErrorKind
) -> RuntimeErrorKind {
  if error is RuntimeLifecycleTimeoutError || error is RuntimeShutdownDeadlineError {
    return .timeout
  }
  if error is DriverProtocolV2CodecError {
    return .protocolViolation
  }
  if let driverError = error as? DriverError {
    switch driverError {
    case .invalidArgs:
      return invalidArgumentKind
    case .socketBind, .socketAccept, .io, .eof:
      return .io
    case .protocolViolation, .handshakeFailed, .authMissing:
      return .protocolViolation
    }
  }

  let nsError = error as NSError
  switch nsError.domain {
  case "VZErrorDomain":
    return switch nsError.code {
    case 2, 5, 10:
      .invalidConfiguration
    case 3, 4, 9:
      .invalidState
    default:
      .virtualization
    }
  case NSCocoaErrorDomain, NSPOSIXErrorDomain:
    return .io
  default:
    return defaultKind
  }
}

struct RuntimeEventError: Equatable {
  let classification: RuntimeErrorClassification
  let kind: RuntimeErrorKind
  let message: String
  let domain: String
  let code: Int
  let retryable: Bool

  init(
    classification: RuntimeErrorClassification,
    kind: RuntimeErrorKind,
    message: String,
    domain: String,
    code: Int
  ) {
    self.classification = classification
    self.kind = kind
    self.message = message
    self.domain = domain
    self.code = code
    retryable = kind.isRetryable
  }
}

/// Process-local runtime observation. The live session adds VM/generation and the
/// operation context captured by `RuntimeEventEnvelope` before writing driver v2.
enum RuntimeEvent: Equatable {
  case stateChanged(occurredAt: Date, state: RuntimeObservedState)
  case cleanShutdown(occurredAt: Date, state: RuntimeObservedState)
  case runtimeError(occurredAt: Date, state: RuntimeObservedState, error: RuntimeEventError)
}

typealias RuntimeEventSink = (RuntimeEvent) -> Void

struct RuntimeEventEnvelope: Equatable {
  let event: RuntimeEvent
  let operationID: String?
}

typealias RuntimeEventEnvelopeSink = (RuntimeEventEnvelope) -> Void

/// Preserves observation order without executing arbitrary sink work on `vzRuntimeQueue`.
/// The session adapter weak-captures its session in the sink closure so the
/// runtime, delivery queue, and session cannot form a retain cycle.
final class RuntimeEventDelivery {
  private let queue: DispatchQueue
  private let sink: RuntimeEventEnvelopeSink

  init(
    label: String = "gaovm.driver.runtime-event-delivery",
    sink: @escaping RuntimeEventSink
  ) {
    queue = DispatchQueue(label: label, qos: .userInitiated)
    self.sink = { sink($0.event) }
  }

  init(
    label: String = "gaovm.driver.runtime-event-delivery",
    envelopeSink: @escaping RuntimeEventEnvelopeSink
  ) {
    queue = DispatchQueue(label: label, qos: .userInitiated)
    sink = envelopeSink
  }

  func deliver(_ event: RuntimeEvent, operationID: String? = nil) {
    let envelope = RuntimeEventEnvelope(event: event, operationID: operationID)
    queue.async {
      self.sink(envelope)
    }
  }
}

final class VzDelegateLifetime {
  private let queue: VzRuntimeQueue
  private var delegate: AnyObject?

  init(queue: VzRuntimeQueue) {
    self.queue = queue
  }

  func retain(_ delegate: AnyObject) {
    queue.preconditionIsCurrent()
    self.delegate = delegate
  }

  func release() {
    queue.preconditionIsCurrent()
    delegate = nil
  }
}

final class RuntimeEventGeneration {
  private enum Lifecycle {
    case active
    case poisoned
    case closed
  }

  private let queue: VzRuntimeQueue
  private let now: () -> Date
  private let delivery: RuntimeEventDelivery
  private var lastState: RuntimeObservedState?
  private var terminalEventWasObserved = false
  private var lifecycle = Lifecycle.active
  private var operationID: String?

  init(
    queue: VzRuntimeQueue,
    now: @escaping () -> Date = Date.init,
    delivery: RuntimeEventDelivery
  ) {
    self.queue = queue
    self.now = now
    self.delivery = delivery
  }

  func setOperationID(_ operationID: String?) {
    queue.preconditionIsCurrent()
    self.operationID = operationID
  }

  convenience init(
    queue: VzRuntimeQueue,
    now: @escaping () -> Date = Date.init,
    sink: @escaping RuntimeEventSink
  ) {
    self.init(queue: queue, now: now, delivery: RuntimeEventDelivery(sink: sink))
  }

  func observeState(_ state: RuntimeObservedState) {
    let capturedOperationID = queue.sync { operationID }
    queue.async {
      guard self.lifecycle == .active, !self.terminalEventWasObserved else { return }
      self.emitStateIfChanged(state, operationID: capturedOperationID)
    }
  }

  func observeConfiguration(currentRuntimeState: RuntimeObservedState?) {
    observeState(currentRuntimeState ?? .configured)
  }

  func observeCommandError(
    _ error: Error,
    classification: RuntimeErrorClassification,
    kind: RuntimeErrorKind,
    state: RuntimeObservedState,
    occurredAt: Date
  ) {
    let capturedOperationID = queue.sync { operationID }
    queue.async {
      guard self.lifecycle == .active, !self.terminalEventWasObserved else { return }
      self.emitError(
        error,
        classification: classification,
        kind: kind,
        state: state,
        occurredAt: occurredAt,
        operationID: capturedOperationID)
    }
  }

  func observeTerminalCleanShutdown(state: RuntimeObservedState, occurredAt: Date) {
    let capturedOperationID = queue.sync { operationID }
    queue.async {
      guard self.lifecycle == .active, !self.terminalEventWasObserved else { return }
      self.terminalEventWasObserved = true
      self.emitTerminalState(
        state, occurredAt: occurredAt, operationID: capturedOperationID)
      self.delivery.deliver(
        .cleanShutdown(occurredAt: occurredAt, state: state),
        operationID: capturedOperationID)
    }
  }

  func observeTerminalRuntimeError(
    _ error: Error,
    state: RuntimeObservedState,
    occurredAt: Date
  ) {
    let capturedOperationID = queue.sync { operationID }
    queue.async {
      guard self.lifecycle == .active, !self.terminalEventWasObserved else { return }
      self.terminalEventWasObserved = true
      self.emitTerminalState(
        state, occurredAt: occurredAt, operationID: capturedOperationID)
      self.emitError(
        error,
        classification: .virtualMachineStopped,
        kind: .virtualization,
        state: state,
        occurredAt: occurredAt,
        operationID: capturedOperationID)
    }
  }

  func poison() {
    queue.async {
      guard self.lifecycle == .active else { return }
      self.lifecycle = .poisoned
    }
  }

  func close() {
    queue.async {
      guard self.lifecycle == .active else { return }
      self.lifecycle = .closed
    }
  }

  private func emitStateIfChanged(_ state: RuntimeObservedState, operationID: String?) {
    guard state != lastState else { return }
    lastState = state
    delivery.deliver(
      .stateChanged(occurredAt: now(), state: state), operationID: operationID)
  }

  private func emitTerminalState(
    _ state: RuntimeObservedState,
    occurredAt: Date,
    operationID: String?
  ) {
    guard state != lastState else { return }
    lastState = state
    delivery.deliver(
      .stateChanged(occurredAt: occurredAt, state: state), operationID: operationID)
  }

  private func emitError(
    _ error: Error,
    classification: RuntimeErrorClassification,
    kind: RuntimeErrorKind,
    state: RuntimeObservedState,
    occurredAt: Date,
    operationID: String?
  ) {
    let nsError = error as NSError
    delivery.deliver(
      .runtimeError(
        occurredAt: occurredAt,
        state: state,
        error: RuntimeEventError(
          classification: classification,
          kind: kind,
          message: nsError.localizedDescription,
          domain: nsError.domain,
          code: nsError.code)),
      operationID: operationID)
  }
}

struct VzDelegateEventMapper {
  private let queue: VzRuntimeQueue
  private let generation: RuntimeEventGeneration
  private let now: () -> Date

  init(
    queue: VzRuntimeQueue,
    generation: RuntimeEventGeneration,
    now: @escaping () -> Date = Date.init
  ) {
    self.queue = queue
    self.generation = generation
    self.now = now
  }

  func guestDidStop(state: @escaping () -> RuntimeObservedState) {
    queue.preconditionIsCurrent()
    let observedState = state()
    let occurredAt = now()
    generation.observeTerminalCleanShutdown(state: observedState, occurredAt: occurredAt)
  }

  func didStopWithError(
    _ error: Error,
    state: @escaping () -> RuntimeObservedState
  ) {
    queue.preconditionIsCurrent()
    let observedState = state()
    let occurredAt = now()
    generation.observeTerminalRuntimeError(error, state: observedState, occurredAt: occurredAt)
  }
}

#if canImport(Virtualization)
  func runtimeObservedState(from state: VZVirtualMachine.State) -> RuntimeObservedState {
    switch state {
    case .stopped:
      return .stopped
    case .running, .paused, .pausing, .resuming:
      return .running
    case .error:
      return .error
    case .starting, .restoring:
      return .starting
    case .stopping, .saving:
      return .stopping
    @unknown default:
      return .error
    }
  }

  /// Signed Apple Silicon E2E coverage for real framework callbacks remains part of PR 014.
  final class VzVirtualMachineDelegateAdapter: NSObject, VZVirtualMachineDelegate {
    private let queue: VzRuntimeQueue
    private let eventMapper: VzDelegateEventMapper

    init(
      queue: VzRuntimeQueue,
      generation: RuntimeEventGeneration,
      now: @escaping () -> Date = Date.init
    ) {
      self.queue = queue
      eventMapper = VzDelegateEventMapper(queue: queue, generation: generation, now: now)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
      eventMapper.guestDidStop {
        self.queue.preconditionIsCurrent()
        return runtimeObservedState(from: virtualMachine.state)
      }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
      eventMapper.didStopWithError(error) {
        self.queue.preconditionIsCurrent()
        return runtimeObservedState(from: virtualMachine.state)
      }
    }
  }
#endif
