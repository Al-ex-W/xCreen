import XCTest
import CoreFoundation
@testable import XCreenCore

final class SessionCompatibilityTests: XCTestCase {
    func testIndependentVetoesAndFreshEvaluation() {
        var state = CaptureLifecycleState()
        let old = state.epoch
        state.transition("system asleep", blocked: true)
        state.transition("session inactive", blocked: true)
        state.transition("screen locked", blocked: true)
        state.transition("system asleep", blocked: false)
        XCTAssertFalse(state.acceptsEvaluation(epoch: state.epoch))
        state.transition("screen locked", blocked: false)
        XCTAssertFalse(state.acceptsEvaluation(epoch: state.epoch))
        state.transition("session inactive", blocked: false)
        XCTAssertTrue(state.acceptsEvaluation(epoch: state.epoch))
        XCTAssertFalse(state.acceptsEvaluation(epoch: old))
        let restore = state.epoch
        state.transition("screen locked", blocked: true)
        XCTAssertFalse(state.acceptsEvaluation(epoch: restore))
        XCTAssertFalse(state.acceptsEvaluation(epoch: state.epoch))
    }
    func testPauseLogsOnlyOnStateTransition() {
        var state = CaptureStatusTransition()
        XCTAssertTrue(state.changed(state: "paused", reason: "sleep"))
        XCTAssertFalse(state.changed(state: "paused", reason: "sleep"))
        XCTAssertTrue(state.changed(state: "paused", reason: "lock"))
        XCTAssertTrue(state.changed(state: "running", reason: ""))
        XCTAssertTrue(state.changed(state: "paused", reason: "lock"))
    }
    func testMissingPrivateKeyIsCompatibleButInvalidPresentValueIsNot() {
        let base: [String: Any] = ["kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true]
        XCTAssertNil(CaptureSessionEvidence.blockReason(dictionary: base, foreground: "example.app"))
        for value: Any in [false, true, "false", 0, 1, NSNull()] {
            var input = base; input["CGSSessionScreenIsLocked"] = value
            XCTAssertEqual(CaptureSessionEvidence.blockReason(dictionary: input, foreground: "example.app") == nil, (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } ?? false)
        }
        XCTAssertNotNil(CaptureSessionEvidence.blockReason(dictionary: nil, foreground: "example.app"))
        for key in base.keys {
            var input = base; input[key] = false
            XCTAssertNotNil(CaptureSessionEvidence.blockReason(dictionary: input, foreground: "example.app"))
            input.removeValue(forKey: key)
            XCTAssertNotNil(CaptureSessionEvidence.blockReason(dictionary: input, foreground: "example.app"))
        }
        for foreground in [nil, "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.SecurityAgent", "com.apple.lockscreen"] as [String?] {
            XCTAssertNotNil(CaptureSessionEvidence.blockReason(dictionary: base, foreground: foreground))
        }
    }
}
