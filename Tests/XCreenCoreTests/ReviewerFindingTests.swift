import Foundation
import XCTest
@testable import XCreenCore

final class ReviewerFindingTests: XCTestCase {
    func testInputBoundsCountUnicodeScalarsLikePythonCodePoints() {
        let family = "👨‍👩‍👧‍👦"
        let source = String(repeating: family, count: 2)
        let bounded = InputBounds.prefix(source, maxUnicodeScalars: 8)
        XCTAssertEqual(bounded.unicodeScalars.count, 8)
        XCTAssertEqual(bounded, family + "👨")
    }

    func testConsentIsScopedToQuestionModelAndVault() {
        let bridge = BridgeSettings(python: "/python-a", script: "/bridge-a.py", hermes: "/hermes-a", vault: "/vault-a")
        let consent = ConsentScope(question: "question", modelID: "model-a", bridge: bridge)
        XCTAssertTrue(consent.allows(question: "question", modelID: "model-a", bridge: bridge))
        XCTAssertFalse(consent.allows(question: "changed", modelID: "model-a", bridge: bridge))
        XCTAssertFalse(consent.allows(question: "question", modelID: "model-b", bridge: bridge))

        var changedHermes = bridge
        changedHermes.hermes = "/hermes-b"
        XCTAssertFalse(consent.allows(question: "question", modelID: "model-a", bridge: changedHermes))
    }

    func testAutomaticModelRefreshUsesSavedSettingsNotDraftEdits() {
        let saved = BridgeSettings(python: "/saved/python", script: "/bridge.py", hermes: "/saved/hermes", vault: "/saved/vault")
        var settings = HarnessSettingsState(saved: saved)
        settings.draft.python = "/partial/python"
        settings.draft.vault = "/partial/vault"
        XCTAssertEqual(settings.automaticRefresh, saved)
        settings.saveDraft()
        XCTAssertEqual(settings.automaticRefresh.python, "/partial/python")
        XCTAssertEqual(settings.automaticRefresh.vault, "/partial/vault")
    }

    func testBridgeRejectsOutputOverTwoMiB() async throws {
        do {
            _ = try await BridgeRunner().run(
                executable: "/usr/bin/python3",
                arguments: ["-c", "import sys; sys.stdout.write('x' * (2 * 1024 * 1024 + 1))"],
                timeout: 5
            )
            XCTFail("Oversized output must be rejected")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testBridgeTimeoutForceKillsSIGTERMIgnoringProcess() async throws {
        let started = Date()
        do {
            _ = try await BridgeRunner().run(
                executable: "/usr/bin/python3",
                arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"],
                timeout: 0.1
            )
            XCTFail("Timed-out process must fail")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        }
    }
}
