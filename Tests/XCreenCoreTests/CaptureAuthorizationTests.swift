import Foundation
import XCTest
@testable import XCreenCore

final class CaptureAuthorizationTests: XCTestCase {
    @MainActor
    func testDelayedCompletionCannotClearReplacementOrDeliverCallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(root: root)
        let epoch = CapturePersistenceEpoch()
        let old = epoch.authorization, now = Date()
        epoch.checkpoint.startedAt = now
        let batch = CaptureBatch(id: "batch-delayed", images: [], startedAt: now, completedAt: now, ocr: [])
        try await store.finalizeBatch(batch, authorization: old)
        // The store finished, but the caller has not yet handled the return.
        epoch.advance()
        XCTAssertNil(epoch.checkpoint.startedAt, "consume the receipt before pause snapshots")
        epoch.checkpoint.startedAt = now.addingTimeInterval(1)
        var delivered = false
        XCTAssertFalse(epoch.complete(old) { delivered = true })
        XCTAssertFalse(delivered)
        XCTAssertEqual(epoch.checkpoint.startedAt, now.addingTimeInterval(1))
        let current = epoch.authorization
        try await store.finalizeBatch(batch, authorization: current)
        XCTAssertTrue(epoch.complete(current) { delivered = true })
        XCTAssertTrue(delivered)
        XCTAssertNil(epoch.checkpoint.startedAt)
    }

    func testPauseResumeRejectsOldFinalizationAndPausedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(root: root)
        let old = CaptureAuthorization(), paused = CaptureAuthorization(), resumed = CaptureAuthorization()
        let now = Date()
        let replacement = CaptureCheckpoint(startedAt: now)
        let batch = CaptureBatch(id: "batch-old", images: [], startedAt: now, completedAt: now, ocr: [])
        // Suspend the store, revoke the old iteration and the paused snapshot,
        // then let a resumed epoch write before both stale operations arrive.
        let entered = expectation(description: "store occupied"), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await store.holdForTest(entered, release) }
        await fulfillment(of: [entered], timeout: 5)
        old.invalidate(); paused.invalidate()
        release.signal(); await blocker.value
        try await store.saveCheckpoint(replacement, authorization: resumed)
        do { try await store.finalizeBatch(batch, authorization: old); XCTFail("stale batch finalized") }
        catch CaptureAuthorization.Revoked.invalidated { }
        do { try await store.saveCheckpoint(CaptureCheckpoint(), authorization: paused); XCTFail("stale pause overwrote replacement") }
        catch CaptureAuthorization.Revoked.invalidated { }
        let checkpoint = try await store.loadCheckpoint()
        XCTAssertEqual(checkpoint.startedAt, now)
        let pending = try await store.pendingBatches()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(old.didFinalize)
    }

    func testFinalizationReceiptSurvivesRevocationBeforeCallerResumes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(root: root)
        let token = CaptureAuthorization(), now = Date()
        try await store.saveCheckpoint(CaptureCheckpoint(startedAt: now), authorization: token)
        let batch = CaptureBatch(id: "batch-complete", images: [], startedAt: now, completedAt: now, ocr: [])
        try await store.finalizeBatch(batch, authorization: token)
        do {
            try await store.saveCheckpoint(CaptureCheckpoint(startedAt: now), authorization: token)
            XCTFail("finalized epoch resurrected its checkpoint")
        } catch CaptureAuthorization.Revoked.invalidated { }
        token.invalidate()
        XCTAssertTrue(token.didFinalize, "pause must reconcile this receipt before saving its snapshot")
        XCTAssertFalse(token.isValid, "the old caller must not deliver a completion")
        let checkpoint = try await store.loadCheckpoint()
        XCTAssertNil(checkpoint.startedAt)
        let pending = try await store.pendingBatches()
        XCTAssertEqual(pending.map(\.id), [batch.id])
    }

    func testQueuedInvalidatedWritesLeaveNoEvidenceOrCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(root: root)
        let token = CaptureAuthorization()
        let entered = expectation(description: "store occupied"), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await store.holdForTest(entered, release) }
        await fulfillment(of: [entered], timeout: 5)
        let submitted = expectation(description: "saves submitted while store occupied")
        submitted.expectedFulfillmentCount = 2
        let imageWrite = Task {
            submitted.fulfill()
            return try await store.saveImage(data: Data([1]), authorization: token)
        }
        let write = Task {
            submitted.fulfill()
            return try await store.saveOCR(text: "private", app: "test", title: "", authorization: token)
        }
        await fulfillment(of: [submitted], timeout: 5)
        token.invalidate()
        release.signal()
        await blocker.value
        do { _ = try await write.value; XCTFail("invalidated queued save accepted") }
        catch CaptureAuthorization.Revoked.invalidated { }
        do { _ = try await imageWrite.value; XCTFail("image accepted") }
        catch CaptureAuthorization.Revoked.invalidated { }
        do { try await store.saveCheckpoint(CaptureCheckpoint(startedAt: Date()), authorization: token); XCTFail("checkpoint accepted") }
        catch CaptureAuthorization.Revoked.invalidated { }
        let latest = await store.latestOCR()
        XCTAssertNil(latest)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ocr").path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("images").path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("capture-checkpoint.json").path))
    }
}

extension EvidenceStore {
    func holdForTest(_ entered: XCTestExpectation, _ release: DispatchSemaphore) {
        entered.fulfill(); release.wait()
    }
}
