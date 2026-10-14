import CoreGraphics
import Foundation
import AppKit
import XCreenCore

/// Conservative session compatibility indicator. `CGSessionCopyCurrentDictionary`
/// and workspace notifications are public APIs, but Apple does not promise they
/// form a universal lock-state contract. Therefore missing values, errors, a
/// non-console session, or login-window foreground state are all unsafe. Lock,
/// sleep and resignation notifications invalidate work without changing user intent.
/// Missing lock-state compatibility evidence is unsafe; wake notifications alone
/// never prove that the session is currently unlocked.
enum MacSessionState: Equatable {
    case unlocked, lockedOrUnsafe

    static var unsafeReason: String {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return "current session dictionary unavailable" }
        guard (dictionary[kCGSessionOnConsoleKey] as? Bool) == true else { return "current console session not verified" }
        guard (dictionary[kCGSessionLoginDoneKey] as? Bool) == true else { return "current login completion not verified" }
        guard let locked = dictionary["CGSSessionScreenIsLocked"] as? Bool else { return "current lock-state signal unavailable" }
        if locked { return "current screen locked" }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" { return "login window foreground" }
        return "current session safety changed"
    }

    static var current: Self {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
              CaptureSessionEvidence.isSafe(onConsole: dictionary[kCGSessionOnConsoleKey] as? Bool,
                  loginDone: dictionary[kCGSessionLoginDoneKey] as? Bool,
                  locked: dictionary["CGSSessionScreenIsLocked"] as? Bool,
                  loginWindow: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow") else { return .lockedOrUnsafe }
        return .unlocked
    }
}
