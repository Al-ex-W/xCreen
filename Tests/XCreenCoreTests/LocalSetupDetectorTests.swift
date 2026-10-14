import XCTest
@testable import XCreenCore

final class LocalSetupDetectorTests: XCTestCase {
    func testParsesOfficialHermesRuntimeCommand() throws {
        let output = #"["/opt/py/bin/python3", "-I", "-c", "import os, sys; sys.path.insert(0, '/opt/hermes-agent'); import hermes_bootstrap"]"#
        let found = try XCTUnwrap(LocalSetupDetector.parseRuntimeCommand(Data(output.utf8)))
        XCTAssertEqual(found.python, "/opt/py/bin/python3")
        XCTAssertEqual(found.hermesRoot, "/opt/hermes-agent")
    }

    func testRejectsRuntimeCommandWithoutAbsolutePaths() {
        XCTAssertNil(LocalSetupDetector.parseRuntimeCommand(Data(#"["python3", "-c", "sys.path.insert(0, 'rel')"]"#.utf8)))
        XCTAssertNil(LocalSetupDetector.parseRuntimeCommand(Data("not json".utf8)))
    }

    func testPrefersOpenObsidianVaultWithDailyFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-vaults-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("Plain"), life = root.appendingPathComponent("Life")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: life.appendingPathComponent("Daily"), withIntermediateDirectories: true)
        let json = """
        {"vaults":{"a":{"path":"\(plain.path)","ts":9,"open":true},"b":{"path":"\(life.path)","ts":1}}}
        """
        XCTAssertEqual(LocalSetupDetector.parseObsidianVaults(Data(json.utf8)), life.path)
    }

    func testFallsBackToOpenThenNewestVault() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-vaults-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Old"), new = root.appendingPathComponent("New")
        for url in [old, new] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let json = #"{"vaults":{"a":{"path":"\#(old.path)","ts":1},"b":{"path":"\#(new.path)","ts":5},"c":{"path":"/does/not/exist","ts":99,"open":true}}}"#
        XCTAssertEqual(LocalSetupDetector.parseObsidianVaults(Data(json.utf8)), new.path)
    }
}
