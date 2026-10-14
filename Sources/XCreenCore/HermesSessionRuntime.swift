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
private struct QueuedTurn { let kind: TurnKind; let text: String; let images: [HermesEvidenceAttachment]; let continuation: CheckedContinuation<Void, Error>; let integrityEpoch: UInt64 }

/// One actor serializes every operation for the dedicated xCreen session. Admission is
/// not completion: a queue item remains current until a terminal gateway event arrives.
public actor HermesSessionRuntime {
    private let gateway: any HermesGatewayTransport
    private let records: HermesSessionRecordStore
    private var session: HermesSessionRecord?
    private var manual: [QueuedTurn] = []; private var automatic: [QueuedTurn] = []
    private var current: QueuedTurn?; private var draining = false; private var eventTask: Task<Void, Never>?
    private var contextTokens = 0; private var contextLimit = 500_000; private var integrity = true; private var integrityEpoch: UInt64 = 0

    public init(gateway: any HermesGatewayTransport, records: HermesSessionRecordStore = UserDefaultsHermesSessionRecordStore()) { self.gateway = gateway; self.records = records; self.session = records.load() }
    deinit { eventTask?.cancel() }

    public func connect(launch: HermesGatewayLaunch) async throws {
        try await gateway.start(launch: launch); let identity = try await gateway.open(storedSessionID: session?.storedSessionID)
        let record = HermesSessionRecord(storedSessionID: identity.storedID, runtimeSessionID: identity.runtimeID); session = record; records.save(record)
        guard try await gateway.gatewayCapabilities().perSessionExclusiveSubmit else { throw HermesGatewayError.protocolFailure }
        observeEventsIfNeeded()
    }
    public func disconnect() async { await gateway.stop() }
    public func setIntegrity(_ enabled: Bool) async {
        integrity = enabled; guard enabled else { return }; integrityEpoch &+= 1
        let rejected = automatic; automatic.removeAll(); rejected.forEach { $0.continuation.resume(throwing: HermesGatewayError.cancelled) }
        if current?.kind == .automatic, let id = session?.runtimeSessionID { _ = try? await gateway.cancel(sessionID: id) }
    }
    public func submitManual(_ text: String) async throws { try validate(text: text); try await enqueue(kind: .manual, text: text, images: []) }
    public func submitAutomatic(manifest: String, images: [HermesEvidenceAttachment]) async throws { guard !integrity else { throw HermesGatewayError.cancelled }; try validate(text: manifest); try await enqueue(kind: .automatic, text: manifest, images: images) }
    public func switchModel(model: String, provider: String) async throws { try await waitForIdle(); guard let id = session?.runtimeSessionID else { throw HermesGatewayError.unavailable }; _ = try await gateway.switchModel(sessionID: id, model: model, provider: provider) }
    public func cancel() async throws { guard let id = session?.runtimeSessionID else { throw HermesGatewayError.unavailable }; _ = try await gateway.cancel(sessionID: id) }
    public func modelOptions() async throws -> Data { try await waitForIdle(); guard let id = session?.runtimeSessionID else { throw HermesGatewayError.unavailable }; return try await gateway.models(sessionID: id) }
    public func updateContextUsage(tokens: Int, limit: Int?) { contextTokens = max(0, tokens); if let limit, limit > 0 { contextLimit = limit } }
    public func currentSession() -> HermesSessionRecord? { session }

    private func enqueue(kind: TurnKind, text: String, images: [HermesEvidenceAttachment]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let turn = QueuedTurn(kind: kind, text: text, images: images, continuation: continuation, integrityEpoch: integrityEpoch)
            if kind == .manual { manual.append(turn) } else { automatic.append(turn) }; drainIfNeeded()
        }
    }
    private func drainIfNeeded() { guard !draining, current == nil else { return }; draining = true; Task { await drainOne() } }
    private func drainOne() async {
        defer { draining = false }
        guard let id = session?.runtimeSessionID else { failQueues(HermesGatewayError.unavailable); return }
        let next: QueuedTurn? = !manual.isEmpty ? manual.removeFirst() : (!automatic.isEmpty ? automatic.removeFirst() : nil)
        guard let next else { return }; current = next
        do {
            try await compactIfNeeded(incomingTokens: next.text.utf8.count / 3 + next.images.count * 1_000)
            if next.kind == .automatic { guard !integrity, next.integrityEpoch == integrityEpoch else { throw HermesGatewayError.cancelled }; try await gateway.submitBatch(sessionID: id, text: next.text, images: next.images, transmissionAllowed: { [weak self] in await self?.automaticTransmissionAllowed(epoch: next.integrityEpoch) ?? false }) }
            else { _ = try await gateway.submit(sessionID: id, text: next.text) }
            // Completion is intentionally deferred to a terminal event.
        } catch { finishCurrent(error) }
    }
    private func automaticTransmissionAllowed(epoch: UInt64) -> Bool { !integrity && integrityEpoch == epoch && current?.kind == .automatic }
    private func observeEventsIfNeeded() {
        guard eventTask == nil else { return }; eventTask = Task { [weak self, gateway] in
            let events = await gateway.events(); for await event in events { await self?.receive(event) }; await self?.gatewayDisconnected()
        }
    }
    private func receive(_ event: HermesGatewayEvent) {
        switch event.type {
        case "session.info":
            if let object = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any], let payload = object["payload"] as? [String: Any], let usage = payload["usage"] as? [String: Any] { updateContextUsage(tokens: usage["context_used"] as? Int ?? 0, limit: usage["context_max"] as? Int) }
        case "message.complete", "run.completed", "turn.completed":
            if current?.kind == .automatic, integrity { finishCurrent(HermesGatewayError.cancelled) } else { finishCurrent(nil) }
        case "message.failed", "run.failed", "turn.failed", "error": finishCurrent(HermesGatewayError.remoteFailure("turn failed"))
        case "message.cancelled", "run.cancelled", "turn.cancelled", "session.interrupted": finishCurrent(HermesGatewayError.cancelled)
        default: break
        }
    }
    private func finishCurrent(_ error: Error?) {
        guard let turn = current else { return }; current = nil
        if let error { turn.continuation.resume(throwing: error) } else { turn.continuation.resume() }
        drainIfNeeded()
    }
    private func gatewayDisconnected() { eventTask = nil; finishCurrent(HermesGatewayError.unavailable); failQueues(HermesGatewayError.unavailable) }
    private func failQueues(_ error: Error) { let all = manual + automatic; manual.removeAll(); automatic.removeAll(); all.forEach { $0.continuation.resume(throwing: error) } }
    private func waitForIdle() async throws { while current != nil || draining { try await Task.sleep(for: .milliseconds(10)) } }
    private func compactIfNeeded(incomingTokens: Int) async throws { let cap = min(500_000, max(1, contextLimit - incomingTokens - 8_192)); guard contextTokens >= cap, let id = session?.runtimeSessionID else { return }; _ = try await gateway.compress(sessionID: id); contextTokens = 0 }
    private func validate(text: String) throws { guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_000 else { throw HermesGatewayError.protocolFailure } }
}
