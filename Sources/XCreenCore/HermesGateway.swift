import Foundation
import CoreFoundation

public enum HermesGatewayError: LocalizedError, Equatable {
    case invalidLaunch, unavailable, deadlineExceeded, protocolFailure, cancelled
    case remoteFailure(String)
    public var errorDescription: String? {
        switch self {
        case .invalidLaunch: return "A local Hermes gateway launcher is required."
        case .unavailable: return "Hermes gateway is not connected."
        case .deadlineExceeded: return "Hermes gateway did not answer before the deadline."
        case .protocolFailure: return "Hermes gateway returned an invalid response."
        case .cancelled: return "The xCreen turn was cancelled before completion."
        case .remoteFailure(let message): return "Hermes gateway rejected the request: \(message)"
        }
    }
}

/// Starts only the bundled local adapter. The adapter owns the inspected Hermes import
/// surface; the app never synthesizes provider credentials or changes user defaults.
public enum HermesGatewayLaunch: Sendable, Equatable {
    case bundled(python: String, hermesRoot: String, evidenceRoot: String, vault: String?)
    case command(executable: String, arguments: [String], workingDirectory: String? = nil)
    // Kept for synthetic compatibility tests of the old raw entry point.
    case python(executable: String, gatewayEntry: String)

    fileprivate func processConfiguration() throws -> (String, [String], URL?) {
        switch self {
        case let .bundled(python, hermesRoot, evidenceRoot, vault):
            guard Self.executable(python), Self.directory(hermesRoot), Self.directory(evidenceRoot),
                  let launcher = Bundle.main.url(forResource: "xcreen_gateway", withExtension: "py", subdirectory: "runtime") else { throw HermesGatewayError.invalidLaunch }
            var arguments = ["-B", launcher.path, "--hermes-root", hermesRoot, "--evidence-root", evidenceRoot]
            if let vault, !vault.isEmpty { guard Self.directory(vault) else { throw HermesGatewayError.invalidLaunch }; arguments += ["--vault", vault] }
            return (python, arguments, launcher.deletingLastPathComponent())
        case let .python(executable, gatewayEntry):
            guard Self.executable(executable), gatewayEntry.hasPrefix("/"), FileManager.default.fileExists(atPath: gatewayEntry) else { throw HermesGatewayError.invalidLaunch }
            let entry = URL(fileURLWithPath: gatewayEntry)
            guard entry.lastPathComponent == "entry.py", entry.deletingLastPathComponent().lastPathComponent == "tui_gateway" else { throw HermesGatewayError.invalidLaunch }
            return (executable, ["-u", "-m", "tui_gateway.entry"], entry.deletingLastPathComponent().deletingLastPathComponent())
        case let .command(executable, arguments, workingDirectory):
            guard Self.executable(executable), arguments.count <= 16, arguments.allSatisfy({ $0.utf8.count <= 4_096 }) else { throw HermesGatewayError.invalidLaunch }
            return (executable, arguments, workingDirectory.map(URL.init(fileURLWithPath:)))
        }
    }
    private static func executable(_ path: String) -> Bool { path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) }
    private static func directory(_ path: String) -> Bool { path.hasPrefix("/") && (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}

public struct HermesSessionIdentity: Codable, Equatable, Sendable { public let storedID: String; public let runtimeID: String; public init(storedID: String, runtimeID: String) { self.storedID = storedID; self.runtimeID = runtimeID } }
public struct HermesGatewayCapabilities: Codable, Equatable, Sendable { public let perSessionExclusiveSubmit: Bool; public init(perSessionExclusiveSubmit: Bool) { self.perSessionExclusiveSubmit = perSessionExclusiveSubmit } }
public struct HermesGatewayEvent: Sendable { public let type: String; public let payload: Data; public init(type: String, payload: Data) { self.type = type; self.payload = payload } }
public struct HermesEvidenceAttachment: Sendable { public let id: String; public let timestamp: Date; public let fileURL: URL; public init(id: String, timestamp: Date, fileURL: URL) { self.id = id; self.timestamp = timestamp; self.fileURL = fileURL } }

public protocol HermesGatewayTransport: Sendable {
    func start(launch: HermesGatewayLaunch) async throws
    func events() async -> AsyncStream<HermesGatewayEvent>
    func gatewayCapabilities() async throws -> HermesGatewayCapabilities
    func open(storedSessionID: String?) async throws -> HermesSessionIdentity
    func models(sessionID: String) async throws -> Data
    func history(sessionID: String) async throws -> Data
    func historyPage(sessionID: String, cursor: String?) async throws -> Data
    func manualContext(sessionID: String) async throws
    func prepareBatch(sessionID: String, batchID: String, sourceIDs: [String]) async throws -> Data
    func batchReceipt(sessionID: String, batchID: String, sourceIDs: [String]) async throws -> Data
    func setHidden(sessionID: String, hidden: Bool) async throws -> Bool
    func switchModel(sessionID: String, model: String, provider: String) async throws -> Data
    func compress(sessionID: String) async throws -> Data
    func submit(sessionID: String, text: String) async throws -> Data
    func submitBatch(sessionID: String, text: String, images: [HermesEvidenceAttachment], transmissionAllowed: @escaping @Sendable () async -> Bool) async throws
    func cancel(sessionID: String) async throws -> Data
    func stop() async
}

public extension HermesGatewayTransport {
    func manualContext(sessionID: String) async throws { throw HermesGatewayError.unavailable }
    func historyPage(sessionID: String, cursor: String?) async throws -> Data { throw HermesGatewayError.unavailable }
    func prepareBatch(sessionID: String, batchID: String, sourceIDs: [String]) async throws -> Data { throw HermesGatewayError.unavailable }
    func batchReceipt(sessionID: String, batchID: String, sourceIDs: [String]) async throws -> Data { throw HermesGatewayError.unavailable }
    func setHidden(sessionID: String, hidden: Bool) async throws -> Bool { throw HermesGatewayError.unavailable }
    func history(sessionID: String) async throws -> Data { throw HermesGatewayError.unavailable }
}

public actor HermesGateway: HermesGatewayTransport {
    private var process: Process?
    private var processToken: UUID?
    private var input: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var isReady = false
    /// Broadcast: the session runtime and the UI each hold their own subscription.
    private var subscribers: [UUID: AsyncStream<HermesGatewayEvent>.Continuation] = [:]
    private let defaultDeadline: TimeInterval
    private let maximumLineBytes = 1_048_576

    /// Gateway stderr goes to `~/Library/Logs/xCreen/gateway.log` (shown by `xcreen logs --gateway`).
    private static func stderrSink() -> FileHandle {
        let url = ActivityLog.defaultDirectory.appendingPathComponent("gateway.log")
        try? FileManager.default.createDirectory(at: ActivityLog.defaultDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return FileHandle.nullDevice }
        _ = try? handle.seekToEnd()
        return handle
    }

    public init(defaultDeadline: TimeInterval = 20) { self.defaultDeadline = min(max(defaultDeadline, 0.1), 60) }

    public func start(launch: HermesGatewayLaunch) async throws {
        guard process == nil else { return }
        let token = UUID(); processToken = token
        let (executable, arguments, directory) = try launch.processConfiguration()
        let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments; child.currentDirectoryURL = directory
        child.environment = ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1"]) { _, new in new }
        let stdin = Pipe(), stdout = Pipe(); child.standardInput = stdin; child.standardOutput = stdout; child.standardError = Self.stderrSink()
        child.terminationHandler = { [weak self] _ in Task { await self?.disconnect(token: token) } }
        try child.run(); process = child; input = stdin.fileHandleForWriting
        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            var remainder = Data(); var discardingOversizeLine = false
            while !Task.isCancelled {
                let chunk = reader.availableData; guard !chunk.isEmpty else { break }; remainder.append(chunk)
                while let newline = remainder.firstIndex(of: 10) {
                    let line = Data(remainder[..<newline]); remainder.removeSubrange(...newline)
                    if !discardingOversizeLine && line.count <= 1_048_576 { await self?.receive(line, token: token) }
                    discardingOversizeLine = false
                }
                if remainder.count > 1_048_576 { remainder.removeAll(keepingCapacity: false); discardingOversizeLine = true }
            }
            await self?.disconnect(token: token)
        }
        try await waitForReady(); _ = try await request("client.capabilities", ["server_requests": false])
    }

    public func events() -> AsyncStream<HermesGatewayEvent> {
        let id = UUID(), pair = AsyncStream<HermesGatewayEvent>.makeStream(bufferingPolicy: .bufferingNewest(1_024))
        subscribers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return pair.stream
    }
    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
    private func broadcast(_ event: HermesGatewayEvent) { subscribers.values.forEach { $0.yield(event) } }
    public func gatewayCapabilities() async throws -> HermesGatewayCapabilities { let object = try decodeObject(await request("gateway.capabilities", [:])); return .init(perSessionExclusiveSubmit: object["per_session_exclusive_submit"] as? Bool ?? false) }
    public func open(storedSessionID: String?) async throws -> HermesSessionIdentity {
        let reply = try await request(storedSessionID?.isEmpty == false ? "session.resume" : "session.create", storedSessionID?.isEmpty == false ? ["session_id": storedSessionID!, "lazy": true, "inline_images": false] : ["source": "desktop", "title": "xCreen", "hidden": true, "close_on_disconnect": false])
        let object = try decodeObject(reply)
        // session.create and live re-attach return `stored_session_id`; a cold session.resume returns `resumed`.
        let stored = (object["stored_session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? object["resumed"] as? String
        guard let stored, !stored.isEmpty, let runtime = object["session_id"] as? String, !runtime.isEmpty else { throw HermesGatewayError.protocolFailure }
        if let requested = storedSessionID, !requested.isEmpty, stored != requested { throw HermesGatewayError.protocolFailure }
        return .init(storedID: stored, runtimeID: runtime)
    }
    public func models(sessionID: String) async throws -> Data { try await request("model.options", ["session_id": sessionID, "explicit_only": false]) }
    public func history(sessionID: String) async throws -> Data { try await request("session.history", ["session_id": sessionID]) }
    public func historyPage(sessionID: String, cursor: String?) async throws -> Data {
        var params: [String: Any] = ["session_id": sessionID, "max_bytes": 48_000, "limit": 20]
        if let cursor { params["cursor"] = cursor }
        let data = try await request("xcreen.history.page", params)
        guard data.count <= 48_000 else { throw HermesGatewayError.protocolFailure }
        return data
    }
    public func manualContext(sessionID: String) async throws {
        let reply = try decodeObject(await request("xcreen.batch.context", ["session_id": sessionID, "mode": "manual"]))
        guard reply["session_id"] as? String == sessionID, reply["mode"] as? String == "manual" else { throw HermesGatewayError.protocolFailure }
    }
    public func prepareBatch(sessionID: String, batchID: String, sourceIDs: [String]) async throws -> Data {
        try await request("xcreen.batch.prepare", ["session_id": sessionID, "batch_id": batchID, "source_ids": sourceIDs])
    }
    public func batchReceipt(sessionID: String, batchID: String, sourceIDs: [String]) async throws -> Data {
        try await request("xcreen.batch.receipt", ["session_id": sessionID, "batch_id": batchID, "source_ids": sourceIDs, "reconcile": true])
    }
    public func setHidden(sessionID: String, hidden: Bool) async throws -> Bool {
        let reply = try decodeObject(await request("session.set_hidden", ["session_id": sessionID, "hidden": hidden]))
        guard let flag = reply["hidden"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              let key = reply["session_key"] as? String, !key.isEmpty else { throw HermesGatewayError.protocolFailure }
        return flag.boolValue
    }
    public func switchModel(sessionID: String, model: String, provider: String) async throws -> Data { guard validText(model, max: 256), validText(provider, max: 128) else { throw HermesGatewayError.protocolFailure }; return try await request("slash.exec", ["session_id": sessionID, "command": "/model \(model) --provider \(provider) --session"]) }
    public func compress(sessionID: String) async throws -> Data { try await request("session.compress", ["session_id": sessionID]) }
    public func submit(sessionID: String, text: String) async throws -> Data { guard validText(text, max: 32_000) else { throw HermesGatewayError.protocolFailure }; return try await request("prompt.submit", ["session_id": sessionID, "text": text]) }
    public func submitBatch(sessionID: String, text: String, images: [HermesEvidenceAttachment], transmissionAllowed: @escaping @Sendable () async -> Bool) async throws {
        guard !images.isEmpty, images.count <= 64, validText(text, max: 32_000) else { throw HermesGatewayError.protocolFailure }
        for image in images {
            guard await transmissionAllowed(), image.id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil, image.fileURL.isFileURL else { throw HermesGatewayError.cancelled }
            let bytes = try Data(contentsOf: image.fileURL, options: [.mappedIfSafe]); guard !bytes.isEmpty, bytes.count <= 8 * 1024 * 1024, await transmissionAllowed() else { throw HermesGatewayError.cancelled }
            _ = try await request("image.attach_bytes", ["session_id": sessionID, "content_base64": bytes.base64EncodedString(), "filename": "\(image.id).png"])
        }
        guard await transmissionAllowed() else { throw HermesGatewayError.cancelled }; _ = try await submit(sessionID: sessionID, text: text)
    }
    public func cancel(sessionID: String) async throws -> Data { try await request("session.interrupt", ["session_id": sessionID]) }
    public func stop() { process?.terminate(); disconnect() }

    private func waitForReady() async throws {
        guard process?.isRunning == true else { throw HermesGatewayError.unavailable }; if isReady { return }; let token = UUID()
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters[token] = continuation
            Task { [weak self] in try? await Task.sleep(for: .seconds(self?.defaultDeadline ?? 0)); await self?.expireReady(token) }
        }
    }
    private func expireReady(_ token: UUID) { readyWaiters.removeValue(forKey: token)?.resume(throwing: HermesGatewayError.deadlineExceeded) }
    private func request(_ method: String, _ params: [String: Any]) async throws -> Data {
        guard let input, process?.isRunning == true else { throw HermesGatewayError.unavailable }; let id = nextID; nextID += 1
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]; let data = try JSONSerialization.data(withJSONObject: frame)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input.write(contentsOf: data + Data([10])); Task { [weak self] in try? await Task.sleep(for: .seconds(self?.defaultDeadline ?? 0)); await self?.expire(id: id) } }
            catch { pending.removeValue(forKey: id); continuation.resume(throwing: error) }
        }
    }
    private func expire(id: Int) { pending.removeValue(forKey: id)?.resume(throwing: HermesGatewayError.deadlineExceeded) }
    private func receive(_ line: Data, token: UUID) {
        guard token == processToken else { return }
        guard line.count <= maximumLineBytes, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if object["method"] as? String == "event", let params = object["params"] as? [String: Any], let type = params["type"] as? String, JSONSerialization.isValidJSONObject(params), let payload = try? JSONSerialization.data(withJSONObject: params) {
            if type == "gateway.ready" { isReady = true; let waiters = readyWaiters; readyWaiters.removeAll(); waiters.values.forEach { $0.resume() } }; broadcast(.init(type: type, payload: payload)); return
        }
        guard let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = object["error"] as? [String: Any] { continuation.resume(throwing: HermesGatewayError.remoteFailure(error["message"] as? String ?? "unknown error")) }
        else if let result = object["result"], JSONSerialization.isValidJSONObject(result), let data = try? JSONSerialization.data(withJSONObject: result) { continuation.resume(returning: data) }
        else { continuation.resume(throwing: HermesGatewayError.protocolFailure) }
    }
    private func disconnect(token: UUID) { guard token == processToken else { return }; disconnect() }
    private func disconnect() { processToken = nil; process = nil; input = nil; isReady = false; let ended = subscribers; subscribers.removeAll(); ended.values.forEach { $0.finish() }; let waiters = readyWaiters; readyWaiters.removeAll(); waiters.values.forEach { $0.resume(throwing: HermesGatewayError.unavailable) }; let waiting = pending; pending.removeAll(); waiting.values.forEach { $0.resume(throwing: HermesGatewayError.unavailable) } }
    private func decodeObject(_ data: Data) throws -> [String: Any] { guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HermesGatewayError.protocolFailure }; return value }
    private func validText(_ value: String, max: Int) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= max }
}
