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

public struct CaptureBatch: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let images: [EvidenceImage]
    public let startedAt: Date
    public let completedAt: Date
    public let ocr: [OCREvidence]
    public init(id: String, images: [EvidenceImage], startedAt: Date, completedAt: Date, ocr: [OCREvidence]) {
        self.id = id; self.images = images; self.startedAt = startedAt; self.completedAt = completedAt; self.ocr = ocr
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

public actor EvidenceStore {
    private struct BatchRecord: Codable { var batch: CaptureBatch; var status: String }
    private struct Index: Codable { var images: [EvidenceImage] = []; var ocr: [OCREvidence] = []; var batches: [BatchRecord] = [] }
    private static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// Index and checkpoint reads are deliberately bounded: these are local
    /// recovery files, not an unbounded import format.
    private static let maximumIndexBytes = 8_000_000
    private static let maximumCheckpointBytes = 8_000_000
    public static let maximumOCRCharacters = 12_000
    private let root: URL
    private let imagesDirectory: URL
    private let ocrDirectory: URL
    private let indexURL: URL
    private let checkpointURL: URL
    private var index: Index

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("xCreen/Evidence", isDirectory: true)
    }

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        if FileManager.default.fileExists(atPath: self.root.path), Self.isSymlink(self.root) { throw EvidenceStoreError.unsafePath }
        self.imagesDirectory = self.root.appendingPathComponent("images", isDirectory: true)
        self.ocrDirectory = self.root.appendingPathComponent("ocr", isDirectory: true)
        self.indexURL = self.root.appendingPathComponent("index.json")
        self.checkpointURL = self.root.appendingPathComponent("capture-checkpoint.json")
        try Self.makePrivateDirectory(self.root)
        try Self.makePrivateDirectory(imagesDirectory)
        try Self.makePrivateDirectory(ocrDirectory)
        guard !Self.isSymlink(imagesDirectory), !Self.isSymlink(ocrDirectory) else { throw EvidenceStoreError.unsafePath }
        if FileManager.default.fileExists(atPath: indexURL.path) {
            self.index = try JSONDecoder().decode(Index.self, from: Self.safeRead(indexURL, in: self.root, maximumBytes: Self.maximumIndexBytes))
        } else {
            self.index = Index()
            try Self.atomicWrite(try JSONEncoder().encode(index), to: indexURL)
        }
        try Self.validate(&index, imagesDirectory: imagesDirectory, ocrDirectory: ocrDirectory)
        try Self.cleanup(&index, imagesDirectory: imagesDirectory, ocrDirectory: ocrDirectory, checkpointURL: checkpointURL, now: Date())
        try Self.atomicWrite(try JSONEncoder().encode(index), to: indexURL)
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
    public func finalizeBatch(_ batch: CaptureBatch, authorization: CaptureAuthorization) throws {
        try authorization.finalize {
            try savePendingBatch(batch)
            try clearCheckpoint()
        }
    }

    public func saveImage(data: Data, timestamp: Date = Date()) throws -> EvidenceImage {
        guard !data.isEmpty, data.count <= 30_000_000 else { throw EvidenceStoreError.invalidInput }
        let id = Self.makeID(prefix: "image")
        let name = Self.timestampName(timestamp, id: id, suffix: "png")
        let url = imagesDirectory.appendingPathComponent(name)
        try Self.atomicWrite(data, to: url)
        let image = EvidenceImage(id: id, timestamp: timestamp, fileURL: url)
        index.images.append(image); try persist()
        return image
    }

    public func saveOCR(text: String, app: String, title: String, timestamp: Date = Date()) throws -> OCREvidence {
        guard text.count <= Self.maximumOCRCharacters,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EvidenceStoreError.invalidInput }
        let evidence = OCREvidence(id: Self.makeID(prefix: "ocr"), timestamp: timestamp, text: text, app: String(app.prefix(256)), title: String(title.prefix(1024)))
        let url = ocrDirectory.appendingPathComponent(Self.timestampName(timestamp, id: evidence.id, suffix: "json"))
        try Self.atomicWrite(try JSONEncoder().encode(evidence), to: url)
        index.ocr.append(evidence); try persist()
        return evidence
    }

    public func savePendingBatch(_ batch: CaptureBatch) throws {
        try Self.validate(batch: batch, imagesDirectory: imagesDirectory, ocrDirectory: ocrDirectory)
        index.batches.removeAll { $0.batch.id == batch.id }
        index.batches.append(BatchRecord(batch: batch, status: "pending")); try persist()
    }

    public func loadCheckpoint() throws -> CaptureCheckpoint {
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return CaptureCheckpoint() }
        var checkpoint = try JSONDecoder().decode(CaptureCheckpoint.self, from: Self.safeRead(checkpointURL, in: root, maximumBytes: Self.maximumCheckpointBytes))
        try Self.validate(checkpoint: checkpoint, imagesDirectory: imagesDirectory, ocrDirectory: ocrDirectory)
        checkpoint.clock.pause() // a persisted anchor cannot prove continuous eligibility.
        return checkpoint
    }

    public func saveCheckpoint(_ checkpoint: CaptureCheckpoint) throws {
        try Self.validate(checkpoint: checkpoint, imagesDirectory: imagesDirectory, ocrDirectory: ocrDirectory)
        try Self.atomicWrite(try JSONEncoder().encode(checkpoint), to: checkpointURL)
    }

    public func clearCheckpoint() throws {
        guard !Self.isSymlink(checkpointURL) else { throw EvidenceStoreError.unsafePath }
        if FileManager.default.fileExists(atPath: checkpointURL.path) { try FileManager.default.removeItem(at: checkpointURL) }
    }

    public func saveCaptureStatus(state: String, reason: String, integrity: Bool) throws {
        let values = ["capture": String(state.prefix(32)), "capture_reason": String(reason.prefix(500)), "desired_integrity": integrity ? "on" : "off", "updated": ISO8601DateFormatter().string(from: Date())]
        try Self.atomicWrite(try JSONEncoder().encode(values), to: root.appendingPathComponent("capture-status.json"))
    }

    public func latestOCR() -> OCREvidence? { index.ocr.filter { !Self.expired($0.timestamp, now: Date()) }.max { $0.timestamp < $1.timestamp } }

    public func searchOCR(query: String, limit: Int = 20) throws -> [OCREvidence] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).prefix(8)
        guard !terms.isEmpty else { return [] }
        return index.ocr.reversed().filter { item in
            guard !Self.expired(item.timestamp, now: Date()) else { return false }
            let haystack = "\(item.text) \(item.app) \(item.title)".lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }.prefix(max(0, min(limit, 100))).map { $0 }
    }

    public func imagesNear(timestamp: Date, seconds: Double = 30) throws -> [EvidenceImage] {
        guard seconds.isFinite, seconds >= 0 else { throw EvidenceStoreError.invalidInput }
        let window = min(seconds, 86_400), now = Date()
        return index.images.filter { item in
            guard !Self.expired(item.timestamp, now: now),
                  abs(item.timestamp.timeIntervalSince(timestamp)) <= window,
                  (try? Self.confined(item.fileURL, in: imagesDirectory)) == true else { return false }
            return Self.regularFileExists(item.fileURL)
        }.sorted { $0.timestamp < $1.timestamp }
    }

    public func image(id: String) throws -> EvidenceImage? {
        guard Self.validID(id) else { throw EvidenceStoreError.invalidInput }
        guard let result = index.images.first(where: { $0.id == id }) else { return nil }
        guard !Self.expired(result.timestamp, now: Date()), try Self.confined(result.fileURL, in: imagesDirectory), Self.regularFileExists(result.fileURL) else { return nil }
        return result
    }

    public func pendingBatches() throws -> [CaptureBatch] { index.batches.filter { $0.status == "pending" && !Self.expired($0.batch.completedAt, now: Date()) }.map(\.batch).sorted { $0.startedAt < $1.startedAt } }
    public func markBatch(id: String, status: String) throws {
        guard Self.validID(id), ["pending", "sent", "failed"].contains(status), let i = index.batches.firstIndex(where: { $0.batch.id == id }) else { throw EvidenceStoreError.invalidInput }
        index.batches[i].status = status; try persist()
    }

    public func cleanup(now: Date = Date()) throws {
        try Self.cleanup(&index, imagesDirectory: imagesDirectory, ocrDirectory: ocrDirectory, checkpointURL: checkpointURL, now: now)
        try persist()
    }

    private static func cleanup(_ index: inout Index, imagesDirectory: URL, ocrDirectory: URL, checkpointURL: URL, now: Date) throws {
        let cutoff = now.addingTimeInterval(-retention)
        let staleImages = index.images.filter { $0.timestamp < cutoff }
        for image in staleImages where try confined(image.fileURL, in: imagesDirectory) { try removeIfPresent(image.fileURL) }
        index.images.removeAll { $0.timestamp < cutoff }
        let staleOCR = index.ocr.filter { $0.timestamp < cutoff }
        for item in staleOCR {
            let url = ocrDirectory.appendingPathComponent(Self.timestampName(item.timestamp, id: item.id, suffix: "json"))
            if try confined(url, in: ocrDirectory) { try removeIfPresent(url) }
        }
        index.ocr.removeAll { $0.timestamp < cutoff }
        // A batch is a derivative: retaining a new batch that points at expired
        // raw evidence would bypass the TTL, so remove it as a whole.
        index.batches.removeAll { record in
            record.batch.completedAt < cutoff || record.batch.images.contains { $0.timestamp < cutoff } || record.batch.ocr.contains { $0.timestamp < cutoff }
        }
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            var checkpoint = try JSONDecoder().decode(CaptureCheckpoint.self, from: safeRead(checkpointURL, in: checkpointURL.deletingLastPathComponent(), maximumBytes: maximumCheckpointBytes))
            checkpoint.images.removeAll { $0.timestamp < cutoff }
            checkpoint.ocr.removeAll { $0.timestamp < cutoff }
            checkpoint.clock.pause()
            if checkpoint.images.isEmpty && checkpoint.ocr.isEmpty && checkpoint.startedAt.map({ $0 < cutoff }) == true { try removeIfPresent(checkpointURL) }
            else { try atomicWrite(try JSONEncoder().encode(checkpoint), to: checkpointURL) }
        }
        // A crash between the atomic evidence write and index write leaves an
        // unindexed file. It is still xCreen-owned and must receive the same TTL.
        try removeExpiredFiles(in: imagesDirectory, before: cutoff)
        try removeExpiredFiles(in: ocrDirectory, before: cutoff)
    }

    private static func removeExpiredFiles(in directory: URL, before cutoff: Date) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        for file in files {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff,
                  try confined(file, in: directory) else { continue }
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
    private static func validate(_ index: inout Index, imagesDirectory: URL, ocrDirectory: URL) throws {
        guard index.images.allSatisfy({ validID($0.id) && (try? confined($0.fileURL, in: imagesDirectory)) == true }),
              index.ocr.allSatisfy({ validID($0.id) }),
              index.batches.allSatisfy({ validID($0.batch.id) }) else { throw EvidenceStoreError.invalidInput }
        for record in index.batches { try validate(batch: record.batch, imagesDirectory: imagesDirectory, ocrDirectory: ocrDirectory) }
    }
    private static func validate(batch: CaptureBatch, imagesDirectory: URL, ocrDirectory: URL) throws {
        guard validID(batch.id), batch.images.allSatisfy({ validID($0.id) && (try? confined($0.fileURL, in: imagesDirectory)) == true }), batch.ocr.allSatisfy({ validID($0.id) }) else { throw EvidenceStoreError.invalidInput }
    }
    private static func validate(checkpoint: CaptureCheckpoint, imagesDirectory: URL, ocrDirectory: URL) throws {
        guard checkpoint.images.allSatisfy({ validID($0.id) && (try? confined($0.fileURL, in: imagesDirectory)) == true }), checkpoint.ocr.allSatisfy({ validID($0.id) }) else { throw EvidenceStoreError.invalidInput }
    }
}

public enum EvidenceStoreError: Error { case invalidInput, unsafePath }
