import CoreGraphics
import Foundation
import AppKit
import XCreenCore

/// Practical compatibility eligibility, NOT universal lock/unlock proof.
/// Public console/login keys require strict true Booleans. The undocumented
/// lock hint may be absent or strict false, never malformed. Notifications and
/// foreground checks remain independent vetoes. See docs/macos-session-research.md.
@MainActor
enum MacSessionState {
    static var blockReason: String? {
        CaptureSessionEvidence.blockReason(
            dictionary: CGSessionCopyCurrentDictionary() as? [String: Any],
            foreground: NSWorkspace.shared.frontmostApplication.flatMap {
                $0.processIdentifier > 0 ? $0.bundleIdentifier : nil
            })
    }
}
