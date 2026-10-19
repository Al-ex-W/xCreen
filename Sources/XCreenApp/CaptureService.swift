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
    private let safetyChanged: (Bool) -> Void
    /// Called after every saved OCR snapshot or screenshot so the uploader sends it promptly.
    private let captured: () -> Void
    private var loop: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private let persistence = CapturePersistenceEpoch()
    private var generation: UInt64 { persistence.generation }
    private var authorization: CaptureAuthorization { persistence.authorization }
    private func advanceEpoch() { persistence.advance() }
    private var intent = CaptureIntentState()
    private var enabled: Bool { !intent.integrity }
    private var storageBlocked = false
    private var ready = false
    private var lifecycle = CaptureLifecycleState()
    private var lifecycleBlocks: Set<String> { lifecycle.blocks }
    private var statusTransition = CaptureStatusTransition()
    private var exclusionDiagnostic = ForegroundExclusionDiagnostic()

    private func sessionBlockReason() -> String? {
        let epoch = lifecycle.epoch
        let reason = MacSessionState.blockReason
        guard lifecycle.acceptsEvaluation(epoch: epoch) else { return "session lifecycle veto" }
        return reason
    }

    private func lifecycleTransition(_ reason: String, blocked: Bool) {
        lifecycle.transition(reason, blocked: blocked)
        // Synchronous delivery in the main notification queue preserves event order.
        // Even restores revoke old work; only a fresh capture-loop evaluation resumes.
        pause(reason: blocked ? "Capture suspended · \(reason)" : "Capture pending · reevaluating session")
    }
    private var statusTask: Task<Void, Never>?
    private func recordStatus(_ state: String, _ reason: String) {
        let previous = statusTask
        let desiredIntegrity = intent.integrity
        statusTask = Task { [store] in
            await previous?.value
            try? await store.saveCaptureStatus(state: state, reason: reason, integrity: desiredIntegrity)
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var checkpoint: CaptureCheckpoint {
        get { persistence.checkpoint }
        set { persistence.checkpoint = newValue }
    }
    private var lastSavedOCR: OCREvidence?
    private let log = ActivityLog.shared

    init(store: EvidenceStore, status: @escaping (String) -> Void, safetyChanged: @escaping (Bool) -> Void, captured: @escaping () -> Void) {
        self.store = store; self.status = status; self.safetyChanged = safetyChanged; self.captured = captured
        safetyChanged(false)
        installLifecycleObservers()
        recordStatus("paused", "Integrity mode · startup")
        Task { [weak self] in
            guard let self else { return }
            do { self.checkpoint = try await store.loadCheckpoint(); self.lastSavedOCR = await store.latestOCR(); self.ready = true }
            catch { self.storageBlocked = true; self.pause(reason: "Capture blocked · evidence checkpoint is unsafe") }
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
    func enableAfterExplicitConsent(requestPermission: Bool = true) -> Bool {
        intent.userSetIntegrity(false); advanceEpoch()
        if ready { storageBlocked = false }
        startLoop()
        guard CGPreflightScreenCaptureAccess() else {
            // The user just turned Integrity off, so asking now is user-initiated. macOS shows
            // its prompt once; afterwards the user grants it in System Settings.
            if requestPermission && !CGRequestScreenCaptureAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            pause(reason: "Capture blocked · Screen Recording permission missing; desired Integrity remains OFF")
            return false
        }
        if let reason = sessionBlockReason() { pause(reason: "Capture blocked · \(reason)"); return false }
        pause(reason: "Capture requested · waiting for verified eligible window")
        return true
    }

    func pause(reason: String = "Integrity mode · capture paused") {
        intent.block(reason: reason); advanceEpoch()
        checkpoint.clock.pause()
        Task { [store, checkpoint, authorization] in try? await store.saveCheckpoint(checkpoint, authorization: authorization) }
        safetyChanged(false)
        guard statusTransition.changed(state: "paused", reason: reason) else { return }
        status(reason)
        log.write(.capture, "paused: \(reason)")
        log.updateStatus(["capture": "paused", "capture_reason": reason])
        recordStatus("paused", reason)
    }

    func userPause() {
        intent.userSetIntegrity(true)
        loop?.cancel(); loop = nil
        pause()
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
        advanceEpoch()
        let token = generation
        let authorization = self.authorization
        guard enabled, ready, !storageBlocked, !Task.isCancelled else { return }
        guard lifecycleBlocks.isEmpty else { pause(reason: "Capture suspended · \(lifecycleBlocks.sorted().joined(separator: ", "))"); return }
        guard CGPreflightScreenCaptureAccess() else { pause(reason: "Capture paused · Screen Recording permission missing"); return }
        // Diagnostic observation only; never reused to authorize capture. Security
        // foregrounds can be vetoed by the session gate before app eligibility.
        let observed = foregroundTarget()
        if let message = exclusionDiagnostic.message(bundleID: observed.flatMap { $0.isEligible ? nil : $0.bundleID }) {
            log.write(.capture, message)
        }
        if let reason = sessionBlockReason() { pause(reason: "Capture blocked · \(reason)"); return }
        guard let target = foregroundTarget() else { await pauseClockForPrivacy("Capture enabled · foreground application is unknown"); return }
        guard target.isEligible else { await pauseClockForPrivacy("Capture enabled · foreground application is excluded"); return }
        intent.verifiedSafe()
        let previousClock = checkpoint.clock
        do {
            let (image, title) = try await captureWindow(target: target, token: token)
            guard accepts(token, target) else { return }
            let text = try await VisionTextRecognizer.recognize(image)
            guard accepts(token, target) else { return }
            let now = Date()
            safetyChanged(true)
            _ = statusTransition.changed(state: "running", reason: "")
            status("Capture running · verified eligible window")
            log.updateStatus(["capture": "running", "capture_reason": ""])
            recordStatus("running", "")
            _ = checkpoint.clock.recordEligibleSample(at: now)
            if !text.isEmpty && !isNearDuplicate(text, lastSavedOCR?.text) {
                let evidence = try await store.saveOCR(text: text, app: target.bundleID, title: title, timestamp: now, authorization: authorization)
                guard accepts(token, target) else { return }
                lastSavedOCR = evidence; checkpoint.ocr.append(evidence)
                log.write(.capture, "ocr saved id=\(evidence.id) app=\(target.bundleID) chars=\(text.count)")
                captured()
            } else if !text.isEmpty {
                log.write(.capture, "ocr skipped (>=90% same as last) app=\(target.bundleID)")
            }
            if checkpoint.images.count < checkpoint.clock.imageCountDue {
                guard let png = pngData(image) else { throw CaptureServiceError.imageEncoding }
                let saved = try await store.saveImage(data: png, timestamp: now, authorization: authorization)
                guard accepts(token, target) else { return }
                checkpoint.images.append(saved)
                log.write(.capture, "image saved id=\(saved.id) \(checkpoint.images.count)/30 active=\(Int(checkpoint.clock.activeSeconds))s")
                captured()
            }
            if checkpoint.startedAt == nil { checkpoint.startedAt = now }
            if checkpoint.clock.isComplete && checkpoint.images.count == 30 {
                // The server forms the batch from the uploaded images; the client starts a new window.
                let images = checkpoint.images.count, texts = checkpoint.ocr.count
                try await store.closeWindow(authorization: authorization)
                guard accepts(token, target) else { return }
                persistence.complete(authorization) {
                    log.write(.batch, "capture window complete images=\(images) ocr=\(texts)")
                }
            } else { try await store.saveCheckpoint(checkpoint, authorization: authorization) }
        } catch CaptureAuthorization.Revoked.invalidated { return }
        catch CaptureServiceError.superseded, is CancellationError { return }
        catch CaptureServiceError.noForegroundWindow {
            guard token == generation, enabled, !Task.isCancelled else { return }
            await handleFailure(.noForegroundWindow, reason: "No foreground window available · retrying")
        } catch let error as NSError where error.domain == SCStreamErrorDomain && error.code == -3811 {
            guard token == generation, enabled, !Task.isCancelled else { return }
            log.write(.error, "temporary acquisition failure: \(error.code)")
            await handleFailure(.screenCaptureTransient, reason: "Screen capture unavailable · retrying")
        } catch {
            guard token == generation, enabled, !Task.isCancelled else { return }
            log.write(.error, "capture failed: \(error)")
            checkpoint.clock = previousClock
            storageBlocked = true
            pause(reason: "Capture blocked · \(String(describing: error).prefix(300)); retry with an explicit OFF request after resolving the failure")
        }
    }

    private func handleFailure(_ failure: CaptureFailurePolicy.Failure, reason: String) async {
        switch CaptureFailurePolicy.action(failure) {
        case .retryGap:
            guard enabled, !Task.isCancelled else { return }
            await pauseClockForPrivacy(reason)
        case .safetyBlock: pause(reason: reason)
        }
    }

    private func pauseClockForPrivacy(_ message: String) async {
        let token = generation
        let authorization = self.authorization
        intent.block(reason: message)
        safetyChanged(false)
        if !checkpoint.clock.isPaused { log.write(.capture, "clock paused: \(message)") }
        checkpoint.clock.pause()
        do { try await store.saveCheckpoint(checkpoint, authorization: authorization) }
        catch CaptureAuthorization.Revoked.invalidated { return }
        catch {
            guard token == generation else { return }
            storageBlocked = true; pause(reason: "Capture blocked · evidence checkpoint is unsafe"); return
        }
        guard token == generation, enabled, !Task.isCancelled else { return }
        _ = statusTransition.changed(state: "gap", reason: message)
        status(message)
        log.updateStatus(["capture": "gap", "capture_reason": message])
        recordStatus("gap", message)
    }

    private func accepts(_ token: UInt64, _ target: ForegroundTarget) -> Bool {
        let safe = token == generation && intent.mayCapture && lifecycleBlocks.isEmpty && CGPreflightScreenCaptureAccess() && sessionBlockReason() == nil && foregroundTarget() == target
        if !safe && token == generation && enabled { pause(reason: "Capture suspended · permission, session or foreground changed") }
        return safe
    }

    private func foregroundTarget() -> ForegroundTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, !id.isEmpty, app.processIdentifier > 0 else { return nil }
        return ForegroundTarget(bundleID: id, processID: app.processIdentifier)
    }

    private func captureWindow(target: ForegroundTarget, token: UInt64) async throws -> (CGImage, String) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard accepts(token, target) else { throw CaptureServiceError.superseded }
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == target.processID && $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 }) else { throw CaptureServiceError.noForegroundWindow }
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
        let transitions: [(Notification.Name, Notification.Name, String)] = [
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session inactive"),
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "system asleep"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display asleep")]
        for (block, restore, reason) in transitions {
            observers.append(workspace.addObserver(forName: block, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lifecycleTransition(reason, blocked: true) } })
            observers.append(workspace.addObserver(forName: restore, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lifecycleTransition(reason, blocked: false) } })
        }
        for (block, restore, reason) in [("com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "screen locked"), ("com.apple.screensaver.didstart", "com.apple.screensaver.didstop", "screensaver active")] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(block), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lifecycleTransition(reason, blocked: true) } })
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(restore), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lifecycleTransition(reason, blocked: false) } })
        }
    }
}

private struct ForegroundTarget: Equatable {
    let bundleID: String; let processID: pid_t
    var isEligible: Bool {
        ForegroundCapturePolicy.isEligible(bundleID: bundleID)
    }
}
