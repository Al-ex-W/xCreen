import AppKit
import SwiftUI
import XCreenCore
import XCreenUI

/// The tray/CLI model. Since 2.0 the app is a capture client: it captures and uploads, and
/// every Hermes, batch and vault operation goes to the xCreen server (docs/protocol.md).
@MainActor final class AppState: ObservableObject {
    /// Single switch: off = consent to capture, on = no screenshots, no OCR, no automatic digests.
    @Published var integrity: Bool {
        didSet {
            defaults.set(integrity, forKey: "xcreen.integrity")
            guard integrity != oldValue else { return }
            log.write(.app, "integrity \(integrity ? "on" : "off")")
            log.updateStatus(["integrity": integrity ? "on" : "off"])
            if integrity { captureService?.userPause() }
            else { _ = captureService?.enableAfterExplicitConsent() }
            reportIntegritySoon()
        }
    }
    @Published var query = ""
    @Published var lastQuestion = ""
    @Published var submissionMessage = ""
    @Published var batchMetadata = ""
    @Published var batchCursor = ""
    @Published var captureStatus = "Capture safety not yet verified"
    @Published var showSettings = false
    @Published var hermesPython = ""
    @Published var hermesRoot = ""
    @Published var vaultPath = ""
    @Published var serverURL = ""
    @Published var serverToken = ""
    @Published var connected = false
    @Published var streamedReply = ""
    @Published var hermesModels: [HermesModelRoute] = []
    @Published var selectedHermesModel = ""
    @Published var appendix: [EvidenceImage] = []
    @Published private(set) var serverStatus: ServerStatus?
    @Published private(set) var serverReachable = false
    @Published private(set) var serverError = ""
    @Published private(set) var uploadState = Uploader.State()
    /// Drives the tray thinking indicator and the menu bar icon swap.
    @Published var askGenerating = false { didSet { if askGenerating != oldValue { AppDelegate.shared?.setGenerating(askGenerating) } } }

    private var server: (any XCreenServerAPI)?
    private var evidenceStore: EvidenceStore?
    private var captureService: CaptureService?
    private var uploader: Uploader?
    private var poller: Task<Void, Never>?
    private var activeTurn: String?
    private let appendixCache = AppendixCache()
    private let defaults: UserDefaults
    private let log = ActivityLog.shared
    private static let serverURLKey = "xcreen.server.url"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        integrity = defaults.object(forKey: "xcreen.integrity") as? Bool ?? true
        serverURL = defaults.string(forKey: Self.serverURLKey) ?? ServerEndpoint.defaultURL.absoluteString
        log.write(.app, "started pid=\(ProcessInfo.processInfo.processIdentifier)")
        log.updateStatus(["app": "running", "server": "connecting", "integrity": integrity ? "on" : "off", "capture": "paused"])
        do {
            let store = try EvidenceStore(root: EvidenceStore.defaultRoot)
            evidenceStore = store
            let uploader = Uploader(store: store, log: { message in ActivityLog.shared.write(.batch, message) }, onChange: { state in
                Task { @MainActor [weak self] in self?.uploadState = state }
            })
            self.uploader = uploader
            captureService = CaptureService(
                store: store,
                status: { [weak self] value in self?.captureStatus = value },
                safetyChanged: { _ in },
                captured: { Task { await uploader.kick() } }
            )
            if !integrity { _ = captureService?.enableAfterExplicitConsent(requestPermission: false) }
        } catch {
            captureStatus = "Capture blocked — local outbox could not be opened."
        }
        appendixCache.prune()  // copies from earlier answers never outlive the app session
        configureServer()
    }

    // MARK: server connection

    private var endpoint: ServerEndpoint? {
        guard let url = try? ServerEndpoint.validate(serverURL), let token = ServerTokenStore.load(account: url.absoluteString), !token.isEmpty else { return nil }
        return ServerEndpoint(url: url, token: token)
    }

    private func configureServer() {
        server = endpoint.map { HTTPXCreenServer(endpoint: $0) }
        let server = self.server
        Task { await uploader?.setServer(server) }
        if server == nil { serverError = ServerAPIError.notConfigured.localizedDescription; serverReachable = false }
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Saves the URL (preferences) and token (Keychain), then reconnects. An empty token keeps the stored one.
    func saveServer(url: String, token: String?) throws {
        let validated = try ServerEndpoint.validate(url)
        if let token, !token.isEmpty {
            guard token.count >= 32, token.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { throw LocalControlError.invalidRequest("token looks invalid (expected the value of xcreen-server token)") }
            try ServerTokenStore.save(token, account: validated.absoluteString)
        } else if ServerTokenStore.load(account: validated.absoluteString) == nil {
            throw LocalControlError.invalidRequest("no token stored for \(validated.absoluteString); pass the server token")
        }
        serverURL = validated.absoluteString
        defaults.set(serverURL, forKey: Self.serverURLKey)
        serverToken = ""
        log.write(.app, "server set to \(serverURL)")
        configureServer()
    }

    func saveServerSettings() {
        do { try saveServer(url: serverURL, token: serverToken) ; submissionMessage = "Server saved." }
        catch { submissionMessage = error.localizedDescription }
    }

    private func requireServer() throws -> any XCreenServerAPI {
        guard let server else { throw ServerAPIError.notConfigured }
        return server
    }

    func refreshStatus() async {
        guard let server else { return }
        do {
            _ = try await server.health()
            let status = try await server.status()
            apply(status)
            if !serverReachable { log.write(.app, "server reachable at \(serverURL) (\(status.version))") }
            serverReachable = true; serverError = ""
            log.updateStatus(["server": "reachable", "hermes": status.hermes.connected ? "connected" : "disconnected"])
        } catch {
            if serverReachable { log.write(.error, "server unreachable: \(error.localizedDescription)") }
            serverReachable = false; serverError = error.localizedDescription; connected = false
            log.updateStatus(["server": "unreachable"])
        }
    }

    private func apply(_ status: ServerStatus) {
        serverStatus = status
        connected = status.hermes.connected
        if let current = status.model.current { selectedHermesModel = current.id }
        else if status.model.applied { selectedHermesModel = status.model.default.id }
    }

    private func reportIntegritySoon() {
        // CaptureService records the new status asynchronously; give it a moment, then upload it.
        Task { [uploader] in
            try? await Task.sleep(for: .milliseconds(300))
            await uploader?.kick()
        }
    }

    // MARK: tray surface

    var status: String {
        guard server != nil else { return "No server configured · set the server URL and token in Settings" }
        guard serverReachable else { return "Server unreachable · capture keeps queuing locally" }
        if connected, let hold = serverStatus?.digestHold, !hold.isEmpty, !integrity { return "Server \(serverStatus?.version ?? "") · digests on hold · \(hold)" }
        if connected { return "Server \(serverStatus?.version ?? "") · Hermes connected · xCreen session" }
        return "Server reachable · Hermes disconnected"
    }
    var canAsk: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var sessionVisible: Bool { serverStatus?.sessionVisible ?? false }
    var visibilityStatus: String {
        guard let status = serverStatus else { return "Unknown until the server answers." }
        return status.visibilityPending ? "Saved preference; pending Hermes confirmation." : "Confirmed by Hermes for this session."
    }
    var modelDefaultStatus: String {
        guard let model = serverStatus?.model else { return "xCreen default: unknown until the server answers." }
        return "xCreen default: \(model.default.provider) · \(model.default.model). \(model.status)"
    }
    var queueStatus: String {
        let pending = uploadState.pendingImages + uploadState.pendingOCR
        return pending == 0 ? "Outbox empty." : "Outbox: \(uploadState.pendingImages) screenshots, \(uploadState.pendingOCR) OCR snapshots waiting to upload."
    }

    func submitQuestion() {
        runControl(["command": "ask", "question": query.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    func runControl(_ fields: [String: String]) {
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await control(LocalControlCommand.decode(JSONSerialization.data(withJSONObject: fields))) }
            catch { submissionMessage = error.localizedDescription }
        }
    }

    func switchHermesModel(_ routeID: String) {
        guard let route = hermesModels.first(where: { $0.id == routeID }) else { return }
        runControl(["command": "model", "provider": route.provider, "model": route.model])
    }

    func autodetectLocalSetup(overwrite: Bool = true) { runControl(["command": "autodetect"]) }

    func saveHermesExecutable() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let values = try await requireServer().updateConfig(["hermes_python": hermesPython, "hermes_root": hermesRoot, "vault": vaultPath])
                applyConfig(values); submissionMessage = "Server settings saved; Hermes reconnected."
            } catch { submissionMessage = "Server settings: \(error.localizedDescription)" }
        }
    }

    private func applyConfig(_ values: ServerConfigValues) {
        hermesPython = values.hermesPython; hermesRoot = values.hermesRoot; vaultPath = values.vault
    }

    func acceptURLQuery(_ value: String) {
        query = AskFieldPolicy.prefill(value)
        submissionMessage = ""
    }

    // MARK: questions

    private func startQuestion(_ question: String) async throws -> TurnCompletion {
        let server = try requireServer()
        let turn = try await server.ask(question)
        activeTurn = turn.id
        streamedReply = ""; appendix = []; appendixCache.prune(); submissionMessage = "Asking Hermes…"
        lastQuestion = question
        query = AskFieldPolicy.fieldAfterAdmission(current: query, submitted: question)
        askGenerating = true
        let completion = TurnCompletion()
        Task { @MainActor in
            var current = turn
            defer { if self.activeTurn == turn.id { self.askGenerating = false; self.activeTurn = nil } }
            do {
                while !current.done {
                    current = try await server.turn(id: turn.id, after: current.version, waitMilliseconds: 25_000)
                    if self.activeTurn == turn.id { self.streamedReply = current.text }
                }
                switch current.state {
                case "completed":
                    completion.reply = current.text
                    if self.activeTurn == turn.id { self.submissionMessage = "Hermes response complete."; self.resolveAppendix(current.text) }
                case "cancelled":
                    completion.error = LocalControlError.failed("The question was cancelled.")
                    if self.activeTurn == turn.id { self.submissionMessage = "Question cancelled." }
                default:
                    completion.error = LocalControlError.failed(current.error ?? "Hermes did not answer.")
                    if self.activeTurn == turn.id { self.submissionMessage = "Hermes did not answer: \(current.error ?? "unknown error")" }
                }
            } catch {
                completion.error = error
                if self.activeTurn == turn.id { self.submissionMessage = "Hermes did not answer: \(error.localizedDescription)" }
            }
            completion.done = true
        }
        return completion
    }

    /// Screenshots the answer cites (`xcreen-image:<id>`) are fetched from the server into a
    /// private cache so the tray can show and open them.
    private func resolveAppendix(_ reply: String) {
        let ids = EvidenceReferences.imageIDs(in: reply)
        appendixCache.prune(keeping: Set(ids))
        guard let server, !ids.isEmpty else { appendix = []; return }
        let cache = appendixCache
        Task { [weak self] in
            var found: [EvidenceImage] = []
            for id in ids {
                guard let image = try? await server.image(id: id),
                      let stored = try? cache.store(id: id, data: image.data, capturedAt: image.capturedAt) else { continue }
                found.append(stored)
            }
            guard let self, self.streamedReply == reply else { return }
            self.appendix = found
        }
    }

    // MARK: control surface

    /// The sole command surface for both the tray and the private local CLI.
    func control(_ command: LocalControlCommand) async throws -> LocalControlResponse {
        switch command.name {
        case .status: await refreshStatus()
        case .history:
            let data = try await requireServer().history(cursor: command.value)
            return .ok(snapshot(), reply: String(data: data, encoding: .utf8))
        case .batches:
            let rows = try await requireServer().batches(after: command.value ?? "")
            batchMetadata = rows.map { "\($0.id) · \($0.state) · attempts \($0.attempts) · receipt \($0.receipt?.status ?? "missing") · verified \($0.receipt?.verified ?? false) · effects \($0.receipt?.effects ?? 0)" }.joined(separator: "\n")
            if rows.isEmpty { batchMetadata = "No more retained batches." }
            batchCursor = rows.last?.id ?? ""
            return .ok(snapshot(), reply: String(data: try JSONEncoder().encode(rows), encoding: .utf8))
        case .retrybatches:
            let count = try await requireServer().retryBatches()
            batchMetadata = "Re-queued \(count) batches whose host receipt proves zero effects. Batches with effects or unknown effects stay uncertain."
            return .ok(snapshot(), reply: batchMetadata)
        case .modeldefault:
            if let provider = command.provider, let model = command.model {
                try await requireServer().setDefaultModel(HermesModelRoute(provider: provider, model: model))
            } else if command.provider != nil || command.model != nil { throw LocalControlError.invalidRequest("model default needs PROVIDER and MODEL") }
            await refreshStatus()
            return .ok(snapshot(), reply: modelDefaultStatus)
        case .verify:
            let count = try await requireServer().verifyBatches()
            batchMetadata = "Verified \(count) retained batch receipts. No inference or note writes."
            return .ok(snapshot(), reply: batchMetadata)
        case .integrity:
            if command.value == nil { break }
            guard let value = command.value, ["on", "off"].contains(value) else { throw LocalControlError.invalidRequest("integrity value must be on or off") }
            // Off is explicit user consent, equivalent to the tray's toggle. Capture still
            // fails closed when macOS permission or state guards reject it.
            if value == "off", !integrity { _ = captureService?.enableAfterExplicitConsent() }
            integrity = value == "on"
        case .connect, .disconnect, .reconnect:
            try await requireServer().connection(command.name.rawValue)
            await refreshStatus()
        case .models:
            hermesModels = try await requireServer().models()
            await refreshStatus()
        case .visibility:
            if let value = command.value {
                guard value == "on" || value == "off" else { throw LocalControlError.invalidRequest("visibility must be on or off") }
                try await requireServer().setSessionVisible(value == "on")
                await refreshStatus()
            }
            return .ok(snapshot(), reply: "Session visibility \(sessionVisible ? "on" : "off"). \(visibilityStatus)")
        case .model:
            if hermesModels.isEmpty { hermesModels = (try? await requireServer().models()) ?? [] }
            guard let provider = command.provider, let model = command.model, hermesModels.contains(where: { $0.provider == provider && $0.model == model }) else { throw LocalControlError.invalidRequest("unknown configured provider/model") }
            try await requireServer().selectModel(HermesModelRoute(provider: provider, model: model))
            selectedHermesModel = HermesModelRoute(provider: provider, model: model).id
            await refreshStatus()
        case .settings:
            if let value = command.value {
                let pieces = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard pieces.count == 2 else { throw LocalControlError.invalidRequest("settings value must be key=value") }
                let keys = ["python": "hermes_python", "root": "hermes_root", "vault": "vault", "timezone": "timezone"]
                guard let key = keys[pieces[0]] else { throw LocalControlError.invalidRequest("unknown setting (python, root, vault or timezone; paths are on the server)") }
                applyConfig(try await requireServer().updateConfig([key: pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)]))
            } else {
                applyConfig(try await requireServer().config())
            }
        case .autodetect:
            applyConfig(try await requireServer().autodetect())
            submissionMessage = "Detected Hermes and vault on the server."
        case .ask:
            guard let question = command.question else { throw LocalControlError.invalidRequest("ask needs question") }
            let completion = try await startQuestion(question)
            if let wait = command.waitMilliseconds, wait > 0 {
                let deadline = ContinuousClock.now + .milliseconds(wait)
                while !completion.done && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                if let error = completion.error { throw error }
                return .ok(snapshot(), reply: completion.done ? completion.reply : nil)
            }
            return .ok(snapshot(), reply: nil)
        case .cancel:
            try await requireServer().cancel()
            submissionMessage = "Question cancellation requested."
        case .images:
            if let id = command.value {
                guard let image = appendix.first(where: { $0.id == id }) else { throw LocalControlError.invalidRequest("unknown reply image") }
                guard NSWorkspace.shared.open(image.fileURL) else { throw LocalControlError.failed("image could not be opened") }
            }
        case .panel:
            if command.value == "hide" { AppDelegate.shared?.popover.performClose(nil) } else { AppDelegate.shared?.showPanel() }
        case .server:
            if let value = command.value { try saveServer(url: value, token: command.token) }
            await refreshStatus()
            return .ok(snapshot(), reply: serverReachable ? "Server \(serverURL) reachable (\(serverStatus?.version ?? "?"))." : "Server \(serverURL): \(serverError)")
        case .flush:
            let sent = await uploader?.drain() ?? 0
            await refreshStatus()
            return .ok(snapshot(), reply: "Uploaded \(sent) items. \(queueStatus)")
        case .quit:
            captureService?.pause(reason: "Capture suspended · quitting")
            await uploader?.drain(maximum: 50)
            await uploader?.stop()
            Task { try? await Task.sleep(for: .milliseconds(300)); NSApplication.shared.terminate(nil) }
        }
        return .ok(snapshot())
    }

    private func snapshot() -> LocalControlSnapshot {
        let routes = hermesModels.map { LocalControlModel(provider: $0.provider, model: $0.model) }
        let current = serverStatus?.model.current.map { LocalControlModel(provider: $0.provider, model: $0.model) }
        let images = appendix.map { LocalControlImage(id: $0.id, timestamp: $0.timestamp) }
        var result = LocalControlSnapshot(app: "running", connected: connected, integrity: integrity, capture: captureStatus, message: submissionMessage, models: routes, currentModel: current, settings: .init(python: hermesPython, root: hermesRoot, vault: vaultPath), images: images)
        result.sessionVisible = sessionVisible
        result.actualSessionVisible = serverStatus?.sessionVisibleConfirmed
        result.sessionVisibilityPending = serverStatus?.visibilityPending ?? true
        if let model = serverStatus?.model {
            result.defaultModel = LocalControlModel(provider: model.default.provider, model: model.default.model)
            result.defaultModelApplied = model.applied
            result.defaultModelStatus = model.status
        }
        result.nextBatchRetry = serverStatus?.nextRetry.flatMap { ISO8601DateFormatter().date(from: String($0.prefix(19)) + "Z") }
        result.server = LocalControlServerInfo(url: serverURL, reachable: serverReachable, version: serverStatus?.version, error: serverError,
                                               pendingImages: uploadState.pendingImages, pendingOCR: uploadState.pendingOCR, batches: serverStatus?.batches ?? [:])
        return result
    }
}

@MainActor private final class TurnCompletion { var done = false; var error: Error?; var reply: String? }

extension AppState: TrayPanelModel {}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    lazy var state = AppState()
    var item: NSStatusItem!
    let popover = NSPopover()
    private var controlServer: LocalControlServer?
    private var handoffs = AskHandoffInbox()

    /// Set before app.run so an App Intent arriving during a cold launch is buffered, not lost.
    override init() { super.init(); Self.shared = self }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        do { controlServer = try LocalControlServer { [weak self] command in
            guard let self else { throw LocalControlError.unavailable("app stopped") }
            return try await self.state.control(command)
        } }
        catch { NSApplication.shared.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "xCreen")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(state: state))
        if let handoff = handoffs.markReady() {
            // Let the status item get laid out before anchoring the popover to it.
            DispatchQueue.main.async { [weak self] in self?.perform(handoff) }
        }
    }

    /// Cheap menu bar swap while a question is generating (static: menu bar symbols don't animate).
    func setGenerating(_ generating: Bool) {
        guard item != nil else { return }
        item.button?.image = NSImage(systemSymbolName: generating ? "arrow.counterclockwise.circle" : "display", accessibilityDescription: generating ? "xCreen, thinking" : "xCreen")
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func showPanel() { if !popover.isShown { toggle() } }
    func applicationWillTerminate(_ notification: Notification) { controlServer?.stop() }

    /// A cold launch by URL (Spotlight/App Intent, `open xcreen://…`) delivers this before
    /// applicationDidFinishLaunching: the status item does not exist yet and AppState must not be
    /// constructed before the control-server lock. Buffer until launch completes.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let handoff = handoffs.receive(urls: urls) { perform(handoff) }
    }

    /// Opens/fills the panel only; the user still submits the question.
    /// In-process delivery from App Intents (openAppWhenRun runs perform() inside this app).
    /// Buffered on cold launch like URLs; fills the panel, never submits.
    func receiveIntent(_ handoff: PanelHandoff) {
        if let ready = handoffs.receive(handoff) { perform(ready) }
    }

    private func perform(_ handoff: PanelHandoff) {
        if case .ask(let question) = handoff { state.acceptURLQuery(question) }
        showPanel()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
