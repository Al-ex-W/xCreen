import Foundation
public struct CaptureGate {
    public private(set) var integrity = true
    public init() {}
    private var generation: UInt64 = 0
    public func accepts(_ token: UInt64, context: CaptureContext) -> Bool { token == generation && begin(context) != nil }
    public mutating func invalidate() { generation &+= 1 }
    public mutating func setIntegrity(_ value: Bool) { invalidate(); integrity = value }
    public func begin(_ context: CaptureContext) -> UInt64? {
        let id = context.bundleID.lowercased()
        let exclusions = [
            "1password", "bitwarden", "lastpass", "dashlane", "keepass", "keychain",
            "loginwindow", "screenlock", "securityagent", "dev.xcreen.app", "com.apple.passwords",
            "com.apple.systempreferences", "com.apple.systemsettings",
            // Browsers are conservatively app-wide excluded until a reliable,
            // separately consented private-window detector exists.
            "com.apple.safari", "com.google.chrome", "org.mozilla.firefox",
            "company.thebrowser.browser", "com.microsoft.edgemac", "com.brave.browser",
            "com.kagi.kagimacos"
        ]
        guard !integrity, context.permission, context.processID > 0, context.locked == false,
              context.idleSeconds.isFinite, context.idleSeconds >= 0, context.idleSeconds < 120,
              !id.isEmpty, !exclusions.contains(where: { id.contains($0) }) else { return nil }
        return generation
    }
}
public struct CaptureContext {
    public let permission: Bool
    public let bundleID: String
    public let processID: Int32
    public let locked: Bool?
    public let idleSeconds: Double
    public init(permission: Bool, bundleID: String, processID: Int32, locked: Bool?, idleSeconds: Double) {
        self.permission = permission; self.bundleID = bundleID; self.processID = processID; self.locked = locked; self.idleSeconds = idleSeconds
    }
}

public enum CaptureLockState: Equatable {
    case unlocked
    case locked
    case unknown
}

public struct CaptureTarget: Equatable {
    public let bundleID: String
    public let processID: Int32
    public init(bundleID: String, processID: Int32) {
        self.bundleID = bundleID
        self.processID = processID
    }
}

/// Stateful policy for the periodic capture loop. Opt-in does not establish
/// the current lock state: only a positively verified unlocked state can
/// disable Integrity mode. Lifecycle failures return to the paused default and
/// advance the generation.
public struct CapturePolicy {
    public static let intervalSeconds: UInt64 = 30
    private var gate = CaptureGate()
    private var permission = false
    private var activeTarget: CaptureTarget?

    public init() {}
    public var integrity: Bool { gate.integrity }

    @discardableResult
    public mutating func optIn(permission: Bool, lockState: CaptureLockState = .unknown) -> Bool {
        guard permission, lockState == .unlocked else {
            failClosed()
            return false
        }
        self.permission = true
        gate.setIntegrity(false)
        return true
    }

    public mutating func failClosed() {
        permission = false
        activeTarget = nil
        gate.setIntegrity(true)
    }

    public mutating func begin(bundleID: String, processID: Int32, idleSeconds: Double, lockState: CaptureLockState) -> UInt64? {
        let target = CaptureTarget(bundleID: bundleID, processID: processID)
        // A later attempt must invalidate any earlier image/OCR work, even when
        // it happens within the same periodic-capture generation.
        gate.invalidate()
        guard let token = gate.begin(context(target: target, idleSeconds: idleSeconds, lockState: lockState)) else {
            return nil
        }
        activeTarget = target
        return token
    }

    public func accepts(_ token: UInt64, bundleID: String, processID: Int32, idleSeconds: Double, lockState: CaptureLockState) -> Bool {
        let target = CaptureTarget(bundleID: bundleID, processID: processID)
        return activeTarget == target && gate.accepts(token, context: context(target: target, idleSeconds: idleSeconds, lockState: lockState))
    }

    private func context(target: CaptureTarget, idleSeconds: Double, lockState: CaptureLockState) -> CaptureContext {
        CaptureContext(
            permission: permission,
            bundleID: target.bundleID,
            processID: target.processID,
            locked: lockState == .unlocked ? false : nil,
            idleSeconds: idleSeconds
        )
    }
}
