import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Virtualization)
import Virtualization
#endif

extension VzRuntime {
    func openDisplay() throws -> [String: Any] {
        guard #available(macOS 14.0, *) else {
            throw DriverError.invalidArgs("display requires macOS 14+")
        }
#if canImport(AppKit) && canImport(Virtualization)
        let (vm, spec): (VZVirtualMachine, NormalizedVmConfig) = try onVzRuntimeQueue {
            guard let vm = virtualMachine else {
                throw DriverError.invalidArgs("vm is not created")
            }
            let spec = try currentNormalizedConfig()
            return (vm, spec)
        }
        guard spec.graphicsEnabled else {
            throw DriverError.invalidArgs("graphics is disabled in config")
        }
        DispatchQueue.main.sync {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            if let existing = displayWindow {
                existing.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                return
            }

            let rect = NSRect(x: 120, y: 120, width: spec.graphicsWidth, height: spec.graphicsHeight)
            let window = NSWindow(
                contentRect: rect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "GaoVM"
            let vmView = VZVirtualMachineView(frame: rect)
            vmView.autoresizingMask = [.width, .height]
            vmView.virtualMachine = vm
            window.contentView = vmView
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)

            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: nil
            ) { [weak self] _ in
                self?.displayWindow = nil
                self?.displayView = nil
                if let observer = self?.windowCloseObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self?.windowCloseObserver = nil
                }
            }

            self.displayWindow = window
            self.displayView = vmView
        }
        return [
            "ok": true,
            "supported": true,
            "open": true
        ]
#else
        return [
            "ok": true,
            "supported": false,
            "message": "AppKit display is unavailable in this build"
        ]
#endif
    }

    func closeDisplay() throws -> [String: Any] {
        guard #available(macOS 14.0, *) else {
            throw DriverError.invalidArgs("display requires macOS 14+")
        }
#if canImport(AppKit) && canImport(Virtualization)
        DispatchQueue.main.sync {
            displayWindow?.close()
            displayWindow = nil
            displayView = nil
            if let observer = windowCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                windowCloseObserver = nil
            }
        }
        return [
            "ok": true,
            "supported": true,
            "open": false
        ]
#else
        return [
            "ok": true,
            "supported": false,
            "message": "AppKit display is unavailable in this build"
        ]
#endif
    }
}
