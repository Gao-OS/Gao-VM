import Foundation
import XCTest

@testable import vz_macos

final class SerialControllerTests: XCTestCase {
  func testRawSerialSinkRotatesAtBoundAndKeepsRequestedHistory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-\(UUID().uuidString)")
    let path = root.appendingPathComponent("serial.log").path
    defer { try? FileManager.default.removeItem(at: root) }
    let sink = try RotatingByteSink(path: path, maxBytes: 8, rotations: 2)

    try sink.write(Data("12345678".utf8))
    try sink.write(Data("abcdefgh".utf8))
    try sink.write(Data("ABCDEFGH".utf8))
    sink.close()

    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "ABCDEFGH")
    XCTAssertEqual(try String(contentsOfFile: "\(path).1", encoding: .utf8), "abcdefgh")
    XCTAssertEqual(try String(contentsOfFile: "\(path).2", encoding: .utf8), "12345678")
  }

  func testSingleOversizedWriteIsSegmentedAndKeepsExactlyThreeRotations() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gaovm-serial-large-\(UUID().uuidString)")
    let path = root.appendingPathComponent("serial.log").path
    defer { try? FileManager.default.removeItem(at: root) }
    let sink = try RotatingByteSink(path: path, maxBytes: 8, rotations: 3)
    let bytes = Data((0..<36).map(UInt8.init))

    try sink.write(bytes)
    sink.close()

    let paths = ["\(path).3", "\(path).2", "\(path).1", path]
    let retained = try paths.reduce(into: Data()) { output, part in
      let data = try Data(contentsOf: URL(fileURLWithPath: part))
      XCTAssertLessThanOrEqual(data.count, 8)
      output.append(data)
    }
    XCTAssertEqual(retained, bytes.suffix(retained.count))
    XCTAssertEqual(retained.count, 28)
    XCTAssertFalse(FileManager.default.fileExists(atPath: "\(path).4"))
  }
}
