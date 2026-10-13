import AppIntents
import Foundation
import XCreenCore

@available(macOS 26.0, *)
struct AskXCreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask xCreen"
    static let description = IntentDescription("Open xCreen with a question ready for review in its disconnected UI preview.")
    static let openAppWhenRun = true

    @Parameter(title: "Question")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask xCreen \(\.$question)")
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        let bounded = InputBounds.prefix(question, maxUnicodeScalars: 8_000)
        guard !bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AskXCreenIntentError.invalidQuestion
        }
        var components = URLComponents()
        components.scheme = "xcreen"
        components.host = "ask"
        components.queryItems = [URLQueryItem(name: "query", value: bounded)]
        guard let url = components.url else { throw AskXCreenIntentError.invalidQuestion }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

private enum AskXCreenIntentError: Error {
    case invalidQuestion
}
