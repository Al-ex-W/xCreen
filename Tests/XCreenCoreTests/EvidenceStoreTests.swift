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

    func testCaptureStatusRoundTripsAndHoldsNoEvidence() async throws {
        let store = try EvidenceStore(root: root)
        try await store.saveCaptureStatus(state: "gap", reason: "excluded", integrity: false)
        let status = await store.captureStatus()
        XCTAssertEqual(status?.capture, "gap")
        XCTAssertEqual(status?.reason, "excluded")
        XCTAssertEqual(status?.integrity, false)
        let raw = try String(contentsOf: root.appendingPathComponent("capture-status.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("text"))
    }

    func testUploadsComeInCaptureOrderWithOCRAheadOfItsImage() async throws {
        let store = try EvidenceStore(root: root)
        let t0 = Date().addingTimeInterval(-100)
        let a = try await store.saveOCR(text: "first", app: "A", title: "T", timestamp: t0)
        let image1 = try await store.saveImage(data: Data([1]), timestamp: t0.addingTimeInterval(1))
        let b = try await store.saveOCR(text: "second", app: "A", title: "T", timestamp: t0.addingTimeInterval(2))
        let c = try await store.saveOCR(text: "third", app: "A", title: "T", timestamp: t0.addingTimeInterval(3))
        let image2 = try await store.saveImage(data: Data([2]), timestamp: t0.addingTimeInterval(4))
        let late = try await store.saveOCR(text: "late", app: "A", title: "T", timestamp: t0.addingTimeInterval(5))
        let items = await store.pendingUploads()
        XCTAssertEqual(items, [.ocr([a]), .image(image1), .ocr([b, c]), .image(image2), .ocr([late])])
        let firstTwo = await store.pendingUploads(limit: 2)
        XCTAssertEqual(firstTwo, [.ocr([a]), .image(image1)])
    }

    func testOCRGroupsAreBounded() async throws {
        let store = try EvidenceStore(root: root)
        let t0 = Date().addingTimeInterval(-1000)
        for i in 0..<(EvidenceStore.maximumOCRUploadGroup + 5) { _ = try await store.saveOCR(text: "t\(i)", app: "A", title: "", timestamp: t0.addingTimeInterval(Double(i))) }
        let items = await store.pendingUploads()
        guard case .ocr(let first) = items[0], case .ocr(let second) = items[1] else { return XCTFail("expected OCR groups") }
        XCTAssertEqual(first.count, EvidenceStore.maximumOCRUploadGroup)
        XCTAssertEqual(second.count, 5)
    }

    func testAcknowledgedItemsLeaveTheOutboxAndTheirFilesAreDeleted() async throws {
        let store = try EvidenceStore(root: root)
        let ocr = try await store.saveOCR(text: "hello", app: "A", title: "T")
        let image = try await store.saveImage(data: Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.fileURL.path))
        try await store.acknowledge(ocr: [ocr.id], image: image.id)
        let left = await store.pendingUploads()
        XCTAssertTrue(left.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.fileURL.path))
        let reopened = try EvidenceStore(root: root)
        let afterReopen = await reopened.pendingUploads()
        XCTAssertTrue(afterReopen.isEmpty)
    }

    func testUnsentItemsSurviveReopen() async throws {
        let store = try EvidenceStore(root: root)
        let image = try await store.saveImage(data: Data([7]))
        let reopened = try EvidenceStore(root: root)
        let items = await reopened.pendingUploads()
        XCTAssertEqual(items, [.image(image)])
    }

    func testCleanupExpiresUnsentEvidenceAndCheckpoint() async throws {
        let store = try EvidenceStore(root: root)
        let old = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let image = try await store.saveImage(data: Data([7]), timestamp: old)
        let ocr = try await store.saveOCR(text: "expired OCR", app: "A", title: "T", timestamp: old)
        try await store.saveCheckpoint(CaptureCheckpoint(startedAt: old, images: [image], ocr: [ocr]))
        try await store.cleanup()
        let items = await store.pendingUploads()
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.fileURL.path))
        let checkpoint = try await store.loadCheckpoint()
        XCTAssertNil(checkpoint.startedAt)
    }

    func testRejectsIndexWithEscapingDecodedImageURL() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        let index = #"{"images":[{"id":"image-1","timestamp":0,"fileURL":"file:///etc/passwd"}],"ocr":[]}"#
        try Data(index.utf8).write(to: root.appendingPathComponent("index.json"))
        XCTAssertThrowsError(try EvidenceStore(root: root))
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

    func testClockPauseClearsAnchorWithoutLosingElapsedActiveTime() {
        var clock = ActiveCaptureClock()
        _ = clock.recordEligibleSample(at: Date(timeIntervalSince1970: 0))
        _ = clock.recordEligibleSample(at: Date(timeIntervalSince1970: 1))
        clock.pause()
        XCTAssertEqual(clock.recordEligibleSample(at: Date(timeIntervalSince1970: 181)), 0)
        XCTAssertEqual(clock.activeSeconds, 1)
    }
}
