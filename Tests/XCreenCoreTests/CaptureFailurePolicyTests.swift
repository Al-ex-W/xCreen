import XCTest
@testable import XCreenCore

final class CaptureFailurePolicyTests: XCTestCase {
    func testAutomaticBlocksNeverChangeUserIntent() {
        var state = CaptureIntentState(integrity: false)
        for reason in ["lock", "sleep", "permission", "no window", "SC error", "storage"] {
            state.block(reason: reason)
            XCTAssertFalse(state.integrity)
            XCTAssertFalse(state.mayCapture)
            state.verifiedSafe()
            XCTAssertTrue(state.mayCapture)
        }
        state.userSetIntegrity(true)
        state.verifiedSafe()
        XCTAssertTrue(state.integrity)
        XCTAssertFalse(state.mayCapture)
    }

    func testCurrentSafetyRequiresPositiveUnlockedEvidence() {
        XCTAssertFalse(CaptureSessionEvidence.isSafe(onConsole: true, loginDone: true, locked: nil, loginWindow: false))
        XCTAssertFalse(CaptureSessionEvidence.isSafe(onConsole: true, loginDone: true, locked: true, loginWindow: false))
        XCTAssertFalse(CaptureSessionEvidence.isSafe(onConsole: false, loginDone: true, locked: false, loginWindow: false))
        XCTAssertTrue(CaptureSessionEvidence.isSafe(onConsole: true, loginDone: true, locked: false, loginWindow: false))
    }

    func testTemporaryGapsRetryButUnsafeStateStops() {
        XCTAssertEqual(CaptureFailurePolicy.action(.noForegroundWindow), .retryGap)
        XCTAssertEqual(CaptureFailurePolicy.action(.screenCaptureTransient), .retryGap)
        XCTAssertEqual(CaptureFailurePolicy.action(.permissionOrSession), .safetyBlock)
        XCTAssertEqual(CaptureFailurePolicy.action(.storageOrOCR), .safetyBlock)
    }
}
