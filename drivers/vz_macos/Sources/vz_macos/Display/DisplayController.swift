import Foundation

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(Virtualization)
  import Virtualization
#endif

/// A small published observation, never an AppKit access from the VZ queue.
final class DisplayObservation {
  private let lock = NSLock()
  private var value = DriverProtocolV2.DisplayState.closed

  var state: DriverProtocolV2.DisplayState {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func update(_ state: DriverProtocolV2.DisplayState) {
    lock.lock()
    defer { lock.unlock() }
    value = state
  }
}

#if canImport(AppKit)
  /// An opaque view binding for one applied runtime generation. Closing its window
  /// does not revoke it; releasing the runtime does.
  final class DisplayBinding {
    let width: Int
    let height: Int
    let makeView: @MainActor () -> NSView
    private let lock = NSLock()
    private var active = true

    init(width: Int, height: Int, makeView: @escaping @MainActor () -> NSView) {
      self.width = width
      self.height = height
      self.makeView = makeView
    }

    var isActive: Bool {
      lock.lock()
      defer { lock.unlock() }
      return active
    }

    func invalidate() {
      lock.lock()
      defer { lock.unlock() }
      active = false
    }
  }

  /// AppKit ownership is confined to the main actor, not the VZ command queue.
  @MainActor
  final class DisplayController: NSObject, NSWindowDelegate {
    private let observation: DisplayObservation
    private let onState: (DisplayBinding, DriverProtocolV2.DisplayState, String?) -> Void
    private let makeWindow: @MainActor (NSRect) -> NSWindow
    private var window: NSWindow?
    private var binding: DisplayBinding?
    private var closingOperationID: String?

    init(
      observation: DisplayObservation,
      onState: @escaping (DisplayBinding, DriverProtocolV2.DisplayState, String?) -> Void = {
        _, _, _ in
      },
      makeWindow: @escaping @MainActor (NSRect) -> NSWindow = { rect in
        NSApplication.shared.setActivationPolicy(.regular)
        return NSWindow(
          contentRect: rect,
          styleMask: [.titled, .closable, .miniaturizable, .resizable],
          backing: .buffered,
          defer: false)
      }
    ) {
      self.observation = observation
      self.onState = onState
      self.makeWindow = makeWindow
    }

    func open(
      _ binding: DisplayBinding, activate: Bool, operationID: String?
    ) throws -> DriverProtocolV2.DisplayState {
      guard binding.isActive else {
        throw DriverError.invalidArgs("display runtime generation has been released")
      }
      if let window, self.binding === binding, observation.state == .open {
        show(window, activate: activate)
        return .open
      }
      _ = close(operationID: operationID)
      publish(.opening, binding: binding, operationID: operationID)
      let view = binding.makeView()
      guard binding.isActive else {
        publish(.closed, binding: binding, operationID: operationID)
        throw DriverError.invalidArgs("display runtime generation has been released")
      }
      let rect = NSRect(x: 120, y: 120, width: binding.width, height: binding.height)
      let window = makeWindow(rect)
      window.isReleasedWhenClosed = false
      guard binding.isActive else {
        window.close()
        window.contentView = nil
        publish(.closed, binding: binding, operationID: operationID)
        throw DriverError.invalidArgs("display runtime generation has been released")
      }
      window.title = "GaoVM"
      window.delegate = self
      view.autoresizingMask = [.width, .height]
      window.contentView = view
      self.window = window
      self.binding = binding
      show(window, activate: activate)
      publish(.open, binding: binding, operationID: operationID)
      return .open
    }

    func close(operationID: String?) -> DriverProtocolV2.DisplayState {
      guard let window, let binding else { return .closed }
      closingOperationID = operationID
      publish(.closing, binding: binding, operationID: operationID)
      window.close()
      finishClose(window, operationID: operationID)
      return .closed
    }

    func retire(_ binding: DisplayBinding) {
      guard self.binding === binding else { return }
      _ = close(operationID: nil)
    }

    func windowWillClose(_ notification: Notification) {
      guard let closing = notification.object as? NSWindow, closing === window,
        let binding
      else { return }
      let operationID = closingOperationID
      publish(.closing, binding: binding, operationID: operationID)
      // willClose precedes the SDK close. Publish closed after that call returns,
      // and fence a late notification from a window replaced in the meantime.
      DispatchQueue.main.async { [weak self, weak closing] in
        guard let self, let closing else { return }
        self.finishClose(closing, operationID: operationID)
      }
    }

    private func finishClose(_ closing: NSWindow, operationID: String?) {
      guard closing === window, let binding else { return }
      closing.contentView = nil
      closing.delegate = nil
      window = nil
      self.binding = nil
      closingOperationID = nil
      publish(.closed, binding: binding, operationID: operationID)
    }

    private func publish(
      _ state: DriverProtocolV2.DisplayState, binding: DisplayBinding, operationID: String?
    ) {
      guard observation.state != state else { return }
      observation.update(state)
      onState(binding, state, operationID)
    }

    private func show(_ window: NSWindow, activate: Bool) {
      if activate {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
      } else {
        window.orderFront(nil)
      }
    }
  }
#endif

extension VzRuntime {
  func openDisplay(
    activate: Bool, operationID: String?, completion: @escaping RuntimeCompletion
  ) {
    vzRuntimeQueue.async {
      #if canImport(AppKit) && canImport(Virtualization)
        guard let vm = self.virtualMachine else {
          completion(.failure(DriverError.invalidArgs("vm is not created")))
          return
        }
        guard runtimeObservedState(from: vm.state) == .running,
          let binding = self.displayBinding, binding.isActive
        else {
          completion(.failure(DriverError.invalidArgs("running VM graphics are unavailable")))
          return
        }
        DispatchQueue.main.async {
          do {
            let state = try self.displayController.open(
              binding, activate: activate, operationID: operationID)
            self.vzRuntimeQueue.async {
              guard self.displayBinding === binding, binding.isActive else {
                completion(
                  .failure(DriverError.invalidArgs("display runtime generation has been released")))
                return
              }
              completion(.success(self.displayResult(state)))
            }
          } catch {
            self.vzRuntimeQueue.async { completion(.failure(error)) }
          }
        }
      #else
        completion(.failure(DriverError.invalidArgs("AppKit display is unavailable in this build")))
      #endif
    }
  }

  func closeDisplay(operationID: String?, completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      guard self.displayObservation.state != .closed else {
        completion(.success(self.displayResult(.closed)))
        return
      }
      #if canImport(AppKit) && canImport(Virtualization)
        DispatchQueue.main.async {
          let state = self.displayController.close(operationID: operationID)
          self.vzRuntimeQueue.async { completion(.success(self.displayResult(state))) }
        }
      #else
        completion(.failure(DriverError.invalidArgs("AppKit display is unavailable in this build")))
      #endif
    }
  }

  func displayStatus(completion: @escaping RuntimeCompletion) {
    vzRuntimeQueue.async {
      completion(.success(self.displayResult(self.displayObservation.state)))
    }
  }

  private func displayResult(_ state: DriverProtocolV2.DisplayState) -> [String: Any] {
    [
      "ok": true, "supported": true, "open": state == .open || state == .closing,
      "display_state": state.rawValue,
    ]
  }
}
