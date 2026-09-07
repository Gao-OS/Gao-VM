import Foundation

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(Virtualization)
  import Virtualization
#endif

final class VzRuntime: RuntimeServicing {
  let logger: RotatingLogger
  let vzRuntimeQueue: VzRuntimeQueue
  private let stopCoordinator: RuntimeStopCoordinator
  private let delegateLifetime: VzDelegateLifetime
  private let eventNow: () -> Date
  private let eventDelivery: RuntimeEventDelivery
  private var eventGeneration: RuntimeEventGeneration
  var config: NormalizedVmConfig?
  private var isTearingDown = false
  private var currentOperationID: String?
  var serialController: SerialController?
  #if canImport(Virtualization)
    var virtualMachine: VZVirtualMachine?
  #endif
  #if canImport(AppKit) && canImport(Virtualization)
    var displayWindow: NSWindow?
    var displayView: VZVirtualMachineView?
    var windowCloseObserver: NSObjectProtocol?
  #endif

  init(
    logger: RotatingLogger,
    now: @escaping () -> Date = Date.init,
    eventSink: @escaping RuntimeEventSink = { _ in }
  ) {
    let queue = VzRuntimeQueue()
    self.logger = logger
    vzRuntimeQueue = queue
    stopCoordinator = RuntimeStopCoordinator(queue: queue)
    delegateLifetime = VzDelegateLifetime(queue: queue)
    eventNow = now
    let delivery = RuntimeEventDelivery(sink: eventSink)
    eventDelivery = delivery
    eventGeneration = RuntimeEventGeneration(queue: queue, now: now, delivery: delivery)
  }

  init(
    logger: RotatingLogger,
    queue: VzRuntimeQueue = VzRuntimeQueue(),
    now: @escaping () -> Date = Date.init,
    eventEnvelopeSink: @escaping RuntimeEventEnvelopeSink
  ) {
    self.logger = logger
    vzRuntimeQueue = queue
    stopCoordinator = RuntimeStopCoordinator(queue: queue)
    delegateLifetime = VzDelegateLifetime(queue: queue)
    eventNow = now
    let delivery = RuntimeEventDelivery(envelopeSink: eventEnvelopeSink)
    eventDelivery = delivery
    eventGeneration = RuntimeEventGeneration(queue: queue, now: now, delivery: delivery)
  }

  func setOperationContext(_ operationID: String?) {
    vzRuntimeQueue.async {
      self.currentOperationID = operationID
      self.eventGeneration.setOperationID(operationID)
    }
  }

  func configure(with config: [String: Any], completion: @escaping RuntimeCompletion) {
    do {
      configure(with: try normalizedConfig(config), completion: completion)
    } catch {
      completion(.failure(error))
    }
  }

  func configure(with config: NormalizedVmConfig, completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      self.config = config
      #if canImport(Virtualization)
        let currentRuntimeState = self.virtualMachine.map {
          runtimeObservedState(from: $0.state)
        }
      #else
        let currentRuntimeState: RuntimeObservedState? = nil
      #endif
      self.eventGeneration.observeConfiguration(currentRuntimeState: currentRuntimeState)
      self.logger.log(.info, "vm configured")
      completion(.success(self.statusLocked()))
    }
  }

  func start(completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      #if canImport(Virtualization)
        guard #available(macOS 14.0, *) else {
          completion(
            .failure(DriverError.invalidArgs("Virtualization.framework requires macOS 14+")))
          return
        }
        guard let config = self.config else {
          completion(.failure(DriverError.invalidArgs("vm is not configured")))
          return
        }
        do {
          let spec = config
          if let vm = self.virtualMachine {
            switch vm.state {
            case .running, .starting, .pausing, .paused, .resuming, .stopping, .saving,
              .restoring:
              self.eventGeneration.observeState(runtimeObservedState(from: vm.state))
              completion(.success(self.statusLocked()))
              return
            case .stopped, .error:
              break
            @unknown default:
              break
            }
          }

          self.beginRuntimeGenerationLocked()
          let eventGeneration = self.eventGeneration
          for disk in spec.disks {
            if let sizeMiB = disk.createSizeMiB {
              try self.ensureSparseDisk(disk.path, sizeMiB: sizeMiB)
            }
          }
          let vmConfig = try self.buildConfiguration(spec)
          let vm = VZVirtualMachine(
            configuration: vmConfig, queue: self.vzRuntimeQueue.dispatchQueue)
          let delegate = VzVirtualMachineDelegateAdapter(
            queue: self.vzRuntimeQueue,
            generation: eventGeneration,
            now: self.eventNow)
          self.delegateLifetime.retain(delegate)
          vm.delegate = delegate
          self.virtualMachine = vm
          let gate = RuntimeResultGate(completion: completion)
          eventGeneration.observeState(.starting)

          vm.start { result in
            self.vzRuntimeQueue.async {
              guard !self.isTearingDown, !gate.isFinished else { return }
              switch result {
              case .success:
                self.logger.log(.info, "vm started")
                guard gate.finish(.success(self.statusLocked())) else { return }
                eventGeneration.observeState(runtimeObservedState(from: vm.state))
              case .failure(let error):
                guard gate.finish(.failure(error)) else { return }
                eventGeneration.observeCommandError(
                  error,
                  classification: .startFailed,
                  kind: runtimeErrorKind(
                    for: error,
                    invalidArgumentKind: .invalidConfiguration,
                    defaultKind: .virtualization),
                  state: runtimeObservedState(from: vm.state),
                  occurredAt: self.eventNow())
              }
            }
          }
          self.vzRuntimeQueue.asyncAfter(deadline: .now() + 30) {
            let error = RuntimeLifecycleTimeoutError("vm start timed out after 30s")
            guard gate.finish(.failure(error)) else { return }
            eventGeneration.observeCommandError(
              error,
              classification: .startFailed,
              kind: .timeout,
              state: runtimeObservedState(from: vm.state),
              occurredAt: self.eventNow())
            eventGeneration.poison()
          }
        } catch {
          let state =
            self.virtualMachine.map { runtimeObservedState(from: $0.state) } ?? .configured
          self.eventGeneration.observeCommandError(
            error,
            classification: .startFailed,
            kind: runtimeErrorKind(
              for: error,
              invalidArgumentKind: .invalidConfiguration,
              defaultKind: .virtualization),
            state: state,
            occurredAt: self.eventNow())
          completion(.failure(error))
        }
      #else
        completion(.failure(DriverError.invalidArgs("Virtualization.framework unavailable")))
      #endif
    }
  }

  func stop(completion: @escaping RuntimeCompletion) {
    stop(
      gracePeriod: 30,
      forceTimeout: 5,
      errorClassification: .stopFailed,
      completion: completion)
  }

  func stop(
    gracePeriod: TimeInterval,
    forceAfterTimeout: Bool,
    completion: @escaping RuntimeCompletion
  ) {
    stop(
      gracePeriod: gracePeriod,
      forceTimeout: 5,
      allowGracefulStop: true,
      allowForceStop: forceAfterTimeout,
      errorClassification: .stopFailed,
      completion: completion)
  }

  func kill(completion: @escaping RuntimeCompletion) {
    stop(
      gracePeriod: 0,
      forceTimeout: 5,
      allowGracefulStop: false,
      errorClassification: .killFailed,
      completion: completion)
  }

  func status(completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      completion(.success(self.statusLocked()))
    }
  }

  func flushSerialOutput() {
    vzRuntimeQueue.sync {
      serialController?.close()
      serialController = nil
    }
  }

  func shutdown(completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      self.isTearingDown = true
      self.stop(
        gracePeriod: 30,
        forceTimeout: 5,
        allowGracefulStop: true,
        errorClassification: .stopFailed
      ) { result in
        self.vzRuntimeQueue.async {
          self.releaseRuntimeGenerationLocked()
          completion(result)
        }
      }
    }
  }

  private func stop(
    gracePeriod: TimeInterval,
    forceTimeout: TimeInterval,
    allowGracefulStop: Bool = true,
    allowForceStop: Bool = true,
    errorClassification: RuntimeErrorClassification,
    completion: @escaping RuntimeCompletion
  ) {
    vzRuntimeQueue.async {
      #if canImport(Virtualization)
        guard #available(macOS 14.0, *) else {
          completion(
            .failure(DriverError.invalidArgs("Virtualization.framework requires macOS 14+")))
          return
        }
        guard let vm = self.virtualMachine else {
          if allowGracefulStop {
            self.eventGeneration.observeTerminalCleanShutdown(
              state: .stopped, occurredAt: self.eventNow())
          } else {
            self.eventGeneration.observeState(.stopped)
          }
          completion(.success(self.statusLocked()))
          return
        }
        if vm.state == .error {
          self.eventGeneration.observeState(.error)
          self.logger.log(.warn, "vm stop requested while VM is in error state")
          completion(.success(self.statusLocked()))
          return
        }

        let eventGeneration = self.eventGeneration
        if self.runtimeMachineState(vm.state) == .running {
          eventGeneration.observeState(.stopping)
        }
        self.stopCoordinator.stop(
          gracePeriod: gracePeriod,
          forceTimeout: forceTimeout,
          allowForceStop: allowForceStop,
          state: { self.runtimeMachineState(vm.state) },
          canRequestStop: { allowGracefulStop && vm.canRequestStop },
          requestStop: {
            try vm.requestStop()
            self.logger.log(.info, "vm stop requested")
          },
          forceStop: { callback in
            self.logger.log(.warn, "attempting force stop")
            vm.stop(completionHandler: callback)
          }
        ) { result in
          switch result {
          case .success:
            self.logger.log(.info, "vm stopped")
            eventGeneration.observeState(runtimeObservedState(from: vm.state))
            completion(.success(self.statusLocked()))
          case .failure(let error):
            eventGeneration.observeCommandError(
              error,
              classification: errorClassification,
              kind: runtimeErrorKind(
                for: error,
                invalidArgumentKind: .invalidState,
                defaultKind: .virtualization),
              state: runtimeObservedState(from: vm.state),
              occurredAt: self.eventNow())
            if error is RuntimeLifecycleTimeoutError || error is RuntimeShutdownDeadlineError {
              eventGeneration.poison()
            }
            completion(.failure(error))
          }
        }
      #else
        completion(.failure(DriverError.invalidArgs("Virtualization.framework unavailable")))
      #endif
    }
  }

  #if canImport(Virtualization)
    private func runtimeMachineState(_ state: VZVirtualMachine.State) -> RuntimeMachineState {
      switch state {
      case .stopped:
        return .stopped
      case .error:
        return .error
      default:
        return .running
      }
    }
  #endif

  private func beginRuntimeGenerationLocked() {
    vzRuntimeQueue.preconditionIsCurrent()
    releaseRuntimeGenerationLocked()
    eventGeneration = RuntimeEventGeneration(
      queue: vzRuntimeQueue, now: eventNow, delivery: eventDelivery)
    eventGeneration.setOperationID(currentOperationID)
  }

  private func releaseRuntimeGenerationLocked() {
    vzRuntimeQueue.preconditionIsCurrent()
    #if canImport(Virtualization)
      virtualMachine?.delegate = nil
    #endif
    delegateLifetime.release()
    eventGeneration.close()
    serialController?.close()
    serialController = nil
    #if canImport(Virtualization)
      virtualMachine = nil
    #endif
  }
}

private final class RuntimeResultGate {
  private var completion: RuntimeCompletion?
  private(set) var isFinished = false

  init(completion: @escaping RuntimeCompletion) {
    self.completion = completion
  }

  @discardableResult
  func finish(_ result: RuntimeResult) -> Bool {
    guard !isFinished else { return false }
    isFinished = true
    let completion = completion
    self.completion = nil
    completion?(result)
    return true
  }
}
