import Foundation

public protocol ImageEncoding: Sendable {
    /// Encodes the image file at `url` and returns JPEG bytes.
    func encode(_ url: URL) throws -> Data
}

public enum ImageEncodingError: Error, Equatable { case failed, timedOut }

/// mozjpeg's `cjpeg`, installed by Homebrew. It reads the PNG directly; no pixels
/// pass through xCreen memory. Quality 30 kept ~95% of OCR-readable words on real
/// screenshots at ~1/8 of the PNG size.
public struct MozJPEGEncoder: ImageEncoding {
    public static let quality = 30
    public static let candidates = ["/opt/homebrew/opt/mozjpeg/bin/cjpeg", "/usr/local/opt/mozjpeg/bin/cjpeg"]
    public let executable: URL

    /// Fixed install locations only, never PATH.
    public static func locate(candidates: [String] = candidates) -> MozJPEGEncoder? {
        for path in candidates {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if FileManager.default.isExecutableFile(atPath: resolved.path) { return MozJPEGEncoder(executable: resolved) }
        }
        return nil
    }

    public func encode(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-quality", String(Self.quality), url.standardizedFileURL.path]
        process.environment = [:]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let collected = Collected()
        let done = DispatchSemaphore(value: 0)
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            collected.set(output.fileHandleForReading.readDataToEndOfFile()); done.signal()
        }
        if done.wait(timeout: .now() + 30) == .timedOut {
            process.terminate(); _ = done.wait(timeout: .now() + 5)
            throw ImageEncodingError.timedOut
        }
        process.waitUntilExit()
        let data = collected.get()
        guard process.terminationStatus == 0, data.count > 3, data.count <= 30_000_000, data.starts(with: [0xff, 0xd8, 0xff]) else { throw ImageEncodingError.failed }
        return data
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock(); private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}

/// Recompresses images whose digest has completed. The digest itself always saw
/// the lossless capture; only retained evidence for later questions is lossy.
public actor ImageCompactor {
    private let store: EvidenceStore
    private let encoder: ImageEncoding?
    private var skipped: Set<String> = []

    public init(store: EvidenceStore, encoder: ImageEncoding?) { self.store = store; self.encoder = encoder }

    public var isAvailable: Bool { encoder != nil }

    /// Returns how many images were replaced. Output that is not smaller, or fails
    /// to encode, keeps the PNG and is not retried until the app restarts.
    @discardableResult public func run(limit: Int = 120) async -> Int {
        guard let encoder else { return 0 }
        try? await store.removeSupersededOriginals()
        var replaced = 0
        for image in await store.compressibleImages(limit: limit + skipped.count) where !skipped.contains(image.id) {
            if Task.isCancelled || replaced >= limit { break }
            let url = image.fileURL
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let data = try? await Task.detached(priority: .background) { try encoder.encode(url) }.value
            guard let data, data.count < size else { skipped.insert(image.id); continue }
            if (try? await store.replaceImage(id: image.id, expecting: url, with: data)) != nil { replaced += 1 } else { skipped.insert(image.id) }
        }
        return replaced
    }
}
