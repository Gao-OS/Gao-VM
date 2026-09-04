import Foundation
#if canImport(AppKit)
import AppKit
#endif
import Darwin

func parseArgs(_ args: [String]) throws -> Config {
    var socketPath: String?
    var idx = 1
    while idx < args.count {
        let arg = args[idx]
        switch arg {
        case "--socket-path":
            idx += 1
            guard idx < args.count else { throw DriverError.invalidArgs("missing value for --socket-path") }
            socketPath = args[idx]
        case "--auth-token":
            idx += 1
            guard idx < args.count else { throw DriverError.invalidArgs("missing value for --auth-token") }
            // M4 contract: token must come from env, not CLI. Consume but reject to avoid accidental insecure usage.
            throw DriverError.invalidArgs("--auth-token is not supported; set GAOVM_AUTH_TOKEN")
        case "--help":
            print("Usage: gaovm-driver-vz --socket-path PATH")
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
    guard let authToken = ProcessInfo.processInfo.environment["GAOVM_AUTH_TOKEN"], !authToken.isEmpty else {
        throw DriverError.authMissing
    }
    let logPath = ProcessInfo.processInfo.environment["GAOVM_DRIVER_LOG_PATH"] ?? "\(NSTemporaryDirectory())/gaovm-driver-vz.log"
    return Config(socketPath: socketPath, authToken: authToken, logPath: logPath)
}

do {
    let config = try parseArgs(CommandLine.arguments)
    let logger = RotatingLogger(path: config.logPath)
    logger.log(.info, "driver bootstrap")
    let driver = DriverSession(config: config, logger: logger)
#if canImport(AppKit)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let driverQueue = DispatchQueue(label: "gaovm.driver.rpc", qos: .userInitiated)
    driverQueue.async {
        do {
            try driver.run()
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
    try driver.run()
#endif
} catch {
    fputs("[gaovm-driver-vz] fatal: \(error)\n", stderr)
    Foundation.exit(1)
}
