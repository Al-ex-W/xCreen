import AppIntents
import Foundation
import XCreenCore

/// Spotlight/Shortcuts action. Opens the xCreen panel with the question filled in; the user submits it.
@available(macOS 26.0, *)
struct AskXCreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask xCreen"
    static let description = IntentDescription(
        "Ask xCreen about what you’ve been doing on your Mac. Opens the xCreen panel with your question filled in, ready to send.",
        searchKeywords: ["screen", "memory", "recall", "history", "Hermes"]
    )
    static let openAppWhenRun = true

    @Parameter(
        title: "Question",
        description: "What you want to ask about your recent screen activity.",
        inputOptions: String.IntentInputOptions(capitalizationType: .sentences, multiline: false, autocorrect: true),
        requestValueDialog: IntentDialog("What do you want to ask xCreen?")
    )
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask xCreen \(\.$question)")
    }

    /// openAppWhenRun runs this inside the app, so deliver in-process. OpenURLIntent with the
    /// custom xcreen:// scheme is refused by the App Intents runtime ("launch is prohibited").
    @MainActor
    func perform() async throws -> some IntentResult {
        guard case .ask = PanelHandoff(question: question) else { throw AskXCreenIntentError.invalidQuestion }
        AppDelegate.shared?.receiveIntent(PanelHandoff(question: question))
        return .result()
    }
}

/// Parameterless action: just show the xCreen panel.
@available(macOS 26.0, *)
struct OpenXCreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Open xCreen"
    static let description = IntentDescription("Show the xCreen panel from the menu bar.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.shared?.receiveIntent(.open)
        return .result()
    }
}

/// Spotlight's "Search in Apps" fallback. Conforming to `ShowInAppSearchResultsIntent` with the
/// `.general` scope makes the system offer a "Search xCreen" row for any typed query, passing the
/// text as `criteria.term`. It uses the same bounded in-process handoff: fills, never submits.
@available(macOS 26.0, *)
struct SearchXCreenIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Ask xCreen"
    static let description = IntentDescription(
        "Opens the xCreen panel with your Spotlight text filled in as a question, ready to send."
    )
    static let searchScopes: [StringSearchScope] = [.general]
    static let openAppWhenRun = true

    @Parameter(title: "Criteria", description: "The text to ask xCreen about.")
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.shared?.receiveIntent(PanelHandoff(question: criteria.term))
        return .result()
    }
}

/// App Shortcuts are what Spotlight on macOS 26+ offers as the app's ready-made actions. Every phrase
/// must contain the app name. A String parameter cannot appear in a phrase, so Spotlight/Shortcuts
/// prompts for `question` using its requestValueDialog.
@available(macOS 26.0, *)
struct XCreenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskXCreenIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) about my screen",
                "Ask \(.applicationName) a question",
                "What was I doing in \(.applicationName)",
            ],
            shortTitle: "Ask xCreen",
            systemImageName: "text.magnifyingglass"
        )
        AppShortcut(
            intent: OpenXCreenIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Show \(.applicationName)",
            ],
            shortTitle: "Open xCreen",
            systemImageName: "display"
        )
    }
}

private enum AskXCreenIntentError: Error, CustomLocalizedStringResourceConvertible {
    case invalidQuestion
    var localizedStringResource: LocalizedStringResource { "Type a question for xCreen." }
}
