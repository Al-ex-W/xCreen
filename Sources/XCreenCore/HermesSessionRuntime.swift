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
private struct QueuedTurn { let id: UUID; let kind: TurnKind; let text: String; let images: [HermesEvidenceAttachment]; let continuation: CheckedContinuation<String, Error>; let integrityEpoch: UInt64; let phaseChanged: (@Sendable (EvidenceStore.BatchState) async throws -> Void)?; let binding: BatchBinding?; let prepared: (@Sendable (String) async throws -> Void)?; let receiptChanged: (@Sendable (BatchReceipt) async throws -> Void)? }

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
    private var awaitingAdmission = false
    private var delayedTerminal: HermesGatewayEvent?
    private var currentOutput = ""
    private var reconcilingTurn: UUID?
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
    public func submitAutomatic(manifest: String, images: [HermesEvidenceAttachment], binding: BatchBinding? = nil, prepared: (@Sendable (String) async throws -> Void)? = nil, receiptChanged: (@Sendable (BatchReceipt) async throws -> Void)? = nil, phaseChanged: (@Sendable (EvidenceStore.BatchState) async throws -> Void)? = nil) async throws { guard !integrity else { throw HermesGatewayError.cancelled }; guard connected else { throw HermesGatewayError.unavailable }; try validate(text: manifest); _ = try await enqueue(kind: .automatic, text: manifest, images: images, id: UUID(), phaseChanged: phaseChanged, binding: binding, prepared: prepared, receiptChanged: receiptChanged) }
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

    private func enqueue(kind: TurnKind, text: String, images: [HermesEvidenceAttachment], id: UUID, phaseChanged: (@Sendable (EvidenceStore.BatchState) async throws -> Void)? = nil, binding: BatchBinding? = nil, prepared: (@Sendable (String) async throws -> Void)? = nil, receiptChanged: (@Sendable (BatchReceipt) async throws -> Void)? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let turn = QueuedTurn(id: id, kind: kind, text: text, images: images, continuation: continuation, integrityEpoch: integrityEpoch, phaseChanged: phaseChanged, binding: binding, prepared: prepared, receiptChanged: receiptChanged)
            if kind == .manual { manual.append(turn) } else { automatic.append(turn) }; drainIfNeeded()
        }
    }
    private func drainIfNeeded() { guard !draining, current == nil, !manual.isEmpty || !automatic.isEmpty else { return }; draining = true; Task { await drainOne() } }
    private func drainOne() async {
        defer { draining = false; if current == nil { drainIfNeeded() } }
        guard connected, let id = session?.runtimeSessionID else { failQueues(HermesGatewayError.unavailable); return }
        let next: QueuedTurn? = !manual.isEmpty ? manual.removeFirst() : (!automatic.isEmpty ? automatic.removeFirst() : nil)
        guard let next else { return }; current = next; currentCancelled = false; currentSubmitting = false; awaitingAdmission = false; delayedTerminal = nil; currentOutput = ""
        do {
            try await compactIfNeeded(incomingTokens: next.text.utf8.count / 3 + next.images.count * 1_000)
            guard current?.id == next.id, !currentCancelled else { throw HermesGatewayError.cancelled }
            currentSubmitting = next.kind == .automatic
            awaitingAdmission = next.kind == .automatic && next.phaseChanged != nil
            if next.kind == .automatic {
                guard !integrity, next.integrityEpoch == integrityEpoch else { throw HermesGatewayError.cancelled }
                try await next.phaseChanged?(.submitting)
                if let binding = next.binding {
                    try await next.prepared?(id) // persist identity before any host-side preparation
                    guard automaticTransmissionAllowed(turnID: next.id, epoch: next.integrityEpoch) else { throw HermesGatewayError.cancelled }
                    let data = try await gateway.prepareBatch(sessionID: id, batchID: binding.batchID, sourceIDs: binding.sourceIDs)
                    guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], reply["prepared"] as? Bool == true,
                          reply["batch_id"] as? String == binding.batchID, reply["session_id"] as? String == id,
                          (reply["source_ids"] as? [String])?.sorted() == binding.sourceIDs.sorted() else { throw HermesGatewayError.protocolFailure }
                }
                guard automaticTransmissionAllowed(turnID: next.id, epoch: next.integrityEpoch) else { throw HermesGatewayError.cancelled }
                try await gateway.submitBatch(sessionID: id, text: next.text, images: next.images, transmissionAllowed: { [weak self] in await self?.automaticTransmissionAllowed(turnID: next.id, epoch: next.integrityEpoch) ?? false })
                try await next.phaseChanged?(.admitted)
            }
            else {
                try await gateway.manualContext(sessionID: id)
                guard current?.id == next.id, !currentCancelled, connected, session?.runtimeSessionID == id else { throw HermesGatewayError.cancelled }
                currentSubmitting = true
                _ = try await gateway.submit(sessionID: id, text: next.text)
            }
            guard current?.id == next.id else { return }
            awaitingAdmission = false
            if let event = delayedTerminal { delayedTerminal = nil; receive(event, generation: connectionGeneration) }
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
        if awaitingAdmission, current?.phaseChanged != nil, ["message.complete", "run.completed", "turn.completed", "message.failed", "run.failed", "turn.failed", "error", "message.cancelled", "run.cancelled", "turn.cancelled", "session.interrupted"].contains(event.type) { delayedTerminal = event; return }
        switch event.type {
        case "message.delta", "message.interim":
            if let object = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any], let payload = object["payload"] as? [String: Any] { currentOutput += payload["text"] as? String ?? "" }
        case "session.info":
            if let object = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any], let payload = object["payload"] as? [String: Any], let usage = payload["usage"] as? [String: Any] { updateContextUsage(tokens: usage["context_used"] as? Int ?? 0, limit: usage["context_max"] as? Int) }
        case "message.complete", "run.completed", "turn.completed", "message.failed", "run.failed", "turn.failed", "error":
            let payload = (try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any])?["payload"] as? [String: Any]
            let failure = Self.providerFailure(type: event.type, payload: payload)
            if failure == nil, let text = payload?["text"] as? String, !text.isEmpty { currentOutput = text }
            if currentCancelled || (current?.kind == .automatic && (integrity || current?.integrityEpoch != integrityEpoch)) { finishCurrent(HermesGatewayError.cancelled) }
            else if let turn = current, let binding = turn.binding, let sessionID = session?.runtimeSessionID {
                guard reconcilingTurn != turn.id else { return }
                reconcilingTurn = turn.id
                Task {
                    do {
                        // Even a failed turn may have produced effects before failing:
                        // reconcile the host receipt before classifying the failure.
                        let receipt = try await self.readReceipt(binding: binding, sessionID: sessionID)
                        guard self.current?.id == turn.id else { return }
                        try await turn.receiptChanged?(receipt)
                        guard self.current?.id == turn.id else { return }
                        if receipt.completesProcessing { self.finishCurrent(nil) }
                        else { self.finishCurrent(failure ?? HermesGatewayError.remoteFailure("batch processing receipt missing or uncertain")) }
                    } catch { if self.current?.id == turn.id { self.finishCurrent(error) } }
                }
            } else if let failure, current?.kind == .automatic { finishCurrent(failure) }
            else if failure != nil, event.type != "message.complete" { finishCurrent(HermesGatewayError.remoteFailure("turn failed")) }
            else {
                // Manual error completions keep Hermes's explanatory text as the answer.
                if let text = payload?["text"] as? String, !text.isEmpty { currentOutput = text }
                finishCurrent(nil)
            }
        case "message.cancelled", "run.cancelled", "turn.cancelled", "session.interrupted": finishCurrent(HermesGatewayError.cancelled)
        default: break
        }
    }
    /// Classify host terminal frames. Stock Hermes closes provider errors with
    /// `message.complete {status:"error", error_surface:{code,...}}`.
    static func providerFailure(type: String, payload: [String: Any]?) -> HermesGatewayError? {
        let failed = ["message.failed", "run.failed", "turn.failed", "error"].contains(type) || payload?["status"] as? String == "error"
        guard failed else { return nil }
        let surface = payload?["error_surface"] as? [String: Any]
        let code = (surface?["code"] as? String ?? "").lowercased()
        let text = ((payload?["error"] as? String ?? "") + " " + (payload?["failure_reason"] as? String ?? "")).lowercased()
        let limited = ["rate_limit", "upstream_rate_limit", "rate_limited"].contains(code)
            || ["429", "rate limit", "rate-limit", "usage limit", "too many requests"].contains { text.contains($0) }
        return .providerFailure(rateLimited: limited)
    }
    private func finishCurrent(_ error: Error?) {
        guard let turn = current else { return }; current = nil
        reconcilingTurn = nil
        if let error { turn.continuation.resume(throwing: error) } else { turn.continuation.resume(returning: currentOutput) }
        drainIfNeeded()
    }
    private func gatewayDisconnected(generation: UInt64) { guard generation == connectionGeneration else { return }; connected = false; eventTask = nil; failQueues(HermesGatewayError.unavailable); finishCurrent(HermesGatewayError.unavailable) }
    private func failQueues(_ error: Error) { let all = manual + automatic; manual.removeAll(); automatic.removeAll(); all.forEach { $0.continuation.resume(throwing: error) } }
    private func waitForIdle() async throws { while current != nil || draining { try await Task.sleep(for: .milliseconds(10)) } }
    public func readReceipt(binding: BatchBinding, sessionID: String) async throws -> BatchReceipt {
        let data = try await gateway.batchReceipt(sessionID: sessionID, batchID: binding.batchID, sourceIDs: binding.sourceIDs)
        return try BatchReceipt(data: data, batchID: binding.batchID, sourceIDs: binding.sourceIDs, sessionID: sessionID)
    }
    private func compactIfNeeded(incomingTokens: Int) async throws { let cap = min(500_000, max(1, contextLimit - incomingTokens - 8_192)); guard contextTokens >= cap, let id = session?.runtimeSessionID else { return }; _ = try await gateway.compress(sessionID: id); contextTokens = 0 }
    private func validate(text: String) throws { guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_000 else { throw HermesGatewayError.protocolFailure } }
}
