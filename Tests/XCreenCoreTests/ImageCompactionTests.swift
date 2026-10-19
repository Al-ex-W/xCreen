import XCTest
import AppKit
@testable import XCreenCore

final class ImageCompactionTests: XCTestCase {
    private var root: URL!
    private static let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(repeating: 7, count: 4_000)
    private static let jpeg = Data([0xff, 0xd8, 0xff, 0xe0]) + Data(repeating: 1, count: 100)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-compaction-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func batch(_ store: EvidenceStore, images count: Int = 2) async throws -> CaptureBatch {
        var images: [EvidenceImage] = []
        for _ in 0..<count { images.append(try await store.saveImage(data: Self.png)) }
        let batch = CaptureBatch(id: "batch-\(UUID().uuidString.lowercased())", images: images, startedAt: Date(), completedAt: Date(), ocr: [])
        try await store.savePendingBatch(batch)
        return batch
    }

    private func complete(_ store: EvidenceStore, _ batch: CaptureBatch) async throws {
        try await store.transitionBatch(id: batch.id, to: .submitting)
        try await store.bindBatch(id: batch.id, sessionID: "runtime-test")
        let ids = batch.images.map(\.id)
        let json = try JSONSerialization.data(withJSONObject: ["batch_id": batch.id, "source_ids": ids, "session_id": "runtime-test", "status": "skipped", "verified": true, "effects": []])
        try await store.reconcile(try BatchReceipt(data: json, batchID: batch.id, sourceIDs: ids, sessionID: "runtime-test"))
    }

    func testOnlyImagesOfCompletedDigestsAreCompressible() async throws {
        let store = try EvidenceStore(root: root)
        let waiting = try await batch(store)
        let done = try await batch(store)
        _ = try await store.saveImage(data: Self.png) // still in the capture checkpoint
        try await complete(store, done)
        let candidates = await store.compressibleImages(limit: 100)
        XCTAssertEqual(Set(candidates.map(\.id)), Set(done.images.map(\.id)))
        XCTAssertTrue(Set(candidates.map(\.id)).isDisjoint(with: waiting.images.map(\.id)))
    }

    func testReplacingSwapsFileAndEveryIndexReferenceAndSurvivesReopen() async throws {
        let store = try EvidenceStore(root: root)
        let done = try await batch(store)
        try await complete(store, done)
        let original = done.images[0]
        let swapped = try await store.replaceImage(id: original.id, expecting: original.fileURL, with: Self.jpeg)
        let replaced = try XCTUnwrap(swapped)
        XCTAssertEqual(replaced.fileURL.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: replaced.fileURL), Self.jpeg)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.fileURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: replaced.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let resolved = try await store.image(id: original.id)
        XCTAssertEqual(resolved?.fileURL, replaced.fileURL)
        XCTAssertEqual(resolved?.timestamp, original.timestamp)
        let remaining = await store.compressibleImages(limit: 100)
        XCTAssertFalse(remaining.contains { $0.id == original.id })

        let reopened = try EvidenceStore(root: root)
        let afterReopen = try await reopened.image(id: original.id)
        XCTAssertEqual(afterReopen?.fileURL, replaced.fileURL)
        let state = await reopened.batchState(id: done.id)
        XCTAssertEqual(state, .completed)
    }

    func testReplaceRejectsNonJPEGStaleExpectationAndUndigestedImages() async throws {
        let store = try EvidenceStore(root: root)
        let waiting = try await batch(store)
        let done = try await batch(store)
        try await complete(store, done)
        let image = done.images[0]
        do { _ = try await store.replaceImage(id: image.id, expecting: image.fileURL, with: Self.png); XCTFail("PNG bytes must be rejected") } catch {}
        let stale = image.fileURL.deletingLastPathComponent().appendingPathComponent("other.png")
        let staleResult = try await store.replaceImage(id: image.id, expecting: stale, with: Self.jpeg)
        XCTAssertNil(staleResult)
        let undigested = try await store.replaceImage(id: waiting.images[0].id, expecting: waiting.images[0].fileURL, with: Self.jpeg)
        XCTAssertNil(undigested, "digest input must stay full quality until the digest completes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: waiting.images[0].fileURL.path))
    }

    func testCrashLeftoverOriginalIsRemovedOnNextPass() async throws {
        let store = try EvidenceStore(root: root)
        let done = try await batch(store, images: 1)
        try await complete(store, done)
        let original = done.images[0]
        let swapped = try await store.replaceImage(id: original.id, expecting: original.fileURL, with: Self.jpeg)
        let replaced = try XCTUnwrap(swapped)
        try Self.png.write(to: original.fileURL) // simulate a crash between index write and unlink
        try await store.removeSupersededOriginals()
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replaced.fileURL.path))
    }

    func testCompactorReplacesOnlySmallerOutputAndStopsWithoutEncoder() async throws {
        let store = try EvidenceStore(root: root)
        let done = try await batch(store)
        try await complete(store, done)
        let none = await ImageCompactor(store: store, encoder: nil).run(limit: 10)
        XCTAssertEqual(none, 0)
        let bigger = await ImageCompactor(store: store, encoder: FakeEncoder(output: Self.jpeg + Data(repeating: 0, count: 10_000))).run(limit: 10)
        XCTAssertEqual(bigger, 0)
        let kept = await store.compressibleImages(limit: 10)
        XCTAssertEqual(kept.count, 2, "a larger result must keep the PNG")
        let compressed = await ImageCompactor(store: store, encoder: FakeEncoder(output: Self.jpeg)).run(limit: 10)
        XCTAssertEqual(compressed, 2)
        let left = await store.compressibleImages(limit: 10)
        XCTAssertEqual(left.count, 0)
    }

    func testMozJPEGEncoderProducesJPEGFromPNG() throws {
        guard let encoder = MozJPEGEncoder.locate() else { throw XCTSkip("mozjpeg not installed") }
        let png = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-moz-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: png)
        let output = try encoder.encode(png)
        XCTAssertEqual(Array(output.prefix(3)), [0xff, 0xd8, 0xff])
    }

    func testMozJPEGEncoderRejectsNonImageInput() throws {
        guard let encoder = MozJPEGEncoder.locate() else { throw XCTSkip("mozjpeg not installed") }
        let junk = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-moz-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: junk) }
        try Data("not an image".utf8).write(to: junk)
        XCTAssertThrowsError(try encoder.encode(junk))
    }
}

private struct FakeEncoder: ImageEncoding { let output: Data; func encode(_ url: URL) throws -> Data { output } }
