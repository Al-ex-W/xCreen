import XCTest
@testable import XCreenCore

final class SessionCoordinatorTests: XCTestCase {
    func testManualWorkIsDequeuedBeforeAutomaticBatches() {
        var coordinator = SessionCoordinator()
        coordinator.enqueue(.automatic(id: "batch-1"))
        coordinator.enqueue(.automatic(id: "batch-2"))
        coordinator.enqueue(.manual(id: "ask-1"))

        XCTAssertEqual(coordinator.next(), .manual(id: "ask-1"))
        XCTAssertEqual(coordinator.next(), .automatic(id: "batch-1"))
        XCTAssertEqual(coordinator.next(), .automatic(id: "batch-2"))
    }

    func testIntegrityPauseDropsAutomaticWorkButNotManualHistoryChat() {
        var coordinator = SessionCoordinator()
        coordinator.enqueue(.automatic(id: "batch-1"))
        coordinator.enqueue(.manual(id: "ask-history"))
        coordinator.setIntegrity(true)

        XCTAssertEqual(coordinator.next(), .manual(id: "ask-history"))
        XCTAssertNil(coordinator.next())
    }

    func testAttachmentResolverOnlyReturnsEvidenceOwnedFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp/xcreen-evidence", isDirectory: true)
        let resolver = EvidencePathResolver(root: root)
        XCTAssertEqual(try resolver.resolve(id: "a1", filename: "a1.png"), root.appendingPathComponent("a1.png"))
        XCTAssertThrowsError(try resolver.resolve(id: "a1", filename: "../secret.png"))
        XCTAssertThrowsError(try resolver.resolve(id: "wrong", filename: "a1.png"))
    }

    func testAttachmentResolverRejectsAssistantSuppliedPathsAndUnknownIDs() throws {
        let root = URL(fileURLWithPath: "/private/tmp/xcreen-evidence", isDirectory: true)
        let resolver = EvidencePathResolver(root: root)
        XCTAssertThrowsError(try resolver.resolve(id: "image-1", filename: "image-2.png"))
        XCTAssertThrowsError(try resolver.resolve(id: "image-1", filename: "image-1.png?remote=https://example.invalid"))
    }

}
