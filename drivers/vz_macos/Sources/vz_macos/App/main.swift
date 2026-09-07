import Darwin
import Foundation

#if canImport(AppKit)
  import AppKit
#endif

enum DriverLaunchMode {
  case legacy(LegacyConfig)
  case v2(Config)

  var logPath: String {
    switch self {
    case .legacy(let config): config.logPath
    case .v2(let config): config.logPath
    }
  }
}

func parseArgs(_ args: [String]) throws -> DriverLaunchMode {
  let environment = ProcessInfo.processInfo.environment
  let logPath =
    environment["GAOVM_DRIVER_LOG_PATH"]
    ?? "\(NSTemporaryDirectory())/gaovm-driver-vz.log"
  if args.count == 3, args[1] == "--socket-path" {
    let socketPath = args[2]
    guard socketPath.hasPrefix("/") else {
      throw DriverError.invalidArgs("legacy socket path must be absolute")
    }
    guard let authToken = environment["GAOVM_AUTH_TOKEN"], !authToken.isEmpty,
      authToken.utf8.count <= 1024
    else { throw DriverError.authMissing }
    // Transitional production boundary: the legacy daemon launches exactly
    // `--socket-path PATH` until its PR017/PR019 composition switches to v2.
    return .legacy(
      LegacyConfig(socketPath: socketPath, authToken: authToken, logPath: logPath))
  }
  var vmId: String?
  var generation: Int?
  var socketPath: String?
  var bundlePath: String?
  var backend: String?
  var idx = 1
  while idx < args.count {
    let arg = args[idx]
    switch arg {
    case "--vm-id":
      idx += 1
      guard idx < args.count else { throw DriverError.invalidArgs("missing value for --vm-id") }
      vmId = args[idx]
    case "--generation":
      idx += 1
      guard idx < args.count, let value = Int(args[idx]) else {
        throw DriverError.invalidArgs("--generation requires an integer")
      }
      generation = value
    case "--socket-path":
      idx += 1
      guard idx < args.count else {
        throw DriverError.invalidArgs("missing value for --socket-path")
      }
      socketPath = args[idx]
    case "--bundle-path":
      idx += 1
      guard idx < args.count else {
        throw DriverError.invalidArgs("missing value for --bundle-path")
      }
      bundlePath = args[idx]
    case "--backend":
      idx += 1
      guard idx < args.count else { throw DriverError.invalidArgs("missing value for --backend") }
      backend = args[idx]
    case "--auth-token":
      idx += 1
      guard idx < args.count else {
        throw DriverError.invalidArgs("missing value for --auth-token")
      }
      // Driver v2 requires the token in the environment, never process arguments.
      throw DriverError.invalidArgs("--auth-token is not supported; set GAOVM_AUTH_TOKEN")
    case "--help":
      print(
        "Usage: gaovm-driver-vz --vm-id ID --generation N --socket-path PATH --bundle-path PATH --backend vz"
      )
      print("Required env: GAOVM_AUTH_TOKEN")
      Foundation.exit(0)
    default:
      throw DriverError.invalidArgs("unknown argument: \(arg)")
    }
    idx += 1
  }
  guard let socketPath else {
    throw DriverError.invalidArgs("--socket-path is required")
  }
  guard let vmId, let generation, let bundlePath, backend == "vz" else {
    throw DriverError.invalidArgs(
      "--vm-id, --generation, --bundle-path, and --backend vz are required")
  }
  guard generation > 0, generation <= DriverProtocolV2.JSONRPCID.maximumInteger else {
    throw DriverError.invalidArgs("--generation is outside the v2 range")
  }
  guard socketPath.hasPrefix("/"), bundlePath.hasPrefix("/") else {
    throw DriverError.invalidArgs("socket and bundle paths must be absolute")
  }
  let typedVmId = try DriverProtocolV2.VMID(vmId)
  guard let authToken = environment["GAOVM_AUTH_TOKEN"],
    (32...1024).contains(authToken.utf8.count)
  else {
    throw DriverError.authMissing
  }
  return .v2(
    Config(
      vmId: typedVmId,
      generation: generation,
      socketPath: socketPath,
      bundlePath: bundlePath,
      authToken: authToken,
      logPath: logPath))
}

do {
  let launch = try parseArgs(CommandLine.arguments)
  let logger = RotatingLogger(path: launch.logPath)
  logger.log(.info, "driver bootstrap")
  let runDriver: () throws -> Void
  switch launch {
  case .legacy(let config):
    let driver = DriverSession(config: config, logger: logger)
    runDriver = { try driver.run() }
  case .v2(let config):
    let driver = DriverSessionV2(config: config, logger: logger)
    runDriver = { try driver.run() }
  }
  #if canImport(AppKit)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let driverQueue = DispatchQueue(label: "gaovm.driver.rpc", qos: .userInitiated)
    driverQueue.async {
      do {
        try runDriver()
      } catch {
        fputs("[gaovm-driver-vz] fatal: \(error)\n", stderr)
        DispatchQueue.main.async {
          NSApplication.shared.terminate(nil)
        }
        Foundation.exit(1)
      }
    }
    app.run()
  #else
    try runDriver()
  #endif
} catch {
  fputs("[gaovm-driver-vz] fatal: \(error)\n", stderr)
  Foundation.exit(1)
}
