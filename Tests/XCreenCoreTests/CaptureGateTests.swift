import XCTest
@testable import XCreenCore
final class CaptureGateTests: XCTestCase {
    func testCaptureRequiresOptInPermissionAndSafeActiveApp() {
        var gate = CaptureGate()
        let safe = CaptureContext(permission: true, bundleID: "com.apple.TextEdit", processID: 42, locked: false, idleSeconds: 0)
        XCTAssertNil(gate.begin(safe))
        gate.setIntegrity(false)
        XCTAssertNotNil(gate.begin(safe))
        XCTAssertNil(gate.begin(CaptureContext(permission: false, bundleID: "com.apple.TextEdit", processID: 42, locked: false, idleSeconds: 0)))
        for app in ["com.1password.1password", "com.bitwarden.desktop", "com.apple.loginwindow", "com.apple.keychainaccess", "org.keepassxc.keepassxc", "com.lastpass.LastPass", "com.dashlane.Dashlane", "", "dev.xcreen.app"] {
            XCTAssertNil(gate.begin(CaptureContext(permission: true, bundleID: app, processID: 42, locked: false, idleSeconds: 0)), app)
        }
        XCTAssertNil(gate.begin(CaptureContext(permission: true, bundleID: safe.bundleID, processID: 42, locked: true, idleSeconds: 0)))
        XCTAssertNil(gate.begin(CaptureContext(permission: true, bundleID: safe.bundleID, processID: 42, locked: false, idleSeconds: 120)))
        XCTAssertNil(gate.begin(CaptureContext(permission: true, bundleID: safe.bundleID, processID: 42, locked: nil, idleSeconds: 0)))
        XCTAssertNil(gate.begin(CaptureContext(permission: true, bundleID: safe.bundleID, processID: 42, locked: false, idleSeconds: .nan)))
        XCTAssertNil(gate.begin(CaptureContext(permission: true, bundleID: safe.bundleID, processID: 0, locked: false, idleSeconds: 0)))
    }
    func testPauseInvalidatesLateOCRAcrossResume() throws {
        var gate = CaptureGate()
        let safe = CaptureContext(permission: true, bundleID: "com.apple.TextEdit", processID: 42, locked: false, idleSeconds: 0)
        gate.setIntegrity(false)
        let token = try XCTUnwrap(gate.begin(safe))
        XCTAssertTrue(gate.accepts(token, context: safe))
        gate.setIntegrity(true)
        XCTAssertFalse(gate.accepts(token, context: safe))
        gate.setIntegrity(false)
        XCTAssertFalse(gate.accepts(token, context: safe))
        let fresh = try XCTUnwrap(gate.begin(safe))
        XCTAssertTrue(gate.accepts(fresh, context: safe))
        gate.invalidate()
        XCTAssertFalse(gate.accepts(fresh, context: safe))
    }
    func testSelectsOnlyFrontmostNormalWindowNeverWholeDisplay() {
        let windows = [WindowCandidate(id: 1, pid: 22, layer: 0, width: 600, height: 400), WindowCandidate(id: 2, pid: 11, layer: 8, width: 600, height: 400), WindowCandidate(id: 3, pid: 11, layer: 0, width: 600, height: 400), WindowCandidate(id: 4, pid: 11, layer: 0, width: 600, height: 400)]
        XCTAssertEqual(WindowSelection.frontmost(windows, pid: 11), 3)
        XCTAssertNil(WindowSelection.frontmost(windows, pid: 33))
        XCTAssertNil(WindowSelection.frontmost([WindowCandidate(id: 1, pid: 11, layer: 0, width: 0, height: 400)], pid: 11))
        XCTAssertNil(WindowSelection.frontmost([WindowCandidate(id: 1, pid: 11, layer: 0, width: .infinity, height: 400)], pid: 11))
        XCTAssertNil(WindowSelection.frontmost([WindowCandidate(id: 1, pid: 11, layer: 0, width: 20_000, height: 400)], pid: 11))
    }
    func testIntegrityDefaultsOn() {
        XCTAssertTrue(CaptureGate().integrity, "Capture must be disabled on startup")
    }

    func testPeriodicCaptureRequiresExplicitOptInAndCurrentVerifiedUnlockedSession() throws {
        var policy = CapturePolicy()
        XCTAssertEqual(CapturePolicy.intervalSeconds, 30)
        XCTAssertTrue(policy.integrity)
        XCTAssertFalse(policy.optIn(permission: false))
        XCTAssertTrue(policy.integrity)
        XCTAssertFalse(policy.optIn(permission: true, lockState: .unknown))
        XCTAssertTrue(policy.integrity, "Opt-in and notifications do not prove the current lock state")
        XCTAssertNil(policy.begin(bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: 0, lockState: .unknown))

        XCTAssertTrue(policy.optIn(permission: true, lockState: .unlocked))
        XCTAssertFalse(policy.integrity)

        let token = try XCTUnwrap(policy.begin(bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: 0, lockState: .unlocked))
        XCTAssertTrue(policy.accepts(token, bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: 0, lockState: .unlocked))
        let replacement = try XCTUnwrap(policy.begin(bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: 0, lockState: .unlocked))
        XCTAssertNotEqual(token, replacement, "A new trace must supersede in-flight work")
        XCTAssertFalse(policy.accepts(token, bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: 0, lockState: .unlocked))
        XCTAssertFalse(policy.accepts(replacement, bundleID: "com.apple.TextEdit", processID: 43, idleSeconds: 0, lockState: .unlocked), "PID changes reject superseded capture work")
        XCTAssertFalse(policy.accepts(replacement, bundleID: "com.apple.Preview", processID: 42, idleSeconds: 0, lockState: .unlocked), "Bundle changes reject superseded capture work")
        XCTAssertFalse(policy.accepts(replacement, bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: 0, lockState: .unknown), "Unknown current lock state blocks OCR and ingestion")
        policy.failClosed()
        XCTAssertTrue(policy.integrity)
        XCTAssertFalse(policy.accepts(replacement, bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: 0, lockState: .unlocked), "Pause must discard in-flight capture/OCR")
    }

    func testIdleAndUnknownOrExcludedApplicationsFailClosed() {
        var policy = CapturePolicy()
        XCTAssertTrue(policy.optIn(permission: true, lockState: .unlocked))
        XCTAssertNil(policy.begin(bundleID: "", processID: 42, idleSeconds: 0, lockState: .unlocked))
        XCTAssertNil(policy.begin(bundleID: "com.1password.1password", processID: 42, idleSeconds: 0, lockState: .unlocked))
        XCTAssertNil(policy.begin(bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: 120, lockState: .unlocked))
        XCTAssertNil(policy.begin(bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: .nan, lockState: .unlocked))
        XCTAssertNil(policy.begin(bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: 0, lockState: .locked))
        XCTAssertNil(policy.begin(bundleID: "com.apple.TextEdit", processID: 42, idleSeconds: 0, lockState: .unknown))
    }
}
