import XCTest
@testable import XCreenCore

final class ActivityLogTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-log-\(UUID().uuidString)") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAppendsTimestampedCategoryLinesAndStatus() throws {
        let log = ActivityLog(directory: root)
        log.write(.gateway, "connected session=abc")
        log.write(.capture, "image saved id=image-1")
        log.updateStatus(["hermes": "connected", "integrity": "off"])
        log.flush()

        let lines = try String(contentsOf: log.logURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("[gateway] connected session=abc"))
        XCTAssertTrue(lines[1].contains("[capture] image saved id=image-1"))
        let status = try JSONSerialization.jsonObject(with: Data(contentsOf: log.statusURL)) as? [String: String]
        XCTAssertEqual(status?["hermes"], "connected")
        XCTAssertNotNil(status?["updated"])
        let mode = try FileManager.default.attributesOfItem(atPath: log.logURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testFlattensNewlinesSoOneEventIsOneLine() throws {
        let log = ActivityLog(directory: root)
        log.write(.app, "first\nsecond")
        log.flush()
        XCTAssertEqual(try String(contentsOf: log.logURL, encoding: .utf8).split(separator: "\n").count, 1)
    }

    func testRotatesWhenLarge() throws {
        let log = ActivityLog(directory: root, maximumBytes: 200)
        for i in 0..<20 { log.write(.app, "line \(i) padding padding") }
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.logURL.path + ".1"))
        let size = try FileManager.default.attributesOfItem(atPath: log.logURL.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, 400)
    }
}
