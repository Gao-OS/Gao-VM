import AppKit
import XCTest

@testable import vz_macos

final class DisplayControllerTests: XCTestCase {
  @MainActor
  func testClosingAndReopeningAWindowPreservesItsRuntimeBinding() async throws {
    _ = NSApplication.shared
    let observation = DisplayObservation()
    var windows: [SilentDisplayWindow] = []
    let controller = DisplayController(
      observation: observation,
      makeWindow: { rect in
        let window = SilentDisplayWindow(
          contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        windows.append(window)
        return window
      })
    var createdViews = 0
    let binding = DisplayBinding(width: 800, height: 600) {
      createdViews += 1
      return NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    XCTAssertEqual(try controller.open(binding, activate: false, operationID: "open"), .open)
    XCTAssertEqual(try controller.open(binding, activate: false, operationID: "again"), .open)
    XCTAssertEqual(windows.count, 1)
    XCTAssertEqual(createdViews, 1)
    XCTAssertEqual(observation.state, .open)

    XCTAssertEqual(controller.close(operationID: "close"), .closed)
    XCTAssertEqual(controller.close(operationID: "again"), .closed)
    XCTAssertTrue(binding.isActive, "closing display must not retire the VM binding")
    XCTAssertNil(windows.first?.contentView)
    XCTAssertEqual(observation.state, .closed)

    XCTAssertEqual(try controller.open(binding, activate: false, operationID: "reopen"), .open)
    XCTAssertEqual(windows.count, 2)
    XCTAssertEqual(createdViews, 2)
    XCTAssertEqual(controller.close(operationID: nil), .closed)
  }

  @MainActor
  func testDisplayEventsKeepCommandCorrelationAndFenceOldWindowCallbacks() async throws {
    _ = NSApplication.shared
    let observation = DisplayObservation()
    var windows: [SilentDisplayWindow] = []
    var states: [DriverProtocolV2.DisplayState] = []
    var operations: [String?] = []
    let controller = DisplayController(
      observation: observation,
      onState: { _, state, operationID in
        states.append(state)
        operations.append(operationID)
      },
      makeWindow: { rect in
        let window = SilentDisplayWindow(
          contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        windows.append(window)
        return window
      })
    let binding = DisplayBinding(width: 800, height: 600) { NSView() }

    _ = try controller.open(binding, activate: false, operationID: "open")
    _ = controller.close(operationID: "close")
    _ = try controller.open(binding, activate: false, operationID: "reopen")
    controller.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: windows[0]))
    await Task.yield()
    XCTAssertEqual(observation.state, .open)
    XCTAssertEqual(states, [.opening, .open, .closing, .closed, .opening, .open])
    XCTAssertEqual(operations, ["open", "open", "close", "close", "reopen", "reopen"])

    windows[1].close()
    XCTAssertEqual(observation.state, .closing, "willClose is not SDK close completion")
    let closed = expectation(description: "main-queue close completion")
    DispatchQueue.main.async { closed.fulfill() }
    await fulfillment(of: [closed], timeout: 1)
    XCTAssertEqual(observation.state, .closed)
    XCTAssertEqual(Array(states.suffix(2)), [.closing, .closed])
    XCTAssertEqual(Array(operations.suffix(2)), [nil, nil])
    XCTAssertTrue(binding.isActive)
  }

  @MainActor
  func testRuntimeRetirementDuringWindowCreationCannotPublishAnOpenDisplay() throws {
    _ = NSApplication.shared
    let observation = DisplayObservation()
    let binding = DisplayBinding(width: 800, height: 600) { NSView() }
    var createdWindow: SilentDisplayWindow?
    let controller = DisplayController(
      observation: observation,
      makeWindow: { rect in
        let window = SilentDisplayWindow(
          contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        createdWindow = window
        binding.invalidate()
        return window
      })

    XCTAssertThrowsError(try controller.open(binding, activate: false, operationID: "open"))
    XCTAssertEqual(observation.state, .closed)
    XCTAssertNil(createdWindow?.contentView)
    XCTAssertFalse(createdWindow?.isVisible ?? true)
  }
}

@MainActor
private final class SilentDisplayWindow: NSWindow {
  override func orderFront(_ sender: Any?) {}
  override func makeKeyAndOrderFront(_ sender: Any?) {}
}
