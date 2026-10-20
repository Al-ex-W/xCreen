import XCTest
@testable import XCreenCore

final class AppendixCacheTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-appendix-\(UUID().uuidString)") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testStoresPrivatelyAndDatesFilesByCaptureTime() throws {
        let cache = AppendixCache(directory: root)
        let captured = Date(timeIntervalSince1970: 1_792_000_000)
        let image = try cache.store(id: "image-1", data: Data([0xff, 0xd8, 0xff, 0xe0]), capturedAt: captured)
        XCTAssertEqual(image.fileURL.pathExtension, "jpg")
        XCTAssertEqual(image.timestamp, captured)
        let attributes = try FileManager.default.attributesOfItem(atPath: image.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, captured.timeIntervalSince1970, accuracy: 1)
        let directory = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testPruneKeepsOnlyTheCurrentAnswerWithinRetention() throws {
        let cache = AppendixCache(directory: root)
        let now = Date()
        let keep = try cache.store(id: "image-keep", data: Data([0x89, 0x50]), capturedAt: now)
        let other = try cache.store(id: "image-other", data: Data([0x89, 0x50]), capturedAt: now)
        let stale = try cache.store(id: "image-stale", data: Data([0x89, 0x50]), capturedAt: now.addingTimeInterval(-8 * 24 * 3600))
        cache.prune(keeping: ["image-keep", "image-stale"], now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.fileURL.path), "older than seven days is never kept")
        cache.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: keep.fileURL.path))
    }

    func testRejectsUnsafeIDsAndSymlinkedDirectory() throws {
        let cache = AppendixCache(directory: root)
        XCTAssertThrowsError(try cache.store(id: "../escape", data: Data([1]), capturedAt: nil))
        let target = root.deletingLastPathComponent().appendingPathComponent("xcreen-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        XCTAssertThrowsError(try cache.store(id: "image-1", data: Data([1]), capturedAt: nil))
    }

    func testCaptureTimeHeaderParses() {
        XCTAssertEqual(HTTPXCreenServer.parseDate("2026-10-20T13:38:11.123Z")?.timeIntervalSince1970 ?? 0, 1_792_503_491.123, accuracy: 0.001)
        XCTAssertNotNil(HTTPXCreenServer.parseDate("2026-10-20T13:38:11Z"))
        XCTAssertNil(HTTPXCreenServer.parseDate("yesterday"))
    }
}
