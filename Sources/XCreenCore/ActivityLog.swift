import Foundation

/// Append-only activity log read by `xcreen logs` and `xcreen status`.
///
/// It records *what happened* (connected, image saved id=…, batch sent), never OCR text,
/// window titles, pixels or model replies. Files are private (`0600`) and rotate at a
/// fixed size, keeping one previous file.
public final class ActivityLog: @unchecked Sendable {
    public enum Category: String, Sendable { case app, gateway, session, capture, batch, model, error }

    public static let shared = ActivityLog(directory: defaultDirectory)
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/xCreen", isDirectory: true)
    }

    public let logURL: URL
    public let statusURL: URL
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "dev.xcreen.activity-log")
    private var status: [String: String] = [:]
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    public init(directory: URL, maximumBytes: Int = 5_000_000) {
        logURL = directory.appendingPathComponent("xcreen.log")
        statusURL = directory.appendingPathComponent("status.json")
        self.maximumBytes = maximumBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func write(_ category: Category, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category.rawValue)] \(message.replacingOccurrences(of: "\n", with: " ").prefix(500))\n"
        queue.async { [self] in append(Data(line.utf8)) }
    }

    /// Merges keys into `status.json`, which `xcreen status` prints.
    public func updateStatus(_ values: [String: String]) {
        queue.async { [self] in
            status.merge(values) { _, new in new }
            status["updated"] = formatter.string(from: Date())
            status["pid"] = String(ProcessInfo.processInfo.processIdentifier)
            guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) else { return }
            let temporary = statusURL.appendingPathExtension("tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
            _ = try? FileManager.default.replaceItemAt(statusURL, withItemAt: temporary)
        }
    }

    /// Waits for queued writes; used by tests and on quit.
    public func flush() { queue.sync {} }

    private func append(_ data: Data) {
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: logURL.path)[.size]) as? Int, size + data.count > maximumBytes {
            let previous = URL(fileURLWithPath: logURL.path + ".1")
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: logURL, to: previous)
        }
        if !manager.fileExists(atPath: logURL.path) {
            manager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
