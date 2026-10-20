import CoreGraphics
import Foundation

/// What to capture for one sample: the display holding the focused window, without the menu
/// bar and Dock, scaled to a bounded width, with every excluded app (and xCreen) removed.
/// Pure geometry and policy so it can be tested without ScreenCaptureKit.
public enum DisplayCapturePlan {
    /// Wider captures are scaled down: OCR stays reliable and attachments stay under Hermes's limit.
    public static let maximumWidth: CGFloat = 2560

    public struct Display: Equatable, Sendable {
        public let id: CGDirectDisplayID
        /// Global display coordinates, top-left origin (ScreenCaptureKit's `SCDisplay.frame`).
        public let frame: CGRect
        public init(id: CGDirectDisplayID, frame: CGRect) { self.id = id; self.frame = frame }
    }

    /// The display containing the focused window's centre; otherwise the one it overlaps most.
    public static func display(for windowFrame: CGRect, among displays: [Display]) -> Display? {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let containing = displays.first(where: { $0.frame.contains(center) }) { return containing }
        func overlap(_ display: Display) -> CGFloat {
            let shared = display.frame.intersection(windowFrame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        return displays.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
    }

    /// The display area without the menu bar and Dock, in display-local points with a top-left
    /// origin (`SCStreamConfiguration.sourceRect`). `frame` and `visibleFrame` are AppKit's
    /// `NSScreen` rects (bottom-left origin).
    public static func sourceRect(frame: CGRect, visibleFrame: CGRect) -> CGRect {
        let visible = visibleFrame.intersection(frame)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return CGRect(origin: .zero, size: frame.size) }
        return CGRect(x: visible.minX - frame.minX, y: frame.maxY - visible.maxY, width: visible.width, height: visible.height)
    }

    /// Output pixels: native (points × backing scale) up to `maximumWidth`, aspect preserved.
    public static func outputSize(for source: CGRect, backingScale: CGFloat, maximumWidth: CGFloat = maximumWidth) -> (width: Int, height: Int) {
        let scale = min(max(backingScale, 1), maximumWidth / max(source.width, 1))
        return (max(1, Int((source.width * scale).rounded())), max(1, Int((source.height * scale).rounded())))
    }

    /// Bundle ids removed from the frame: every app the foreground policy excludes, and xCreen.
    public static func excludedBundleIDs(running bundleIDs: [String]) -> Set<String> {
        Set(bundleIDs.filter { !ForegroundCapturePolicy.isEligible(bundleID: $0) || $0.lowercased() == "dev.xcreen.app" })
    }
}
