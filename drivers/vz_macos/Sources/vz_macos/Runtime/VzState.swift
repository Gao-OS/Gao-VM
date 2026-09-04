import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Virtualization)
import Virtualization
#endif

extension VzRuntime {
#if canImport(Virtualization)
    func statusLocked() -> [String: Any] {
        vzRuntimeQueue.preconditionIsCurrent()
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

#else
    func statusLocked() -> [String: Any] {
        vzRuntimeQueue.preconditionIsCurrent()
        return [
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
