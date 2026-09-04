import Foundation

protocol SocketWriteTransport: AnyObject {
  func writeAll(_ data: Data) throws
  func interrupt()
  func close()
}

final class SerializedSocketWriter {
  private let ownershipQueue = DispatchQueue(label: "gaovm.driver.socket-writer")
  private let stateLock = NSLock()
  private var transport: SocketWriteTransport?
  private var closing = false

  init(transport: SocketWriteTransport? = nil) {
    self.transport = transport
  }

  func attach(_ transport: SocketWriteTransport) throws {
    try ownershipQueue.sync {
      self.stateLock.lock()
      defer { self.stateLock.unlock() }
      guard !closing else {
        throw DriverError.io("control socket writer is closing")
      }
      guard self.transport == nil else {
        throw DriverError.io("control socket writer already has a socket")
      }
      self.transport = transport
    }
  }

  func write(_ data: Data) throws {
    try ownershipQueue.sync {
      self.stateLock.lock()
      guard !closing, let transport else {
        self.stateLock.unlock()
        throw DriverError.io("control socket writer is closing")
      }
      self.stateLock.unlock()
      try transport.writeAll(data)
    }
  }

  func close() {
    stateLock.lock()
    guard !closing else {
      stateLock.unlock()
      return
    }
    closing = true
    let transport = self.transport
    stateLock.unlock()

    transport?.interrupt()
    ownershipQueue.async {
      self.stateLock.lock()
      self.transport = nil
      self.stateLock.unlock()
      transport?.close()
    }
  }
}
