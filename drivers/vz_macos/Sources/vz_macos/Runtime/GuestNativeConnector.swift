import Darwin
import Foundation

/// The external VZ connection boundary. Every access is runtime-queue confined.
protocol GuestNativeSocket: AnyObject {
  var fileDescriptor: Int32 { get }
  func close()
}

enum GuestNativeError: Error, Equatable {
  case unavailable, cancelled, deadlineExpired, limitExceeded
}

/// Native slots are retained through actual cleanup, including late completions.
/// Peer authentication and the eight pending opening limit belong to the listener.
/// Callbacks run on the runtime queue; schedule framing I/O elsewhere. An opened
/// failure is not a cleanup acknowledgement: only closed permits slot reuse.
final class GuestNativeConnector {
  typealias Connect = (@escaping (Result<GuestNativeSocket, Error>) -> Void) -> Void
  typealias Opened = (Result<GuestNativeChannel, GuestNativeError>) -> Void
  typealias BeforeNativeClose = (@escaping () -> Void) -> Void

  private let queue: VzRuntimeQueue
  private let connect: Connect
  private var workers: [UUID: GuestNativeConnectionWorker] = [:]
  private var active = true

  init(queue: VzRuntimeQueue, connect: @escaping Connect) {
    self.queue = queue
    self.connect = connect
  }

  /// Fence now; each opening's closed callback remains the actual cleanup barrier.
  func shutdown() {
    queue.sync {
      active = false
      for worker in Array(workers.values) { worker.refuse(.cancelled) }
    }
  }

  /// A caller retaining a raw client must acknowledge its actual close, not
  /// merely a scheduled cancellation, before the native VZ object is released.
  func open(
    streamKind: GuestBridgeProtocol.StreamKind, deadline: DispatchTime,
    beforeNativeClose: @escaping BeforeNativeClose = { $0() },
    opened: @escaping Opened, closed: @escaping () -> Void
  ) -> GuestNativeOpening {
    let identity = UUID()
    let worker = GuestNativeConnectionWorker(
      queue: queue, streamKind: streamKind, deadline: deadline,
      beforeNativeClose: beforeNativeClose, opened: opened,
      closed: { [weak self] in
        self?.workers.removeValue(forKey: identity)
        closed()
      })
    let opening = GuestNativeOpening(worker: worker)
    queue.async {
      guard self.active else { return worker.refuse(.unavailable) }
      let limit = streamKind == .control ? 1 : 2
      guard self.workers.values.filter({ $0.streamKind == streamKind }).count < limit else {
        return worker.refuse(.limitExceeded)
      }
      self.workers[identity] = worker
      worker.begin(connect: self.connect)
    }
    return opening
  }
}

/// Dropping an unresolved opening cancels it; success transfers owning custody.
final class GuestNativeOpening {
  private let worker: GuestNativeConnectionWorker
  fileprivate init(worker: GuestNativeConnectionWorker) { self.worker = worker }
  func cancel() { worker.cancel() }
  deinit { worker.abandonOpening() }
}

/// Start only after the authenticated ready frame has fully flushed and been stripped.
final class GuestNativeChannel {
  private let worker: GuestNativeConnectionWorker
  fileprivate init(worker: GuestNativeConnectionWorker) { self.worker = worker }

  func startRelay(
    clientDescriptor: Int32,
    completion: @escaping (Result<GuestBridgeRelay.End, GuestNativeError>) -> Void
  ) {
    worker.startRelay(clientDescriptor: clientDescriptor, completion: completion)
  }

  func cancel() { worker.cancel() }
  deinit { worker.cancel() }
}

private final class GuestNativeConnectionWorker {
  let streamKind: GuestBridgeProtocol.StreamKind
  private let queue: VzRuntimeQueue
  private let deadline: DispatchTime
  private var opened: GuestNativeConnector.Opened?
  private var beforeNativeClose: GuestNativeConnector.BeforeNativeClose?
  private var closed: (() -> Void)?
  private var native: GuestNativeSocket?
  private var descriptor: Int32 = -1
  private var relay: GuestBridgeRelay?
  private var awaitingNative = false
  private var awaitingClientCleanup = false
  private var failure: GuestNativeError?
  private var deadlineWork: DispatchWorkItem?
  private var finished = false
  private var lifetime: GuestNativeConnectionWorker?

  init(
    queue: VzRuntimeQueue, streamKind: GuestBridgeProtocol.StreamKind,
    deadline: DispatchTime,
    beforeNativeClose: @escaping GuestNativeConnector.BeforeNativeClose,
    opened: @escaping GuestNativeConnector.Opened,
    closed: @escaping () -> Void
  ) {
    self.queue = queue
    self.streamKind = streamKind
    self.deadline = deadline
    self.beforeNativeClose = beforeNativeClose
    self.opened = opened
    self.closed = closed
  }

  func begin(connect: GuestNativeConnector.Connect) {
    queue.preconditionIsCurrent()
    lifetime = self
    guard failure == nil else { return finish() }
    guard DispatchTime.now() < deadline else { return cancelLocked(.deadlineExpired) }
    let work = DispatchWorkItem { [weak self] in self?.cancelLocked(.deadlineExpired) }
    deadlineWork = work
    queue.dispatchQueue.asyncAfter(deadline: deadline, execute: work)
    awaitingNative = true
    connect { result in self.queue.async { self.accept(result) } }
  }

  func cancel() { queue.async { self.cancelLocked(.cancelled) } }

  func refuse(_ error: GuestNativeError) { cancelLocked(error) }

  func abandonOpening() {
    queue.async {
      if self.opened != nil { self.cancelLocked(.cancelled) }
    }
  }

  private func accept(_ result: Result<GuestNativeSocket, Error>) {
    queue.preconditionIsCurrent()
    awaitingNative = false
    switch result {
    case .failure: cancelLocked(.unavailable)
    case .success(let connection):
      native = connection
      guard failure == nil else {
        finishCancelledNative()
        return
      }
      guard DispatchTime.now() < deadline else { return cancelLocked(.deadlineExpired) }
      descriptor = Darwin.fcntl(connection.fileDescriptor, F_DUPFD_CLOEXEC, 3)
      guard descriptor >= 0 else { return cancelLocked(.unavailable) }
      let callback = opened
      opened = nil
      callback?(.success(GuestNativeChannel(worker: self)))
    }
  }

  func startRelay(
    clientDescriptor: Int32,
    completion: @escaping (Result<GuestBridgeRelay.End, GuestNativeError>) -> Void
  ) {
    queue.async {
      let expired = self.failure == nil && DispatchTime.now() >= self.deadline
      guard self.failure == nil, self.descriptor >= 0, !expired else {
        if clientDescriptor >= 0 {
          Darwin.shutdown(clientDescriptor, SHUT_RDWR)
          Darwin.close(clientDescriptor)
        }
        if expired { self.cancelLocked(.deadlineExpired) }
        completion(.failure(self.failure ?? .unavailable))
        return
      }
      let descriptor = self.descriptor
      self.descriptor = -1
      self.deadlineWork?.cancel()
      self.deadlineWork = nil
      // The relay now owns both raw descriptors and supplies its own close barrier.
      self.beforeNativeClose = nil
      self.relay = GuestBridgeRelay.start(
        clientDescriptor: clientDescriptor, guestDescriptor: descriptor,
        releaseNative: { done in
          self.queue.async {
            self.closeNative()
            done()
          }
        },
        completion: { end in
          self.queue.async {
            self.relay = nil
            self.finish()
            completion(.success(end))
          }
        })
    }
  }

  private func cancelLocked(_ error: GuestNativeError) {
    queue.preconditionIsCurrent()
    guard !finished else { return }
    if failure == nil { failure = error }
    deadlineWork?.cancel()
    deadlineWork = nil
    let callback = opened
    opened = nil
    callback?(.failure(failure ?? error))
    if let relay { return relay.cancel() }
    guard !awaitingNative else { return }
    if descriptor >= 0 {
      Darwin.shutdown(descriptor, SHUT_RDWR)
      Darwin.close(descriptor)
      descriptor = -1
    }
    finishCancelledNative()
  }

  private func finishCancelledNative() {
    queue.preconditionIsCurrent()
    guard native != nil else { return finish() }
    guard !awaitingClientCleanup else { return }
    awaitingClientCleanup = true
    let prepare = beforeNativeClose
    beforeNativeClose = nil
    guard let prepare else {
      closeNative()
      finish()
      return
    }
    prepare {
      self.queue.async {
        guard self.awaitingClientCleanup, !self.finished else { return }
        self.awaitingClientCleanup = false
        self.closeNative()
        self.finish()
      }
    }
  }

  private func closeNative() {
    queue.preconditionIsCurrent()
    native?.close()
    native = nil
  }

  private func finish() {
    queue.preconditionIsCurrent()
    guard !finished else { return }
    finished = true
    deadlineWork?.cancel()
    deadlineWork = nil
    beforeNativeClose = nil
    let callback = closed
    closed = nil
    callback?()
    lifetime = nil
  }
}
