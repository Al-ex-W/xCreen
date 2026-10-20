import CoreGraphics
import XCTest
@testable import XCreenCore

final class DisplayCapturePlanTests: XCTestCase {
    private let laptop = DisplayCapturePlan.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    private let external = DisplayCapturePlan.Display(id: 2, frame: CGRect(x: 1512, y: -300, width: 2560, height: 1440))

    func testPicksTheDisplayHoldingTheFocusedWindow() {
        XCTAssertEqual(DisplayCapturePlan.display(for: CGRect(x: 100, y: 100, width: 800, height: 600), among: [laptop, external]), laptop)
        XCTAssertEqual(DisplayCapturePlan.display(for: CGRect(x: 2000, y: 0, width: 800, height: 600), among: [laptop, external]), external)
        // Centre between displays: the one it overlaps most (external: 188x240 pt vs laptop: 212x82 pt).
        XCTAssertEqual(DisplayCapturePlan.display(for: CGRect(x: 1300, y: 900, width: 400, height: 400), among: [laptop, external]), external)
        XCTAssertNil(DisplayCapturePlan.display(for: CGRect(x: 9000, y: 9000, width: 10, height: 10), among: [laptop, external]))
    }

    func testCropRemovesMenuBarAndDock() {
        // AppKit coordinates: 1512x982 display, 33 pt menu bar at the top, 60 pt Dock at the bottom.
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 60, width: 1512, height: 982 - 33 - 60)
        XCTAssertEqual(DisplayCapturePlan.sourceRect(frame: frame, visibleFrame: visible), CGRect(x: 0, y: 33, width: 1512, height: 889))
        // Dock on the left of a secondary display.
        let second = CGRect(x: 1512, y: -300, width: 2560, height: 1440)
        let secondVisible = CGRect(x: 1512 + 70, y: -300, width: 2560 - 70, height: 1440 - 25)
        XCTAssertEqual(DisplayCapturePlan.sourceRect(frame: second, visibleFrame: secondVisible), CGRect(x: 70, y: 25, width: 2490, height: 1415))
    }

    func testOutputIsNativeUpToTheMaximumWidth() {
        let laptopSize = DisplayCapturePlan.outputSize(for: CGRect(x: 0, y: 33, width: 1512, height: 889), backingScale: 2)
        XCTAssertEqual(laptopSize.width, 2560)  // 3024 native would exceed the cap
        XCTAssertEqual(laptopSize.height, Int((889.0 * 2560 / 1512).rounded()))
        let small = DisplayCapturePlan.outputSize(for: CGRect(x: 0, y: 0, width: 1000, height: 500), backingScale: 2)
        XCTAssertEqual(small.width, 2000)
        XCTAssertEqual(small.height, 1000)
    }

    func testExcludedAppsAndXCreenAreRemovedFromTheFrame() {
        let running = ["com.apple.Safari", "com.1password.1password", "com.apple.systemsettings", "dev.xcreen.app", "com.apple.MobileSMS", "com.bitwarden.desktop"]
        XCTAssertEqual(DisplayCapturePlan.excludedBundleIDs(running: running), ["com.1password.1password", "com.apple.systemsettings", "dev.xcreen.app", "com.bitwarden.desktop"])
    }
}
