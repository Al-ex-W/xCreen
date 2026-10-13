import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import XCreenCore

private enum CaptureServiceError: Error {
    case noForegroundWindow
    case emptyOCR
    case superseded
}

private enum VisionTextRecognizer {
    static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let text = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw CaptureServiceError.emptyOCR }
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
final class CaptureService {
    private var policy = CapturePolicy()
    private var loop: Task<Void, Never>?
    private var activeRunner: BridgeRunner?
    private var observers: [NSObjectProtocol] = []
    private let settings: () -> BridgeSettings
    private let status: (String) -> Void
    private let integrityChanged: (Bool) -> Void

    init(
        settings: @escaping () -> BridgeSettings,
        status: @escaping (String) -> Void,
        integrityChanged: @escaping (Bool) -> Void
    ) {
        self.settings = settings
        self.status = status
        self.integrityChanged = integrityChanged
        installLifecycleObservers()
    }

    @discardableResult
    func enableAfterExplicitConsent() -> Bool {
        // Preflight never asks for TCC permission. The preview deliberately has
        // no CGRequestScreenCaptureAccess call and cannot prompt during development.
        guard CGPreflightScreenCaptureAccess() else {
            failClosed("Capture remains paused · enable Screen Recording in System Settings, then opt in again")
            return false
        }
        // The preview has no public, synchronous current-lock-state assertion.
        // Opt-in and lifecycle notifications are not evidence that the session is
        // currently unlocked, so policy keeps Integrity mode on.
        guard policy.optIn(permission: true, lockState: currentLockState()) else {
            integrityChanged(true)
            status("Capture unavailable · current lock state cannot be verified in this preview")
            return false
        }
        integrityChanged(false)
        status("Capture enabled · permitted foreground window every 30 seconds")
        loop?.cancel()
        loop = Task { [weak self] in
            guard let self else { return }
            await self.captureOnce()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: CapturePolicy.intervalSeconds * 1_000_000_000)
                } catch { return }
                await self.captureOnce()
            }
        }
        return true
    }

    func pause(reason: String = "Integrity mode · capture paused") {
        failClosed(reason)
    }

    private func failClosed(_ message: String) {
        loop?.cancel()
        loop = nil
        activeRunner?.cancel()
        activeRunner = nil
        policy.failClosed()
        integrityChanged(true)
        status(message)
    }

    private func captureOnce() async {
        guard !Task.isCancelled else { return }
        guard CGPreflightScreenCaptureAccess() else {
            failClosed("Capture paused · Screen Recording permission unavailable")
            return
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        guard idle.isFinite, idle >= 0, idle < 120 else {
            failClosed("Capture paused · session idle state is unsafe")
            return
        }
        guard let target = currentForegroundTarget() else {
            failClosed("Capture paused · foreground application is unknown")
            return
        }
        guard let token = policy.begin(
            bundleID: target.bundleID,
            processID: target.processID,
            idleSeconds: idle,
            lockState: currentLockState()
        ) else {
            status("Capture enabled · foreground application is excluded")
            return
        }

        do {
            let (image, title) = try await captureForegroundWindow(target: target, token: token)
            // The image may have arrived after focus changed. Do not OCR stale work.
            guard acceptsCurrentWork(token: token, target: target) else { return }
            let text = try await VisionTextRecognizer.recognize(image)
            guard acceptsCurrentWork(token: token, target: target) else { return }

            let saved = settings()
            let request = IngestRequest(
                text: InputBounds.prefix(text, maxUnicodeScalars: 12_000),
                app: InputBounds.prefix(target.bundleID, maxUnicodeScalars: 256),
                title: InputBounds.prefix(title, maxUnicodeScalars: 1_024)
            )
            let payload = try JSONEncoder().encode(request)
            let runner = BridgeRunner()
            activeRunner = runner
            // Last check before handing OCR to the ingestion subprocess.
            guard acceptsCurrentWork(token: token, target: target) else {
                activeRunner = nil
                return
            }
            _ = try await runner.run(
                executable: saved.python,
                arguments: saved.ingestArguments,
                input: payload,
                timeout: 15
            )
            activeRunner = nil
            guard acceptsCurrentWork(token: token, target: target) else { return }
            status("Capture enabled · last local OCR indexed")
        } catch CaptureServiceError.emptyOCR {
            status("Capture enabled · no text recognized in permitted window")
        } catch CaptureServiceError.noForegroundWindow {
            status("Capture enabled · no permitted foreground window")
        } catch CaptureServiceError.superseded {
            // Focus or policy changed while awaiting ScreenCaptureKit; discard it.
            return
        } catch is CancellationError {
            activeRunner = nil
            // A policy transition owns the user-visible status.
        } catch {
            activeRunner = nil
            failClosed("Capture paused · capture, OCR, or local indexing failed")
        }
    }

    private func currentIdleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
    }

    private func currentLockState() -> CaptureLockState {
        // Notifications only invalidate known work. They cannot establish a
        // current unlocked state after an opt-in, wake, or missed notification.
        .unknown
    }

    private func currentForegroundTarget() -> CaptureTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleID = application.bundleIdentifier, !bundleID.isEmpty,
              application.processIdentifier > 0 else { return nil }
        return CaptureTarget(bundleID: bundleID, processID: application.processIdentifier)
    }

    private func acceptsCurrentWork(token: UInt64, target: CaptureTarget) -> Bool {
        guard currentForegroundTarget() == target else { return false }
        return policy.accepts(
            token,
            bundleID: target.bundleID,
            processID: target.processID,
            idleSeconds: currentIdleSeconds(),
            lockState: currentLockState()
        )
    }

    private func captureForegroundWindow(target: CaptureTarget, token: UInt64) async throws -> (CGImage, String) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.map {
            WindowCandidate(
                id: $0.windowID,
                pid: $0.owningApplication?.processID ?? -1,
                layer: $0.windowLayer,
                width: $0.frame.width,
                height: $0.frame.height
            )
        }
        guard let windowID = WindowSelection.frontmost(candidates, pid: target.processID),
              let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureServiceError.noForegroundWindow
        }
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let rawWidth = max(1, Int(window.frame.width * scale))
        let rawHeight = max(1, Int(window.frame.height * scale))
        let reduction = max(1, Int(ceil(Double(max(rawWidth, rawHeight)) / 4_096)))
        configuration.width = rawWidth / reduction
        configuration.height = rawHeight / reduction
        configuration.showsCursor = false
        // Shareable-content discovery is asynchronous; focus must still be the
        // same app immediately before creating a window filter.
        guard acceptsCurrentWork(token: token, target: target) else {
            throw CaptureServiceError.superseded
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard acceptsCurrentWork(token: token, target: target) else {
            throw CaptureServiceError.superseded
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (image, window.title ?? "")
    }

    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.failClosed("Capture paused · session inactive or display asleep") }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for rawName in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observers.append(distributed.addObserver(
                forName: Notification.Name(rawName), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.failClosed("Capture paused · screen locked") }
            })
        }
    }
}
