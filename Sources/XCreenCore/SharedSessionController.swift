import Foundation

/// xCreen-owned model preference. Applied only to the dedicated xCreen session through
/// the session-scoped switch; Hermes global config and profiles are never touched.
public struct XCreenModelPreference: Codable, Equatable, Sendable {
    public let provider: String; public let model: String
    public init(provider: String, model: String) { self.provider = provider; self.model = model }
    public var id: String { "\(provider)::\(model)" }
    /// Cheap, fast default for automatic five-minute batches.
    public static let builtIn = XCreenModelPreference(provider: "anthropic", model: "claude-haiku-5-5")
}

/// Shared native action owner. Lifecycle operations are FIFO transactions, including
/// every await. Integrity uses a separate lane so a slow connection cannot delay pause.
@MainActor public final class SharedSessionController {
    public let runtime: HermesSessionRuntime
    private let gateway: any HermesGatewayTransport
    private var integrityTail: Task<Void, Never>?
    private var lifecycleTail: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var configuredLaunch: HermesGatewayLaunch?
    public private(set) var connected = false
    public private(set) var readOnlyConnection = false
    public private(set) var generation: UInt64 = 0
    public var connectionChanged: (@MainActor (Bool) -> Void)?
    public var eventReceived: (@MainActor (HermesGatewayEvent) -> Void)?
    public var connectionReady: (@MainActor (HermesSessionRecord, Data) -> Void)?
    public private(set) var activeManualID: UUID?
    private var cancelledQuestions: Set<UUID> = []
    private var runtimeAdmissions: Set<UUID> = []
    private let defaults: UserDefaults
    public private(set) var sessionVisible: Bool
    public private(set) var actualSessionVisible: Bool?
    public var visibilityChanged: (@MainActor () -> Void)?
    public var visibilityPending: Bool { actualSessionVisible != sessionVisible }
    public private(set) var modelPreference: XCreenModelPreference
    /// Human-readable; "applied" only after the host inventory confirmed the route.
    public private(set) var modelPreferenceStatus = "Not applied yet; waiting for the xCreen session."
    public private(set) var modelPreferenceApplied = false
    static let modelProviderKey = "xcreen.hermes.model.provider", modelIDKey = "xcreen.hermes.model.id"

    public init(gateway: any HermesGatewayTransport, records: HermesSessionRecordStore = UserDefaultsHermesSessionRecordStore(), defaults: UserDefaults = .standard) {
        self.gateway = gateway
        self.defaults = defaults
        sessionVisible = defaults.object(forKey: "xcreen.hermes.sessionVisible") as? Bool ?? false
        if let provider = defaults.string(forKey: Self.modelProviderKey), let model = defaults.string(forKey: Self.modelIDKey), !provider.isEmpty, !model.isEmpty {
            modelPreference = XCreenModelPreference(provider: provider, model: model)
        } else { modelPreference = .builtIn }
        runtime = HermesSessionRuntime(gateway: gateway, records: records)
    }
    deinit { observer?.cancel() }
    public func setIntegrity(_ value: Bool) -> Task<Void, Never> {
        let previous = integrityTail
        let task = Task { [runtime] in
            await previous?.value
            await runtime.setIntegrity(value)
        }
        integrityTail = task
        return task
    }
    /// Queue synchronously on MainActor; completion/error never breaks the next item.
    private func ordered<T>(_ operation: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
        let previous = lifecycleTail
        let task = Task { await previous?.value; return try await operation() }
        lifecycleTail = Task { _ = try? await task.value }
        return task
    }
    public func connect(launch: HermesGatewayLaunch) async throws {
        try await ordered { try await self.connectLocked(launch: launch) }.value
    }
    public func disconnect() async {
        _ = try? await ordered { await self.disconnectLocked() }.value
    }
    /// Save intent even offline; only a validated gateway acknowledgment establishes actual state.
    public func setSessionVisible(_ visible: Bool) async throws {
        try await ordered {
            self.sessionVisible = visible
            self.defaults.set(visible, forKey: "xcreen.hermes.sessionVisible")
            self.visibilityChanged?()
            guard self.connected else { return }
            try await self.applyVisibilityLocked()
        }.value
    }
    private func applyVisibilityLocked() async throws {
        actualSessionVisible = nil
        visibilityChanged?()
        guard let identity = await runtime.currentSession() else { throw HermesGatewayError.unavailable }
        let token = generation
        let hidden = try await gateway.setHidden(sessionID: identity.runtimeSessionID, hidden: !sessionVisible)
        guard token == generation, hidden == !sessionVisible else { throw HermesGatewayError.protocolFailure }
        actualSessionVisible = !hidden
        visibilityChanged?()
    }
    /// Reserve identity before creating any task or awaiting connection. Cancel always
    /// refers to this question, including when automatic work is occupying the runtime.
    public func admitManual(_ text: String, launch: HermesGatewayLaunch) throws -> Task<String, Error> {
        guard activeManualID == nil else { throw HermesGatewayError.remoteFailure("a manual turn is already active; use cancel or history") }
        let id = UUID(); activeManualID = id
        let admission = ordered { try await self.connectLocked(launch: launch); return (self.generation, await self.runtime.connectionToken()) }
        return Task {
            defer { if self.activeManualID == id { self.activeManualID = nil }; self.cancelledQuestions.remove(id); self.runtimeAdmissions.remove(id) }
            let (token, runtimeToken) = try await admission.value
            guard !self.cancelledQuestions.contains(id) else { throw HermesGatewayError.cancelled }
            guard self.connected, self.generation == token else { throw HermesGatewayError.unavailable }
            self.runtimeAdmissions.insert(id)
            return try await self.runtime.submitManualResult(text, turnID: id, connectionToken: runtimeToken)
        }
    }
    public func cancelManual() async throws {
        guard let id = activeManualID else { throw HermesGatewayError.remoteFailure("no admitted manual question to cancel") }
        cancelledQuestions.insert(id)
        if runtimeAdmissions.contains(id) { try await runtime.cancelManual(turnID: id) }
    }
    public func reconnect(launch: HermesGatewayLaunch) async throws {
        try await ordered { await self.disconnectLocked(); try await self.connectLocked(launch: launch) }.value
    }
    public func readModelOptions(launch: HermesGatewayLaunch, apply: @escaping @MainActor (Data) throws -> Void) async throws {
        try await ordered {
            try await self.connectLocked(launch: launch)
            let token = self.generation
            let data = try await self.runtime.modelOptions()
            guard self.connected, self.generation == token else { throw HermesGatewayError.unavailable }
            try apply(data)
        }.value
    }
    /// Picker/CLI selection: switch the xCreen session, then persist it as the xCreen default.
    public func switchModel(model: String, provider: String, apply: @escaping @MainActor () -> Void) async throws {
        try await ordered {
            guard self.connected else { throw HermesGatewayError.unavailable }
            let token = self.generation
            try await self.runtime.switchModel(model: model, provider: provider)
            guard self.connected, self.generation == token else { throw HermesGatewayError.unavailable }
            self.persistModelPreference(XCreenModelPreference(provider: provider, model: model))
            self.modelPreferenceApplied = true
            self.modelPreferenceStatus = "Applied to the xCreen session."
            apply()
        }.value
    }
    /// `xcreen model default PROVIDER MODEL`. Offline, the preference is saved and applied
    /// on the next connect; connected, it must exist in the live inventory or is rejected.
    public func setDefaultModel(_ preference: XCreenModelPreference) async throws {
        try await ordered {
            guard self.connected else {
                self.persistModelPreference(preference)
                self.modelPreferenceApplied = false
                self.modelPreferenceStatus = "Saved; will be applied to the xCreen session on connect."
                return
            }
            let token = self.generation
            let inventory = try await self.runtime.modelOptions()
            guard self.generation == token else { throw HermesGatewayError.unavailable }
            guard (try HermesModelRoute.decodeInventory(inventory)).contains(where: { $0.provider == preference.provider && $0.model == preference.model }) else {
                throw HermesGatewayError.remoteFailure("\(preference.provider) · \(preference.model) is not in Hermes's configured model inventory; default unchanged")
            }
            self.persistModelPreference(preference)
            _ = await self.applyModelPreferenceLocked(inventory: inventory, token: token)
        }.value
    }
    private func persistModelPreference(_ preference: XCreenModelPreference) {
        modelPreference = preference
        defaults.set(preference.provider, forKey: Self.modelProviderKey)
        defaults.set(preference.model, forKey: Self.modelIDKey)
    }
    /// Resolve the preference against live `model.options`; never substitute another route.
    private func applyModelPreferenceLocked(inventory: Data, token: UInt64) async -> Data {
        let preference = modelPreference
        modelPreferenceApplied = false
        guard let routes = try? HermesModelRoute.decodeInventory(inventory) else {
            modelPreferenceStatus = "Unavailable: Hermes model inventory could not be read; session model unchanged."
            return inventory
        }
        guard routes.contains(where: { $0.provider == preference.provider && $0.model == preference.model }) else {
            // Providers spell the same model differently (claude-haiku-5-5 vs anthropic/claude-haiku-5.5).
            func leaf(_ model: String) -> String { (model.split(separator: "/").last.map(String.init) ?? model).replacingOccurrences(of: ".", with: "-") }
            let wanted = leaf(preference.model)
            let alternatives = routes.filter { leaf($0.model) == wanted }.map { "\($0.provider) · \($0.model)" }
            modelPreferenceStatus = "Unavailable: \(preference.provider) · \(preference.model) is not in Hermes's configured inventory; session model unchanged (no fallback)." + (alternatives.isEmpty ? "" : " Configured alternatives: \(alternatives.prefix(3).joined(separator: ", ")).")
            return inventory
        }
        let root = try? JSONSerialization.jsonObject(with: inventory) as? [String: Any]
        if root?["provider"] as? String == preference.provider, root?["model"] as? String == preference.model {
            modelPreferenceApplied = true; modelPreferenceStatus = "Applied to the xCreen session."
            return inventory
        }
        do {
            try await runtime.switchModel(model: preference.model, provider: preference.provider)
            guard generation == token else { return inventory }
            // The gateway already verified Hermes's session-scoped ack. model.options can't confirm it:
            // on a lazy session without a live agent it reports the profile default, not the override.
            modelPreferenceApplied = true; modelPreferenceStatus = "Applied to the xCreen session."
            return (try? await runtime.modelOptions()) ?? inventory
        } catch {
            modelPreferenceStatus = "Switch to \(preference.provider) · \(preference.model) failed: \(error.localizedDescription)"
            return inventory
        }
    }
    public func verifyBatches(launch: HermesGatewayLaunch, store: EvidenceStore) async throws -> Int {
        try await ordered { try await self.verifyBatchesLocked(launch: launch, store: store) }.value
    }
    /// Startup and `xcreen batches retry`: verify, then return only receipt-proven
    /// effect-free, non-terminal uncertain batches to pending. Never submits inference
    /// itself and never touches batches with effects, unknown effects or old hosts.
    public func recoverRetryableBatches(launch: HermesGatewayLaunch, store: EvidenceStore) async throws -> Int {
        try await ordered {
            var failure: Error?
            do { _ = try await self.verifyBatchesLocked(launch: launch, store: store) } catch { failure = error }
            var requeued = 0
            for id in await store.uncertainBatchIDs().sorted() where try await store.requeueRetrySafe(id: id) { requeued += 1 }
            if let failure, requeued == 0 { throw failure }
            return requeued
        }.value
    }
    private func verifyBatchesLocked(launch: HermesGatewayLaunch, store: EvidenceStore) async throws -> Int {
        readOnlyConnection = true
        defer { readOnlyConnection = false }
        try await connectLocked(launch: launch)
        var verified = 0
        var failure: Error?
        for binding in await store.batchBindings() {
            guard let sessionID = binding.sessionID else { continue }
            do {
                let receipt = try await runtime.readReceipt(binding: binding, sessionID: sessionID)
                try await store.reconcile(receipt)
                if receipt.completesProcessing { verified += 1 }
            } catch {
                try await store.invalidateReceipt(id: binding.batchID)
                failure = error
            }
        }
        if let failure { throw failure }
        return verified
    }
    public func historyPage(launch: HermesGatewayLaunch, cursor: String? = nil) async throws -> Data {
        try await ordered {
            try await self.connectLocked(launch: launch)
            guard let identity = await self.runtime.currentSession() else { throw HermesGatewayError.unavailable }
            return try await self.gateway.historyPage(sessionID: identity.runtimeSessionID, cursor: cursor)
        }.value
    }
    public func history(launch: HermesGatewayLaunch) async throws -> Data {
        try await ordered {
            try await self.connectLocked(launch: launch)
            guard let identity = await self.runtime.currentSession() else { throw HermesGatewayError.unavailable }
            return try await self.gateway.history(sessionID: identity.runtimeSessionID)
        }.value
    }
    /// A value-type launch is frozen before enqueueing; persistence, teardown and
    /// replacement are one transaction. Reconnect errors are not persistence success.
    public func configure(launch: HermesGatewayLaunch, persist: @escaping @MainActor () -> Void) async throws {
        try await configure(prepare: { (launch, persist) })
    }
    /// Discovery belongs inside the gate too: a later explicit save cannot be
    /// overwritten by an earlier detector that happens to finish late.
    public func configure(prepare: @escaping @MainActor () async throws -> (HermesGatewayLaunch, @MainActor () -> Void)) async throws {
        try await ordered {
            let (launch, persist) = try await prepare()
            self.configuredLaunch = launch
            persist()
            await self.disconnectLocked()
            try await self.connectLocked(launch: launch)
        }.value
    }
    private func publishConnection(_ value: Bool) {
        connected = value
        if !value { actualSessionVisible = nil; visibilityChanged?() }
        connectionChanged?(value)
    }
    private func connectLocked(launch: HermesGatewayLaunch) async throws {
        guard !connected else { return }
        generation &+= 1
        let token = generation
        do {
            try await runtime.connect(launch: configuredLaunch ?? launch)
            // Visibility failure leaves desired saved/pending, not a falsely confirmed state.
            do { try await applyVisibilityLocked() } catch { actualSessionVisible = nil; visibilityChanged?() }
            let stream = await gateway.events()
            observer = Task { [weak self] in
                for await event in stream {
                    guard let self, self.generation == token else { return }
                    self.eventReceived?(event)
                }
                guard let self, self.generation == token else { return }
                self.generation &+= 1
                self.publishConnection(false)
            }
            var inventory = try await runtime.modelOptions()
            guard generation == token else { throw HermesGatewayError.unavailable }
            // Before connectionReady: pending automatic work must run on the xCreen default.
            inventory = await applyModelPreferenceLocked(inventory: inventory, token: token)
            let identity = await runtime.currentSession()
            guard generation == token, let identity else { throw HermesGatewayError.unavailable }
            publishConnection(true)
            connectionReady?(identity, inventory)
        } catch {
            await disconnectLocked()
            throw error
        }
    }
    private func disconnectLocked() async {
        generation &+= 1
        modelPreferenceApplied = false
        observer?.cancel(); observer = nil
        publishConnection(false)
        await runtime.disconnect()
    }
}
