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

    private var preview: DisconnectedPreviewState

    init(defaults: UserDefaults = .standard) {
        let savedPreview = DisconnectedPreviewState(defaults: defaults)
        preview = savedPreview
        integrity = savedPreview.integrityMode
        modelSelection = savedPreview.modelSelection
        interval = savedPreview.interval
    }

    var status: String { preview.connectionStatus }
    var canAsk: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func submitQuestion() {
        submissionMessage = preview.submit(question: query).message
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
                    Text("A smarter view, anywhere.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Toggle("Integrity mode", isOn: $state.integrity)
                .toggleStyle(.switch)
                .accessibilityHint("Saves a local preview preference only. Capture remains off.")
            Text("Capture is OFF. Changing this switch only saves a local UI preference.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                Text("Recommendation")
                    .font(.subheadline.weight(.medium))
                Picker("Recommendation", selection: $state.modelSelection) {
                    ForEach(PreviewModelSelection.allCases, id: \.self) { selection in
                        Text(selection.label).tag(selection)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Demo model recommendation")
                Text("These are preview choices, not discovered models. Use your main harness selection when connected later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("UI preview only")
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

            DisclosureGroup("Preview settings", isExpanded: $state.showSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Interval", selection: $state.interval) {
                        ForEach(PreviewInterval.allCases, id: \.self) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    Text("Stored locally for this preview only; it does not schedule capture or notifications.")
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
