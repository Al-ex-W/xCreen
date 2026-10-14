import Foundation

public struct HermesSessionRecord: Codable, Equatable, Sendable { public var storedSessionID: String; public var runtimeSessionID: String; public init(storedSessionID: String, runtimeSessionID: String) { self.storedSessionID = storedSessionID; self.runtimeSessionID = runtimeSessionID } }

public struct HermesModelRoute: Identifiable, Equatable, Sendable {
    public let provider: String; public let model: String; public let supportsVision: Bool; public let imageLimit: Int?
    public var id: String { "\(provider)::\(model)" }
    public init(provider: String, model: String, supportsVision: Bool = false, imageLimit: Int? = nil) { self.provider = provider; self.model = model; self.supportsVision = supportsVision; self.imageLimit = imageLimit }
    /// Preserve the provider inventory's configured identifiers. No aliases are reconstructed.
    public static func decodeInventory(_ data: Data) throws -> [HermesModelRoute] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let providers = root["providers"] as? [[String: Any]] else { throw HermesGatewayError.protocolFailure }
        // Shape from hermes_cli.inventory.build_model_options_payload:
        // providers[] = {slug, name, is_current, models: [String], capabilities: {model: {...}}}.
        // The inventory carries no vision flag, so vision stays false (unknown) here.
        var routes: [HermesModelRoute] = []
        for provider in providers {
            guard let slug = provider["slug"] as? String, !slug.isEmpty else { continue }
            for model in provider["models"] as? [String] ?? [] where !model.isEmpty {
                routes.append(HermesModelRoute(provider: slug, model: model))
            }
        }
        return routes
    }
}

public protocol HermesSessionRecordStore: Sendable { func load() -> HermesSessionRecord?; func save(_ record: HermesSessionRecord) }
public final class UserDefaultsHermesSessionRecordStore: HermesSessionRecordStore, @unchecked Sendable {
    private let defaults: UserDefaults; private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "xcreen.hermes.session.record") { self.defaults = defaults; self.key = key }
    public func load() -> HermesSessionRecord? { guard let data = defaults.data(forKey: key) else { return nil }; return try? JSONDecoder().decode(HermesSessionRecord.self, from: data) }
    public func save(_ record: HermesSessionRecord) { defaults.set(try? JSONEncoder().encode(record), forKey: key) }
}

private enum TurnKind { case manual, automatic }
private struct QueuedTurn { let id: UUID; let kind: TurnKind; let text: String; let images: [HermesEvidenceAttachment]; let continuation: CheckedContinuation<String, Error>; let integrityEpoch: UInt64 }

/// Actor-owned turn queue for the dedicated xCreen session. SharedSessionController
/// serializes lifecycle transactions across awaits. Admission is not completion:
/// a queue item remains current until a terminal gateway event arrives.
public actor HermesSessionRuntime {
    private let gateway: any HermesGatewayTransport
    private let records: HermesSessionRecordStore
    private var session: HermesSessionRecord?
    private var manual: [QueuedTurn] = []; private var automatic: [QueuedTurn] = []
    private var current: QueuedTurn?; private var draining = false; private var eventTask: Task<Void, Never>?
    private var cancelledManual: Set<UUID> = []
    private var currentCancelled = false
    private var currentSubmitting = false
    private var currentOutput = ""
    private var connectionGeneration: UInt64 = 0
    private var connected = false
    private var contextTokens = 0; private var contextLimit = 500_000; private var integrity = true; private var integrityEpoch: UInt64 = 0

    public init(gateway: any HermesGatewayTransport, records: HermesSessionRecordStore = UserDefaultsHermesSessionRecordStore()) { self.gateway = gateway; self.records = records; self.session = records.load() }
    deinit { eventTask?.cancel() }

    public func connect(launch: HermesGatewayLaunch) async throws {
        connectionGeneration &+= 1
        let token = connectionGeneration
        try await gateway.start(launch: launch); let identity = try await gateway.open(storedSessionID: session?.storedSessionID)
        guard token == connectionGeneration else { throw HermesGatewayError.unavailable }
        let record = HermesSessionRecord(storedSessionID: identity.storedID, runtimeSessionID: identity.runtimeID); session = record; records.save(record)
        guard try await gateway.gatewayCapabilities().perSessionExclusiveSubmit else { throw HermesGatewayError.protocolFailure }
        guard token == connectionGeneration else { throw HermesGatewayError.unavailable }
        connected = true
        await observeEvents(generation: token)
    }
    public func disconnect() async {
        connectionGeneration &+= 1; connected = false
        eventTask?.cancel(); eventTask = nil
        failQueues(HermesGatewayError.unavailable); finishCurrent(HermesGatewayError.unavailable)
        await gateway.stop()
    }
    public func setIntegrity(_ enabled: Bool) async {
        integrity = enabled; guard enabled else { return }; integrityEpoch &+= 1
        let rejected = automatic; automatic.removeAll(); rejected.forEach { $0.continuation.resume(throwing: HermesGatewayError.cancelled) }
        if current?.kind == .automatic, let id = session?.runtimeSessionID { _ = try? await gateway.cancel(sessionID: id) }
    }
    public func submitManual(_ text: String, turnID: UUID = UUID()) async throws { _ = try await submitManualResult(text, turnID: turnID) }
    public func submitManualResult(_ text: String, turnID: UUID = UUID(), connectionToken: UInt64? = nil) async throws -> String {
        try validate(text: text)
        guard cancelledManual.remove(turnID) == nil else { throw HermesGatewayError.cancelled }
        guard connected else { throw HermesGatewayError.unavailable }
        if let connectionToken, connectionToken != connectionGeneration { throw HermesGatewayError.unavailable }
        return try await enqueue(kind: .manual, text: text, images: [], id: turnID)
    }
    public func submitAutomatic(manifest: String, images: [HermesEvidenceAttachment]) async throws { guard !integrity else { throw HermesGatewayError.cancelled }; guard connected else { throw HermesGatewayError.unavailable }; try validate(text: manifest); _ = try await enqueue(kind: .automatic, text: manifest, images: images, id: UUID()) }
    public func switchModel(model: String, provider: String) async throws { try await waitForIdle(); guard let id = session?.runtimeSessionID else { throw HermesGatewayError.unavailable }; _ = try await gateway.switchModel(sessionID: id, model: model, provider: provider) }
    public func cancel() async throws {
        let target = current?.kind == .manual ? current?.id : manual.first?.id
        guard let target else { throw HermesGatewayError.unavailable }
        try await cancelManual(turnID: target)
    }
    /// Cancel an admitted user question, not whichever automatic turn owns the session.
    /// A tombstone covers cancellation before the caller's submission task is scheduled.
    public func cancelManual(turnID: UUID) async throws {
        if let index = manual.firstIndex(where: { $0.id == turnID }) {
            manual.remove(at: index).continuation.resume(throwing: HermesGatewayError.cancelled)
        } else if current?.id == turnID {
            currentCancelled = true
            if currentSubmitting, let id = session?.runtimeSessionID { _ = try await gateway.cancel(sessionID: id) }
        } else { cancelledManual.insert(turnID) }
    }
    public func modelOptions() async throws -> Data { try await waitForIdle(); guard let id = session?.runtimeSessionID else { throw HermesGatewayError.unavailable }; return try await gateway.models(sessionID: id) }
    public func updateContextUsage(tokens: Int, limit: Int?) { contextTokens = max(0, tokens); if let limit, limit > 0 { contextLimit = limit } }
    public func currentSession() -> HermesSessionRecord? { session }
    public func connectionToken() -> UInt64 { connectionGeneration }

    private func enqueue(kind: TurnKind, text: String, images: [HermesEvidenceAttachment], id: UUID) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let turn = QueuedTurn(id: id, kind: kind, text: text, images: images, continuation: continuation, integrityEpoch: integrityEpoch)
            if kind == .manual { manual.append(turn) } else { automatic.append(turn) }; drainIfNeeded()
        }
    }
    private func drainIfNeeded() { guard !draining, current == nil, !manual.isEmpty || !automatic.isEmpty else { return }; draining = true; Task { await drainOne() } }
    private func drainOne() async {
        defer { draining = false; if current == nil { drainIfNeeded() } }
        guard connected, let id = session?.runtimeSessionID else { failQueues(HermesGatewayError.unavailable); return }
        let next: QueuedTurn? = !manual.isEmpty ? manual.removeFirst() : (!automatic.isEmpty ? automatic.removeFirst() : nil)
        guard let next else { return }; current = next; currentCancelled = false; currentSubmitting = false; currentOutput = ""
        do {
            try await compactIfNeeded(incomingTokens: next.text.utf8.count / 3 + next.images.count * 1_000)
            guard current?.id == next.id, !currentCancelled else { throw HermesGatewayError.cancelled }
            currentSubmitting = true
            if next.kind == .automatic { guard !integrity, next.integrityEpoch == integrityEpoch else { throw HermesGatewayError.cancelled }; try await gateway.submitBatch(sessionID: id, text: next.text, images: next.images, transmissionAllowed: { [weak self] in await self?.automaticTransmissionAllowed(turnID: next.id, epoch: next.integrityEpoch) ?? false }) }
            else { _ = try await gateway.submit(sessionID: id, text: next.text) }
            // Completion is intentionally deferred to a terminal event.
        } catch { if current?.id == next.id { finishCurrent(error) } }
    }
    private func automaticTransmissionAllowed(turnID: UUID, epoch: UInt64) -> Bool { connected && !integrity && integrityEpoch == epoch && current?.id == turnID && current?.kind == .automatic }
    private func observeEvents(generation: UInt64) async {
        eventTask?.cancel()
        let events = await gateway.events()
        eventTask = Task { [weak self] in
            for await event in events { await self?.receive(event, generation: generation) }; await self?.gatewayDisconnected(generation: generation)
        }
    }
    private func receive(_ event: HermesGatewayEvent, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        switch event.type {
        case "message.delta", "message.interim":
            if let object = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any], let payload = object["payload"] as? [String: Any] { currentOutput += payload["text"] as? String ?? "" }
        case "session.info":
            if let object = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any], let payload = object["payload"] as? [String: Any], let usage = payload["usage"] as? [String: Any] { updateContextUsage(tokens: usage["context_used"] as? Int ?? 0, limit: usage["context_max"] as? Int) }
        case "message.complete", "run.completed", "turn.completed":
            if let object = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any], let payload = object["payload"] as? [String: Any], let text = payload["text"] as? String, !text.isEmpty { currentOutput = text }
            if currentCancelled || (current?.kind == .automatic && (integrity || current?.integrityEpoch != integrityEpoch)) { finishCurrent(HermesGatewayError.cancelled) } else { finishCurrent(nil) }
        case "message.failed", "run.failed", "turn.failed", "error": finishCurrent(HermesGatewayError.remoteFailure("turn failed"))
        case "message.cancelled", "run.cancelled", "turn.cancelled", "session.interrupted": finishCurrent(HermesGatewayError.cancelled)
        default: break
        }
    }
    private func finishCurrent(_ error: Error?) {
        guard let turn = current else { return }; current = nil
        if let error { turn.continuation.resume(throwing: error) } else { turn.continuation.resume(returning: currentOutput) }
        drainIfNeeded()
    }
    private func gatewayDisconnected(generation: UInt64) { guard generation == connectionGeneration else { return }; connected = false; eventTask = nil; failQueues(HermesGatewayError.unavailable); finishCurrent(HermesGatewayError.unavailable) }
    private func failQueues(_ error: Error) { let all = manual + automatic; manual.removeAll(); automatic.removeAll(); all.forEach { $0.continuation.resume(throwing: error) } }
    private func waitForIdle() async throws { while current != nil || draining { try await Task.sleep(for: .milliseconds(10)) } }
    private func compactIfNeeded(incomingTokens: Int) async throws { let cap = min(500_000, max(1, contextLimit - incomingTokens - 8_192)); guard contextTokens >= cap, let id = session?.runtimeSessionID else { return }; _ = try await gateway.compress(sessionID: id); contextTokens = 0 }
    private func validate(text: String) throws { guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_000 else { throw HermesGatewayError.protocolFailure } }
}
