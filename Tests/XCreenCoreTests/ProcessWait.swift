import Foundation

extension Process {
    /// Waits at most `seconds` for the process to exit; then sends SIGKILL (which, unlike
    /// SIGTERM, can't be blocked or ignored) and reaps it. Returns whether it exited on its own.
    /// Tests must never wait unbounded on a child: a blocked signal hangs the whole suite.
    @discardableResult
    func waitUntilExit(timeout seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard isRunning else { return true }
        kill(processIdentifier, SIGKILL)
        waitUntilExit()
        return false
    }
}
