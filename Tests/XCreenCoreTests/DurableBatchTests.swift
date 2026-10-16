import XCTest
@testable import XCreenCore

final class DurableBatchTests: XCTestCase {
    func testPreadmissionFailuresAreBoundedAndRefinalizationCannotResetAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(root: root)
        let batch = CaptureBatch(id: "batch-bounded", images: [], startedAt: Date(), completedAt: Date(), ocr: [])
        try await store.savePendingBatch(batch)
        for _ in 0..<4 { try await store.recordBatchFailure(id: batch.id, cancelled: true) }
        let afterCancellation = await store.batchPage()
        XCTAssertEqual(afterCancellation.first?.attempts, 0, "Integrity cancellation before admission must not exhaust retries")
        for _ in 0..<3 { try await store.recordBatchFailure(id: batch.id) }
        var page = await store.batchPage()
        XCTAssertEqual(page.first?.state, .deadletter)
        XCTAssertEqual(page.first?.attempts, 3)
        try await store.savePendingBatch(batch)
        page = await store.batchPage()
        XCTAssertEqual(page.first?.state, .deadletter)
    }

    func testInterruptedSubmissionSurvivesRestartWithoutBlindRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(root: root)
        let batch = CaptureBatch(id: "batch-durable", images: [], startedAt: Date(), completedAt: Date(), ocr: [])
        try await store.savePendingBatch(batch)
        try await store.transitionBatch(id: batch.id, to: .submitting)
        let reopened = try EvidenceStore(root: root)
        let pending = try await reopened.pendingBatches()
        XCTAssertTrue(pending.isEmpty, "a crash after send intent is ambiguous, never retry automatically")
        let page = await reopened.batchPage()
        XCTAssertEqual(page.first?.state, .uncertain)
        XCTAssertEqual(page.first?.attempts, 1)
    }
}
