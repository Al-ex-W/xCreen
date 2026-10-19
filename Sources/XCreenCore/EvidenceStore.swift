import Foundation
import Darwin

public struct EvidenceImage: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public let fileURL: URL
    public init(id: String, timestamp: Date, fileURL: URL) {
        self.id = id; self.timestamp = timestamp; self.fileURL = fileURL
    }
}

public struct OCREvidence: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let timestamp: Date
    public let text: String
    public let app: String
    public let title: String
    public init(id: String, timestamp: Date, text: String, app: String, title: String) {
        self.id = id; self.timestamp = timestamp; self.text = text; self.app = app; self.title = title
    }
}

public struct CaptureCheckpoint: Codable, Sendable {
    public var clock: ActiveCaptureClock
    public var startedAt: Date?
    public var images: [EvidenceImage]
    public var ocr: [OCREvidence]
    public init(clock: ActiveCaptureClock = ActiveCaptureClock(), startedAt: Date? = nil, images: [EvidenceImage] = [], ocr: [OCREvidence] = []) {
        self.clock = clock; self.startedAt = startedAt; self.images = images; self.ocr = ocr
    }
}

/// One upload in capture order: OCR snapshots travel in groups ahead of the image that
/// follows them, so every batch the server forms holds the text captured before it.
public enum UploadItem: Sendable, Equatable {
    case ocr([OCREvidence])
    case image(EvidenceImage)
}

/// The capture outbox. Captured screenshots and OCR stay here, private and bounded by the
/// same seven-day retention, until the server acknowledges them; then they are deleted.
/// The server owns batching, the Hermes session and long-term evidence.
public actor EvidenceStore {
    private struct Index: Codable { var images: [EvidenceImage] = []; var ocr: [OCREvidence] = [] }
    private static let retention: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumIndexBytes = 128_000_000
    private static let maximumCheckpointBytes = 32_000_000
    public static let maximumOCRCharacters = 12_000
    public static let maximumOCRUploadGroup = 200
    private let root: URL
    private let imagesDirectory: URL
    private let indexURL: URL
    private let checkpointURL: URL
    private let statusURL: URL
    private var index: Index

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("xCreen/Outbox", isDirectory: true)
    }

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        if FileManager.default.fileExists(atPath: self.root.path), Self.isSymlink(self.root) { throw EvidenceStoreError.unsafePath }
        self.imagesDirectory = self.root.appendingPathComponent("images", isDirectory: true)
        self.indexURL = self.root.appendingPathComponent("index.json")
        self.checkpointURL = self.root.appendingPathComponent("capture-checkpoint.json")
        self.statusURL = self.root.appendingPathComponent("capture-status.json")
        try Self.makePrivateDirectory(self.root)
        try Self.makePrivateDirectory(imagesDirectory)
        guard !Self.isSymlink(imagesDirectory) else { throw EvidenceStoreError.unsafePath }
        var loaded = Index()
        if FileManager.default.fileExists(atPath: indexURL.path) {
            loaded = try JSONDecoder().decode(Index.self, from: Self.safeRead(indexURL, in: self.root, maximumBytes: Self.maximumIndexBytes))
        }
        let images = imagesDirectory
        guard loaded.images.allSatisfy({ Self.validID($0.id) && (try? Self.confined($0.fileURL, in: images)) == true }),
              loaded.ocr.allSatisfy({ Self.validID($0.id) }) else { throw EvidenceStoreError.invalidInput }
        try Self.cleanup(&loaded, imagesDirectory: images, checkpointURL: checkpointURL, now: Date())
        try Self.atomicWrite(try JSONEncoder().encode(loaded), to: indexURL)
        self.index = loaded
    }

    public func saveImage(data: Data, timestamp: Date = Date(), authorization: CaptureAuthorization) throws -> EvidenceImage {
        try authorization.withAuthorization { try saveImage(data: data, timestamp: timestamp) }
    }
    public func saveOCR(text: String, app: String, title: String, timestamp: Date = Date(), authorization: CaptureAuthorization) throws -> OCREvidence {
        try authorization.withAuthorization { try saveOCR(text: text, app: app, title: title, timestamp: timestamp) }
    }
    public func saveCheckpoint(_ checkpoint: CaptureCheckpoint, authorization: CaptureAuthorization) throws {
        try authorization.withAuthorization { try saveCheckpoint(checkpoint) }
    }
    /// Ends an active-time window (30 images / five active minutes). The server forms the
    /// batch from what it receives; the client only starts a fresh window.
    public func closeWindow(authorization: CaptureAuthorization) throws {
        try authorization.finalize { try clearCheckpoint() }
    }

    public func saveImage(data: Data, timestamp: Date = Date()) throws -> EvidenceImage {
        guard !data.isEmpty, data.count <= 30_000_000 else { throw EvidenceStoreError.invalidInput }
        let id = Self.makeID(prefix: "image")
        let url = imagesDirectory.appendingPathComponent(Self.timestampName(timestamp, id: id, suffix: "png"))
        try Self.atomicWrite(data, to: url)
        let image = EvidenceImage(id: id, timestamp: timestamp, fileURL: url)
        index.images.append(image); try persist()
        return image
    }

    public func saveOCR(text: String, app: String, title: String, timestamp: Date = Date()) throws -> OCREvidence {
        guard text.count <= Self.maximumOCRCharacters,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EvidenceStoreError.invalidInput }
        let evidence = OCREvidence(id: Self.makeID(prefix: "ocr"), timestamp: timestamp, text: text, app: String(app.prefix(256)), title: String(title.prefix(1024)))
        index.ocr.append(evidence); try persist()
        return evidence
    }

    public func loadCheckpoint() throws -> CaptureCheckpoint {
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return CaptureCheckpoint() }
        var checkpoint = try JSONDecoder().decode(CaptureCheckpoint.self, from: Self.safeRead(checkpointURL, in: root, maximumBytes: Self.maximumCheckpointBytes))
        guard checkpoint.ocr.allSatisfy({ Self.validID($0.id) }), checkpoint.images.allSatisfy({ Self.validID($0.id) }) else { throw EvidenceStoreError.invalidInput }
        checkpoint.clock.pause() // a persisted anchor cannot prove continuous eligibility.
        return checkpoint
    }

    /// The checkpoint keeps image records for counting even after their files were uploaded.
    public func saveCheckpoint(_ checkpoint: CaptureCheckpoint) throws {
        guard checkpoint.ocr.allSatisfy({ Self.validID($0.id) }), checkpoint.images.allSatisfy({ Self.validID($0.id) }) else { throw EvidenceStoreError.invalidInput }
        try Self.atomicWrite(try JSONEncoder().encode(checkpoint), to: checkpointURL)
    }

    public func clearCheckpoint() throws {
        guard !Self.isSymlink(checkpointURL) else { throw EvidenceStoreError.unsafePath }
        if FileManager.default.fileExists(atPath: checkpointURL.path) { try FileManager.default.removeItem(at: checkpointURL) }
    }

    public struct CaptureStatus: Codable, Equatable, Sendable {
        public let capture: String; public let reason: String; public let integrity: Bool; public let updated: Date
    }

    /// Latest capture state and Integrity value, relayed to the server by the uploader.
    public func saveCaptureStatus(state: String, reason: String, integrity: Bool) throws {
        let status = CaptureStatus(capture: String(state.prefix(32)), reason: String(reason.prefix(500)), integrity: integrity, updated: Date())
        try Self.atomicWrite(try JSONEncoder().encode(status), to: statusURL)
    }

    public func captureStatus() -> CaptureStatus? {
        guard let data = try? Self.safeRead(statusURL, in: root, maximumBytes: 64_000) else { return nil }
        return try? JSONDecoder().decode(CaptureStatus.self, from: data)
    }

    public func latestOCR() -> OCREvidence? { index.ocr.filter { !Self.expired($0.timestamp, now: Date()) }.max { $0.timestamp < $1.timestamp } }

    public var pendingCounts: (images: Int, ocr: Int) { (index.images.count, index.ocr.count) }

    /// The next uploads in capture order, at most `limit` items.
    public func pendingUploads(limit: Int = 20) -> [UploadItem] {
        let now = Date()
        let images = index.images.filter { !Self.expired($0.timestamp, now: now) }.sorted { $0.timestamp < $1.timestamp }
        var ocr = index.ocr.filter { !Self.expired($0.timestamp, now: now) }.sorted { $0.timestamp < $1.timestamp }[...]
        var items: [UploadItem] = []
        for image in images {
            guard items.count < limit else { return items }
            var group: [OCREvidence] = []
            while let next = ocr.first, next.timestamp <= image.timestamp {
                group.append(next); ocr = ocr.dropFirst()
                if group.count == Self.maximumOCRUploadGroup { items.append(.ocr(group)); group = [] }
            }
            if !group.isEmpty { items.append(.ocr(group)) }
            items.append(.image(image))
        }
        while !ocr.isEmpty && items.count < limit {
            let group = Array(ocr.prefix(Self.maximumOCRUploadGroup)); ocr = ocr.dropFirst(group.count)
            items.append(.ocr(group))
        }
        return Array(items.prefix(limit))
    }

    /// Removes acknowledged items (and image files) from the outbox.
    public func acknowledge(ocr ids: [String] = [], image id: String? = nil) throws {
        let drop = Set(ids)
        index.ocr.removeAll { drop.contains($0.id) }
        if let id, let i = index.images.firstIndex(where: { $0.id == id }) {
            let image = index.images.remove(at: i)
            if try Self.confined(image.fileURL, in: imagesDirectory) { try Self.removeIfPresent(image.fileURL) }
        }
        try persist()
    }

    public func cleanup(now: Date = Date()) throws {
        try Self.cleanup(&index, imagesDirectory: imagesDirectory, checkpointURL: checkpointURL, now: now)
        try persist()
    }

    private static func cleanup(_ index: inout Index, imagesDirectory: URL, checkpointURL: URL, now: Date) throws {
        let cutoff = now.addingTimeInterval(-retention)
        for image in index.images where image.timestamp < cutoff {
            if try confined(image.fileURL, in: imagesDirectory) { try removeIfPresent(image.fileURL) }
        }
        index.images.removeAll { $0.timestamp < cutoff }
        index.ocr.removeAll { $0.timestamp < cutoff }
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            var checkpoint = try JSONDecoder().decode(CaptureCheckpoint.self, from: safeRead(checkpointURL, in: checkpointURL.deletingLastPathComponent(), maximumBytes: maximumCheckpointBytes))
            checkpoint.images.removeAll { $0.timestamp < cutoff }
            checkpoint.ocr.removeAll { $0.timestamp < cutoff }
            checkpoint.clock.pause()
            if checkpoint.images.isEmpty && checkpoint.ocr.isEmpty && checkpoint.startedAt.map({ $0 < cutoff }) == true { try removeIfPresent(checkpointURL) }
            else { try atomicWrite(try JSONEncoder().encode(checkpoint), to: checkpointURL) }
        }
        // A crash between the atomic file write and the index write leaves an unindexed
        // file. It is still xCreen-owned and must receive the same TTL.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        for file in try FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff, try confined(file, in: imagesDirectory) else { continue }
            try removeIfPresent(file)
        }
    }

    private func persist() throws { try Self.atomicWrite(try JSONEncoder().encode(index), to: indexURL) }
    private static func makeID(prefix: String) -> String { "\(prefix)-\(UUID().uuidString.lowercased())" }
    private static func timestampName(_ date: Date, id: String, suffix: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-") + "_\(id).\(suffix)"
    }
    private static func validID(_ id: String) -> Bool { !id.isEmpty && id.count <= 100 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
    private static func makePrivateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { guard !isSymlink(url) else { throw EvidenceStoreError.unsafePath } }
        else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        guard !isSymlink(directory) else { throw EvidenceStoreError.unsafePath }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch { _ = Darwin.unlink(temporary.path); throw error }
    }
    private static func isSymlink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    private static func confined(_ url: URL, in directory: URL) throws -> Bool {
        let candidate = url.standardizedFileURL, base = directory.standardizedFileURL
        guard candidate.isFileURL, candidate.path.hasPrefix(base.path + "/"), !isSymlink(candidate), !isSymlink(base) else { return false }
        return true
    }
    private static func safeRead(_ url: URL, in directory: URL, maximumBytes: Int) throws -> Data {
        guard try confined(url, in: directory), regularFileExists(url) else { throw EvidenceStoreError.unsafePath }
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= 0 && size <= maximumBytes else { throw EvidenceStoreError.invalidInput }
        return try Data(contentsOf: url)
    }
    private static func regularFileExists(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])) .map { $0.isRegularFile == true && $0.isSymbolicLink != true } ?? false }
    private static func expired(_ date: Date, now: Date) -> Bool { date < now.addingTimeInterval(-retention) }
    private static func removeIfPresent(_ url: URL) throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}

public enum EvidenceStoreError: Error, Equatable { case invalidInput, unsafePath, deferred }
