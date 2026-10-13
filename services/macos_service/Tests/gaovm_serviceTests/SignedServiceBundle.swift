import Darwin
import Foundation
import XCTest

final class SignedServiceBundle {
  let root: URL
  var app: URL
  let identifier =
    "org.gaovm.tests.Service.g" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  private var cleanupAllowed = true

  var executable: URL { app.appendingPathComponent("Contents/MacOS/gaovm-service") }
  var descriptor: URL { app.appendingPathComponent("Contents/Library/LaunchAgents/gaovmd.plist") }

  init() throws {
    var template = Array("/private/tmp/gsr.XXXXXX".utf8CString)
    guard let directory = Darwin.mkdtemp(&template) else {
      throw NSError(domain: "service-fixture-create", code: 1)
    }
    root = URL(fileURLWithPath: String(cString: directory))
    app = root.appendingPathComponent("GaoVM.app")
    for path in ["Contents/MacOS", "Contents/Library/LaunchAgents"] {
      try FileManager.default.createDirectory(
        at: app.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    for name in ["gaovmd", "gaovm-service"] {
      try FileManager.default.copyItem(
        at: helperExecutable(), to: app.appendingPathComponent("Contents/MacOS/" + name))
    }
    try writePlist(
      [
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "gaovmd",
        "CFBundleName": "GaoVM", "CFBundlePackageType": "APPL", "CFBundleVersion": "1.0.0",
        "CFBundleShortVersionString": "1.0.0", "LSMinimumSystemVersion": "14.0",
        "LSBackgroundOnly": true,
      ], to: app.appendingPathComponent("Contents/Info.plist"))
    try writePlist(
      [
        "Label": identifier + ".gaovmd", "BundleProgram": "Contents/MacOS/gaovmd",
        "ProgramArguments": ["gaovmd"], "KeepAlive": true, "Umask": 63,
        "AbandonProcessGroup": true,
      ], to: descriptor)
  }

  func sign(serviceIdentifier: String? = nil, hardened: Bool = true, entitlements: URL? = nil)
    throws
  {
    for (url, codeID) in [
      (executable, serviceIdentifier ?? identifier + ".service"), (app, identifier),
    ] {
      var arguments = ["--force", "--sign", "-", "--timestamp=none", "--identifier", codeID]
      if url != executable || hardened { arguments += ["--options", "runtime"] }
      if url == executable, let entitlements { arguments += ["--entitlements", entitlements.path] }
      let result = try run(
        arguments + [url.path], executable: URL(fileURLWithPath: "/usr/bin/codesign"))
      XCTAssertEqual(result.status, 0, result.error)
    }
    let verified = try run(
      ["--verify", "--deep", "--strict", app.path],
      executable: URL(fileURLWithPath: "/usr/bin/codesign"))
    XCTAssertEqual(verified.status, 0, verified.error)
  }

  func run(_ arguments: [String], executable: URL? = nil) throws -> HelperResult {
    do { return try runHelper(arguments, executable: executable ?? self.executable) } catch {
      if error is UnconfirmedChildExit { cleanupAllowed = false }
      throw error
    }
  }

  func cleanUp() {
    guard cleanupAllowed else {
      return XCTFail("retaining fixture with an unconfirmed child exit: " + root.path)
    }
    do { try FileManager.default.removeItem(at: root) } catch {
      XCTFail("could not remove exited fixture: " + root.path)
    }
  }
}

func writePlist(_ value: [String: Any], to url: URL) throws {
  try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    .write(to: url, options: .atomic)
}
