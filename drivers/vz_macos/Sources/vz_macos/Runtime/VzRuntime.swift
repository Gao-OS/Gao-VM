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
  let displayObservation = DisplayObservation()
  private var isTearingDown = false
  private var guestConnector: GuestNativeConnector?
  private var guestChannelsFenced = true
  private var appliedGuestPort: UInt32?
  private var currentOperationID: String?
  private let serialDrains = DispatchGroup()
  private var serialDrainFailure: Error?
  private var pendingStart: RuntimeResultGate?
  var serialController: SerialController?
  #if canImport(Virtualization)
    var virtualMachine: VZVirtualMachine?
  #endif
  #if canImport(AppKit) && canImport(Virtualization)
    var displayBinding: DisplayBinding?
    @MainActor lazy var displayController = DisplayController(
      observation: displayObservation,
      onState: { [weak self] binding, state, operationID in
        self?.observeDisplay(binding, state: state, operationID: operationID)
      })
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

  #if canImport(AppKit) && canImport(Virtualization)
    private func observeDisplay(
      _ binding: DisplayBinding, state: DriverProtocolV2.DisplayState, operationID: String?
    ) {
      vzRuntimeQueue.async {
        guard self.displayBinding === binding, binding.isActive else { return }
        self.eventGeneration.observeDisplayState(state, operationID: operationID)
      }
    }
  #endif

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
      self.logRuntime(.info, "vm configured", eventType: .runtimeConfigured)
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
        guard !self.isTearingDown, self.pendingStart == nil else {
          completion(.failure(DriverError.invalidArgs("runtime is starting or shutting down")))
          return
        }
        if let vm = self.virtualMachine {
          switch vm.state {
          case .running, .starting, .pausing, .paused, .resuming, .stopping, .saving, .restoring:
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
        let gate = RuntimeResultGate(completion: completion)
        self.pendingStart = gate
        // Include retired writers and serial preparation in the existing deadline.
        // A late preparation must be closed, never applied to a replacement VM.
        self.vzRuntimeQueue.asyncAfter(deadline: .now() + 30) {
          guard self.pendingStart === gate, !gate.isFinished else { return }
          let error = RuntimeLifecycleTimeoutError("vm start timed out after 30s")
          self.failStartLocked(error, generation: eventGeneration, gate: gate)
          eventGeneration.poison()
        }
        self.afterSerialDrainLocked { result in
          guard self.pendingStart === gate, !gate.isFinished, !self.isTearingDown else { return }
          if case .failure(let error) = result {
            self.failStartLocked(error, generation: eventGeneration, gate: gate)
            return
          }
          guard let serial = config.serial, serial.capture else {
            self.startConfiguredMachineLocked(config, generation: eventGeneration, gate: gate)
            return
          }
          self.serialDrains.enter()
          SerialController.prepare(path: serial.logPath) { result in
            self.vzRuntimeQueue.async {
              defer { self.serialDrains.leave() }
              guard self.pendingStart === gate, !gate.isFinished, !self.isTearingDown else {
                if case .success(let controller) = result { self.retireSerialLocked(controller) }
                return
              }
              switch result {
              case .success(let controller):
                self.serialController = controller
                controller.start()
                if let path = controller.snapshot.logPath {
                  eventGeneration.observeConsoleReady(logPath: path)
                }
                self.startConfiguredMachineLocked(config, generation: eventGeneration, gate: gate)
              case .failure(let error):
                self.failStartLocked(error, generation: eventGeneration, gate: gate)
              }
            }
          }
        }
      #else
        completion(.failure(DriverError.invalidArgs("Virtualization.framework unavailable")))
      #endif
    }
  }

  #if canImport(Virtualization)
    @available(macOS 14.0, *)
    private func startConfiguredMachineLocked(
      _ spec: NormalizedVmConfig, generation: RuntimeEventGeneration, gate: RuntimeResultGate
    ) {
      vzRuntimeQueue.preconditionIsCurrent()
      do {
        for disk in spec.disks {
          if let sizeMiB = disk.createSizeMiB { try ensureSparseDisk(disk.path, sizeMiB: sizeMiB) }
        }
        let vmConfig = try buildConfiguration(spec, serialOutput: serialController?.driverOutput)
        let vm = VZVirtualMachine(configuration: vmConfig, queue: vzRuntimeQueue.dispatchQueue)
        let delegate = VzVirtualMachineDelegateAdapter(
          queue: vzRuntimeQueue, generation: generation, now: eventNow)
        delegateLifetime.retain(delegate)
        vm.delegate = delegate
        virtualMachine = vm
        if spec.graphicsEnabled {
          displayBinding = DisplayBinding(width: spec.graphicsWidth, height: spec.graphicsHeight) {
            let view = VZVirtualMachineView(
              frame: NSRect(x: 0, y: 0, width: spec.graphicsWidth, height: spec.graphicsHeight))
            // AppKit owns the view; no VM property or lifecycle access occurs here.
            view.virtualMachine = vm
            return view
          }
        }
        appliedGuestPort = spec.guestAgent?.vsockPort
        guestChannelsFenced = false
        generation.observeState(.starting)
        vm.start { result in
          self.vzRuntimeQueue.async {
            guard self.pendingStart === gate, !gate.isFinished, !self.isTearingDown else { return }
            switch result {
            case .success:
              self.pendingStart = nil
              self.logRuntime(.info, "vm started", eventType: .runtimeStarted)
              guard gate.finish(.success(self.statusLocked())) else { return }
              generation.observeState(runtimeObservedState(from: vm.state))
            case .failure(let error):
              self.failStartLocked(error, generation: generation, gate: gate)
            }
          }
        }
      } catch {
        closeSerialLocked()
        failStartLocked(error, generation: generation, gate: gate)
      }
    }

    private func failStartLocked(
      _ error: Error, generation: RuntimeEventGeneration, gate: RuntimeResultGate
    ) {
      vzRuntimeQueue.preconditionIsCurrent()
      guard pendingStart === gate, !gate.isFinished else { return }
      pendingStart = nil
      generation.observeCommandError(
        error, classification: .startFailed,
        kind: runtimeErrorKind(
          for: error, invalidArgumentKind: .invalidConfiguration,
          defaultKind: error is RuntimeLifecycleTimeoutError ? .timeout : .virtualization),
        state: virtualMachine.map { runtimeObservedState(from: $0.state) } ?? .configured,
        occurredAt: eventNow())
      gate.finish(.failure(error))
    }
  #endif

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

  func consoleStatus(completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      let snapshot = self.serialController?.snapshot
      completion(
        .success([
          "ready": snapshot?.ready ?? false,
          "log_path": snapshot?.logPath as Any? ?? NSNull(),
        ]))
    }
  }

  /// A runtime-queue snapshot, not permission to open or an authenticated Guest-ready signal.
  func guestStatus(bridgeAvailable: Bool, completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      var port = self.config?.guestAgent?.vsockPort
      var available = false
      #if canImport(Virtualization)
        if let vm = self.virtualMachine {
          // Report the applied device/port, never a newer pending configuration.
          port = self.appliedGuestPort
          available =
            bridgeAvailable && !self.isTearingDown && !self.guestChannelsFenced
            && port != nil && vm.state == .running
            && vm.socketDevices.first is VZVirtioSocketDevice
        }
      #endif
      completion(
        .success([
          "bridge_protocol_version": GuestBridgeProtocol.version,
          "available": available,
          "vsock_port": port.map { Int($0) } as Any? ?? NSNull(),
        ]))
    }
  }

  /// An internal native channel attempt, never a public API or guest-ready signal.
  /// The caller must authenticate the bridge opening before reaching this entry.
  func openGuestChannel(
    streamKind: GuestBridgeProtocol.StreamKind, deadline: DispatchTime,
    beforeNativeClose: @escaping GuestNativeConnector.BeforeNativeClose = { $0() },
    opened: @escaping GuestNativeConnector.Opened, closed: @escaping () -> Void
  ) -> GuestNativeOpening {
    vzRuntimeQueue.sync {
      let connector: GuestNativeConnector
      if let existing = guestConnector {
        connector = existing
      } else {
        connector = GuestNativeConnector(queue: vzRuntimeQueue) { [weak self] callback in
          guard let self else {
            callback(.failure(GuestNativeError.unavailable))
            return
          }
          self.vzRuntimeQueue.preconditionIsCurrent()
          #if canImport(Virtualization)
            guard !self.isTearingDown, !self.guestChannelsFenced,
              let port = self.appliedGuestPort, let vm = self.virtualMachine,
              vm.state == .running,
              let device = vm.socketDevices.first as? VZVirtioSocketDevice
            else {
              callback(.failure(GuestNativeError.unavailable))
              return
            }
            let queue = self.vzRuntimeQueue
            device.connect(toPort: port) { result in
              queue.async {
                callback(
                  result.map {
                    VzGuestNativeSocket(connection: $0, machine: vm, queue: queue)
                      as GuestNativeSocket
                  })
              }
            }
          #else
            callback(.failure(GuestNativeError.unavailable))
          #endif
        }
        guestConnector = connector
      }
      return connector.open(
        streamKind: streamKind, deadline: deadline, beforeNativeClose: beforeNativeClose,
        opened: opened, closed: closed)
    }
  }

  @discardableResult
  func flushSerialOutput(timeout: TimeInterval = 10) -> Bool {
    let finished = DispatchGroup()
    finished.enter()
    let resultLock = NSLock()
    var succeeded = false
    vzRuntimeQueue.sync {
      releaseRuntimeGenerationLocked()
      afterSerialDrainLocked { result in
        resultLock.lock()
        if case .success = result { succeeded = true }
        resultLock.unlock()
        finished.leave()
      }
    }
    // Process-exit callers may join off the VZ queue with a bounded deadline.
    // On that queue, cleanup is requested but never synchronously awaited.
    guard !vzRuntimeQueue.isCurrent,
      finished.wait(timeout: .now() + max(0, timeout)) == .success
    else { return false }
    resultLock.lock()
    defer { resultLock.unlock() }
    return succeeded
  }

  func logRuntime(_ level: LogLevel, _ message: String, eventType: DriverLogEvent) {
    vzRuntimeQueue.preconditionIsCurrent()
    let operationID = currentOperationID.flatMap { try? DriverProtocolV2.OperationID($0) }
    logger.log(level, message, operationID: operationID, eventType: eventType)
  }

  func shutdown(completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      self.isTearingDown = true
      self.pendingStart?.finish(.failure(DriverError.io("vm start cancelled by shutdown")))
      self.pendingStart = nil
      self.fenceGuestChannelsLocked()
      self.stop(
        gracePeriod: 30,
        forceTimeout: 5,
        allowGracefulStop: true,
        errorClassification: .stopFailed
      ) { result in
        self.vzRuntimeQueue.async {
          self.releaseRuntimeGenerationLocked()
          self.afterSerialDrainLocked { drainResult in
            switch (result, drainResult) {
            case (.success, .failure(let error)): completion(.failure(error))
            default: completion(result)
            }
          }
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
      self.fenceGuestChannelsLocked()
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
          self.logRuntime(
            .warn, "vm stop requested while VM is in error state", eventType: .runtimeStopRequested)
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
            self.logRuntime(.info, "vm stop requested", eventType: .runtimeStopRequested)
          },
          forceStop: { callback in
            self.logRuntime(.warn, "attempting force stop", eventType: .runtimeForceStop)
            vm.stop(completionHandler: callback)
          }
        ) { result in
          switch result {
          case .success:
            self.logRuntime(.info, "vm stopped", eventType: .runtimeStopped)
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
    #if canImport(AppKit) && canImport(Virtualization)
      if let binding = displayBinding {
        binding.invalidate()
        displayBinding = nil
        DispatchQueue.main.async { self.displayController.retire(binding) }
      }
    #endif
    fenceGuestChannelsLocked()
    guestConnector = nil
    appliedGuestPort = nil
    #if canImport(Virtualization)
      virtualMachine?.delegate = nil
    #endif
    delegateLifetime.release()
    eventGeneration.close()
    #if canImport(Virtualization)
      virtualMachine = nil
    #endif
    closeSerialLocked()
  }

  private func closeSerialLocked() {
    vzRuntimeQueue.preconditionIsCurrent()
    guard let controller = serialController else { return }
    serialController = nil
    retireSerialLocked(controller)
  }

  private func retireSerialLocked(_ controller: SerialController) {
    vzRuntimeQueue.preconditionIsCurrent()
    let operationID = currentOperationID.flatMap { try? DriverProtocolV2.OperationID($0) }
    serialDrains.enter()
    controller.close { result in
      self.vzRuntimeQueue.async {
        if case .failure(let error) = result {
          self.serialDrainFailure = error
          self.logger.log(
            .error, "serial drain failed: \(error)", operationID: operationID,
            eventType: .runtimeError)
        }
        self.serialDrains.leave()
      }
    }
  }

  private func afterSerialDrainLocked(_ completion: @escaping (Result<Void, Error>) -> Void) {
    vzRuntimeQueue.preconditionIsCurrent()
    serialDrains.notify(queue: vzRuntimeQueue.dispatchQueue) {
      if let error = self.serialDrainFailure {
        completion(.failure(error))
      } else {
        completion(.success(()))
      }
    }
  }

  private func fenceGuestChannelsLocked() {
    vzRuntimeQueue.preconditionIsCurrent()
    guestChannelsFenced = true
    guestConnector?.shutdown()
  }
}

#if canImport(Virtualization)
  /// Keep the original machine through late completion and actual connection close.
  private final class VzGuestNativeSocket: GuestNativeSocket {
    private let queue: VzRuntimeQueue
    private var connection: VZVirtioSocketConnection?
    private var machine: VZVirtualMachine?

    init(connection: VZVirtioSocketConnection, machine: VZVirtualMachine, queue: VzRuntimeQueue) {
      queue.preconditionIsCurrent()
      self.queue = queue
      self.connection = connection
      self.machine = machine
    }

    var fileDescriptor: Int32 {
      queue.preconditionIsCurrent()
      return connection?.fileDescriptor ?? -1
    }

    func close() {
      queue.preconditionIsCurrent()
      connection?.close()
      connection = nil
      machine = nil
    }

    deinit {
      queue.preconditionIsCurrent()
      connection?.close()
    }
  }
#endif

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
