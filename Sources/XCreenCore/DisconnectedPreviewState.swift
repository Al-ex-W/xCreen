import Foundation

/// Local-only choices shown by the disconnected menu-bar preview.
/// They are deliberately not model identifiers and cannot start an integration.
public enum PreviewModelSelection: String, CaseIterable, Equatable, Hashable {
    case mainHarness
    case haikuDemo
    case lunaDemo

    public var label: String {
        switch self {
        case .mainHarness: "Use main harness selection"
        case .haikuDemo: "DEMO recommendation · Haiku"
        case .lunaDemo: "DEMO recommendation · Luna"
        }
    }
}

public enum PreviewInterval: String, CaseIterable, Equatable, Hashable {
    case minutes1
    case minutes5
    case minutes15

    public var label: String {
        switch self {
        case .minutes1: "1 minute"
        case .minutes5: "5 minutes"
        case .minutes15: "15 minutes"
        }
    }
}

public struct PreviewSubmission: Equatable {
    public let wasSent: Bool
    public let message: String
    public let connectionStatus: String
}

/// Preference-only state for the native disconnected UI.
/// This type intentionally has no bridge, capture, database, or network dependency.
public struct DisconnectedPreviewState {
    public static let disconnectedStatus = "Disconnected · UI preview"
    public static let notSentMessage = "Not connected — your question was not sent."

    private enum Key {
        static let integrityMode = "xcreen.preview.integrityMode"
        static let modelSelection = "xcreen.preview.modelSelection"
        static let interval = "xcreen.preview.interval"
    }

    private let defaults: UserDefaults
    public private(set) var integrityMode: Bool
    public private(set) var modelSelection: PreviewModelSelection
    public private(set) var interval: PreviewInterval

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        integrityMode = defaults.object(forKey: Key.integrityMode) as? Bool ?? true
        modelSelection = PreviewModelSelection(rawValue: defaults.string(forKey: Key.modelSelection) ?? "") ?? .mainHarness
        interval = PreviewInterval(rawValue: defaults.string(forKey: Key.interval) ?? "") ?? .minutes5
    }

    public var connectionStatus: String { Self.disconnectedStatus }

    public mutating func setIntegrityMode(_ value: Bool) {
        integrityMode = value
        defaults.set(value, forKey: Key.integrityMode)
    }

    public mutating func setModelSelection(_ value: PreviewModelSelection) {
        modelSelection = value
        defaults.set(value.rawValue, forKey: Key.modelSelection)
    }

    public mutating func setInterval(_ value: PreviewInterval) {
        interval = value
        defaults.set(value.rawValue, forKey: Key.interval)
    }

    public func submit(question: String) -> PreviewSubmission {
        // A question is intentionally not persisted or forwarded in this preview.
        _ = question
        return PreviewSubmission(wasSent: false, message: Self.notSentMessage, connectionStatus: connectionStatus)
    }
}
