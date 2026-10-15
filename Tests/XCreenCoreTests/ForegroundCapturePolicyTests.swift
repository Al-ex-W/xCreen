import XCTest
@testable import XCreenCore

final class ForegroundCapturePolicyTests: XCTestCase {
    func testCredentialAndSecurityVariantsRemainExcluded() {
        for id in ["", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.Dashlane", "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.systemsettings", "com.apple.systempreferences", "dev.xcreen.app", "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.ScreenSaver.Engine", "com.apple.lockscreen", "com.example.screenlock.helper", "com.example.bitwarden.helper"] {
            XCTAssertFalse(ForegroundCapturePolicy.isEligible(bundleID: id), id)
        }
    }

    func testExactIDsDoNotExcludeUnrelatedSubstringMatches() {
        for id in ["org.example.com.apple.passwords.notes", "com.apple.passwordshelper", "dev.xcreen.application", "org.example.com.apple.systemsettings.manual", "com.apple.TextEdit"] {
            XCTAssertTrue(ForegroundCapturePolicy.isEligible(bundleID: id), id)
        }
    }

    func testExclusionDiagnosticsAreBoundedSanitizedAndTransitionOnly() {
        var diagnostic = ForegroundExclusionDiagnostic()
        XCTAssertEqual(diagnostic.message(bundleID: "com.bitwarden.desktop"), "foreground excluded app=com.bitwarden.desktop")
        XCTAssertNil(diagnostic.message(bundleID: "com.bitwarden.desktop"))
        XCTAssertEqual(diagnostic.message(bundleID: "com.apple.Passwords"), "foreground excluded app=com.apple.Passwords")
        XCTAssertNil(diagnostic.message(bundleID: nil))
        XCTAssertNotNil(diagnostic.message(bundleID: "com.apple.Passwords"))
        let hostile = "com.bitwarden.\n\r\t\u{1b}" + String(repeating: "x", count: 400)
        guard let message = diagnostic.message(bundleID: hostile) else { return XCTFail("Missing exclusion metadata") }
        XCTAssertFalse(message.contains("\n"))
        XCTAssertFalse(message.contains("\r"))
        XCTAssertFalse(message.contains("\t"))
        XCTAssertFalse(message.contains("\u{1b}"))
        XCTAssertLessThanOrEqual(message.count, 280)
    }
}
