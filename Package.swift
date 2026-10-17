// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "xCreen",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "xCreen", targets: ["XCreenApp"])],
    targets: [
        .target(name: "XCreenCore"),
        .target(name: "XCreenUI", dependencies: ["XCreenCore"]),
        .executableTarget(name: "XCreenApp", dependencies: ["XCreenCore", "XCreenUI"]),
        // Dev-only: renders the tray panel with synthetic demo state for docs/assets. Not bundled.
        .executableTarget(name: "XCreenScreenshots", dependencies: ["XCreenCore", "XCreenUI"]),
        .testTarget(name: "XCreenCoreTests", dependencies: ["XCreenCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
