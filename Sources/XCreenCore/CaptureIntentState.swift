/// The desired user privacy switch is independent of automatic safety gates.
/// Only userSetIntegrity mutates intent; every restoration requires a new safe check.
public enum CaptureSessionEvidence {
    public static func isSafe(onConsole: Bool?, loginDone: Bool?, locked: Bool?, loginWindow: Bool) -> Bool {
        onConsole == true && loginDone == true && locked == false && !loginWindow
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
