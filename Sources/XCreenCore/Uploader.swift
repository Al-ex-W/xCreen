import Foundation

/// Drains the capture outbox to the server in capture order and relays capture status.
///
/// An item leaves the outbox only after the server acknowledged it (uploads are idempotent
/// by id, so a lost acknowledgement just repeats the upload). Transport failures back off
/// up to a minute; an item the server permanently rejects (400/409/413) is dropped and
/// logged so it can't block everything behind it.
public actor Uploader {
    public struct State: Equatable, Sendable {
        public var reachable = false
        public var lastError = ""
        public var lastUpload: Date?
        public var pendingImages = 0
        public var pendingOCR = 0
        public init() {}
    }

    private let store: EvidenceStore
    private var server: (any XCreenServerAPI)?
    private var task: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var kicked = false
    private var reported: EvidenceStore.CaptureStatus?
    private var reportedAt: Date = .distantPast
    public private(set) var state = State()
    private let log: (@Sendable (String) -> Void)?
    private let onChange: (@Sendable (State) -> Void)?

    public init(store: EvidenceStore, log: (@Sendable (String) -> Void)? = nil, onChange: (@Sendable (State) -> Void)? = nil) {
        self.store = store; self.log = log; self.onChange = onChange
    }

    public func setServer(_ server: (any XCreenServerAPI)?) {
        self.server = server
        reported = nil
        if task == nil { task = Task { await self.loop() } }
        kick()
    }

    /// Points the uploader at a server without starting its loop (tests drive `drain()`).
    func setServerWithoutLoop(_ server: (any XCreenServerAPI)?) { self.server = server; reported = nil }

    public func stop() { task?.cancel(); task = nil; wake?.resume(); wake = nil }

    /// New evidence or a status change: upload now instead of at the next poll.
    public func kick() {
        kicked = true
        wake?.resume(); wake = nil
    }

    /// One full pass; returns how many items were acknowledged. Public for tests and `flush`.
    @discardableResult public func drain(maximum: Int = 500) async -> Int {
        guard let server else { publish(reachable: false, error: ServerAPIError.notConfigured.localizedDescription); return 0 }
        var done = 0
        do {
            try await reportStatusIfNeeded(server)
            while done < maximum {
                let items = await store.pendingUploads(limit: 20)
                if items.isEmpty { break }
                for item in items {
                    try Task.checkCancellation()
                    do {
                        switch item {
                        case .ocr(let group):
                            try await server.uploadOCR(group)
                            try await store.acknowledge(ocr: group.map(\.id))
                        case .image(let image):
                            let data = try Data(contentsOf: image.fileURL, options: [.mappedIfSafe])
                            try await server.uploadImage(image, data: data)
                            try await store.acknowledge(image: image.id)
                        }
                        done += 1
                    } catch let error as ServerAPIError where error.isPermanentRejection {
                        log?("upload rejected permanently, dropped: \(error.localizedDescription)")
                        switch item {
                        case .ocr(let group): try await store.acknowledge(ocr: group.map(\.id))
                        case .image(let image): try await store.acknowledge(image: image.id)
                        }
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                        if case .image(let image) = item { try await store.acknowledge(image: image.id) }
                    }
                }
            }
            if done > 0 { state.lastUpload = Date() }
            publish(reachable: true, error: "")
        } catch is CancellationError {
        } catch {
            publish(reachable: false, error: error.localizedDescription)
        }
        return done
    }

    private func reportStatusIfNeeded(_ server: any XCreenServerAPI) async throws {
        guard let status = await store.captureStatus() else { return }
        let changed = reported.map { $0.capture != status.capture || $0.reason != status.reason || $0.integrity != status.integrity } ?? true
        guard changed || Date().timeIntervalSince(reportedAt) > 60 else { return }
        try await server.reportCapture(state: status.capture, reason: status.reason, integrity: status.integrity)
        reported = status; reportedAt = Date()
    }

    private func publish(reachable: Bool, error: String) {
        state.reachable = reachable
        state.lastError = error
        Task { [store] in
            let counts = await store.pendingCounts
            await self.updateCounts(images: counts.images, ocr: counts.ocr)
        }
    }

    private func updateCounts(images: Int, ocr: Int) {
        state.pendingImages = images; state.pendingOCR = ocr
        onChange?(state)
    }

    private func loop() async {
        var backoff: Double = 2
        while !Task.isCancelled {
            kicked = false
            let before = state.reachable
            await drain()
            if state.reachable { backoff = 2 } else { backoff = min(backoff * 2, 60) }
            if !before && state.reachable { log?("server reachable") }
            if kicked { continue }
            let delay = state.reachable ? 15 : backoff
            await sleep(seconds: delay)
        }
    }

    private func sleep(seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if kicked { continuation.resume(); return }
            wake = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await self?.timerFired()
            }
        }
    }

    private func timerFired() { wake?.resume(); wake = nil }
}
