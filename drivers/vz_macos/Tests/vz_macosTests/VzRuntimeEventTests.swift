import Foundation
import XCTest

@testable import vz_macos

#if canImport(Virtualization)
  import Virtualization
#endif

final class VzRuntimeEventTests: XCTestCase {
  func testStateTransitionsAreDeliveredInOrderAndDuplicatesAreSuppressed() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.order")
    let delivered = expectation(description: "two distinct states delivered")
    delivered.expectedFulfillmentCount = 2
    delivered.assertForOverFulfill = true
    let recorder = RuntimeEventRecorder()
    let generation = RuntimeEventGeneration(
      queue: queue,
      now: { Date(timeIntervalSince1970: 1_000) },
      sink: { event in
        recorder.append(event)
        delivered.fulfill()
      })

    generation.observeState(.starting)
    generation.observeState(.starting)
    generation.observeState(.running)

    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(
      recorder.snapshot,
      [
        .stateChanged(
          occurredAt: Date(timeIntervalSince1970: 1_000), state: .starting),
        .stateChanged(
          occurredAt: Date(timeIntervalSince1970: 1_000), state: .running),
      ])
  }

  func testCleanShutdownAndRuntimeErrorAreDistinctAndTerminalCallbacksAreDeduplicated() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.terminal")
    let delivered = expectation(description: "state and terminal cause delivered")
    delivered.expectedFulfillmentCount = 4
    delivered.assertForOverFulfill = true
    let recorder = RuntimeEventRecorder()
    let now = { Date(timeIntervalSince1970: 2_000) }
    let delivery = RuntimeEventDelivery { event in
      recorder.append(event)
      delivered.fulfill()
    }
    let cleanGeneration = RuntimeEventGeneration(queue: queue, now: now, delivery: delivery)
    let errorGeneration = RuntimeEventGeneration(queue: queue, now: now, delivery: delivery)
    let failure = NSError(
      domain: "VZErrorDomain", code: 17,
      userInfo: [
        NSLocalizedDescriptionKey: "virtual machine stopped unexpectedly"
      ])

    cleanGeneration.observeTerminalCleanShutdown(state: .stopped, occurredAt: now())
    cleanGeneration.observeTerminalCleanShutdown(state: .stopped, occurredAt: now())
    cleanGeneration.observeState(.running)
    errorGeneration.observeTerminalRuntimeError(failure, state: .error, occurredAt: now())
    errorGeneration.observeTerminalRuntimeError(failure, state: .error, occurredAt: now())
    errorGeneration.observeState(.running)

    wait(for: [delivered], timeout: 1)
    queue.sync {}
    XCTAssertEqual(
      recorder.snapshot,
      [
        .stateChanged(occurredAt: now(), state: .stopped),
        .cleanShutdown(occurredAt: now(), state: .stopped),
        .stateChanged(occurredAt: now(), state: .error),
        .runtimeError(
          occurredAt: now(),
          state: .error,
          error: RuntimeEventError(
            classification: .virtualMachineStopped,
            kind: .virtualization,
            message: "virtual machine stopped unexpectedly",
            domain: "VZErrorDomain",
            code: 17)),
      ])
  }

  func testDelegateReadsStateOnVzQueueButDeliversSinkOffQueue() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.affinity")
    let delivered = expectation(description: "state and clean shutdown delivered")
    delivered.expectedFulfillmentCount = 2
    let generation = RuntimeEventGeneration(queue: queue) { _ in
      XCTAssertFalse(queue.isCurrent)
      delivered.fulfill()
    }
    let mapper = VzDelegateEventMapper(queue: queue, generation: generation)

    queue.sync {
      mapper.guestDidStop {
        XCTAssertTrue(queue.isCurrent)
        return .stopped
      }
    }

    wait(for: [delivered], timeout: 1)
  }

  func testDelegateCallbacksMapToCleanShutdownAndClassifiedRuntimeError() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.delegate-mapping")
    let delivered = expectation(description: "delegate events delivered")
    delivered.expectedFulfillmentCount = 4
    let recorder = RuntimeEventRecorder()
    let now = { Date(timeIntervalSince1970: 2_500) }
    let delivery = RuntimeEventDelivery {
      recorder.append($0)
      delivered.fulfill()
    }
    let cleanGeneration = RuntimeEventGeneration(queue: queue, now: now, delivery: delivery)
    let errorGeneration = RuntimeEventGeneration(queue: queue, now: now, delivery: delivery)
    let cleanMapper = VzDelegateEventMapper(queue: queue, generation: cleanGeneration, now: now)
    let errorMapper = VzDelegateEventMapper(queue: queue, generation: errorGeneration, now: now)
    let error = NSError(
      domain: "VZErrorDomain", code: 22,
      userInfo: [
        NSLocalizedDescriptionKey: "runtime failed"
      ])

    queue.sync {
      cleanMapper.guestDidStop { .stopped }
      errorMapper.didStopWithError(error) { .error }
    }

    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(recorder.snapshot[1], .cleanShutdown(occurredAt: now(), state: .stopped))
    XCTAssertEqual(
      recorder.snapshot[3],
      .runtimeError(
        occurredAt: now(),
        state: .error,
        error: RuntimeEventError(
          classification: .virtualMachineStopped,
          kind: .virtualization,
          message: "runtime failed",
          domain: "VZErrorDomain",
          code: 22)))
  }

  func testCommandErrorDoesNotSuppressCanonicalDelegateTerminalCause() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.command-then-delegate")
    let delivered = expectation(description: "command error and delegate terminal cause delivered")
    delivered.expectedFulfillmentCount = 3
    let recorder = RuntimeEventRecorder()
    let commandAt = Date(timeIntervalSince1970: 2_600)
    let delegateAt = Date(timeIntervalSince1970: 2_601)
    let generation = RuntimeEventGeneration(queue: queue) {
      recorder.append($0)
      delivered.fulfill()
    }
    let mapper = VzDelegateEventMapper(
      queue: queue, generation: generation, now: { delegateAt })
    let commandError = NSError(domain: "VZErrorDomain", code: 30)
    let delegateError = NSError(domain: "VZErrorDomain", code: 31)

    generation.observeCommandError(
      commandError,
      classification: .startFailed,
      kind: .virtualization,
      state: .stopped,
      occurredAt: commandAt)
    queue.sync {
      mapper.didStopWithError(delegateError) { .error }
    }

    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(
      recorder.snapshot.map(\.summary),
      [
        "error:startFailed:stopped:2600.0",
        "state:error:2601.0",
        "error:virtualMachineStopped:error:2601.0",
      ])
  }

  func testDelegateTerminalCauseRemainsCanonicalWhenCommandErrorArrivesLater() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.delegate-then-command")
    let delivered = expectation(description: "only the delegate terminal cause is delivered")
    delivered.expectedFulfillmentCount = 2
    delivered.assertForOverFulfill = true
    let recorder = RuntimeEventRecorder()
    let delegateAt = Date(timeIntervalSince1970: 2_700)
    let commandAt = Date(timeIntervalSince1970: 2_701)
    let generation = RuntimeEventGeneration(queue: queue) {
      recorder.append($0)
      delivered.fulfill()
    }
    let mapper = VzDelegateEventMapper(
      queue: queue, generation: generation, now: { delegateAt })
    let delegateError = NSError(domain: "VZErrorDomain", code: 40)
    let commandError = NSError(domain: "VZErrorDomain", code: 41)

    queue.sync {
      mapper.didStopWithError(delegateError) { .error }
    }
    generation.observeCommandError(
      commandError,
      classification: .startFailed,
      kind: .virtualization,
      state: .stopped,
      occurredAt: commandAt)

    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(
      recorder.snapshot.map(\.summary),
      [
        "state:error:2700.0",
        "error:virtualMachineStopped:error:2700.0",
      ])
  }

  func testTerminalCauseDoesNotRepeatAnAlreadyObservedTerminalState() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.terminal-state-dedupe")
    let delivered = expectation(description: "state then terminal cause")
    delivered.expectedFulfillmentCount = 2
    delivered.assertForOverFulfill = true
    let recorder = RuntimeEventRecorder()
    let occurredAt = Date(timeIntervalSince1970: 2_750)
    let generation = RuntimeEventGeneration(queue: queue) {
      recorder.append($0)
      delivered.fulfill()
    }

    generation.observeState(.stopped)
    queue.sync {}
    generation.observeTerminalCleanShutdown(state: .stopped, occurredAt: occurredAt)

    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(recorder.snapshot.count, 2)
    XCTAssertEqual(
      recorder.snapshot.last,
      .cleanShutdown(occurredAt: occurredAt, state: .stopped))
  }

  func testDelegateCapturesStateAndSingleTimestampBeforeDeferredEventHandling() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.delegate-capture")
    let delivered = expectation(description: "captured delegate pair delivered")
    delivered.expectedFulfillmentCount = 2
    let recorder = RuntimeEventRecorder()
    let capturedAt = Date(timeIntervalSince1970: 2_800)
    var timestampCalls = 0
    var callbackState = RuntimeObservedState.stopped
    let generation = RuntimeEventGeneration(queue: queue) {
      recorder.append($0)
      delivered.fulfill()
    }
    let mapper = VzDelegateEventMapper(
      queue: queue,
      generation: generation,
      now: {
        timestampCalls += 1
        return capturedAt
      })

    queue.sync {
      mapper.guestDidStop { callbackState }
    }
    callbackState = .running

    wait(for: [delivered], timeout: 1)
    XCTAssertEqual(timestampCalls, 1)
    XCTAssertEqual(
      recorder.snapshot,
      [
        .stateChanged(occurredAt: capturedAt, state: .stopped),
        .cleanShutdown(occurredAt: capturedAt, state: .stopped),
      ])
  }

  func testRetryabilityComesFromErrorKind() {
    let makeError = { (kind: RuntimeErrorKind) in
      RuntimeEventError(
        classification: .startFailed,
        kind: kind,
        message: "failure",
        domain: "test",
        code: 1)
    }

    XCTAssertFalse(makeError(.invalidConfiguration).retryable)
    XCTAssertFalse(makeError(.invalidState).retryable)
    XCTAssertFalse(makeError(.protocolViolation).retryable)
    XCTAssertFalse(makeError(.internalFailure).retryable)
    XCTAssertTrue(makeError(.virtualization).retryable)
    XCTAssertTrue(makeError(.io).retryable)
    XCTAssertTrue(makeError(.timeout).retryable)

    XCTAssertEqual(
      runtimeErrorKind(
        for: DriverError.invalidArgs("bad config"),
        invalidArgumentKind: .invalidConfiguration,
        defaultKind: .internalFailure),
      .invalidConfiguration)
    XCTAssertEqual(
      runtimeErrorKind(
        for: DriverError.protocolViolation("bad frame"),
        invalidArgumentKind: .invalidState,
        defaultKind: .internalFailure),
      .protocolViolation)
    XCTAssertEqual(
      runtimeErrorKind(
        for: NSError(domain: "VZErrorDomain", code: 1),
        invalidArgumentKind: .invalidState,
        defaultKind: .internalFailure),
      .virtualization)
    for code in [2, 5, 10] {
      XCTAssertEqual(
        runtimeErrorKind(
          for: NSError(domain: "VZErrorDomain", code: code),
          invalidArgumentKind: .invalidState,
          defaultKind: .internalFailure),
        .invalidConfiguration)
    }
    for code in [3, 4, 9] {
      XCTAssertEqual(
        runtimeErrorKind(
          for: NSError(domain: "VZErrorDomain", code: code),
          invalidArgumentKind: .invalidConfiguration,
          defaultKind: .internalFailure),
        .invalidState)
    }
    for code in [6, 7, 8] {
      XCTAssertEqual(
        runtimeErrorKind(
          for: NSError(domain: "VZErrorDomain", code: code),
          invalidArgumentKind: .invalidState,
          defaultKind: .internalFailure),
        .virtualization)
    }
    XCTAssertEqual(
      runtimeErrorKind(
        for: DriverError.io("disk unavailable"),
        invalidArgumentKind: .invalidState,
        defaultKind: .internalFailure),
      .io)
  }

  func testConfigureOnlyUsesConfiguredStateWithoutALiveVm() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.configure-state")
    let delivered = expectation(description: "configuration states delivered")
    delivered.expectedFulfillmentCount = 2
    delivered.assertForOverFulfill = true
    let recorder = RuntimeEventRecorder()
    let now = { Date(timeIntervalSince1970: 2_900) }
    let delivery = RuntimeEventDelivery {
      recorder.append($0)
      delivered.fulfill()
    }
    let liveGeneration = RuntimeEventGeneration(queue: queue, now: now, delivery: delivery)
    let idleGeneration = RuntimeEventGeneration(queue: queue, now: now, delivery: delivery)

    liveGeneration.observeState(.running)
    liveGeneration.observeConfiguration(currentRuntimeState: .running)
    idleGeneration.observeConfiguration(currentRuntimeState: nil)

    wait(for: [delivered], timeout: 1)
    queue.sync {}
    XCTAssertEqual(
      recorder.snapshot,
      [
        .stateChanged(occurredAt: now(), state: .running),
        .stateChanged(occurredAt: now(), state: .configured),
      ])
  }

  func testBlockedSinkCannotBlockVzQueueAndDeliveryOrderIsPreserved() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.nonblocking-delivery")
    let firstDeliveryStarted = expectation(description: "first delivery started")
    let queueRemainedResponsive = expectation(description: "VZ queue remained responsive")
    let allDelivered = expectation(description: "all events delivered")
    allDelivered.expectedFulfillmentCount = 2
    let sink = BlockingRuntimeEventSink {
      firstDeliveryStarted.fulfill()
    } onEvent: {
      allDelivered.fulfill()
    }
    let generation = RuntimeEventGeneration(queue: queue, sink: sink.receive)

    generation.observeState(.starting)
    wait(for: [firstDeliveryStarted], timeout: 1)

    generation.observeState(.running)
    queue.async { queueRemainedResponsive.fulfill() }
    let responsiveness = XCTWaiter().wait(for: [queueRemainedResponsive], timeout: 1)
    sink.releaseFirstDelivery()

    XCTAssertEqual(responsiveness, .completed)
    wait(for: [allDelivered], timeout: 1)
    XCTAssertEqual(
      sink.events.map(\.summary),
      [
        "state:starting:\(sink.events[0].occurredAt.timeIntervalSince1970)",
        "state:running:\(sink.events[1].occurredAt.timeIntervalSince1970)",
      ])
  }

  func testLateEventsAreIgnoredAfterGenerationIsPoisonedOrClosed() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.closed")
    let delivered = expectation(description: "only pre-close events delivered")
    delivered.expectedFulfillmentCount = 2
    delivered.assertForOverFulfill = true
    let recorder = RuntimeEventRecorder()
    let now = { Date(timeIntervalSince1970: 3_000) }
    let delivery = RuntimeEventDelivery {
      recorder.append($0)
      delivered.fulfill()
    }
    let poisoned = RuntimeEventGeneration(queue: queue, now: now, delivery: delivery)
    let closed = RuntimeEventGeneration(queue: queue, now: now, delivery: delivery)
    let lateError = NSError(domain: "late", code: 1)

    poisoned.observeState(.starting)
    poisoned.poison()
    poisoned.observeState(.running)
    poisoned.observeCommandError(
      lateError,
      classification: .startFailed,
      kind: .virtualization,
      state: .error,
      occurredAt: now())

    closed.observeState(.running)
    closed.close()
    closed.observeTerminalCleanShutdown(state: .stopped, occurredAt: now())
    closed.observeState(.stopped)

    wait(for: [delivered], timeout: 1)
    queue.sync {}
    XCTAssertEqual(
      recorder.snapshot,
      [
        .stateChanged(occurredAt: now(), state: .starting),
        .stateChanged(occurredAt: now(), state: .running),
      ])
  }

  func testDelegateLifetimeRetainsUntilRuntimeGenerationIsReleased() {
    let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.delegate-lifetime")
    let lifetime = VzDelegateLifetime(queue: queue)
    #if canImport(Virtualization)
      let generation = RuntimeEventGeneration(queue: queue) { _ in }
      weak var weakDelegate: VzVirtualMachineDelegateAdapter?

      queue.sync {
        var delegate: VzVirtualMachineDelegateAdapter? = VzVirtualMachineDelegateAdapter(
          queue: queue, generation: generation)
        weakDelegate = delegate
        lifetime.retain(delegate!)
        delegate = nil
        XCTAssertNotNil(weakDelegate)

        lifetime.release()
        XCTAssertNil(weakDelegate)
      }
    #endif
  }

  #if canImport(Virtualization)
    func testVirtualizationDelegateAdapterIsRealAndMapsAllVzStates() {
      let queue = VzRuntimeQueue(label: "test.gaovm.runtime-events.real-delegate")
      let generation = RuntimeEventGeneration(queue: queue) { _ in }
      let adapter = VzVirtualMachineDelegateAdapter(queue: queue, generation: generation)
      let protocolDelegate: VZVirtualMachineDelegate = adapter

      XCTAssertTrue(protocolDelegate === adapter)
      XCTAssertEqual(runtimeObservedState(from: .stopped), .stopped)
      XCTAssertEqual(runtimeObservedState(from: .running), .running)
      XCTAssertEqual(runtimeObservedState(from: .paused), .running)
      XCTAssertEqual(runtimeObservedState(from: .error), .error)
      XCTAssertEqual(runtimeObservedState(from: .starting), .starting)
      XCTAssertEqual(runtimeObservedState(from: .pausing), .running)
      XCTAssertEqual(runtimeObservedState(from: .resuming), .running)
      XCTAssertEqual(runtimeObservedState(from: .stopping), .stopping)
      XCTAssertEqual(runtimeObservedState(from: .saving), .stopping)
      XCTAssertEqual(runtimeObservedState(from: .restoring), .starting)
    }
  #endif

  func testVzRuntimePublishesConfigurationObservationThroughInjectedSink() {
    let configured = expectation(description: "configure completed")
    let eventDelivered = expectation(description: "configured event delivered")
    let occurredAt = Date(timeIntervalSince1970: 4_000)
    let runtime = VzRuntime(
      logger: RotatingLogger(path: NSTemporaryDirectory() + "/gaovm-pr012-test.log"),
      now: { occurredAt },
      eventSink: { event in
        XCTAssertEqual(event, .stateChanged(occurredAt: occurredAt, state: .configured))
        eventDelivered.fulfill()
      })

    runtime.configure(
      with: [
        "cpu": 2,
        "memory": 1_073_741_824,
        "boot": ["loader": "linux", "kernelPath": "/tmp/kernel"],
        "disk": ["path": "/tmp/disk.img", "sizeMiB": 64],
        "network": ["mode": "shared"],
        "graphics": ["enabled": false],
      ]
    ) { result in
      if case .failure(let error) = result {
        XCTFail("configure failed: \(error)")
      }
      configured.fulfill()
    }

    wait(for: [configured, eventDelivered], timeout: 1)
  }
}

private final class RuntimeEventRecorder {
  private let lock = NSLock()
  private var events: [RuntimeEvent] = []

  var snapshot: [RuntimeEvent] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }

  func append(_ event: RuntimeEvent) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }
}

private final class BlockingRuntimeEventSink {
  private let condition = NSCondition()
  private let onFirstStart: () -> Void
  private let onEvent: () -> Void
  private var releaseFirst = false
  private var recordedEvents: [RuntimeEvent] = []

  init(onFirstStart: @escaping () -> Void, onEvent: @escaping () -> Void) {
    self.onFirstStart = onFirstStart
    self.onEvent = onEvent
  }

  var events: [RuntimeEvent] {
    condition.lock()
    defer { condition.unlock() }
    return recordedEvents
  }

  func receive(_ event: RuntimeEvent) {
    condition.lock()
    recordedEvents.append(event)
    let isFirst = recordedEvents.count == 1
    condition.unlock()

    if isFirst {
      onFirstStart()
      condition.lock()
      while !releaseFirst {
        condition.wait()
      }
      condition.unlock()
    }
    onEvent()
  }

  func releaseFirstDelivery() {
    condition.lock()
    releaseFirst = true
    condition.broadcast()
    condition.unlock()
  }
}

extension RuntimeEvent {
  fileprivate var occurredAt: Date {
    switch self {
    case .stateChanged(let occurredAt, _), .cleanShutdown(let occurredAt, _),
      .runtimeError(let occurredAt, _, _):
      return occurredAt
    }
  }

  fileprivate var summary: String {
    switch self {
    case .stateChanged(let occurredAt, let state):
      return "state:\(state.rawValue):\(occurredAt.timeIntervalSince1970)"
    case .cleanShutdown(let occurredAt, let state):
      return "clean:\(state.rawValue):\(occurredAt.timeIntervalSince1970)"
    case .runtimeError(let occurredAt, let state, let error):
      return
        "error:\(error.classification.rawValue):\(state.rawValue):\(occurredAt.timeIntervalSince1970)"
    }
  }
}
