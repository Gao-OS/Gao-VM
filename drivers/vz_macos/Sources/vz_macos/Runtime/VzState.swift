import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Virtualization)
import Virtualization
#endif
import Darwin

extension VzRuntime {
#if canImport(Virtualization)
    func statusLocked() -> [String: Any] {
        var out: [String: Any] = [
            "configured": config != nil,
            "graphicsWindowOpen": isDisplayOpen()
        ]
        if let vm = virtualMachine {
            out["state"] = vmStateName(vm.state)
            out["canStart"] = vm.canStart
            out["canPause"] = vm.canPause
            out["canResume"] = vm.canResume
            out["canRequestStop"] = vm.canRequestStop
        } else {
            out["state"] = "not_created"
        }
        return out
    }

    func waitForStoppedState(_ vm: VZVirtualMachine, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            switch vm.state {
            case .stopped:
                return true
            case .error:
                return false
            default:
                usleep(200_000)
            }
        }
        return vm.state == .stopped
    }

    @available(macOS 14.0, *)
    func forceStop(_ vm: VZVirtualMachine, timeoutSeconds: TimeInterval) throws {
        let sem = DispatchSemaphore(value: 0)
        var stopError: Error?
        vm.stop { error in
            stopError = error
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            throw DriverError.io("vm force stop callback timed out after \(Int(timeoutSeconds))s")
        }
        if let stopError {
            throw stopError
        }
    }
#else
    func statusLocked() -> [String: Any] {
        [
            "configured": config != nil,
            "graphicsWindowOpen": isDisplayOpen(),
            "state": "virtualization_unavailable"
        ]
    }
#endif

    func isDisplayOpen() -> Bool {
#if canImport(AppKit) && canImport(Virtualization)
        if Thread.isMainThread {
            return displayWindow != nil
        }
        return DispatchQueue.main.sync { displayWindow != nil }
#else
        return false
#endif
    }

#if canImport(Virtualization)
    func vmStateName(_ state: VZVirtualMachine.State) -> String {
        switch state {
        case .stopped: return "stopped"
        case .running: return "running"
        case .paused: return "paused"
        case .error: return "error"
        case .starting: return "starting"
        case .pausing: return "pausing"
        case .resuming: return "resuming"
        case .stopping: return "stopping"
        case .saving: return "saving"
        case .restoring: return "restoring"
        @unknown default: return "unknown"
        }
    }
#endif
}
