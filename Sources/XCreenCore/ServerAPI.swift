import Foundation
import Security

/// A configured Hermes model route, as the server's `GET /v1/models` lists it.
public struct HermesModelRoute: Identifiable, Equatable, Sendable, Codable {
    public let provider: String; public let model: String
    public var id: String { "\(provider)::\(model)" }
    public init(provider: String, model: String) { self.provider = provider; self.model = model }
}

/// `GET /v1/status` (docs/protocol.md). Unknown fields are ignored, missing optional ones tolerated.
public struct ServerStatus: Decodable, Equatable, Sendable {
    public struct Hermes: Decodable, Equatable, Sendable { public let connected: Bool; public let configured: Bool; public let error: String?; public let session: String? }
    public struct Model: Decodable, Equatable, Sendable { public let current: HermesModelRoute?; public let `default`: HermesModelRoute; public let applied: Bool; public let status: String }
    public let `protocol`: Int
    public let version: String
    public let hermes: Hermes
    public let model: Model
    public let sessionVisible: Bool
    public let sessionVisibleConfirmed: Bool?
    public let visibilityPending: Bool
    public let integrity: Bool
    public let batches: [String: Int]
    public let unbatched: [String: Int]?
    public let nextRetry: String?
    public let message: String?
    /// Why automatic digests are on hold (empty when they run).
    public let digestHold: String?
    public let vault: Bool?
    public let compression: String?
    public let activeTurn: String?
    enum CodingKeys: String, CodingKey {
        case `protocol`, version, hermes, model, integrity, batches, unbatched, message, vault, compression
        case sessionVisible = "session_visible", sessionVisibleConfirmed = "session_visible_confirmed", visibilityPending = "visibility_pending"
        case nextRetry = "next_retry", activeTurn = "active_turn", digestHold = "digest_hold"
    }
}

public struct ServerTurn: Decodable, Equatable, Sendable {
    public let id: String; public let state: String; public let text: String; public let error: String?; public let version: Int; public let done: Bool
}

public struct ServerBatch: Codable, Equatable, Sendable {
    public struct Receipt: Codable, Equatable, Sendable { public let status: String; public let verified: Bool; public let effects: Int }
    public let id: String; public let state: String; public let attempts: Int; public let images: Int; public let ocr: Int; public let receipt: Receipt?
    public let startedAt: String; public let completedAt: String; public let retryAfter: String?
    enum CodingKeys: String, CodingKey { case id, state, attempts, images, ocr, receipt, startedAt = "started_at", completedAt = "completed_at", retryAfter = "retry_after" }
}

public struct ServerConfigValues: Codable, Equatable, Sendable {
    public let hermesPython: String; public let hermesRoot: String; public let vault: String; public let timezone: String
    enum CodingKeys: String, CodingKey { case hermesPython = "hermes_python", hermesRoot = "hermes_root", vault, timezone }
}

public enum ServerAPIError: LocalizedError, Equatable {
    case notConfigured
    case unreachable(String)
    case unauthorized
    case incompatible(Int)
    case rejected(status: Int, code: String, message: String)
    case invalidResponse
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "No xCreen server configured (xcreen server set URL)."
        case .unreachable(let detail): return "xCreen server unreachable: \(detail)"
        case .unauthorized: return "The xCreen server rejected the token."
        case .incompatible(let version): return "The xCreen server speaks protocol \(version); this app needs \(HTTPXCreenServer.protocolVersion). Update the older side."
        case .rejected(_, _, let message): return message
        case .invalidResponse: return "The xCreen server returned an invalid response."
        }
    }
    /// The server permanently refused this item; retrying the same bytes can't succeed.
    public var isPermanentRejection: Bool { if case .rejected(let status, _, _) = self { return status == 400 || status == 409 || status == 413 }; return false }
}

/// The stable client/server contract (docs/protocol.md). The app, uploader and tests all
/// depend on this protocol, never on the transport.
public protocol XCreenServerAPI: Sendable {
    func health() async throws -> Int
    func status() async throws -> ServerStatus
    func uploadOCR(_ items: [OCREvidence]) async throws
    func uploadImage(_ image: EvidenceImage, data: Data) async throws
    func image(id: String) async throws -> Data
    func reportCapture(state: String, reason: String, integrity: Bool) async throws
    func ask(_ question: String) async throws -> ServerTurn
    func turn(id: String, after: Int, waitMilliseconds: Int) async throws -> ServerTurn
    func cancel() async throws
    func history(cursor: String?) async throws -> Data
    func batches(after: String) async throws -> [ServerBatch]
    func retryBatches() async throws -> Int
    func verifyBatches() async throws -> Int
    func models() async throws -> [HermesModelRoute]
    func selectModel(_ route: HermesModelRoute) async throws
    func setDefaultModel(_ route: HermesModelRoute) async throws
    func setSessionVisible(_ visible: Bool) async throws
    func connection(_ action: String) async throws
    func config() async throws -> ServerConfigValues
    func updateConfig(_ changes: [String: String]) async throws -> ServerConfigValues
    func autodetect() async throws -> ServerConfigValues
}

/// Server URL (non-secret, in preferences) and bearer token (in the login Keychain).
public struct ServerEndpoint: Equatable, Sendable {
    public let url: URL; public let token: String
    public init(url: URL, token: String) { self.url = url; self.token = token }

    public static let defaultURL = URL(string: "http://127.0.0.1:8765")!

    /// http is accepted only for loopback, private (RFC 1918), Tailscale (100.64/10) and
    /// `*.ts.net` / `*.local` hosts; anything else must use https.
    public static func validate(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), ["http", "https"].contains(scheme), url.user == nil, url.query == nil else {
            throw ServerAPIError.rejected(status: 0, code: "invalid_url", message: "Server URL must look like http://100.x.y.z:8765 or https://host")
        }
        if scheme == "http" && !Self.isPrivate(host) {
            throw ServerAPIError.rejected(status: 0, code: "insecure_url", message: "Use https for a server outside loopback, a private network or Tailscale.")
        }
        return url
    }

    static func isPrivate(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".ts.net") || host.hasSuffix(".local") || host == "::1" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // Tailscale CGNAT range
        default: return false
        }
    }
}

public enum ServerTokenStore {
    private static let service = "dev.xcreen.server"

    public static func load(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ token: String, account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ServerAPIError.rejected(status: 0, code: "keychain", message: "Could not store the server token in the Keychain (\(status)).") }
    }
}

public final class HTTPXCreenServer: XCreenServerAPI, @unchecked Sendable {
    public static let protocolVersion = 1
    private let endpoint: ServerEndpoint
    private let session: URLSession
    public var endpointURL: URL { endpoint.url }

    public init(endpoint: ServerEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 130
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: endpoint.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        // '+' in an ISO offset would otherwise decode as a space on the server.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], json: Any? = nil, body: Data? = nil, contentType: String? = nil, timeout: TimeInterval = 130, authorized: Bool = true) async throws -> Data {
        var request = URLRequest(url: url(path, query), timeoutInterval: timeout)
        request.httpMethod = method
        if authorized { request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw ServerAPIError.unreachable(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw ServerAPIError.invalidResponse }
        if http.statusCode == 401 { throw ServerAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            throw ServerAPIError.rejected(status: http.statusCode, code: object?["code"] as? String ?? "http_\(http.statusCode)",
                                          message: object?["message"] as? String ?? "xCreen server returned HTTP \(http.statusCode)")
        }
        return data
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["ok"] as? Bool == true else { throw ServerAPIError.invalidResponse }
        return value
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, key: String) throws -> T {
        guard let inner = try object(data)[key] else { throw ServerAPIError.invalidResponse }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: inner, options: [.fragmentsAllowed]))
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public func health() async throws -> Int {
        let value = try object(await send("GET", "v1/health", timeout: 10, authorized: false))
        guard let version = value["protocol"] as? Int else { throw ServerAPIError.invalidResponse }
        guard version == Self.protocolVersion else { throw ServerAPIError.incompatible(version) }
        return version
    }
    public func status() async throws -> ServerStatus { try decode(ServerStatus.self, await send("GET", "v1/status", timeout: 15), key: "status") }
    public func uploadOCR(_ items: [OCREvidence]) async throws {
        let payload = items.map { ["id": $0.id, "timestamp": Self.iso($0.timestamp), "text": $0.text, "app": $0.app, "title": $0.title] }
        _ = try object(await send("POST", "v1/ocr", json: ["items": payload], timeout: 60))
    }
    public func uploadImage(_ image: EvidenceImage, data: Data) async throws {
        let type = data.starts(with: [0xff, 0xd8, 0xff]) ? "image/jpeg" : "image/png"
        _ = try object(await send("PUT", "v1/images/\(image.id)", query: ["timestamp": Self.iso(image.timestamp)], body: data, contentType: type, timeout: 120))
    }
    public func image(id: String) async throws -> Data { try await send("GET", "v1/images/\(id)", timeout: 60) }
    public func reportCapture(state: String, reason: String, integrity: Bool) async throws {
        _ = try object(await send("POST", "v1/capture", json: ["capture": state, "reason": reason, "integrity": integrity], timeout: 15))
    }
    public func ask(_ question: String) async throws -> ServerTurn { try decode(ServerTurn.self, await send("POST", "v1/ask", json: ["question": question]), key: "turn") }
    public func turn(id: String, after: Int, waitMilliseconds: Int) async throws -> ServerTurn {
        try decode(ServerTurn.self, await send("GET", "v1/turns/\(id)", query: ["after": String(after), "wait_ms": String(min(max(waitMilliseconds, 0), 30_000))], timeout: 45), key: "turn")
    }
    public func cancel() async throws { _ = try object(await send("POST", "v1/cancel", json: [String: String]())) }
    public func history(cursor: String?) async throws -> Data {
        let value = try object(await send("GET", "v1/history", query: cursor.map { ["cursor": $0] } ?? [:]))
        return try JSONSerialization.data(withJSONObject: value["history"] ?? [:])
    }
    public func batches(after: String) async throws -> [ServerBatch] { try decode([ServerBatch].self, await send("GET", "v1/batches", query: after.isEmpty ? [:] : ["after": after]), key: "batches") }
    public func retryBatches() async throws -> Int { try decode(Int.self, await send("POST", "v1/batches/retry", json: [String: String](), timeout: 310), key: "requeued") }
    public func verifyBatches() async throws -> Int { try decode(Int.self, await send("POST", "v1/batches/verify", json: [String: String](), timeout: 310), key: "verified") }
    public func models() async throws -> [HermesModelRoute] { try decode([HermesModelRoute].self, await send("GET", "v1/models"), key: "routes") }
    public func selectModel(_ route: HermesModelRoute) async throws { _ = try object(await send("PUT", "v1/model", json: ["provider": route.provider, "model": route.model])) }
    public func setDefaultModel(_ route: HermesModelRoute) async throws { _ = try object(await send("PUT", "v1/model/default", json: ["provider": route.provider, "model": route.model])) }
    public func setSessionVisible(_ visible: Bool) async throws { _ = try object(await send("PUT", "v1/session/visibility", json: ["visible": visible])) }
    public func connection(_ action: String) async throws { _ = try object(await send("POST", "v1/connection", json: ["action": action])) }
    public func config() async throws -> ServerConfigValues { try decode(ServerConfigValues.self, await send("GET", "v1/config"), key: "config") }
    public func updateConfig(_ changes: [String: String]) async throws -> ServerConfigValues { try decode(ServerConfigValues.self, await send("PUT", "v1/config", json: changes), key: "config") }
    public func autodetect() async throws -> ServerConfigValues { try decode(ServerConfigValues.self, await send("POST", "v1/config/autodetect", json: [String: String]()), key: "config") }
}
