import Foundation

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

    public init(gateway: any HermesGatewayTransport, records: HermesSessionRecordStore = UserDefaultsHermesSessionRecordStore(), defaults: UserDefaults = .standard) {
        self.gateway = gateway
        self.defaults = defaults
        sessionVisible = defaults.object(forKey: "xcreen.hermes.sessionVisible") as? Bool ?? false
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
    public func switchModel(model: String, provider: String, apply: @escaping @MainActor () -> Void) async throws {
        try await ordered {
            guard self.connected else { throw HermesGatewayError.unavailable }
            let token = self.generation
            try await self.runtime.switchModel(model: model, provider: provider)
            guard self.connected, self.generation == token else { throw HermesGatewayError.unavailable }
            apply()
        }.value
    }
    public func verifyBatches(launch: HermesGatewayLaunch, store: EvidenceStore) async throws -> Int {
        try await ordered {
            self.readOnlyConnection = true
            defer { self.readOnlyConnection = false }
            try await self.connectLocked(launch: launch)
            var verified = 0
            var failure: Error?
            for binding in await store.batchBindings() {
                guard let sessionID = binding.sessionID else { continue }
                do {
                    let receipt = try await self.runtime.readReceipt(binding: binding, sessionID: sessionID)
                    try await store.reconcile(receipt)
                    if receipt.completesProcessing { verified += 1 }
                } catch {
                    try await store.invalidateReceipt(id: binding.batchID)
                    failure = error
                }
            }
            if let failure { throw failure }
            return verified
        }.value
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
            let inventory = try await runtime.modelOptions()
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
        observer?.cancel(); observer = nil
        publishConnection(false)
        await runtime.disconnect()
    }
}
