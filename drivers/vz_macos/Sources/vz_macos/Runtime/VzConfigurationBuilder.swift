import Foundation

#if canImport(Virtualization)
  import Virtualization
#endif

extension VzRuntime {
  #if canImport(Virtualization)
    @available(macOS 14.0, *)
    func buildConfiguration(_ spec: NormalizedVmConfig) throws -> VZVirtualMachineConfiguration {
      vzRuntimeQueue.preconditionIsCurrent()
      let cfg = VZVirtualMachineConfiguration()
      cfg.cpuCount = spec.cpu
      cfg.memorySize = UInt64(spec.memoryBytes)

      switch spec.boot {
      case .linux(let boot):
        let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: boot.kernelPath))
        if let initrd = boot.initrdPath {
          bootLoader.initialRamdiskURL = URL(fileURLWithPath: initrd)
        }
        if !boot.commandLine.isEmpty {
          bootLoader.commandLine = boot.commandLine
        }
        cfg.bootLoader = bootLoader
      case .efi(let variableStorePath):
        let url = URL(fileURLWithPath: variableStorePath)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let variableStore =
          if FileManager.default.fileExists(atPath: variableStorePath) {
            VZEFIVariableStore(url: url)
          } else {
            try VZEFIVariableStore(creatingVariableStoreAt: url)
          }
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = variableStore
        cfg.bootLoader = bootLoader
      }

      cfg.networkDevices = try spec.networks.compactMap { network in
        guard network.mode == .shared else { return nil }
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        guard let macAddress = network.macAddress,
          let typedAddress = VZMACAddress(string: macAddress)
        else {
          throw DriverError.invalidArgs("shared network \(network.id) requires a valid MAC")
        }
        device.macAddress = typedAddress
        return device
      }

      cfg.storageDevices = try spec.disks.map { disk in
        let attachment = try VZDiskImageStorageDeviceAttachment(
          url: URL(fileURLWithPath: disk.path), readOnly: !disk.writable)
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
      }
      cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

      if let serial = spec.serial {
        let port = VZVirtioConsoleDeviceSerialPortConfiguration()
        let output: FileHandle
        if serial.capture {
          let controller = try SerialController(path: serial.logPath)
          serialController?.close()
          serialController = controller
          controller.start()
          output = controller.driverOutput
        } else {
          serialController?.close()
          serialController = nil
          output = .nullDevice
        }
        port.attachment = VZFileHandleSerialPortAttachment(
          fileHandleForReading: .nullDevice, fileHandleForWriting: output)
        cfg.serialPorts = [port]
      } else {
        cfg.serialPorts = []
      }

      cfg.socketDevices = spec.guestAgent == nil ? [] : [VZVirtioSocketDeviceConfiguration()]

      if spec.graphicsEnabled {
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
          VZVirtioGraphicsScanoutConfiguration(
            widthInPixels: spec.graphicsWidth,
            heightInPixels: spec.graphicsHeight
          )
        ]
        cfg.graphicsDevices = [graphics]
        cfg.keyboards = [VZUSBKeyboardConfiguration()]
        cfg.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
      } else {
        cfg.graphicsDevices = []
        cfg.keyboards = []
        cfg.pointingDevices = []
      }

      try cfg.validate()
      return cfg
    }
  #endif

  func ensureSparseDisk(_ path: String, sizeMiB: Int) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: path) { return }
    let url = URL(fileURLWithPath: path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard fm.createFile(atPath: path, contents: nil) else {
      throw DriverError.io("failed to create disk image: \(path)")
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024)
    logger.log(.info, "created sparse disk at \(path) sizeMiB=\(sizeMiB)")
  }

  func normalizedConfig(_ root: [String: Any]) throws -> NormalizedVmConfig {
    func dict(_ parent: [String: Any], _ key: String) throws -> [String: Any] {
      guard let value = parent[key] as? [String: Any] else {
        throw DriverError.invalidArgs("config.\(key) must be object")
      }
      return value
    }
    func int(_ parent: [String: Any], _ key: String) throws -> Int {
      if let value = parent[key] as? Int { return value }
      if let value = parent[key] as? NSNumber { return value.intValue }
      throw DriverError.invalidArgs("config.\(key) must be int")
    }
    func strOpt(_ parent: [String: Any], _ key: String) -> String? {
      if let value = parent[key] as? String, !value.isEmpty { return value }
      return nil
    }
    func bool(_ parent: [String: Any], _ key: String) throws -> Bool {
      if let value = parent[key] as? Bool { return value }
      if let value = parent[key] as? NSNumber { return value.boolValue }
      throw DriverError.invalidArgs("config.\(key) must be bool")
    }

    let cpu = try int(root, "cpu")
    let memory = try int(root, "memory")
    let boot = try dict(root, "boot")
    let disk = try dict(root, "disk")
    let network = try dict(root, "network")
    let graphics = try dict(root, "graphics")

    guard (boot["loader"] as? String) == "linux" || (boot["loader"] as? String) == "auto" else {
      throw DriverError.invalidArgs("config.boot.loader must be linux or auto")
    }
    guard let kernelPath = strOpt(boot, "kernelPath") else {
      throw DriverError.invalidArgs("config.boot.kernelPath is required for VZLinuxBootLoader")
    }
    guard let diskPath = strOpt(disk, "path") else {
      throw DriverError.invalidArgs("config.disk.path is required")
    }
    let diskSizeMiB = (disk["sizeMiB"] as? Int) ?? (disk["sizeMiB"] as? NSNumber)?.intValue ?? 8192
    let networkMode = (network["mode"] as? String) ?? "shared"
    guard networkMode == "shared" else {
      throw DriverError.invalidArgs("Only network.mode=shared is supported in v1.2")
    }

    return NormalizedVmConfig(
      cpu: cpu,
      memoryBytes: memory,
      boot: .linux(
        .init(
          kernelPath: kernelPath,
          initrdPath: strOpt(boot, "initrdPath"),
          commandLine: strOpt(boot, "commandLine") ?? "")),
      disks: [
        .init(id: "root", path: diskPath, writable: true, createSizeMiB: diskSizeMiB)
      ],
      networks: [.init(id: "net0", mode: .shared, macAddress: nil)],
      graphicsEnabled: try bool(graphics, "enabled"),
      graphicsWidth: (graphics["width"] as? Int) ?? (graphics["width"] as? NSNumber)?.intValue
        ?? 1280,
      graphicsHeight: (graphics["height"] as? Int) ?? (graphics["height"] as? NSNumber)?.intValue
        ?? 800,
      serial: nil,
      guestAgent: nil,
      bundlePath: nil
    )
  }

  func currentNormalizedConfig() throws -> NormalizedVmConfig {
    guard let config else {
      throw DriverError.invalidArgs("vm is not configured")
    }
    return config
  }

  func onVzRuntimeQueue<T>(_ work: () throws -> T) rethrows -> T {
    try vzRuntimeQueue.sync(work)
  }
}

enum NormalizedBoot: Equatable {
  case linux(NormalizedLinuxBoot)
  case efi(variableStorePath: String)
}

struct NormalizedLinuxBoot: Equatable {
  let kernelPath: String
  let initrdPath: String?
  let commandLine: String
}

struct NormalizedDisk: Equatable {
  let id: String
  let path: String
  let writable: Bool
  let createSizeMiB: Int?
}

struct NormalizedNetwork: Equatable {
  enum Mode: Equatable { case shared, none }

  let id: String
  let mode: Mode
  let macAddress: String?
}

struct NormalizedSerial: Equatable {
  let capture: Bool
  let logPath: String
}

struct NormalizedGuestAgent: Equatable {
  let vsockPort: UInt32
}

struct NormalizedVmConfig: Equatable {
  let cpu: Int
  let memoryBytes: Int
  let boot: NormalizedBoot
  let disks: [NormalizedDisk]
  let networks: [NormalizedNetwork]
  let graphicsEnabled: Bool
  let graphicsWidth: Int
  let graphicsHeight: Int
  let serial: NormalizedSerial?
  let guestAgent: NormalizedGuestAgent?
  let bundlePath: String?

  init(
    cpu: Int,
    memoryBytes: Int,
    boot: NormalizedBoot,
    disks: [NormalizedDisk],
    networks: [NormalizedNetwork],
    graphicsEnabled: Bool,
    graphicsWidth: Int,
    graphicsHeight: Int,
    serial: NormalizedSerial?,
    guestAgent: NormalizedGuestAgent?,
    bundlePath: String?
  ) {
    self.cpu = cpu
    self.memoryBytes = memoryBytes
    self.boot = boot
    self.disks = disks
    self.networks = networks
    self.graphicsEnabled = graphicsEnabled
    self.graphicsWidth = graphicsWidth
    self.graphicsHeight = graphicsHeight
    self.serial = serial
    self.guestAgent = guestAgent
    self.bundlePath = bundlePath
  }

  init(v2 value: DriverProtocolV2.RuntimeConfiguration) throws {
    guard value.architecture == "arm64" else {
      throw DriverError.invalidArgs("only arm64 is supported")
    }
    func requireAbsolute(_ path: String, _ name: String) throws -> String {
      guard path.hasPrefix("/") else {
        throw DriverError.invalidArgs("\(name) must be absolute")
      }
      return path
    }
    cpu = value.cpu
    memoryBytes = Int(value.memoryBytes)
    boot =
      switch value.boot {
      case .linuxKernel(let boot):
        .linux(
          .init(
            kernelPath: try requireAbsolute(boot.kernelPath, "kernel path"),
            initrdPath: try boot.initrdPath.map { try requireAbsolute($0, "initrd path") },
            commandLine: boot.commandLine))
      case .efi(let boot):
        .efi(
          variableStorePath: try requireAbsolute(
            boot.variableStorePath, "EFI variable store"))
      }
    disks = try value.disks.map {
      .init(
        id: $0.id, path: try requireAbsolute($0.path, "disk path"), writable: $0.writable,
        createSizeMiB: nil)
    }
    networks = value.networks.map {
      .init(
        id: $0.id, mode: $0.mode == .shared ? .shared : .none,
        macAddress: $0.macAddress)
    }
    graphicsEnabled = value.graphics.enabled
    graphicsWidth = value.graphics.width ?? 1280
    graphicsHeight = value.graphics.height ?? 800
    serial =
      value.serial.enabled
      ? .init(
        capture: value.serial.capture,
        logPath: try requireAbsolute(value.serial.logPath, "serial log path")) : nil
    guestAgent = value.guestAgent.enabled ? .init(vsockPort: value.guestAgent.vsockPort) : nil
    bundlePath = try requireAbsolute(value.bundlePath, "bundle path")
  }
}
