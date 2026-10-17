import XCTest
@testable import XCreenCore

final class EvidenceStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A week of real use produced a >8 MB index (OCR text plus batch manifests); the store
    /// must still open, or capture is blocked indefinitely.
    func testOpensIndexLargerThanEightMegabytes() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date().timeIntervalSinceReferenceDate
        let text = String(repeating: "x", count: 4_000)
        let ocr = (0..<2_600).map { i in #"{"id":"ocr-\#(i)","timestamp":\#(now - Double(i)),"text":"\#(text)","app":"a","title":"t"}"# }
        let json = #"{"images":[],"batches":[],"ocr":["# + ocr.joined(separator: ",") + "]}"
        XCTAssertGreaterThan(json.utf8.count, 9_000_000)
        try Data(json.utf8).write(to: root.appendingPathComponent("index.json"))
        XCTAssertNoThrow(try EvidenceStore(root: root))
    }

    func testTimestampedCaptureStatusContainsNoEvidence() async throws {
        let store = try EvidenceStore(root: root)
        try await store.saveCaptureStatus(state: "gap", reason: "excluded", integrity: false)
        let data = try Data(contentsOf: root.appendingPathComponent("capture-status.json"))
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(status["capture"], "gap")
        XCTAssertEqual(status["desired_integrity"], "off")
        XCTAssertEqual(status["capture_reason"], "excluded")
        XCTAssertNotNil(status["updated"])
    }

    func testStoresSearchesAndFindsTimestampedEvidence() async throws {
        let store = try EvidenceStore(root: root)
        let time = Date().addingTimeInterval(-60).rounded()
        let image = try await store.saveImage(data: Data([1, 2, 3]), timestamp: time)
        let ocr = try await store.saveOCR(text: "A blue bicycle", app: "TextEdit", title: "Notes", timestamp: time)

        XCTAssertTrue(FileManager.default.fileExists(atPath: image.fileURL.path))
        let search = try await store.searchOCR(query: "BICYCLE")
        let nearby = try await store.imagesNear(timestamp: time)
        let lookedUp = try await store.image(id: image.id)
        XCTAssertEqual(search.map(\.id), [ocr.id])
        XCTAssertEqual(nearby.map(\.id), [image.id])
        XCTAssertEqual(lookedUp?.fileURL, image.fileURL)
    }

    func testBatchesAndCleanupPersistAcrossReopen() async throws {
        let store = try EvidenceStore(root: root)
        let old = Date().addingTimeInterval(-60)
        let image = try await store.saveImage(data: Data([9]), timestamp: old)
        _ = try await store.saveOCR(text: "old text", app: "A", title: "T", timestamp: old)
        let batch = CaptureBatch(id: "batch-1", images: [image], startedAt: old, completedAt: old, ocr: [])
        try await store.savePendingBatch(batch)
        let pending = try await store.pendingBatches()
        XCTAssertEqual(pending.map(\.id), [batch.id])
        try await store.markBatch(id: batch.id, status: "sent")
        let afterMark = try await store.pendingBatches()
        XCTAssertTrue(afterMark.isEmpty)

        try await store.cleanup(now: old.addingTimeInterval(8 * 24 * 60 * 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.fileURL.path))
        let reopened = try EvidenceStore(root: root)
        let oldSearch = try await reopened.searchOCR(query: "old")
        XCTAssertTrue(oldSearch.isEmpty)
    }

    func testClockDoesNotCatchUpAndCompletesAtThirtyImages() {
        var clock = ActiveCaptureClock()
        XCTAssertEqual(clock.recordEligibleSample(at: Date(timeIntervalSince1970: 0)), 0)
        XCTAssertEqual(clock.recordEligibleSample(at: Date(timeIntervalSince1970: 20)), 1)
        XCTAssertEqual(clock.activeSeconds, 1, accuracy: 0.001)
        for second in 1...299 { _ = clock.recordEligibleSample(at: Date(timeIntervalSince1970: TimeInterval(20 + second))) }
        XCTAssertEqual(clock.activeSeconds, 300, accuracy: 0.001)
        XCTAssertTrue(clock.isComplete)
    }

    func testCleanupPurgesExpiredCheckpointAndBatchReferences() async throws {
        let store = try EvidenceStore(root: root)
        let old = Date(timeIntervalSinceNow: -(8 * 24 * 60 * 60))
        let image = try await store.saveImage(data: Data([7]), timestamp: old)
        let ocr = try await store.saveOCR(text: "expired OCR", app: "A", title: "T", timestamp: old)
        let newer = Date()
        let batch = CaptureBatch(id: "batch-new", images: [image], startedAt: newer, completedAt: newer, ocr: [ocr])
        try await store.savePendingBatch(batch)
        try await store.saveCheckpoint(CaptureCheckpoint(startedAt: newer, images: [image], ocr: [ocr]))

        try await store.cleanup(now: newer)

        XCTAssertFalse(FileManager.default.fileExists(atPath: image.fileURL.path))
        let awaited1 = try await store.pendingBatches().isEmpty
        XCTAssertTrue(awaited1)
        let checkpoint = try await store.loadCheckpoint()
        XCTAssertTrue(checkpoint.images.isEmpty)
        XCTAssertTrue(checkpoint.ocr.isEmpty)
    }

    func testRejectsIndexWithEscapingDecodedImageURL() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let escaping = EvidenceImage(id: "image-escape", timestamp: Date(), fileURL: URL(fileURLWithPath: "/tmp/not-xcreen.png"))
        struct RawIndex: Encodable { let images: [EvidenceImage]; let ocr: [OCREvidence]; let batches: [String] }
        let index = RawIndex(images: [escaping], ocr: [], batches: [])
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("index.json"))

        XCTAssertThrowsError(try EvidenceStore(root: root))
    }

    func testClockPauseClearsAnchorWithoutLosingElapsedActiveTime() {
        var clock = ActiveCaptureClock()
        _ = clock.recordEligibleSample(at: Date(timeIntervalSince1970: 0))
        _ = clock.recordEligibleSample(at: Date(timeIntervalSince1970: 1))
        clock.pause()
        XCTAssertEqual(clock.recordEligibleSample(at: Date(timeIntervalSince1970: 181)), 0)
        XCTAssertEqual(clock.activeSeconds, 1)
    }
}


private extension Date {
    /// Whole seconds, so ISO-8601 filenames round-trip exactly.
    func rounded() -> Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
