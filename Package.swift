// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "xCreen", platforms: [.macOS(.v14)], products: [.executable(name: "xCreen", targets: ["XCreenApp"])], targets: [.target(name: "XCreenCore"), .executableTarget(name: "XCreenApp", dependencies: ["XCreenCore"]), .testTarget(name: "XCreenCoreTests", dependencies: ["XCreenCore"])], swiftLanguageVersions: [.v5])
