import Foundation
import Darwin

/// Local copies of the screenshots an answer cites (`xcreen-image:<id>`), so the tray can show
/// and open them. The cache only ever holds the current answer's images: every resolve prunes
/// the rest, launch empties it, and nothing older than the seven-day evidence retention is kept.
public struct AppendixCache: Sendable {
    public let directory: URL
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("xCreen/appendix", isDirectory: true)
    }

    public init(directory: URL = AppendixCache.defaultDirectory) { self.directory = directory.standardizedFileURL }

    /// Writes one image privately (0600, no symlink following) and dates the file by capture time.
    public func store(id: String, data: Data, capturedAt: Date?) throws -> EvidenceImage {
        guard id.range(of: "^[A-Za-z0-9-]{1,100}$", options: .regularExpression) != nil, !data.isEmpty else { throw EvidenceStoreError.invalidInput }
        try prepareDirectory()
        let url = directory.appendingPathComponent("\(id).\(data.starts(with: [0xff, 0xd8, 0xff]) ? "jpg" : "png")")
        let temporary = directory.appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data); try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch { _ = unlink(temporary.path); throw error }
        let when = capturedAt ?? Date()
        try? FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        return EvidenceImage(id: id, timestamp: when, fileURL: url)
    }

    /// Deletes every cached image except `keeping`, and anything captured over seven days ago.
    public func prune(keeping ids: Set<String> = [], now: Date = Date()) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: []) else { return }
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                try? FileManager.default.removeItem(at: file); continue
            }
            let id = file.deletingPathExtension().lastPathComponent
            let expired = (values.contentModificationDate ?? .distantPast) < now.addingTimeInterval(-Self.retention)
            if values.isRegularFile != true || !ids.contains(id) || expired { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func prepareDirectory() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let symlink = (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            guard isDirectory.boolValue, !symlink else { throw EvidenceStoreError.unsafePath }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
