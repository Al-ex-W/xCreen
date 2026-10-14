import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import XCreenCore

private enum CaptureServiceError: Error { case noForegroundWindow, imageEncoding, superseded }

private enum VisionTextRecognizer {
    static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Native capture owner. It asks no permissions: explicit user opt-in must pass
/// the system preflight check. A changed generation discards every in-flight image
/// and OCR result before it is persisted.
@MainActor
final class CaptureService {
    private let store: EvidenceStore
    private let status: (String) -> Void
    private let integrityChanged: (Bool) -> Void
    private let batchReady: (CaptureBatch) -> Void
    private var loop: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var enabled = false
    private var observers: [NSObjectProtocol] = []
    private var checkpoint = CaptureCheckpoint()
    private var lastSavedOCR: OCREvidence?
    private let log = ActivityLog.shared

    init(store: EvidenceStore, status: @escaping (String) -> Void, integrityChanged: @escaping (Bool) -> Void, batchReady: @escaping (CaptureBatch) -> Void) {
        self.store = store; self.status = status; self.integrityChanged = integrityChanged; self.batchReady = batchReady
        integrityChanged(true)
        installLifecycleObservers()
        Task { [weak self] in
            guard let self else { return }
            do { self.checkpoint = try await store.loadCheckpoint(); self.lastSavedOCR = await store.latestOCR() }
            catch { self.pause(reason: "Capture paused · evidence checkpoint is unsafe") }
        }
        // Retention runs even while Integrity mode pauses capture.
        maintenance = Task { [store] in
            while !Task.isCancelled {
                try? await store.cleanup()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    deinit { loop?.cancel(); maintenance?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }

    @discardableResult
    func enableAfterExplicitConsent() -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            // The user just turned Integrity off, so asking now is user-initiated. macOS shows
            // its prompt once; afterwards the user grants it in System Settings.
            if !CGRequestScreenCaptureAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            pause(reason: "Allow xCreen under Screen Recording, then turn Integrity off again")
            return false
        }
        guard MacSessionState.current == .unlocked else { pause(reason: "Capture remains paused · current session state cannot be verified safely"); return false }
        enabled = true; generation &+= 1; integrityChanged(false); status("Capture enabled · local native evidence only")
        log.write(.capture, "enabled")
        log.updateStatus(["capture": "running", "capture_reason": ""])
        startLoop(); return true
    }

    func pause(reason: String = "Integrity mode · capture paused") {
        enabled = false; generation &+= 1; loop?.cancel(); loop = nil
        checkpoint.clock.pause()
        Task { [store, checkpoint] in try? await store.saveCheckpoint(checkpoint) }
        integrityChanged(true); status(reason)
        log.write(.capture, "paused: \(reason)")
        log.updateStatus(["capture": "paused", "capture_reason": reason])
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while let self, !Task.isCancelled {
                await self.captureOnce()
                deadline += .seconds(1)
                if deadline < clock.now { deadline = clock.now + .seconds(1) }
                do { try await clock.sleep(until: deadline, tolerance: .milliseconds(25)) } catch { return }
            }
        }
    }

    private func captureOnce() async {
        let token = generation
        guard enabled, !Task.isCancelled else { return }
        guard CGPreflightScreenCaptureAccess() else { pause(reason: "Capture paused · Screen Recording permission missing"); return }
        guard MacSessionState.current == .unlocked else { pause(reason: "Capture paused · session locked or not verifiable"); return }
        guard let target = foregroundTarget() else { await pauseClockForPrivacy("Capture enabled · foreground application is unknown"); return }
        guard target.isEligible else { await pauseClockForPrivacy("Capture enabled · foreground application is excluded"); return }
        do {
            let (image, title) = try await captureWindow(target: target, token: token)
            guard accepts(token, target) else { return }
            let text = try await VisionTextRecognizer.recognize(image)
            guard accepts(token, target) else { return }
            let now = Date()
            _ = checkpoint.clock.recordEligibleSample(at: now)
            if !text.isEmpty && !isNearDuplicate(text, lastSavedOCR?.text) {
                let evidence = try await store.saveOCR(text: text, app: target.bundleID, title: title, timestamp: now)
                guard accepts(token, target) else { return }
                lastSavedOCR = evidence; checkpoint.ocr.append(evidence)
                log.write(.capture, "ocr saved id=\(evidence.id) app=\(target.bundleID) chars=\(text.count)")
            } else if !text.isEmpty {
                log.write(.capture, "ocr skipped (>=90% same as last) app=\(target.bundleID)")
            }
            if checkpoint.images.count < checkpoint.clock.imageCountDue {
                guard let png = pngData(image) else { throw CaptureServiceError.imageEncoding }
                let saved = try await store.saveImage(data: png, timestamp: now)
                guard accepts(token, target) else { return }
                checkpoint.images.append(saved)
                log.write(.capture, "image saved id=\(saved.id) \(checkpoint.images.count)/30 active=\(Int(checkpoint.clock.activeSeconds))s")
            }
            if checkpoint.startedAt == nil { checkpoint.startedAt = now }
            if checkpoint.clock.isComplete && checkpoint.images.count == 30 {
                let batch = CaptureBatch(id: "batch-\(UUID().uuidString.lowercased())", images: checkpoint.images, startedAt: checkpoint.startedAt ?? now, completedAt: now, ocr: checkpoint.ocr)
                try await store.savePendingBatch(batch)
                try await store.clearCheckpoint()
                checkpoint = CaptureCheckpoint()
                log.write(.batch, "batch ready id=\(batch.id) images=\(batch.images.count) ocr=\(batch.ocr.count)")
                batchReady(batch)
            } else { try await store.saveCheckpoint(checkpoint) }
        } catch CaptureServiceError.superseded, is CancellationError { return }
        catch {
            log.write(.error, "capture failed: \(error)")
            pause(reason: "Capture paused · capture, OCR, or evidence storage failed")
        }
    }

    private func pauseClockForPrivacy(_ message: String) async {
        if !checkpoint.clock.isPaused { log.write(.capture, "clock paused: \(message)") }
        checkpoint.clock.pause()
        do { try await store.saveCheckpoint(checkpoint) }
        catch { pause(reason: "Capture paused · evidence checkpoint is unsafe") ; return }
        status(message)
    }

    private func accepts(_ token: UInt64, _ target: ForegroundTarget) -> Bool {
        token == generation && enabled && MacSessionState.current == .unlocked && foregroundTarget() == target
    }

    private func foregroundTarget() -> ForegroundTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, !id.isEmpty, app.processIdentifier > 0 else { return nil }
        return ForegroundTarget(bundleID: id, processID: app.processIdentifier)
    }

    private func captureWindow(target: ForegroundTarget, token: UInt64) async throws -> (CGImage, String) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard accepts(token, target), let window = content.windows.first(where: { $0.owningApplication?.processID == target.processID && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 }) else { throw CaptureServiceError.noForegroundWindow }
        let config = SCStreamConfiguration(); let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = min(4096, max(1, Int(window.frame.width * scale))); config.height = min(4096, max(1, Int(window.frame.height * scale))); config.showsCursor = false
        guard accepts(token, target) else { throw CaptureServiceError.superseded }
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        return (image, window.title ?? "")
    }

    private func pngData(_ image: CGImage) -> Data? { NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) }
    private func isNearDuplicate(_ candidate: String, _ previous: String?) -> Bool {
        guard let previous else { return false }
        let left = normalizedTokens(candidate), right = normalizedTokens(previous)
        guard !left.isEmpty || !right.isEmpty else { return true }
        let overlap = left.intersection(right).count, union = left.union(right).count
        return union > 0 && Double(overlap) / Double(union) >= 0.9
    }
    private func normalizedTokens(_ text: String) -> Set<String> { Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }) }
    private func installLifecycleObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification].forEach { name in
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pause(reason: "Capture paused · session inactive or display asleep") } })
        }
        ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"].forEach { raw in
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(raw), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pause(reason: "Capture paused · screen locked") } })
        }
    }
}

private struct ForegroundTarget: Equatable {
    let bundleID: String; let processID: pid_t
    var isEligible: Bool {
        let id = bundleID.lowercased()
        let excluded = ["1password", "bitwarden", "lastpass", "dashlane", "keepass", "keychain", "loginwindow", "screenlock", "securityagent", "com.apple.passwords", "com.apple.systemsettings", "com.apple.systempreferences", "com.apple.safari", "com.google.chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.browser", "dev.xcreen.app"]
        return !excluded.contains(where: id.contains)
    }
}
