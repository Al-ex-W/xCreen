// Dev-only renderer for docs/assets. Renders the real tray `Panel` view offscreen with a
// clearly synthetic demo model. It never captures the screen, never starts capture, the
// gateway or the evidence store, and reads no user data.
import AppKit
import SwiftUI
import XCreenCore
import XCreenUI

@MainActor final class DemoTrayModel: TrayPanelModel {
    @Published var integrity = false
    let captureStatus = "Capture running · verified eligible window"
    let sessionVisible = false
    let visibilityStatus = "Confirmed by Hermes for this session."
    let hermesModels = [
        HermesModelRoute(provider: "anthropic", model: "claude-haiku-5-5"),
        HermesModelRoute(provider: "anthropic", model: "claude-sonnet-5"),
    ]
    let selectedHermesModel = "anthropic::claude-haiku-5-5"
    let modelDefaultStatus = "xCreen default: anthropic · claude-haiku-5-5. Applied to the xCreen session."
    @Published var query = "What was I working on before lunch?"
    var canAsk: Bool { !query.isEmpty }
    let connected = true
    let submissionMessage = "Hermes response complete."
    let lastQuestion = ""
    let streamedReply = """
    From about 10:05 to 11:50 you were mostly in Xcode on the demo app's onboarding screen, \
    fixing the layout of the permissions step. Around 11:20 you read the SwiftUI Layout docs in \
    Safari, and your last edit before lunch was OnboardingView.swift. One screenshot is attached.
    """
    let appendix: [EvidenceImage]
    let batchMetadata = ""
    let batchCursor = ""
    @Published var showSettings = false
    @Published var hermesPython = ""
    @Published var hermesRoot = ""
    @Published var vaultPath = ""
    let status = "Hermes connected · xCreen session"

    init() {
        var parts = DateComponents(); parts.year = 2026; parts.month = 1; parts.day = 1; parts.hour = 11; parts.minute = 42; parts.second = 10
        let when = Calendar.current.date(from: parts) ?? Date(timeIntervalSince1970: 0)
        // Deliberately nonexistent file: the panel draws its placeholder tile, no pixels are read.
        appendix = [EvidenceImage(id: "demo-attachment", timestamp: when, fileURL: URL(fileURLWithPath: "/nonexistent/xcreen-demo/placeholder.png"))]
    }

    func submitQuestion() {}
    func runControl(_ fields: [String: String]) {}
    func switchHermesModel(_ routeID: String) {}
    func autodetectLocalSetup(overwrite: Bool) {}
    func saveHermesExecutable() {}
}

@MainActor func render(to output: URL, scale: CGFloat) throws {
    let model = DemoTrayModel()
    let host = NSHostingView(rootView: Panel(state: model).environment(\.colorScheme, .dark))
    host.appearance = NSAppearance(named: .darkAqua)
    let size = host.fittingSize
    // Offscreen, borderless window: provides a real AppKit backing so native controls draw.
    // It is positioned far off-screen and never ordered front; nothing on screen is read.
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    host.display()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded()

    let pixelsWide = Int(size.width * scale), pixelsHigh = Int(size.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = size // points; pixel dimensions carry the 2x scale
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: output)
    print("wrote \(output.path) \(pixelsWide)x\(pixelsHigh) px (\(Int(size.width))x\(Int(size.height)) pt @\(Int(scale))x)")
}

/// 1280x640 social preview: dark card, name, tagline and the rendered tray composited right.
@MainActor func renderSocial(tray trayURL: URL, to output: URL) throws {
    let width = 1280, height = 640
    guard let tray = NSImage(contentsOf: trayURL), let trayCG = tray.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileReadCorruptFile) }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let full = CGRect(x: 0, y: 0, width: width, height: height)

    // Background: near-black vertical gradient with a soft blue glow behind the tray.
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.075, green: 0.082, blue: 0.105, alpha: 1), CGColor(red: 0.035, green: 0.039, blue: 0.051, alpha: 1)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(background, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
    let glow = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.20, green: 0.45, blue: 1.0, alpha: 0.28), CGColor(red: 0.20, green: 0.45, blue: 1.0, alpha: 0)] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 1000, y: 330), startRadius: 0, endCenter: CGPoint(x: 1000, y: 330), endRadius: 420, options: [])
    cg.setStrokeColor(CGColor(gray: 1, alpha: 0.06)); cg.setLineWidth(2); cg.stroke(full.insetBy(dx: 1, dy: 1))

    // Tray: crop the 2x render just below the attachment row (header → Q&A → attachment),
    // scale it into the right column, then round, shadow and outline it.
    let cropPoints: CGFloat = 664 // ends below the attachment timestamp; omits batches/settings/footer
    guard let cropped = trayCG.cropping(to: CGRect(x: 0, y: 0, width: trayCG.width, height: min(trayCG.height, Int(cropPoints * 2)))) else { throw CocoaError(.fileReadCorruptFile) }
    let trayHeight: CGFloat = 548
    let trayWidth = trayHeight * CGFloat(cropped.width) / CGFloat(cropped.height)
    let trayRect = CGRect(x: CGFloat(width) - trayWidth - 76, y: (CGFloat(height) - trayHeight) / 2 + 10, width: trayWidth, height: trayHeight)
    let path = CGPath(roundedRect: trayRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: CGColor(gray: 0, alpha: 0.65))
    cg.addPath(path); cg.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)); cg.fillPath()
    cg.restoreGState()
    cg.saveGState(); cg.addPath(path); cg.clip()
    cg.interpolationQuality = .high
    cg.draw(cropped, in: trayRect)
    cg.restoreGState()
    cg.addPath(path); cg.setStrokeColor(CGColor(gray: 1, alpha: 0.14)); cg.setLineWidth(1); cg.strokePath()

    // Text column.
    func draw(_ text: String, _ font: NSFont, _ color: NSColor, at origin: CGPoint, width: CGFloat, kern: CGFloat = 0) -> CGFloat {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping; style.lineSpacing = 4
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style, .kern: kern])
        let bounds = string.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading])
        string.draw(with: NSRect(x: origin.x, y: origin.y - bounds.height, width: width, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return bounds.height
    }
    let left: CGFloat = 80, column: CGFloat = 660
    var y: CGFloat = 486
    if let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 50, weight: .regular).applying(.init(paletteColors: [NSColor(red: 0.35, green: 0.62, blue: 1, alpha: 1)]))) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: left, y: y - size.height + 4, width: size.width, height: size.height))
        _ = draw("xCreen", .systemFont(ofSize: 76, weight: .bold), .white, at: CGPoint(x: left + size.width + 18, y: y + 24), width: column, kern: -1.5)
    }
    y -= 96
    y -= draw("Open-source screen memory\nfor macOS", .systemFont(ofSize: 40, weight: .semibold), NSColor(white: 0.94, alpha: 1), at: CGPoint(x: left, y: y), width: column)
    y -= 20
    y -= draw("Local OCR + screenshots \u{2192} insights\nin your Obsidian daily notes", .systemFont(ofSize: 26, weight: .regular), NSColor(white: 0.64, alpha: 1), at: CGPoint(x: left, y: y), width: column)
    y -= 34
    _ = draw("github.com/Al-ex-W/xCreen", .monospacedSystemFont(ofSize: 19, weight: .regular), NSColor(red: 0.45, green: 0.68, blue: 1, alpha: 0.95), at: CGPoint(x: left, y: y), width: column)
    _ = draw("UI rendered from synthetic demo data", .systemFont(ofSize: 13, weight: .regular), NSColor(white: 0.50, alpha: 1), at: CGPoint(x: trayRect.minX, y: trayRect.minY - 12), width: trayWidth)

    context.flushGraphics()
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: output)
    print("wrote \(output.path) \(rep.pixelsWide)x\(rep.pixelsHigh) px")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let args = Array(CommandLine.arguments.dropFirst())
    do {
        if args.first == "--social" {
            guard args.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
            try renderSocial(tray: URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2]))
        } else {
            try render(to: URL(fileURLWithPath: args.first ?? "docs/assets/tray.png"), scale: 2)
        }
    } catch { FileHandle.standardError.write(Data("render failed: \(error)\n".utf8)); exit(1) }
}
