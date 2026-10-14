import CoreGraphics
import Foundation
import AppKit

/// Conservative session compatibility indicator. `CGSessionCopyCurrentDictionary`
/// and workspace notifications are public APIs, but Apple does not promise they
/// form a universal lock-state contract. Therefore missing values, errors, a
/// non-console session, or login-window foreground state are all unsafe. Lock,
/// sleep and resignation notifications immediately pause capture; users must
/// explicitly opt in again after a state transition.
enum MacSessionState: Equatable {
    case unlocked, lockedOrUnsafe

    static var current: Self {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
              (dictionary[kCGSessionOnConsoleKey] as? Bool) == true,
              (dictionary[kCGSessionLoginDoneKey] as? Bool) == true,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { return .lockedOrUnsafe }
        return .unlocked
    }
}
