/// The desired user privacy switch is independent of automatic safety gates.
/// Only userSetIntegrity mutates intent; every restoration requires a new safe check.
import Foundation
import CoreFoundation

public enum CaptureSessionEvidence {
    /// Public console/login keys plus an undocumented compatibility lock hint.
    /// Absence is not proof of unlock; independent lifecycle/foreground vetoes apply.
    public static func blockReason(dictionary: [String: Any]?, foreground: String?) -> String? {
        guard let dictionary else { return "current session dictionary unavailable" }
        func boolean(_ key: String) -> Bool? {
            guard let number = dictionary[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        guard boolean("kCGSSessionOnConsoleKey") == true else { return "current console session not verified" }
        guard boolean("kCGSessionLoginDoneKey") == true else { return "current login completion not verified" }
        if dictionary.keys.contains("CGSSessionScreenIsLocked") {
            guard let locked = boolean("CGSSessionScreenIsLocked") else { return "invalid current lock-state hint" }
            if locked { return "current screen locked" }
        }
        guard let foreground, !foreground.isEmpty else { return "current foreground unavailable" }
        let id = foreground.lowercased()
        if ["loginwindow", "screensaver", "screenlock", "lockscreen", "securityagent"].contains(where: id.contains) { return "security foreground" }
        return nil
    }

}

/// Ordered notification vetoes. A resume clears only its matching veto and
/// invalidates prior evaluations; it never authorizes capture on its own.
public struct CaptureLifecycleState: Sendable {
    public private(set) var blocks: Set<String> = []
    public private(set) var epoch: UInt64 = 0
    public init() {}
    public mutating func transition(_ reason: String, blocked: Bool) {
        epoch &+= 1
        if blocked { blocks.insert(reason) } else { blocks.remove(reason) }
    }
    public func acceptsEvaluation(epoch: UInt64) -> Bool { epoch == self.epoch && blocks.isEmpty }
}

public struct CaptureStatusTransition: Sendable {
    private var previous: String?
    public init() {}
    public mutating func changed(state: String, reason: String) -> Bool {
        let next = state + "\u{0}" + reason
        guard next != previous else { return false }
        previous = next
        return true
    }
}

public struct CaptureIntentState: Sendable {
    public private(set) var integrity: Bool
    public private(set) var blockedReason: String? = "Safety not yet verified"
    public var mayCapture: Bool { !integrity && blockedReason == nil }
    public init(integrity: Bool = true) { self.integrity = integrity }
    public mutating func userSetIntegrity(_ value: Bool) { integrity = value; blockedReason = "Safety not yet verified" }
    public mutating func block(reason: String) { blockedReason = reason }
    public mutating func verifiedSafe() { blockedReason = nil }
}
