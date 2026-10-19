import AppKit
import SwiftUI
import XCreenCore

/// Everything the tray panel reads or invokes. The app's `AppState` is the only runtime
/// conformer; the dev-only screenshot renderer supplies a fixed sample model, so the panel
/// can be rendered without starting capture, the gateway or the evidence store.
@MainActor public protocol TrayPanelModel: ObservableObject {
    var integrity: Bool { get set }
    var captureStatus: String { get }
    var sessionVisible: Bool { get }
    var visibilityStatus: String { get }
    var hermesModels: [HermesModelRoute] { get }
    var selectedHermesModel: String { get }
    var modelDefaultStatus: String { get }
    var query: String { get set }
    /// The question most recently sent; shown above the reply after the field clears.
    var lastQuestion: String { get }
    var canAsk: Bool { get }
    var connected: Bool { get }
    var submissionMessage: String { get }
    var streamedReply: String { get }
    var appendix: [EvidenceImage] { get }
    var batchMetadata: String { get }
    var batchCursor: String { get }
    var showSettings: Bool { get set }
    var hermesPython: String { get set }
    var hermesRoot: String { get set }
    var vaultPath: String { get set }
    var status: String { get }
    /// xCreen server (docs/protocol.md). The token field is write-only: it is stored in the Keychain.
    var serverURL: String { get set }
    var serverToken: String { get set }
    /// Captured items still waiting to upload.
    var queueStatus: String { get }
    func saveServerSettings()
    func submitQuestion()
    func runControl(_ fields: [String: String])
    func switchHermesModel(_ routeID: String)
    func autodetectLocalSetup(overwrite: Bool)
    func saveHermesExecutable()
    /// True only while an admitted tray question is waiting for Hermes's answer.
    var askGenerating: Bool { get }
}

public extension TrayPanelModel {
    var askGenerating: Bool { false }
}

/// The xCreen monitor symbol with a small circular arrow that rotates counterclockwise
/// (rewinding) while Hermes generates. Reduce Motion shows the static composite.
public struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    public init() {}
    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "display").font(.system(size: 16, weight: .regular))
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 8, weight: .bold))
                .padding(1.5)
                .background(Circle().fill(.background))
                .rotationEffect(.degrees(spinning ? -360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 1.2).repeatForever(autoreverses: false), value: spinning)
                .offset(x: 3, y: 3)
        }
        .foregroundStyle(.blue)
        .onAppear { if !reduceMotion { spinning = true } }
        .onChange(of: reduceMotion) { _, reduced in spinning = !reduced }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hermes is thinking")
    }
}

public struct Panel<Model: TrayPanelModel>: View {
    @ObservedObject var state: Model

    public init(state: Model) { self.state = state }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.blue.gradient)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("xCreen").font(.system(size: 24, weight: .medium))
                Text("Screen memory for Hermes")
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
                 : "Off: capturing. Pauses on its own when the Mac locks or an excluded app is open.")
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

                .accessibilityHint("Changes the model for xCreen only.")
                Text("Used only by xCreen. Claude Haiku 5.5 is fast and cheap.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(state.modelDefaultStatus).font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Ask about your day", text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.submitQuestion() }
                HStack {
                    Button("Ask") { state.submitQuestion() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!state.canAsk)
                    Button("Cancel") { state.runControl(["command": "cancel"]) }
                    Spacer()
                    Text(state.connected ? "Persistent xCreen session" : "Hermes not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !state.submissionMessage.isEmpty || state.askGenerating {
                HStack(alignment: .center, spacing: 8) {
                    if state.askGenerating { ThinkingIndicator() }
                    Text(state.submissionMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !state.lastQuestion.isEmpty {
                Text("You: \(state.lastQuestion)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(4)
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

            DisclosureGroup("Batches") {
                HStack {
                    Button("Refresh") { state.runControl(["command": "batches"]) }
                    Button("Verify receipts") { state.runControl(["command": "verify"]) }
                    Button("Next page") { state.runControl(["command": "batches", "value": state.batchCursor]) }.disabled(state.batchCursor.isEmpty)
                }
                ScrollView { Text(state.batchMetadata).font(.caption).textSelection(.enabled) }.frame(maxHeight: 100)
                Button("Retry zero-effect batches") { state.runControl(["command": "retrybatches"]) }
                Text("Failed batches retry automatically when it's safe to.").font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Settings", isExpanded: $state.showSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server").font(.caption.weight(.semibold))
                    TextField("Server URL, e.g. http://100.x.y.z:8765", text: $state.serverURL)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Token (from xcreen-server token; leave empty to keep)", text: $state.serverToken)
                        .textFieldStyle(.roundedBorder)
                    Button("Save server") { state.saveServerSettings() }
                        .buttonStyle(.borderless)
                    Text(state.queueStatus).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Hermes on the server").font(.caption.weight(.semibold))
                    TextField("Python executable (path on the server)", text: $state.hermesPython)
                        .textFieldStyle(.roundedBorder)
                    TextField("Hermes source root (contains tui_gateway/)", text: $state.hermesRoot)
                        .textFieldStyle(.roundedBorder)
                    TextField("Obsidian vault on the server (optional)", text: $state.vaultPath)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Load") { state.runControl(["command": "settings"]) }
                        Button("Auto-detect") { state.autodetectLocalSetup(overwrite: true) }
                        Button("Save") { state.saveHermesExecutable() }
                    }
                    .buttonStyle(.borderless)
                    Text("The server runs Hermes and writes notes. Your Hermes profile and defaults stay untouched. Set a vault to get notes in Obsidian.")
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

/// Screenshots the reply cited, shown like email attachments under the answer.
public struct EvidenceAppendix: View {
    let images: [EvidenceImage]

    public init(images: [EvidenceImage]) { self.images = images }

    public var body: some View {
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
