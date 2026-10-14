import AppKit
import SwiftUI
import XCreenCore

@MainActor final class AppState: ObservableObject {
    @Published var integrity: Bool { didSet { preview.setIntegrityMode(integrity) } }
    @Published var modelSelection: PreviewModelSelection { didSet { preview.setModelSelection(modelSelection) } }
    @Published var interval: PreviewInterval { didSet { preview.setInterval(interval) } }
    @Published var query = ""
    @Published var submissionMessage = ""
    @Published var showSettings = false
    @Published var hermesPython = ""
    @Published var hermesRoot = ""
    @Published var vaultPath = ""
    @Published var connected = false
    @Published var streamedReply = ""
    @Published var hermesModels: [HermesModelRoute] = []
    @Published var selectedHermesModel = ""
    @Published var appendix: [EvidenceImage] = []

    private var preview: DisconnectedPreviewState
    private let gateway = HermesGateway()
    private let sessionRuntime: HermesSessionRuntime
    private var evidenceStore: EvidenceStore?
    private var captureService: CaptureService?
    private var storedSessionID = ""
    private var runtimeSessionID = ""
    private var observingGateway = false
    private var inFlightBatches: Set<String> = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sessionRuntime = HermesSessionRuntime(gateway: gateway, records: UserDefaultsHermesSessionRecordStore(defaults: defaults))
        let savedPreview = DisconnectedPreviewState(defaults: defaults)
        preview = savedPreview
        integrity = savedPreview.integrityMode
        modelSelection = savedPreview.modelSelection
        interval = savedPreview.interval
        hermesPython = defaults.string(forKey: "xcreen.hermes.python") ?? ""
        hermesRoot = defaults.string(forKey: "xcreen.hermes.root") ?? ""
        vaultPath = defaults.string(forKey: "xcreen.vault.path") ?? ""
        storedSessionID = defaults.string(forKey: "xcreen.hermes.session") ?? ""
        if hermesPython.isEmpty || hermesRoot.isEmpty || vaultPath.isEmpty { autodetectLocalSetup(overwrite: false) }
        else { connectOnLaunch() }
        do {
            let store = try EvidenceStore(root: EvidenceStore.defaultRoot)
            evidenceStore = store
            captureService = CaptureService(
                store: store,
                status: { [weak self] value in self?.submissionMessage = value },
                integrityChanged: { [weak self] value in self?.integrity = value },
                batchReady: { [weak self] batch in self?.submit(batch: batch) }
            )
        } catch {
            submissionMessage = "Capture remains paused — local evidence storage could not be opened."
        }
    }

    var status: String {
        if connected { return "Hermes connected · xCreen session" }
        if hermesPython.isEmpty || hermesRoot.isEmpty { return "Hermes unavailable · configure local Python and Hermes source root" }
        return "Hermes disconnected · no request was sent"
    }
    var canAsk: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func submitQuestion() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard !hermesPython.isEmpty, !hermesRoot.isEmpty else {
            submissionMessage = "Hermes is unavailable — configure local Python and the Hermes source root before sending."
            return
        }
        streamedReply = ""
        Task { [weak self] in
            guard let self else { return }
            do {
                try await connectIfNeeded()
                submissionMessage = "Asking Hermes…"
                try await sessionRuntime.submitManual(XCreenPrompts.manual(question: question))
                submissionMessage = "Hermes response complete."
            } catch {
                submissionMessage = "Hermes did not answer: \(error.localizedDescription)"
            }
        }
    }

    /// Opens (or resumes) the xCreen session. Connecting runs no model; it only starts the
    /// local gateway, resumes the stored session and loads the model list.
    func connectIfNeeded() async throws {
        guard !connected else { return }
        guard !hermesPython.isEmpty, !hermesRoot.isEmpty else { throw HermesGatewayError.invalidLaunch }
        submissionMessage = "Connecting to Hermes…"
        do {
            try await sessionRuntime.connect(launch: .bundled(python: hermesPython, hermesRoot: hermesRoot, evidenceRoot: EvidenceStore.defaultRoot.path, vault: vaultPath.isEmpty ? nil : vaultPath))
        } catch {
            connected = false
            submissionMessage = "Hermes connection failed: \(error.localizedDescription)"
            throw error
        }
        observeGatewayIfNeeded()
        if let identity = await sessionRuntime.currentSession() {
            storedSessionID = identity.storedSessionID
            runtimeSessionID = identity.runtimeSessionID
        }
        connected = true
        submissionMessage = "Hermes connected."
        if let inventory = try? await sessionRuntime.modelOptions() {
            hermesModels = (try? HermesModelRoute.decodeInventory(inventory)) ?? []
        }
        await submitPendingBatches()
    }

    func connectOnLaunch() {
        guard !hermesPython.isEmpty, !hermesRoot.isEmpty else { return }
        Task { [weak self] in try? await self?.connectIfNeeded() }
    }

    private func observeGatewayIfNeeded() {
        guard !observingGateway else { return }
        observingGateway = true
        Task { [weak self] in
            guard let self else { return }
            let events = await gateway.events()
            for await event in events {
                receiveGatewayEvent(event)
            }
            observingGateway = false
            connected = false
            submissionMessage = "Hermes gateway stopped. It reconnects on your next question."
        }
    }

    private func receiveGatewayEvent(_ event: HermesGatewayEvent) {
        guard let frame = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any],
              let payload = frame["payload"] as? [String: Any] else { return }
        switch event.type {
        case "message.start": streamedReply = ""; appendix = []
        case "message.delta", "message.interim":
            streamedReply += payload["text"] as? String ?? ""
        case "message.complete": submissionMessage = "Hermes response complete."; resolveAppendix()
        case "session.info":
            if let usage = payload["usage"] as? [String: Any] {
                Task { [weak self] in
                    guard let self else { return }
                    await self.sessionRuntime.updateContextUsage(tokens: usage["context_used"] as? Int ?? 0, limit: usage["context_max"] as? Int)
                }
            }
        case "error": submissionMessage = "Hermes reported an error — no answer was claimed."
        default: break
        }
    }

    /// Fills Python, Hermes root and vault from the installed `hermes` launcher and Obsidian.
    /// Without `overwrite`, values the user already set are kept.
    func autodetectLocalSetup(overwrite: Bool = true) {
        submissionMessage = "Detecting Hermes and Obsidian vault…"
        Task { [weak self] in
            let (hermes, vault) = await Task.detached { (LocalSetupDetector.detectHermes(), LocalSetupDetector.detectVault()) }.value
            guard let self else { return }
            if let hermes {
                if overwrite || hermesPython.isEmpty { hermesPython = hermes.python }
                if overwrite || hermesRoot.isEmpty { hermesRoot = hermes.hermesRoot }
            }
            if let vault, overwrite || vaultPath.isEmpty { vaultPath = vault }
            saveHermesExecutable()
            submissionMessage = hermes == nil
                ? "Hermes not found. Install it or fill the paths in Local settings."
                : "Detected Hermes\(vault == nil ? "" : " and vault")."
        }
    }

    func saveHermesExecutable() {
        defaults.set(hermesPython.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "xcreen.hermes.python")
        defaults.set(hermesRoot.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "xcreen.hermes.root")
        defaults.set(vaultPath.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "xcreen.vault.path")
        // New paths need a fresh gateway process.
        Task { [weak self] in
            guard let self else { return }
            await sessionRuntime.disconnect()
            connected = false
            connectOnLaunch()
        }
    }

    func enableCaptureAfterExplicitConsent() {
        guard !integrity else {
            submissionMessage = "Turn off Integrity mode first, then explicitly enable capture."
            return
        }
        guard captureService?.enableAfterExplicitConsent() == true else { return }
    }

    func switchHermesModel(_ routeID: String) {
        guard let route = hermesModels.first(where: { $0.id == routeID }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await sessionRuntime.switchModel(model: route.model, provider: route.provider)
                selectedHermesModel = route.id
                submissionMessage = "Switched this xCreen session to \(route.provider) / \(route.model)."
            } catch { submissionMessage = "Hermes could not switch this session model; defaults were not changed." }
        }
    }

    private func submit(batch: CaptureBatch) {
        // A batch is retried after reconnects; never put the same one in flight twice.
        guard inFlightBatches.insert(batch.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { inFlightBatches.remove(batch.id) }
            let manifest = XCreenPrompts.batch(batch)
            let images = batch.images.map { HermesEvidenceAttachment(id: $0.id, timestamp: $0.timestamp, fileURL: $0.fileURL) }
            do {
                try await sessionRuntime.submitAutomatic(manifest: manifest, images: images)
                try await evidenceStore?.markBatch(id: batch.id, status: "sent")
            } catch {
                // Keep the durable marker eligible for a later reconnect; no inference was claimed.
                try? await evidenceStore?.markBatch(id: batch.id, status: "pending")
                submissionMessage = "Automatic evidence batch was retained locally; Hermes did not accept it."
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
        guard let evidenceStore, !ids.isEmpty else { appendix = []; return }
        Task { [weak self] in
            var found: [EvidenceImage] = []
            for id in ids { if let image = try? await evidenceStore.image(id: id) { found.append(image) } }
            self?.appendix = found
        }
    }

    func acceptURLQuery(_ value: String) {
        query = value
        submissionMessage = ""
    }
}

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
            Button("Enable capture after explicit consent") { state.enableCaptureAfterExplicitConsent() }
                .disabled(state.integrity)
            Text("Capture is paused by default. This build fails closed because it cannot safely prove the current lock state.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                Text("Hermes route")
                    .font(.subheadline.weight(.medium))
                Picker("Route preference", selection: $state.modelSelection) {
                    ForEach(PreviewModelSelection.allCases, id: \.self) { selection in
                        Text(selection.label).tag(selection)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Local route preference")
                Text("The session picker is populated only by Hermes after a connection; this preference never changes Hermes defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !state.hermesModels.isEmpty {
                Picker("Hermes session model", selection: $state.selectedHermesModel) {
                    Text("Choose provider/model").tag("")
                    ForEach(state.hermesModels) { route in Text("\(route.provider) · \(route.model)").tag(route.id) }
                }
                .onChange(of: state.selectedHermesModel) { _, new in state.switchHermesModel(new) }
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
                    Picker("Interval", selection: $state.interval) {
                        ForEach(PreviewInterval.allCases, id: \.self) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
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
                Button("Quit") { NSApplication.shared.terminate(nil) }
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
    let state = AppState()
    var item: NSStatusItem!
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
