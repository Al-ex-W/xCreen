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

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let url = AskShortcut.url(question: question) else { throw AskXCreenIntentError.invalidQuestion }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

/// Parameterless action: just show the xCreen panel.
@available(macOS 26.0, *)
struct OpenXCreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Open xCreen"
    static let description = IntentDescription("Show the xCreen panel from the menu bar.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(AskShortcut.openURL))
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
