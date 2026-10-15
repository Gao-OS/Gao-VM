import Darwin
import Foundation
import XCTest

@testable import gaovm_service

final class ServiceCommandTests: XCTestCase {
  func testComponentProbeRunsWithoutBundleHomeOrServiceAccess() throws {
    let result = try runHelper(["--component-info"], environment: [:])
    XCTAssertEqual(result.status, 0, result.output + result.error)
    let json = try result.json
    XCTAssertEqual(json["format"] as? String, "gaovm.component.v1")
    XCTAssertEqual(json["role"] as? String, "service")
    XCTAssertEqual(json["version"] as? String, "0.1.0")
    XCTAssertTrue(json["catalog_schema"] is NSNull)
    XCTAssertEqual(json["service_actions"] as? [String], ["register", "status", "unregister"])
    XCTAssertEqual(result.error, "")
  }

  func testHelperMustBeHardenedAndHaveNoEntitlementException() throws {
    for hardened in [false, true] {
      let fixture = try SignedServiceBundle()
      defer { fixture.cleanUp() }
      let exception = fixture.root.appendingPathComponent("exception.plist")
      try writePlist(
        ["com.apple.security.cs.allow-unsigned-executable-memory": true], to: exception)
      try fixture.sign(hardened: hardened, entitlements: hardened ? exception : nil)
      let result = try fixture.run(["status"])
      XCTAssertEqual(result.status, 2)
      XCTAssertEqual(try result.json["error_code"] as? String, "INVALID_SIGNATURE")
    }
  }

  func testInvalidInvocationsDoNotEchoUntrustedArguments() throws {
    for arguments in [
      [], ["help"], ["--help", "status"], ["--bundle", "argument-secret-marker"],
      ["register", "--socket", "argument-secret-marker"], ["status", "status"],
    ] {
      let result = try runHelper(arguments, environment: [:])
      XCTAssertEqual(result.status, 2)
      XCTAssertEqual(try result.json["error_code"] as? String, "INVALID_INVOCATION")
      XCTAssertFalse(result.output.contains("argument-secret-marker"))
      XCTAssertEqual(result.error, "")
    }
  }

  func testWrongDescriptorBindingIsRejectedEvenWhenTheBundleSignatureIsValid() throws {
    let fixture = try SignedServiceBundle()
    defer { fixture.cleanUp() }
    try writePlist(
      [
        "Label": fixture.identifier + ".gaovmd", "BundleProgram": "/usr/bin/true",
        "ProgramArguments": ["gaovmd"], "KeepAlive": true, "Umask": 63,
        "AbandonProcessGroup": true,
      ], to: fixture.descriptor)
    try fixture.sign()
    let result = try fixture.run(["status"])
    XCTAssertEqual(result.status, 2)
    XCTAssertEqual(try result.json["error_code"] as? String, "INVALID_BUNDLE")
  }

  func testWrongHelperCodeIdentifierIsRejected() throws {
    let fixture = try SignedServiceBundle()
    defer { fixture.cleanUp() }
    try fixture.sign(serviceIdentifier: fixture.identifier + ".other")
    let result = try fixture.run(["status"])
    XCTAssertEqual(result.status, 2)
    XCTAssertEqual(try result.json["error_code"] as? String, "INVALID_SIGNATURE")
  }

  func testSignatureTamperingIsRejectedBeforeServiceAccess() throws {
    let fixture = try SignedServiceBundle()
    defer { fixture.cleanUp() }
    try fixture.sign()
    let infoURL = fixture.app.appendingPathComponent("Contents/Info.plist")
    var info = try XCTUnwrap(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: infoURL), options: [], format: nil) as? [String: Any])
    info["CFBundleName"] = "Changed after signing"
    try writePlist(info, to: infoURL)
    let result = try fixture.run(["status"])
    XCTAssertEqual(result.status, 2)
    XCTAssertEqual(try result.json["error_code"] as? String, "INVALID_SIGNATURE")
  }

  func testSignedRenamedBundleAndResolvedHelperSymlinkReturnReadOnlyAuthorization() throws {
    let fixture = try SignedServiceBundle()
    defer { fixture.cleanUp() }
    try fixture.sign()
    let renamed = fixture.root.appendingPathComponent("Renamed GaoVM.app")
    try FileManager.default.moveItem(at: fixture.app, to: renamed)
    fixture.app = renamed
    let alias = fixture.root.appendingPathComponent("service-link")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.executable)
    for executable in [fixture.executable, alias] {
      let result = try fixture.run(["status"], executable: executable)
      XCTAssertEqual(result.status, 0, result.output + result.error)
      let json = try result.json
      XCTAssertEqual(json["bundle_identifier"] as? String, fixture.identifier)
      XCTAssertEqual(json["action"] as? String, "status")
      XCTAssertEqual(json["plist_name"] as? String, "gaovmd.plist")
      XCTAssertEqual(json["outcome"] as? String, "observed")
      XCTAssertTrue(
        ["notRegistered", "enabled", "requiresApproval", "notFound", "unknown"]
          .contains(json["authorization_state"] as? String ?? ""))
      XCTAssertNotNil(json["native_status"] as? Int)
      XCTAssertEqual(result.error, "")
    }
  }

  func testServiceCommandsRejectAnUnbundledExecutableBeforeServiceAccess() throws {
    for action in ["status", "register", "unregister"] {
      let result = try runHelper([action])
      XCTAssertEqual(result.status, 2)
      let json = try result.json
      XCTAssertEqual(json["action"] as? String, action)
      XCTAssertEqual(json["plist_name"] as? String, "gaovmd.plist")
      XCTAssertEqual(json["error_code"] as? String, "INVALID_BUNDLE")
      XCTAssertTrue(json["authorization_state"] is NSNull)
      XCTAssertEqual(result.error, "")
    }
  }

  func testHelpRunsOutsideAnAppWithoutHomeOrServiceAccess() throws {
    let result = try runHelper(["--help"], environment: [:])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("gaovm-service status"))
    XCTAssertTrue(result.output.contains("gaovm-service register"))
    XCTAssertTrue(result.output.contains("gaovm-service unregister"))
    XCTAssertEqual(result.error, "")
  }
}

struct HelperResult {
  let status: Int32
  let output: String
  let error: String

  var json: [String: Any] {
    get throws {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
  }
}

func runHelper(
  _ arguments: [String], executable: URL? = nil, environment: [String: String]? = nil
) throws -> HelperResult {
  let child = Process()
  child.executableURL = executable ?? helperExecutable()
  child.arguments = arguments
  if let environment { child.environment = environment }
  let output = Pipe()
  let error = Pipe()
  child.standardOutput = output
  child.standardError = error
  let exited = DispatchGroup()
  exited.enter()
  child.terminationHandler = { _ in exited.leave() }
  try child.run()
  if exited.wait(timeout: .now() + 5) != .success {
    child.terminate()
    if exited.wait(timeout: .now() + 1) != .success {
      Darwin.kill(child.processIdentifier, SIGKILL)
      guard exited.wait(timeout: .now() + 2) == .success else {
        throw UnconfirmedChildExit()
      }
    }
    XCTFail("helper exceeded its test deadline")
  }
  return HelperResult(
    status: child.terminationStatus,
    output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
    error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

struct UnconfirmedChildExit: Error {}

func helperExecutable() -> URL {
  Bundle(for: ServiceCommandTests.self).bundleURL.deletingLastPathComponent()
    .appendingPathComponent("gaovm-service")
}
