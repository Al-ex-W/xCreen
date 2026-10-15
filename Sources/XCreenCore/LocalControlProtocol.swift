import Foundation

/// Private, local-only request contract shared by the menu-bar app and `xcreen`.
/// It deliberately contains no transport details: the app owns the Unix socket and
/// executes these commands on its main actor.
public enum LocalControlProtocol {
    public static let maximumFrameBytes = 64 * 1024
    public static let maximumWaitMilliseconds = 30_000
}

public enum LocalControlCommandName: String, Codable, Sendable {
    case status, integrity, visibility, connect, disconnect, reconnect, models, model, settings, autodetect, ask, cancel, history, images, panel, quit
}

public struct LocalControlCommand: Codable, Sendable {
    public let id: String?
    public let name: LocalControlCommandName
    public let value: String?
    public let provider: String?
    public let model: String?
    public let question: String?
    public let waitMilliseconds: Int?

    enum CodingKeys: String, CodingKey { case id, command, value, provider, model, question, waitMilliseconds = "wait_ms" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decode(LocalControlCommandName.self, forKey: .command)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        waitMilliseconds = try c.decodeIfPresent(Int.self, forKey: .waitMilliseconds)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id); try c.encode(name, forKey: .command); try c.encodeIfPresent(value, forKey: .value); try c.encodeIfPresent(provider, forKey: .provider); try c.encodeIfPresent(model, forKey: .model); try c.encodeIfPresent(question, forKey: .question); try c.encodeIfPresent(waitMilliseconds, forKey: .waitMilliseconds)
    }

    public static func decode(_ data: Data) throws -> LocalControlCommand {
        guard data.count <= LocalControlProtocol.maximumFrameBytes else { throw LocalControlError.invalidRequest("request too large") }
        let command = try JSONDecoder().decode(LocalControlCommand.self, from: data)
        guard command.id?.utf8.count ?? 0 <= 128 else { throw LocalControlError.invalidRequest("id too large") }
        guard command.value?.utf8.count ?? 0 <= 4096,
              command.provider?.utf8.count ?? 0 <= 256,
              command.model?.utf8.count ?? 0 <= 512,
              command.question?.utf8.count ?? 0 <= 32_000 else { throw LocalControlError.invalidRequest("field too large") }
        if command.name == .ask, command.question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { throw LocalControlError.invalidRequest("ask needs question") }
        if let wait = command.waitMilliseconds, !(0...LocalControlProtocol.maximumWaitMilliseconds).contains(wait) { throw LocalControlError.invalidRequest("invalid wait") }
        return command
    }
}

public struct LocalControlSettings: Codable, Equatable, Sendable {
    public var python = ""; public var root = ""; public var vault = ""
    public init(python: String = "", root: String = "", vault: String = "") { self.python = python; self.root = root; self.vault = vault }
}

public struct LocalControlModel: Codable, Equatable, Sendable { public let provider: String; public let model: String; public init(provider: String, model: String) { self.provider = provider; self.model = model } }
public struct LocalControlImage: Codable, Equatable, Sendable { public let id: String; public let timestamp: Date; public init(id: String, timestamp: Date) { self.id = id; self.timestamp = timestamp } }

public struct LocalControlSnapshot: Codable, Equatable, Sendable {
    public var sessionVisible: Bool = false
    public var actualSessionVisible: Bool? = nil
    public var sessionVisibilityPending: Bool = true
    public let app: String; public let connected: Bool; public let integrity: Bool; public let capture: String
    /// This is returned only to an explicit foreground CLI caller, never written to logs.
    public let message: String; public let models: [LocalControlModel]; public let currentModel: LocalControlModel?; public let settings: LocalControlSettings; public let images: [LocalControlImage]
    public init(app: String, connected: Bool, integrity: Bool, capture: String, message: String = "", models: [LocalControlModel] = [], currentModel: LocalControlModel? = nil, settings: LocalControlSettings, images: [LocalControlImage] = []) { self.app = app; self.connected = connected; self.integrity = integrity; self.capture = capture; self.message = message; self.models = models; self.currentModel = currentModel; self.settings = settings; self.images = images }
}

public enum LocalControlError: Error, LocalizedError { case invalidRequest(String), unavailable(String), failed(String)
    public var errorDescription: String? { switch self { case .invalidRequest(let value), .unavailable(let value), .failed(let value): return value } }
}

public struct LocalControlResponse: Codable, Sendable {
    public let ok: Bool; public let error: String?; public let snapshot: LocalControlSnapshot?; public let reply: String?
    public static func ok(_ snapshot: LocalControlSnapshot, reply: String? = nil) -> LocalControlResponse { .init(ok: true, error: nil, snapshot: snapshot, reply: reply) }
    public static func failure(_ error: Error) -> LocalControlResponse { .init(ok: false, error: error.localizedDescription, snapshot: nil, reply: nil) }
}
