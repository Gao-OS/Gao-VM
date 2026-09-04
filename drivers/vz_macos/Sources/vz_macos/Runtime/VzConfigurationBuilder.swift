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

        let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: spec.kernelPath))
        if let initrd = spec.initrdPath {
            bootLoader.initialRamdiskURL = URL(fileURLWithPath: initrd)
        }
        if let cmdline = spec.commandLine, !cmdline.isEmpty {
            bootLoader.commandLine = cmdline
        }
        cfg.bootLoader = bootLoader

        let nat = VZNATNetworkDeviceAttachment()
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = nat
        cfg.networkDevices = [net]

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: spec.diskPath),
            readOnly: false
        )
        cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

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
            kernelPath: kernelPath,
            initrdPath: strOpt(boot, "initrdPath"),
            commandLine: strOpt(boot, "commandLine"),
            diskPath: diskPath,
            diskSizeMiB: diskSizeMiB,
            graphicsEnabled: try bool(graphics, "enabled"),
            graphicsWidth: (graphics["width"] as? Int) ?? (graphics["width"] as? NSNumber)?.intValue ?? 1280,
            graphicsHeight: (graphics["height"] as? Int) ?? (graphics["height"] as? NSNumber)?.intValue ?? 800
        )
    }

    func currentNormalizedConfig() throws -> NormalizedVmConfig {
        guard let config else {
            throw DriverError.invalidArgs("vm is not configured")
        }
        return try normalizedConfig(config)
    }

    func onVzRuntimeQueue<T>(_ work: () throws -> T) rethrows -> T {
        try vzRuntimeQueue.sync(work)
    }
}

struct NormalizedVmConfig {
    let cpu: Int
    let memoryBytes: Int
    let kernelPath: String
    let initrdPath: String?
    let commandLine: String?
    let diskPath: String
    let diskSizeMiB: Int
    let graphicsEnabled: Bool
    let graphicsWidth: Int
    let graphicsHeight: Int
}
