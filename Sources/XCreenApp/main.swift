import AppKit
import SwiftUI
import XCreenCore

struct ModelChoice: Decodable, Identifiable {
    let id: String
    let label: String
    let model: String
    let provider: String
}
struct ModelInventory: Decodable { let models: [ModelChoice] }
struct Answer: Decodable { let answer: String }

@MainActor final class AppState: ObservableObject {
    @Published var models: [ModelChoice] = []
    @Published var modelID = "" { didSet { if oldValue != modelID { resetConsent() } } }
    @Published var query = "" { didSet { if oldValue != query { resetConsent() } } }
    @Published var answer = ""
    @Published var status = "Integrity mode · capture paused"
    @Published var busy = false
    @Published var integrity = true
    @Published var consent = false {
        didSet {
            consentScope = consent ? ConsentScope(question: query, modelID: modelID, bridge: settings) : nil
        }
    }
    @Published var python: String
    @Published var hermes: String
    @Published var vault: String { didSet { if oldValue != vault { resetConsent() } } }
    private var runner: BridgeRunner?
    private var consentScope: ConsentScope?
    private var harnessSettings: HarnessSettingsState
    private let defaults: UserDefaults
    private lazy var captureService = CaptureService(
        settings: { [weak self] in self?.settings ?? BridgeSettings(python: "", script: "", hermes: "") },
        status: { [weak self] message in self?.status = message },
        integrityChanged: { [weak self] value in self?.integrity = value }
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let script = Bundle.main.resourceURL?.appendingPathComponent("bridge/xcreen_bridge.py").path ?? ""
        let saved = BridgeSettings(
            python: defaults.string(forKey: "python") ?? "/opt/homebrew/bin/python3",
            script: script,
            hermes: defaults.string(forKey: "hermes") ?? "",
            vault: defaults.string(forKey: "vault") ?? ""
        )
        python = saved.python
        hermes = saved.hermes
        vault = saved.vault
        harnessSettings = HarnessSettingsState(saved: saved)
    }

    var settings: BridgeSettings {
        harnessSettings.automaticRefresh
    }

    var canAsk: Bool {
        let saved = settings
        return !busy && consent &&
            consentScope?.allows(question: query, modelID: modelID, bridge: saved) == true &&
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !modelID.isEmpty && !saved.hermes.isEmpty
    }

    func resetConsent() {
        consentScope = nil
        if consent { consent = false }
    }

    func enableCaptureAfterConsent() { _ = captureService.enableAfterExplicitConsent() }
    func pauseCapture() { captureService.pause() }
    func acceptURLQuery(_ value: String) {
        resetConsent()
        query = value
    }

    func save() {
        resetConsent()
        harnessSettings.draft.python = python
        harnessSettings.draft.hermes = hermes
        harnessSettings.draft.vault = vault
        harnessSettings.saveDraft()
        defaults.set(python, forKey: "python")
        defaults.set(hermes, forKey: "hermes")
        defaults.set(vault, forKey: "vault")
    }

    func saveAndLoadModels() async {
        save()
        await loadModels()
    }

    func loadModels() async {
        do {
            let saved = settings
            let data = try await BridgeRunner().run(executable: saved.python, arguments: [saved.script, "models"], timeout: 15)
            models = try JSONDecoder().decode(ModelInventory.self, from: data).models
            if !models.contains(where: { $0.id == modelID }) { modelID = models.first?.id ?? "" }
            status = integrity ? "Ready · capture paused" : "Ready · capture enabled"
        } catch { status = "Model discovery failed · check Python and PyYAML" }
    }
    func ask() async {
        let saved = settings
        guard canAsk else { return }
        resetConsent()
        busy = true; answer = ""; status = "Asking your Hermes harness…"
        let active = BridgeRunner(); runner = active
        defer { busy = false; runner = nil }
        do {
            let data = try await active.run(executable: saved.python, arguments: saved.askArguments(query: InputBounds.prefix(query, maxUnicodeScalars: 8000), modelID: modelID))
            answer = try JSONDecoder().decode(Answer.self, from: data).answer
            status = integrity ? "Ready · capture paused" : "Ready · capture enabled"
        } catch { status = "Query failed or cancelled · check harness settings" }
    }
    func cancel() { runner?.cancel() }
    func purge() async {
        guard !busy else { return }
        do {
            let saved = settings
            _ = try await BridgeRunner().run(executable: saved.python, arguments: [saved.script, "purge"], timeout: 15)
            status = integrity ? "Local history purged · capture paused" : "Local history purged · capture enabled"
        } catch { status = "Purge failed · local history may remain" }
    }
}

struct Panel: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Image(systemName: "display").font(.system(size: 40)).foregroundStyle(.blue.gradient)
                VStack(alignment: .leading) {
                    Text("xCreen").font(.system(size: 28, weight: .medium))
                    Text("A smarter view, anywhere.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            Toggle("Integrity mode · live capture unavailable", isOn: .constant(true))
                .toggleStyle(.switch)
                .disabled(true)
            Text("Screenshots remain OFF in this preview because a current unlocked-session state cannot be verified with a public synchronous source. Lock notifications only stop work; they cannot enable capture.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Model picker")
            Picker("Model", selection: $state.modelID) {
                ForEach(state.models) { model in Text(model.label).tag(model.id) }
            }.labelsHidden()
            Text("Recommend a light model such as Haiku or Luna, if configured in your harness.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Ask about your recent context", text: $state.query).textFieldStyle(.roundedBorder)
                .onSubmit { Task { await state.ask() } }
            Toggle("Allow this question's retrieved text to reach my model provider", isOn: $state.consent)
                .font(.caption)
            Text("Hermes transcripts and your provider may retain submitted evidence. Local purge cannot erase those copies.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Ask xCreen") { Task { await state.ask() } }
                    .disabled(!state.canAsk)
                if state.busy { ProgressView().controlSize(.small); Button("Cancel") { state.cancel() } }
            }
            if !state.answer.isEmpty {
                ScrollView { Text(state.answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180)
            }
            DisclosureGroup("Harness settings") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Python executable", text: $state.python)
                    TextField("Hermes executable (absolute path)", text: $state.hermes)
                    TextField("Vault directory (optional)", text: $state.vault)
                    HStack {
                        Button("Save & refresh models") { Task { await state.saveAndLoadModels() } }
                        Button("Purge local history") { Task { await state.purge() } }.disabled(state.busy)
                    }
                    Text("Existing profile only; no configuration or vault writes. Screenshots/OCR never belong in your vault.").font(.caption)
                }.textFieldStyle(.roundedBorder).padding(.top, 6)
            }
            Divider()
            HStack {
                Circle().fill(state.busy ? Color.orange : Color.green).frame(width: 8, height: 8)
                Text(state.status).font(.caption)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
            }
            Text("Developer preview · 0.1.0 · live capture & Spotlight discovery unverified").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 440)
        .background(LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)], startPoint: .top, endPoint: .bottom))
        .task { await state.loadModels() }
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
        item.button?.target = self; item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(state: state))
    }
    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let query = AskShortcut.query(url) { state.acceptURLQuery(query); if !popover.isShown { toggle() } }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { state.pauseCapture() }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
