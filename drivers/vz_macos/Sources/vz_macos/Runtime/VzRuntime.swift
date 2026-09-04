import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Virtualization)
import Virtualization
#endif
import Darwin

final class VzRuntime {
    let logger: RotatingLogger
    let vmQueue = DispatchQueue(label: "gaovm.driver.vm")
    let vmQueueKey = DispatchSpecificKey<UInt8>()
    var config: [String: Any]?
#if canImport(Virtualization)
    var virtualMachine: VZVirtualMachine?
#endif
#if canImport(AppKit) && canImport(Virtualization)
    var displayWindow: NSWindow?
    var displayView: VZVirtualMachineView?
    var windowCloseObserver: NSObjectProtocol?
#endif

    init(logger: RotatingLogger) {
        self.logger = logger
        vmQueue.setSpecific(key: vmQueueKey, value: 1)
    }

    func configure(with config: [String: Any]) throws -> [String: Any] {
        try onVmQueue {
            _ = try normalizedConfig(config)
            self.config = config
            logger.log(.info, "vm configured")
            return statusLocked()
        }
    }

    func start() throws -> [String: Any] {
#if canImport(Virtualization)
        guard #available(macOS 14.0, *) else {
            throw DriverError.invalidArgs("Virtualization.framework requires macOS 14+")
        }
        guard let config else {
            throw DriverError.invalidArgs("vm is not configured")
        }
        return try onVmQueue {
            let spec = try normalizedConfig(config)
            if let vm = virtualMachine {
                switch vm.state {
                case .running, .starting, .pausing, .paused, .resuming, .stopping, .saving, .restoring:
                    return statusLocked()
                case .stopped, .error:
                    break
                @unknown default:
                    break
                }
            }

            try ensureSparseDisk(spec.diskPath, sizeMiB: spec.diskSizeMiB)
            let vmConfig = try buildConfiguration(spec)
            let vm = VZVirtualMachine(configuration: vmConfig)
            virtualMachine = vm

            let sem = DispatchSemaphore(value: 0)
            var startError: Error?
            vm.start { result in
                switch result {
                case .success:
                    break
                case .failure(let err):
                    startError = err
                }
                sem.signal()
            }
            if sem.wait(timeout: .now() + 30) == .timedOut {
                throw DriverError.io("vm start timed out after 30s")
            }
            if let startError {
                throw startError
            }
            logger.log(.info, "vm started")
            return statusLocked()
        }
#else
        throw DriverError.invalidArgs("Virtualization.framework unavailable")
#endif
    }

    func stop() throws -> [String: Any] {
#if canImport(Virtualization)
        guard #available(macOS 14.0, *) else {
            throw DriverError.invalidArgs("Virtualization.framework requires macOS 14+")
        }
        return try onVmQueue {
            guard let vm = virtualMachine else {
                return statusLocked()
            }

            switch vm.state {
            case .stopped:
                return statusLocked()
            case .error:
                logger.log(.warn, "vm stop requested while VM is in error state")
                return statusLocked()
            default:
                break
            }

            if vm.canRequestStop {
                try vm.requestStop()
                logger.log(.info, "vm stop requested")
                if waitForStoppedState(vm, timeoutSeconds: 30) {
                    logger.log(.info, "vm stopped after graceful requestStop")
                    return statusLocked()
                }
                logger.log(.warn, "vm did not stop within 30s after requestStop; attempting force stop")
            } else {
                logger.log(.warn, "vm cannot requestStop; attempting force stop")
            }

            try forceStop(vm, timeoutSeconds: 5)
            if waitForStoppedState(vm, timeoutSeconds: 5) {
                logger.log(.info, "vm force-stopped")
                return statusLocked()
            }
            throw DriverError.io("vm stop timed out: VM did not reach stopped state")
        }
#else
        throw DriverError.invalidArgs("Virtualization.framework unavailable")
#endif
    }

    func status() -> [String: Any] {
        return onVmQueue {
            statusLocked()
        }
    }
}
