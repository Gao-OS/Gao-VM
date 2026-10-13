import Darwin
import Foundation
import MachO
import Security

struct ServiceBundle {
  let identifier: String
  private let executable: URL
  private let needsCanonicalLaunch: Bool
  // Public Security/CSCommon.h kSecCodeSignatureRuntime; not exposed to Swift.
  private static let hardenedRuntimeFlag: UInt32 = 0x10000

  static func current() throws -> Self {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 0, size < 64 * 1024 else { throw ServiceFailure.invalidBundle }
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else { throw ServiceFailure.invalidBundle }
    let launchPath = URL(fileURLWithPath: String(cString: path))
    let executable = launchPath.resolvingSymlinksInPath()
    let macOS = executable.deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    let needsCanonicalLaunch = Bundle.main.bundleURL.resolvingSymlinksInPath().path != app.path
    let launchedThroughLink =
      (try? FileManager.default.attributesOfItem(atPath: launchPath.path)[.type])
      as? FileAttributeType == .typeSymbolicLink
    guard executable.lastPathComponent == "gaovm-service", macOS.lastPathComponent == "MacOS",
      contents.lastPathComponent == "Contents", app.pathExtension == "app",
      !needsCanonicalLaunch || launchedThroughLink
    else {
      throw ServiceFailure.invalidBundle
    }

    do {
      for directory in [
        app, contents, macOS, contents.appendingPathComponent("Library"),
        contents.appendingPathComponent("Library/LaunchAgents"),
      ] {
        try requireType(directory, .typeDirectory)
      }
      try requireType(executable, .typeRegular)
      try requireType(macOS.appendingPathComponent("gaovmd"), .typeRegular)
      let info = try plist(contents.appendingPathComponent("Info.plist"))
      guard let identifier = info["CFBundleIdentifier"] as? String,
        identifier.count <= 255,
        identifier.range(
          of: #"^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#,
          options: .regularExpression) != nil,
        needsCanonicalLaunch || Bundle.main.bundleIdentifier == identifier,
        info["CFBundleExecutable"] as? String == "gaovmd",
        info["CFBundlePackageType"] as? String == "APPL"
      else { throw ServiceFailure.invalidBundle }
      let agent = try plist(contents.appendingPathComponent("Library/LaunchAgents/gaovmd.plist"))
      guard
        Set(agent.keys)
          == Set([
            "Label", "BundleProgram", "ProgramArguments", "KeepAlive", "Umask",
            "AbandonProcessGroup",
          ]), agent["Label"] as? String == identifier + ".gaovmd",
        agent["BundleProgram"] as? String == "Contents/MacOS/gaovmd",
        agent["ProgramArguments"] as? [String] == ["gaovmd"],
        agent["KeepAlive"] as? Bool == true, agent["Umask"] as? Int == 63,
        agent["AbandonProcessGroup"] as? Bool == true
      else { throw ServiceFailure.invalidBundle }
      try verifySignature(app, identifier: identifier, nested: true)
      let code = try verifySignature(executable, identifier: identifier + ".service", nested: false)
      var signing: CFDictionary?
      guard
        SecCodeCopySigningInformation(
          code, SecCSFlags(rawValue: kSecCSSigningInformation),
          &signing) == errSecSuccess,
        let fields = signing as? [String: Any],
        let flags = fields[kSecCodeInfoFlags as String] as? UInt32,
        flags & hardenedRuntimeFlag != 0,
        (fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]).isEmpty
      else { throw ServiceFailure.invalidSignature }
      var running: SecCode?
      guard SecCodeCopySelf(SecCSFlags(), &running) == errSecSuccess, let running,
        SecCodeCheckValidity(running, SecCSFlags(), try requirement(identifier + ".service"))
          == errSecSuccess
      else { throw ServiceFailure.invalidSignature }
      return Self(
        identifier: identifier, executable: executable, needsCanonicalLaunch: needsCanonicalLaunch)
    } catch let error as ServiceFailure { throw error } catch { throw ServiceFailure.invalidBundle }
  }

  // SMAppService uses Bundle.main, which an external executable symlink can
  // misbind. Re-exec only the validated signed owner; the canonical invocation
  // must pass the normal owning-bundle check before accessing Service Management.
  func relaunchIfNeeded(action: ServiceAction) throws {
    guard needsCanonicalLaunch else { return }
    let strings: [UnsafeMutablePointer<CChar>?] = [executable.path, action.rawValue].map { value in
      value.withCString { Darwin.strdup($0) }
    }
    defer { for string in strings { free(string) } }
    guard strings.allSatisfy({ $0 != nil }) else { throw ServiceFailure.relaunchFailed }
    var arguments = strings + [nil]
    _ = execv(executable.path, &arguments)
    throw ServiceFailure.relaunchFailed
  }

  private static func requireType(_ url: URL, _ type: FileAttributeType) throws {
    let fields = try FileManager.default.attributesOfItem(atPath: url.path)
    guard fields[.type] as? FileAttributeType == type else { throw ServiceFailure.invalidBundle }
  }

  private static func plist(_ url: URL) throws -> [String: Any] {
    try requireType(url, .typeRegular)
    let fields = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = fields[.size] as? UInt64, size <= 64 * 1024,
      let value = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url), options: [], format: nil) as? [String: Any]
    else { throw ServiceFailure.invalidBundle }
    return value
  }

  private static func requirement(_ identifier: String) throws -> SecRequirement {
    var value: SecRequirement?
    guard
      SecRequirementCreateWithString(
        "identifier \"\(identifier)\"" as CFString, SecCSFlags(), &value) == errSecSuccess,
      let value
    else { throw ServiceFailure.invalidSignature }
    return value
  }

  @discardableResult
  private static func verifySignature(_ url: URL, identifier: String, nested: Bool) throws
    -> SecStaticCode
  {
    var code: SecStaticCode?
    let flags = SecCSFlags(
      rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        | (nested ? kSecCSCheckNestedCode : 0))
    guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
      let code,
      SecStaticCodeCheckValidity(code, flags, try requirement(identifier)) == errSecSuccess
    else { throw ServiceFailure.invalidSignature }
    return code
  }
}
