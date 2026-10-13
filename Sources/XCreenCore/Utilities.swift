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
        return InputBounds.prefix(query, maxUnicodeScalars: 8000)
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
