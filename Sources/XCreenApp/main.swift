import AppKit
import SwiftUI
import XCreenCore

@MainActor final class AppState: ObservableObject {
    /// Single switch: off = consent to capture, on = no screenshots, no OCR, no automatic turns.
    @Published var integrity: Bool {
        didSet {
            defaults.set(integrity, forKey: "xcreen.integrity")
            guard integrity != oldValue else { return }
            let value = integrity
            log.write(.app, "integrity \(value ? "on" : "off")")
            log.updateStatus(["integrity": value ? "on" : "off"])
            captureSafe = false
            integrityTransition = controller.setIntegrity(true)
            if value { captureService?.userPause() }
            else { _ = captureService?.enableAfterExplicitConsent() }
        }
    }
    @Published var query = ""
    @Published var submissionMessage = ""
    @Published var batchMetadata = ""
    @Published var batchCursor = ""
    @Published var captureStatus = "Capture safety not yet verified"
    private var captureSafe = false
    private func captureSafetyChanged(_ safe: Bool) {
        guard captureSafe != safe else { return }
        captureSafe = safe
        integrityTransition = controller.setIntegrity(integrity || !safe)
        if safe && !integrity {
            Task { [weak self] in
                guard let self else { return }
                await self.integrityTransition?.value
                await self.submitPendingBatches()
            }
        }
    }
    @Published var showSettings = false
    @Published var hermesPython = ""
    @Published var hermesRoot = ""
    @Published var vaultPath = ""
    @Published var connected = false
    @Published var streamedReply = ""
    @Published var hermesModels: [HermesModelRoute] = []
    @Published var selectedHermesModel = ""
    @Published var appendix: [EvidenceImage] = []

    private let gateway = HermesGateway()
    private let controller: SharedSessionController
    private var sessionRuntime: HermesSessionRuntime { controller.runtime }
    private var integrityTransition: Task<Void, Never>?
    private var manualPresentationID: UUID?
    private var evidenceStore: EvidenceStore?
    private var captureService: CaptureService?
    private var storedSessionID = ""
    private var runtimeSessionID = ""

    private var inFlightBatches: Set<String> = []
    private let defaults: UserDefaults
    private let log = ActivityLog.shared

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        controller = SharedSessionController(gateway: gateway, records: UserDefaultsHermesSessionRecordStore(defaults: defaults), defaults: defaults)

        integrity = defaults.object(forKey: "xcreen.integrity") as? Bool ?? true
        integrityTransition = controller.setIntegrity(true) // Transmission blocked until current safety verified.
        hermesPython = defaults.string(forKey: "xcreen.hermes.python") ?? ""
        hermesRoot = defaults.string(forKey: "xcreen.hermes.root") ?? ""
        vaultPath = defaults.string(forKey: "xcreen.vault.path") ?? ""
        storedSessionID = defaults.string(forKey: "xcreen.hermes.session") ?? ""
        controller.connectionChanged = { [weak self] value in
            guard let self else { return }
            self.connected = value
            self.log.updateStatus(["hermes": value ? "connected" : "disconnected"])
        }
        controller.eventReceived = { [weak self] event in self?.receiveGatewayEvent(event) }
        controller.visibilityChanged = { [weak self] in self?.objectWillChange.send() }
        controller.connectionReady = { [weak self] identity, inventory in
            guard let self else { return }
            self.storedSessionID = identity.storedSessionID
            self.runtimeSessionID = identity.runtimeSessionID
            self.hermesModels = (try? HermesModelRoute.decodeInventory(inventory)) ?? []
            self.applyInventorySelection(inventory)
            self.submissionMessage = "Hermes connected."
            self.log.write(.gateway, "connected session=\(identity.storedSessionID) runtime=\(identity.runtimeSessionID)")
            self.log.updateStatus(["hermes": "connected", "session": identity.storedSessionID])
            guard !self.controller.readOnlyConnection else { return }
            Task {
                if let store = self.evidenceStore {
                    do { _ = try await self.controller.verifyBatches(launch: self.frozenLaunch(), store: store) }
                    catch { self.submissionMessage = "Batch receipt verification unavailable; interrupted work remains fenced." }
                }
                await self.submitPendingBatches()
            }
        }
        log.write(.app, "started pid=\(ProcessInfo.processInfo.processIdentifier)")
        log.updateStatus(["app": "running", "hermes": "connecting", "integrity": integrity ? "on" : "off", "capture": "paused"])
        if hermesPython.isEmpty || hermesRoot.isEmpty || vaultPath.isEmpty { autodetectLocalSetup(overwrite: false) }
        else { connectOnLaunch() }
        do {
            let store = try EvidenceStore(root: EvidenceStore.defaultRoot)
            evidenceStore = store
            captureService = CaptureService(
                store: store,
                status: { [weak self] value in self?.captureStatus = value },
                safetyChanged: { [weak self] safe in self?.captureSafetyChanged(safe) },
                batchReady: { [weak self] batch in self?.submit(batch: batch) }
            )
            if !integrity { _ = captureService?.enableAfterExplicitConsent(requestPermission: false) }
        } catch {
            captureStatus = "Capture blocked — local evidence storage could not be opened."
        }
    }

    var status: String {
        if connected { return "Hermes connected · xCreen session" }
        if hermesPython.isEmpty || hermesRoot.isEmpty { return "Hermes unavailable · configure local Python and Hermes source root" }
        return "Hermes disconnected · no request was sent"
    }
    var canAsk: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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

    /// Opens (or resumes) the xCreen session. Connecting runs no model; it only starts the
    /// local gateway, resumes the stored session and loads the model list.
    private func frozenLaunch() -> HermesGatewayLaunch {
        .bundled(python: hermesPython, hermesRoot: hermesRoot, evidenceRoot: EvidenceStore.defaultRoot.path, vault: vaultPath.isEmpty ? nil : vaultPath)
    }

    func connectIfNeeded() async throws {
        let launch = frozenLaunch()
        do { try await controller.connect(launch: launch) }
        catch {
            log.write(.error, "gateway connect failed: \(error)")
            submissionMessage = "Hermes connection failed: \(error.localizedDescription)"
            throw error
        }
    }

    func connectOnLaunch() {
        guard !hermesPython.isEmpty, !hermesRoot.isEmpty else { return }
        Task { [weak self] in try? await self?.connectIfNeeded() }
    }

    private func applyInventorySelection(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let provider = root["provider"] as? String, let model = root["model"] as? String else { return }
        selectedHermesModel = "\(provider)::\(model)"
    }

    private func receiveGatewayEvent(_ event: HermesGatewayEvent) {
        if !["message.delta", "message.interim", "thinking.delta", "reasoning.delta"].contains(event.type) {
            log.write(.session, "event \(event.type)")
        }
        guard let frame = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any],
              let payload = frame["payload"] as? [String: Any] else { return }
        switch event.type {
        case "message.start": streamedReply = ""; appendix = []
        case "message.delta", "message.interim":
            streamedReply += payload["text"] as? String ?? ""
        case "message.complete":
            if let text = payload["text"] as? String, !text.isEmpty { streamedReply = text }
            submissionMessage = "Hermes response complete."; resolveAppendix()

        case "session.info":
            if let provider = payload["provider"] as? String, let model = payload["model"] as? String { selectedHermesModel = "\(provider)::\(model)" }
        case "error": submissionMessage = "Hermes reported an error — no answer was claimed."
        default: break
        }
    }

    /// Fills Python, Hermes root and vault from the installed `hermes` launcher and Obsidian.
    /// Without `overwrite`, values the user already set are kept.
    func autodetectLocalSetup(overwrite: Bool = true) {
        Task { do { try await detectAndSave(overwrite: overwrite) } catch { submissionMessage = error.localizedDescription } }
    }

    private func detectAndSave(overwrite: Bool) async throws {
        submissionMessage = "Detecting Hermes and Obsidian vault…"
        do {
            try await controller.configure(prepare: {
                let existing = LocalControlSettings(python: self.hermesPython, root: self.hermesRoot, vault: self.vaultPath)
                let (hermes, vault) = await Task.detached { (LocalSetupDetector.detectHermes(), LocalSetupDetector.detectVault()) }.value
                let settings = LocalControlSettings(
                    python: (overwrite || existing.python.isEmpty) ? hermes?.python ?? existing.python : existing.python,
                    root: (overwrite || existing.root.isEmpty) ? hermes?.hermesRoot ?? existing.root : existing.root,
                    vault: (overwrite || existing.vault.isEmpty) ? vault ?? existing.vault : existing.vault)
                let launch = HermesGatewayLaunch.bundled(python: settings.python, hermesRoot: settings.root, evidenceRoot: EvidenceStore.defaultRoot.path, vault: settings.vault.isEmpty ? nil : settings.vault)
                return (launch, { self.applySettings(settings) })
            })
            submissionMessage = "Detected local setup."
        } catch { throw LocalControlError.failed("Detected settings saved; reconnect failed: \(error.localizedDescription)") }
    }

    private func applySettings(_ settings: LocalControlSettings) {
        hermesPython = settings.python; hermesRoot = settings.root; vaultPath = settings.vault
        defaults.set(settings.python, forKey: "xcreen.hermes.python")
        defaults.set(settings.root, forKey: "xcreen.hermes.root")
        defaults.set(settings.vault, forKey: "xcreen.vault.path")
    }

    func saveHermesExecutable() {
        let settings = LocalControlSettings(python: hermesPython, root: hermesRoot, vault: vaultPath)
        Task { do { try await persistSettings(settings) } catch { submissionMessage = error.localizedDescription } }
    }

    private func persistSettings(_ settings: LocalControlSettings? = nil) async throws {
        let frozen = settings ?? LocalControlSettings(python: hermesPython, root: hermesRoot, vault: vaultPath)
        let python = frozen.python.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = frozen.root.trimmingCharacters(in: .whitespacesAndNewlines)
        let vault = frozen.vault.trimmingCharacters(in: .whitespacesAndNewlines)
        let launch = HermesGatewayLaunch.bundled(python: python, hermesRoot: root, evidenceRoot: EvidenceStore.defaultRoot.path, vault: vault.isEmpty ? nil : vault)
        do {
            try await controller.configure(launch: launch) {
                self.hermesPython = python; self.hermesRoot = root; self.vaultPath = vault
                self.defaults.set(python, forKey: "xcreen.hermes.python")
                self.defaults.set(root, forKey: "xcreen.hermes.root")
                self.defaults.set(vault, forKey: "xcreen.vault.path")
            }
        } catch { throw LocalControlError.failed("Settings saved; reconnect failed: \(error.localizedDescription)") }
    }

    func switchHermesModel(_ routeID: String) {
        guard let route = hermesModels.first(where: { $0.id == routeID }) else { return }
        runControl(["command": "model", "provider": route.provider, "model": route.model])
    }

    private func submit(batch: CaptureBatch) {
        guard !integrity, captureSafe else { return }
        // A batch is retried after reconnects; never put the same one in flight twice.
        guard inFlightBatches.insert(batch.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { inFlightBatches.remove(batch.id) }
            await integrityTransition?.value
            guard !integrity, captureSafe else { return }
            let manifest = XCreenPrompts.batch(batch)
            let images = batch.images.map { HermesEvidenceAttachment(id: $0.id, timestamp: $0.timestamp, fileURL: $0.fileURL) }
            do {
                log.write(.batch, "sending id=\(batch.id) images=\(images.count)")
                guard let evidenceStore else { throw EvidenceStoreError.invalidInput }
                // Stable ID/evidence is already durable before this queued turn exists.
                try await evidenceStore.savePendingBatch(batch)
                let binding = BatchBinding(batchID: batch.id, sourceIDs: batch.images.map(\.id) + batch.ocr.map(\.id))
                try await sessionRuntime.submitAutomatic(manifest: manifest, images: images, binding: binding, prepared: { sessionID in
                    try await evidenceStore.bindBatch(id: batch.id, sessionID: sessionID)
                }, receiptChanged: { receipt in
                    try await evidenceStore.reconcile(receipt)
                }, phaseChanged: { state in
                    try await evidenceStore.transitionBatch(id: batch.id, to: state)
                })
                log.write(.batch, "verified processing receipt id=\(batch.id)")
            } catch {
                // Only work that never crossed the send boundary remains retryable.
                try? await evidenceStore?.recordBatchFailure(id: batch.id, cancelled: (error as? HermesGatewayError) == .cancelled)
                log.write(.error, "batch id=\(batch.id) interrupted; inspect durable batch state")
                submissionMessage = "Automatic batch interrupted. Pending work may retry; ambiguous/admitted work requires receipt verification."
            }
        }
    }

    private func submitPendingBatches() async {
        guard let evidenceStore else { return }
        guard let batches = try? await evidenceStore.pendingBatches() else { return }
        for batch in batches { submit(batch: batch) }
    }

    /// Resolves `xcreen-image:<id>` references through the evidence store only.
    private func resolveAppendix() {
        let ids = EvidenceReferences.imageIDs(in: streamedReply)
        let reply = streamedReply
        let generation = controller.generation
        guard let evidenceStore, !ids.isEmpty else { appendix = []; return }
        Task { [weak self] in
            var found: [EvidenceImage] = []
            for id in ids { if let image = try? await evidenceStore.image(id: id) { found.append(image) } }
            guard let self, self.controller.generation == generation, self.streamedReply == reply else { return }
            self.appendix = found
        }
    }

    func acceptURLQuery(_ value: String) {
        query = value
        submissionMessage = ""
    }

    /// The sole command surface for both the tray and the private local CLI.  It only
    /// calls the same methods and session runtime the visible controls use.
    func control(_ command: LocalControlCommand) async throws -> LocalControlResponse {
        switch command.name {
        case .status: break
        case .history:
            let data = try await controller.historyPage(launch: frozenLaunch(), cursor: command.value)
            return .ok(snapshot(), reply: String(data: data, encoding: .utf8))
        case .batches:
            guard let evidenceStore else { throw LocalControlError.unavailable("evidence store unavailable") }
            let rows = await evidenceStore.batchPage(after: command.value ?? "", limit: 20)
            batchMetadata = rows.map { "\($0.id) · \($0.state.rawValue) · attempts \($0.attempts) · receipt \($0.receipt?.status ?? "missing") · verified \($0.receipt?.verified ?? false) · effects \($0.receipt?.effectCount ?? 0)" }.joined(separator: "\n")
            if rows.isEmpty { batchMetadata = "No more retained batches." }
            batchCursor = rows.last?.id ?? ""
            let data = try JSONEncoder().encode(rows)
            return .ok(snapshot(), reply: String(data: data, encoding: .utf8))
        case .verify:
            guard let evidenceStore else { throw LocalControlError.unavailable("evidence store unavailable") }
            let count = try await controller.verifyBatches(launch: frozenLaunch(), store: evidenceStore)
            batchMetadata = "Verified \(count) retained batch receipts. No inference or note writes."
            return .ok(snapshot(), reply: batchMetadata)
        case .integrity:
            if command.value == nil { break }
            guard let value = command.value, ["on", "off"].contains(value) else { throw LocalControlError.invalidRequest("integrity value must be on or off") }
            // Off is explicit user consent, equivalent to the tray's toggle. Capture still
            // fails closed when macOS permission or state guards reject it.
            if value == "off", !integrity { _ = captureService?.enableAfterExplicitConsent() }
            integrity = value == "on"
            await integrityTransition?.value

        case .connect: try await connectIfNeeded()
        case .disconnect:
            await controller.disconnect(); submissionMessage = "Hermes disconnected."
        case .reconnect:
            try await controller.reconnect(launch: frozenLaunch())
        case .models:
            try await controller.readModelOptions(launch: frozenLaunch()) { inventory in
                self.hermesModels = try HermesModelRoute.decodeInventory(inventory)
                self.applyInventorySelection(inventory)
            }
        case .visibility:
            if let value = command.value {
                guard value == "on" || value == "off" else { throw LocalControlError.invalidRequest("visibility must be on or off") }
                do { try await controller.setSessionVisible(value == "on") }
                catch { submissionMessage = "Session visibility saved; pending: \(error.localizedDescription)"; return .ok(snapshot(), reply: submissionMessage) }
            }
            return .ok(snapshot(), reply: controller.visibilityPending ? "Session visibility \(controller.sessionVisible ? "on" : "off") saved; pending gateway confirmation." : "Session visibility \(controller.sessionVisible ? "on" : "off") confirmed by Hermes.")

        case .model:
            guard let provider = command.provider, let model = command.model, hermesModels.contains(where: { $0.provider == provider && $0.model == model }) else { throw LocalControlError.invalidRequest("unknown configured provider/model") }
            try await controller.switchModel(model: model, provider: provider) { self.selectedHermesModel = "\(provider)::\(model)" }
        case .settings:
            if let value = command.value {
                let pieces = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard pieces.count == 2 else { throw LocalControlError.invalidRequest("settings value must be key=value") }
                guard ["python", "root", "vault"].contains(pieces[0]) else { throw LocalControlError.invalidRequest("unknown setting") }
                do {
                    try await controller.configure(prepare: {
                        var settings = LocalControlSettings(python: self.hermesPython, root: self.hermesRoot, vault: self.vaultPath)
                        let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        switch pieces[0] { case "python": settings.python = value; case "root": settings.root = value; default: settings.vault = value }
                        let launch = HermesGatewayLaunch.bundled(python: settings.python, hermesRoot: settings.root, evidenceRoot: EvidenceStore.defaultRoot.path, vault: settings.vault.isEmpty ? nil : settings.vault)
                        return (launch, { self.applySettings(settings) })
                    })
                } catch { throw LocalControlError.failed("Settings saved; reconnect failed: \(error.localizedDescription)") }
            }
        case .autodetect: try await detectAndSave(overwrite: true)
        case .ask:
            guard let question = command.question else { throw LocalControlError.invalidRequest("ask needs question") }
            let answer = try controller.admitManual(XCreenPrompts.manual(question: question), launch: frozenLaunch())
            let presentationID = UUID(); manualPresentationID = presentationID
            streamedReply = ""; submissionMessage = "Asking Hermes…"
            query = question

            let completion = TurnCompletion()
            Task { @MainActor in
                do {
                    completion.reply = try await answer.value
                    if self.manualPresentationID == presentationID { self.submissionMessage = "Hermes response complete." }
                } catch {
                    completion.error = error
                    if self.manualPresentationID == presentationID { self.submissionMessage = "Hermes did not answer: \(error.localizedDescription)" }
                }
                completion.done = true
            }
            if let wait = command.waitMilliseconds, wait > 0 {
                let deadline = ContinuousClock.now + .milliseconds(wait)
                while !completion.done && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                if let error = completion.error { throw error }
                if !completion.done { return .ok(snapshot(), reply: nil) }
                return .ok(snapshot(), reply: completion.reply)
            }
            return .ok(snapshot(), reply: nil)
        case .cancel: try await controller.cancelManual(); submissionMessage = "Hermes question cancellation requested."
        case .images:
            if let id = command.value {
                guard let image = appendix.first(where: { $0.id == id }) else { throw LocalControlError.invalidRequest("unknown reply image") }
                guard NSWorkspace.shared.open(image.fileURL) else { throw LocalControlError.failed("image could not be opened") }
            }
        case .panel:
            if command.value == "hide" { AppDelegate.shared?.popover.performClose(nil) } else { AppDelegate.shared?.showPanel() }
        case .quit:
            captureService?.pause(reason: "Capture suspended · quitting")
            integrityTransition = controller.setIntegrity(true)
            await integrityTransition?.value
            await controller.disconnect()
            Task { try? await Task.sleep(for: .milliseconds(300)); NSApplication.shared.terminate(nil) }
        }
        return .ok(snapshot())
    }

    private func snapshot() -> LocalControlSnapshot {
        let routes = hermesModels.map { LocalControlModel(provider: $0.provider, model: $0.model) }
        let current = hermesModels.first(where: { $0.id == selectedHermesModel }).map { LocalControlModel(provider: $0.provider, model: $0.model) }
        let images = appendix.map { LocalControlImage(id: $0.id, timestamp: $0.timestamp) }
        var result = LocalControlSnapshot(app: "running", connected: connected, integrity: integrity, capture: captureStatus, message: submissionMessage, models: routes, currentModel: current, settings: .init(python: hermesPython, root: hermesRoot, vault: vaultPath), images: images)
        result.sessionVisible = controller.sessionVisible
        result.actualSessionVisible = controller.actualSessionVisible
        result.sessionVisibilityPending = controller.visibilityPending
        return result
    }
    var sessionVisible: Bool { controller.sessionVisible }
    var visibilityStatus: String { controller.visibilityPending ? "Saved preference; pending gateway confirmation." : "Confirmed by Hermes for this session." }
}

@MainActor private final class TurnCompletion { var done = false; var error: Error?; var reply: String? }

struct Panel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.blue.gradient)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("xCreen").font(.system(size: 24, weight: .medium))
                Text("Private evidence, deliberate assistance.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Toggle("Integrity mode", isOn: $state.integrity)
                .toggleStyle(.switch)
                .accessibilityHint("Integrity pauses capture and automatic work.")
            Text(state.integrity
                 ? "On: no screenshots, no OCR, nothing sent automatically."
                 : "Off: capture requested; automatic safety gates may suspend it without changing this switch.")
            Text(state.captureStatus).font(.caption).foregroundStyle(.secondary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show session in Hermes", isOn: Binding(get: { state.sessionVisible }, set: { state.runControl(["command": "visibility", "value": $0 ? "on" : "off"]) }))
                .toggleStyle(.switch)
            Text(state.visibilityStatus).font(.caption).foregroundStyle(.secondary)

            if !state.hermesModels.isEmpty {
                Picker("Hermes session model", selection: Binding(get: { state.selectedHermesModel }, set: { state.switchHermesModel($0) })) {
                    Text("Choose provider/model").tag("")
                    ForEach(state.hermesModels) { route in Text("\(route.provider) · \(route.model)").tag(route.id) }
                }

                .accessibilityHint("Uses Hermes's provider-aware inventory and changes only the xCreen session.")
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Ask about your recent context", text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.submitQuestion() }
                HStack {
                    Button("Ask") { state.submitQuestion() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!state.canAsk)
                    Button("Cancel") { state.runControl(["command": "cancel"]) }
                    Spacer()
                    Text(state.connected ? "Persistent xCreen session" : "No request sent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !state.submissionMessage.isEmpty {
                Text(state.submissionMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !state.streamedReply.isEmpty {
                Text(state.streamedReply)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !state.appendix.isEmpty {
                EvidenceAppendix(images: state.appendix)
            }

            DisclosureGroup("Durable batches") {
                HStack {
                    Button("Refresh") { state.runControl(["command": "batches"]) }
                    Button("Verify receipts") { state.runControl(["command": "verify"]) }
                    Button("Next page") { state.runControl(["command": "batches", "value": state.batchCursor]) }.disabled(state.batchCursor.isEmpty)
                }
                ScrollView { Text(state.batchMetadata).font(.caption).textSelection(.enabled) }.frame(maxHeight: 100)
                Text("Transport completion is not verified processing. Uncertain batches are never retried automatically.").font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Local settings", isExpanded: $state.showSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Python executable (absolute path)", text: $state.hermesPython)
                        .textFieldStyle(.roundedBorder)
                    TextField("Hermes source root (contains tui_gateway/)", text: $state.hermesRoot)
                        .textFieldStyle(.roundedBorder)
                    TextField("Obsidian vault (optional, enables Daily notes)", text: $state.vaultPath)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Auto-detect") { state.autodetectLocalSetup() }
                        Button("Save") { state.saveHermesExecutable() }
                    }
                    .buttonStyle(.borderless)
                    Text("xCreen launches its bundled runtime/xcreen_gateway.py with this Python, which registers the xcreen tools and starts Hermes's raw tui_gateway. Only the xCreen session uses them; no profile or model default is changed. With a vault set, the agent may append sourced facts to existing Daily notes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            Divider()

            HStack(spacing: 7) {
                Circle().fill(Color.gray).frame(width: 8, height: 8)
                Text(state.status).font(.caption.weight(.medium))
                Spacer()
                Button(state.connected ? "Disconnect" : "Connect") { state.runControl(["command": state.connected ? "disconnect" : "connect"]) }
                Button("Quit") { state.runControl(["command": "quit"]) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(18)
        .frame(width: 410)
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    lazy var state = AppState()
    var item: NSStatusItem!
    let popover = NSPopover()
    private var controlServer: LocalControlServer?

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

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where AskShortcut.query(url) != nil {
            if let query = AskShortcut.query(url) {
                state.acceptURLQuery(query)
                if !popover.isShown { toggle() }
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}


/// Screenshots the reply cited, shown like email attachments under the answer.
struct EvidenceAppendix: View {
    let images: [EvidenceImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Attachments · \(images.count)").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(images) { image in
                        Button { NSWorkspace.shared.open(image.fileURL) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                if let preview = NSImage(contentsOf: image.fileURL) {
                                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 120, height: 76).clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 120, height: 76)
                                }
                                Text(image.timestamp.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Open screenshot from \(image.timestamp.formatted())")
                    }
                }
            }
        }
    }
}
