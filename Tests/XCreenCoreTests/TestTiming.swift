import Foundation

/// Generous deadlines for tests that spawn real subprocesses (python3 fake gateways).
/// Hosted CI runners (GitHub macos-latest) are much slower than a developer Mac; a deadline only
/// bounds a hang, so a large value costs nothing when the test passes quickly.
enum TestTiming {
    static let subprocessDeadline: TimeInterval = 30

    /// Polls `condition` until it holds or `timeout` elapses. Use instead of a fixed sleep before a
    /// positive assertion, so slow schedulers cannot fail a test that would eventually succeed.
    static func eventually(timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
