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
  var config: [String: Any]?
  private var isTearingDown = false
  #if canImport(Virtualization)
    var virtualMachine: VZVirtualMachine?
  #endif
  #if canImport(AppKit) && canImport(Virtualization)
    var displayWindow: NSWindow?
    var displayView: VZVirtualMachineView?
    var windowCloseObserver: NSObjectProtocol?
  #endif

  init(logger: RotatingLogger) {
    let queue = VzRuntimeQueue()
    self.logger = logger
    vzRuntimeQueue = queue
    stopCoordinator = RuntimeStopCoordinator(queue: queue)
  }

  func configure(with config: [String: Any], completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      do {
        _ = try self.normalizedConfig(config)
        self.config = config
        self.logger.log(.info, "vm configured")
        completion(.success(self.statusLocked()))
      } catch {
        completion(.failure(error))
      }
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
          let spec = try self.normalizedConfig(config)
          if let vm = self.virtualMachine {
            switch vm.state {
            case .running, .starting, .pausing, .paused, .resuming, .stopping, .saving,
              .restoring:
              completion(.success(self.statusLocked()))
              return
            case .stopped, .error:
              break
            @unknown default:
              break
            }
          }

          try self.ensureSparseDisk(spec.diskPath, sizeMiB: spec.diskSizeMiB)
          let vmConfig = try self.buildConfiguration(spec)
          let vm = VZVirtualMachine(
            configuration: vmConfig, queue: self.vzRuntimeQueue.dispatchQueue)
          self.virtualMachine = vm
          let gate = RuntimeResultGate(completion: completion)

          vm.start { result in
            self.vzRuntimeQueue.async {
              guard !self.isTearingDown, !gate.isFinished else { return }
              switch result {
              case .success:
                self.logger.log(.info, "vm started")
                gate.finish(.success(self.statusLocked()))
              case .failure(let error):
                gate.finish(.failure(error))
              }
            }
          }
          self.vzRuntimeQueue.asyncAfter(deadline: .now() + 30) {
            gate.finish(.failure(RuntimeLifecycleTimeoutError("vm start timed out after 30s")))
          }
        } catch {
          completion(.failure(error))
        }
      #else
        completion(.failure(DriverError.invalidArgs("Virtualization.framework unavailable")))
      #endif
    }
  }

  func stop(completion: @escaping RuntimeCompletion) {
    stop(gracePeriod: 30, forceTimeout: 5, completion: completion)
  }

  func kill(completion: @escaping RuntimeCompletion) {
    stop(gracePeriod: 0, forceTimeout: 5, allowGracefulStop: false, completion: completion)
  }

  func status(completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      completion(.success(self.statusLocked()))
    }
  }

  func shutdown(completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      self.isTearingDown = true
      self.stop(
        gracePeriod: 30, forceTimeout: 5, allowGracefulStop: true, completion: completion)
    }
  }

  private func stop(
    gracePeriod: TimeInterval,
    forceTimeout: TimeInterval,
    allowGracefulStop: Bool = true,
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
          completion(.success(self.statusLocked()))
          return
        }
        if vm.state == .error {
          self.logger.log(.warn, "vm stop requested while VM is in error state")
          completion(.success(self.statusLocked()))
          return
        }

        self.stopCoordinator.stop(
          gracePeriod: gracePeriod,
          forceTimeout: forceTimeout,
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
            completion(.success(self.statusLocked()))
          case .failure(let error):
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
}

private final class RuntimeResultGate {
  private var completion: RuntimeCompletion?
  private(set) var isFinished = false

  init(completion: @escaping RuntimeCompletion) {
    self.completion = completion
  }

  func finish(_ result: RuntimeResult) {
    guard !isFinished else { return }
    isFinished = true
    let completion = completion
    self.completion = nil
    completion?(result)
  }
}
