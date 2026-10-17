import Foundation
import CryptoKit
public enum InputBounds {
    public static func prefix(_ value: String, maxUnicodeScalars: Int) -> String {
        guard maxUnicodeScalars > 0 else { return "" }
        return String(String.UnicodeScalarView(value.unicodeScalars.prefix(maxUnicodeScalars)))
    }
}
public enum AskShortcut {
    public static func query(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "xcreen", url.host?.lowercased() == "ask",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.queryItems?.first(where: { $0.name == "query" })?.value,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return InputBounds.prefix(query, maxUnicodeScalars: maxQuestionScalars)
    }

    public static let maxQuestionScalars = 8_000

    /// Builds the `xcreen://ask?query=` handoff URL. Nil for blank questions.
    public static func url(question: String) -> URL? {
        let bounded = InputBounds.prefix(question, maxUnicodeScalars: maxQuestionScalars)
        guard !bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "xcreen"
        components.host = "ask"
        components.queryItems = [URLQueryItem(name: "query", value: bounded)]
        // URLQueryItem leaves '+' unescaped; encode it so no decoder can read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

extension AskShortcut {
    /// Parameterless handoff: show the panel without changing the question field.
    public static let openURL = URL(string: "xcreen://open")!

    /// Spotlight "Search xCreen" row: fill the (bounded) typed term, or just open the panel when blank.
    public static func searchURL(term: String) -> URL {
        url(question: term) ?? openURL
    }
}

/// What an `xcreen://` URL asks the tray to do. Neither case submits a question.
public enum PanelHandoff: Equatable {
    case open
    case ask(String)

    public init?(url: URL) {
        if let question = AskShortcut.query(url) { self = .ask(question); return }
        guard url.scheme?.lowercased() == "xcreen", url.host?.lowercased() == "open" else { return nil }
        self = .open
    }
}

extension PanelHandoff {
    /// In-process App Intent delivery: a bounded question, or just open the panel when blank.
    public init(question: String) {
        let bounded = InputBounds.prefix(question, maxUnicodeScalars: AskShortcut.maxQuestionScalars)
        self = bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .open : .ask(bounded)
    }
}

/// Ask-field rules for the tray: prefill is bounded; the field clears only once a question was admitted.
public enum AskFieldPolicy {
    public static func prefill(_ value: String) -> String {
        InputBounds.prefix(value, maxUnicodeScalars: AskShortcut.maxQuestionScalars)
    }

    /// Clears the field if it still holds the admitted question; keeps anything typed since.
    public static func fieldAfterAdmission(current: String, submitted: String) -> String {
        current.trimmingCharacters(in: .whitespacesAndNewlines) == submitted ? "" : current
    }
}

/// Holds a handoff until the app has finished launching. A cold launch by URL can deliver
/// `application(_:open:)` before `applicationDidFinishLaunching`, when the tray does not exist yet.
/// Only opens/fills the panel; submission stays an explicit user action.
public struct AskHandoffInbox {
    private var ready = false
    private var pending: PanelHandoff?
    public init() {}

    /// Returns the handoff to perform now, or nil when buffered.
    public mutating func receive(_ handoff: PanelHandoff) -> PanelHandoff? {
        guard ready else {
            // A later bare "open" must not discard a pending question.
            if case .ask = pending, handoff == .open { return nil }
            pending = handoff
            return nil
        }
        return handoff
    }

    public mutating func receive(urls: [URL]) -> PanelHandoff? {
        let handoffs = urls.compactMap(PanelHandoff.init(url:))
        guard let chosen = handoffs.last(where: { if case .ask = $0 { return true } else { return false } }) ?? handoffs.last else { return nil }
        return receive(chosen)
    }

    /// Marks launch complete and returns (once) the latest buffered handoff.
    public mutating func markReady() -> PanelHandoff? {
        ready = true
        defer { pending = nil }
        return pending
    }
}

public struct ConsentScope: Equatable {
    private let question: String
    private let modelID: String
    private let bridge: BridgeSettings
    public init(question: String, modelID: String, bridge: BridgeSettings) {
        self.question = question
        self.modelID = modelID
        self.bridge = bridge
    }
    public func allows(question: String, modelID: String, bridge: BridgeSettings) -> Bool {
        self == ConsentScope(question: question, modelID: modelID, bridge: bridge)
    }
}
public struct OCRDedup {
    private let capacity: Int
    private var hashes: [Data] = []
    public init(capacity: Int = 128) { self.capacity = max(1, capacity) }
    public var count: Int { hashes.count }
    public mutating func insert(_ text: String, app: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        let hash = Data(SHA256.hash(data: Data((app + "\u{0}" + normalized).utf8)))
        guard !hashes.contains(hash) else { return false }
        hashes.append(hash)
        if hashes.count > capacity { hashes.removeFirst() }
        return true
    }
}
