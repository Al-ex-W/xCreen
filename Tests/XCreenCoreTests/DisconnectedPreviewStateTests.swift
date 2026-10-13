import XCTest
@testable import XCreenCore

final class DisconnectedPreviewStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "DisconnectedPreviewStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsToIntegrityOnAndDisconnected() {
        let state = DisconnectedPreviewState(defaults: defaults)

        XCTAssertTrue(state.integrityMode)
        XCTAssertEqual(state.connectionStatus, "Disconnected · UI preview")
    }

    func testIntegrityPickerAndIntervalAreLocalPreferences() {
        var state = DisconnectedPreviewState(defaults: defaults)
        state.setIntegrityMode(false)
        state.setModelSelection(.lunaDemo)
        state.setInterval(.minutes5)

        let reloaded = DisconnectedPreviewState(defaults: defaults)
        XCTAssertFalse(reloaded.integrityMode)
        XCTAssertEqual(reloaded.modelSelection, .lunaDemo)
        XCTAssertEqual(reloaded.interval, .minutes5)
    }

    func testSubmittingQuestionIsNotSentAndDoesNotClaimAnAnswer() {
        let state = DisconnectedPreviewState(defaults: defaults)

        let result = state.submit(question: "What did I miss?")

        XCTAssertFalse(result.wasSent)
        XCTAssertEqual(result.message, "Not connected — your question was not sent.")
        XCTAssertEqual(result.connectionStatus, "Disconnected · UI preview")
    }
}
