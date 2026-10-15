import Foundation

/// One metadata-only log entry per excluded foreground transition. Nil resets it.
public struct ForegroundExclusionDiagnostic {
    private var previous: String?
    public init() {}
    public mutating func message(bundleID: String?) -> String? {
        guard let bundleID else { previous = nil; return nil }
        guard bundleID != previous else { return nil }
        previous = bundleID
        let safe = bundleID.unicodeScalars.prefix(256).map { scalar -> String in
            let value = scalar.value
            return (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122) || value == 45 || value == 46 || value == 95 ? String(scalar) : "_"
        }.joined()
        return "foreground excluded app=\(safe)"
    }
}

/// App metadata only: no page, field, extension or private-window inspection.
public enum ForegroundCapturePolicy {
    public static func isEligible(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        let exact: Set<String> = ["dev.xcreen.app", "com.apple.passwords", "com.apple.systemsettings", "com.apple.systempreferences", "com.agilebits.onepassword7"]
        // Deliberately conservative substrings cover credential/security app variants.
        let fragments = ["1password", "bitwarden", "lastpass", "dashlane", "keepass", "keychain", "loginwindow", "screenlock", "securityagent", "screensaver", "lockscreen"]
        return !id.isEmpty && !exact.contains(id) && !fragments.contains(where: id.contains)
    }
}
