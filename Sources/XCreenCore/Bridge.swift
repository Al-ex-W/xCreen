import Foundation
#if os(macOS)
import Darwin
#endif

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = Data()
    private(set) var overflowed = false

    init(limit: Int) {
        self.limit = limit
        bytes.reserveCapacity(min(limit, 64 * 1024))
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return }
        let remaining = limit - bytes.count
        if chunk.count > remaining {
            if remaining > 0 { bytes.append(chunk.prefix(remaining)) }
            overflowed = true
        } else {
            bytes.append(chunk)
        }
    }

    func snapshot() -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, overflowed)
    }
}

public final class BridgeRunner: @unchecked Sendable {
    public static let maximumOutputBytes = 2 * 1024 * 1024
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let active = process; lock.unlock()
        active?.terminate()
    }
    public func run(executable: String, arguments: [String], input: Data? = nil, timeout: TimeInterval = 120) async throws -> Data {
        guard timeout.isFinite, timeout > 0 else {
            throw NSError(domain: "xCreen.Bridge", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid bridge timeout."])
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global().async {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: executable)
                child.arguments = arguments
                let output = Pipe()
                child.standardOutput = output
                child.standardError = FileHandle.nullDevice
                let inputPipe = input == nil ? nil : Pipe()
                child.standardInput = inputPipe
                let terminated = DispatchSemaphore(value: 0)
                child.terminationHandler = { _ in terminated.signal() }
                self.lock.lock()
                guard !self.cancelled else { self.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.process = child
                do { try child.run() } catch {
                    self.process = nil
                    self.lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                self.lock.unlock()
                output.fileHandleForWriting.closeFile()
                if let input, let inputPipe {
                    do { try inputPipe.fileHandleForWriting.write(contentsOf: input) }
                    catch { child.terminate() }
                    inputPipe.fileHandleForWriting.closeFile()
                }

                let collected = BoundedOutput(limit: Self.maximumOutputBytes)
                let readerFinished = DispatchGroup()
                readerFinished.enter()
                DispatchQueue.global().async {
                    defer { readerFinished.leave() }
                    while true {
                        do {
                            guard let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024),
                                  !chunk.isEmpty else { break }
                            collected.append(chunk)
                        } catch {
                            break
                        }
                    }
                }

                let end = Date().addingTimeInterval(timeout)
                var timedOut = false
                var stopped = false
                while terminated.wait(timeout: .now() + 0.02) == .timedOut {
                    self.lock.lock(); stopped = self.cancelled; self.lock.unlock()
                    let overflowed = collected.snapshot().1
                    if stopped || overflowed || Date() >= end {
                        timedOut = !stopped && !overflowed
                        if child.isRunning { child.terminate() }
                        if terminated.wait(timeout: .now() + 0.35) == .timedOut {
#if os(macOS)
                            Darwin.kill(child.processIdentifier, SIGKILL)
#endif
                            _ = terminated.wait(timeout: .now() + 2)
                        }
                        break
                    }
                }
                if child.isRunning {
#if os(macOS)
                    Darwin.kill(child.processIdentifier, SIGKILL)
#endif
                    child.waitUntilExit()
                }
                _ = readerFinished.wait(timeout: .now() + 2)
                let (data, overflowed) = collected.snapshot()
                self.lock.lock(); self.process = nil; stopped = self.cancelled; self.lock.unlock()

                if stopped { continuation.resume(throwing: CancellationError()) }
                else if overflowed { continuation.resume(throwing: NSError(domain: "xCreen.Bridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bridge output exceeded the 2 MiB limit."])) }
                else if timedOut { continuation.resume(throwing: NSError(domain: "xCreen.Bridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bridge timed out."])) }
                else if child.terminationStatus != 0 { continuation.resume(throwing: NSError(domain: "xCreen.Bridge", code: Int(child.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Bridge failed. Check interpreter, dependencies and harness settings."])) }
                else { continuation.resume(returning: data) }
            }
        }
    }
}
public struct BridgeSettings: Equatable {
    public var python: String
    public var script: String
    public var hermes: String
    public var vault: String
    public init(python: String, script: String, hermes: String, vault: String = "") { self.python = python; self.script = script; self.hermes = hermes; self.vault = vault }
    public func askArguments(query: String, modelID: String) -> [String] {
        var args = [script, "ask", "--query", query, "--model-id", modelID, "--hermes", hermes]
        if !vault.isEmpty { args += ["--vault", vault] }
        return args
    }
    public var ingestArguments: [String] { [script, "ingest", "--stdin-json"] }
}

public struct IngestRequest: Codable, Equatable {
    public let text: String
    public let app: String
    public let title: String
    public let timestamp: String?
    public init(text: String, app: String, title: String, timestamp: String? = nil) {
        self.text = text
        self.app = app
        self.title = title
        self.timestamp = timestamp
    }
}

public struct HarnessSettingsState {
    public private(set) var automaticRefresh: BridgeSettings
    public var draft: BridgeSettings
    public init(saved: BridgeSettings) {
        automaticRefresh = saved
        draft = saved
    }
    public mutating func saveDraft() { automaticRefresh = draft }
}
