import Darwin
import Foundation

@main
struct GaoVMService {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--component-info"] {
      do {
        try FileHandle.standardOutput.write(contentsOf: ServiceComponentInfo.encoded() + Data([10]))
      } catch { exit(1) }
      return
    }
    if arguments == ["--help"] {
      print(
        """
        Usage:
          gaovm-service --help
          gaovm-service status
          gaovm-service register
          gaovm-service unregister
        """)
      return
    }
    let action = ServiceAction(rawValue: arguments.count == 1 ? arguments[0] : "invalid")
    var result = ServiceResult(
      action: action?.rawValue ?? "invalid", bundleIdentifier: nil, state: nil,
      outcome: "failed", error: .invalidInvocation, exitCode: 2)
    if let action {
      do {
        let bundle = try ServiceBundle.current()
        try bundle.relaunchIfNeeded(action: action)
        result = await ServiceRegistration(
          bundleIdentifier: bundle.identifier, service: NativeServiceRegistration()
        ).execute(action)
      } catch {
        result = ServiceResult(
          action: action.rawValue, bundleIdentifier: nil, state: nil, outcome: "failed",
          error: error as? ServiceFailure ?? .invalidBundle,
          exitCode: error as? ServiceFailure == .relaunchFailed ? 1 : 2)
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      let output = try encoder.encode(result)
      try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
    } catch { exit(1) }
    exit(result.exitCode)
  }
}
