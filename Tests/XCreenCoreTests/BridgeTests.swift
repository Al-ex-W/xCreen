import XCTest
@testable import XCreenCore
final class BridgeTests: XCTestCase {
    func testProcessReturnsJSONAndRejectsErrorsWithoutLeakingStderr() async throws {
        let runner = BridgeRunner()
        let data = try await runner.run(executable: "/usr/bin/python3", arguments: ["-c", "import json,sys; print(json.dumps({'literal':sys.argv[1]}))", "$(not a shell)"])
        let result = try JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(result["literal"], "$(not a shell)")
        do {
            _ = try await BridgeRunner().run(executable: "/usr/bin/python3", arguments: ["-c", "import sys; print('PRIVATE',file=sys.stderr); sys.exit(3)"])
            XCTFail("Must fail closed")
        } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        let cancelled = BridgeRunner()
        cancelled.cancel()
        do {
            _ = try await cancelled.run(executable: "/usr/bin/python3", arguments: ["-c", "print('{}')"])
            XCTFail("Cancelled runner must never start")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testAskArgumentsPreserveLiteralQueryAndOptionalVault() {
        let settings = BridgeSettings(python: "/usr/bin/python3", script: "/a/bridge.py", hermes: "/bin/hermes", vault: "")
        XCTAssertEqual(settings.askArguments(query: "a ; $(secret)\n b", modelID: "chosen"), ["/a/bridge.py", "ask", "--query", "a ; $(secret)\n b", "--model-id", "chosen", "--hermes", "/bin/hermes"])
        var withVault = settings
        withVault.vault = "/vault with spaces"
        XCTAssertEqual(Array(withVault.askArguments(query: "q", modelID: "m").suffix(2)), ["--vault", "/vault with spaces"])
    }
    func testIngestUsesStdinInsteadOfProcessArguments() throws {
        let settings = BridgeSettings(python: "/usr/bin/python3", script: "/a/bridge.py", hermes: "")
        let request = IngestRequest(text: "private OCR", app: "Example", title: "Fixture")
        XCTAssertEqual(settings.ingestArguments, ["/a/bridge.py", "ingest", "--stdin-json"])
        let payload = try JSONEncoder().encode(request)
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("private OCR"))
        XCTAssertFalse(settings.ingestArguments.joined().contains("private OCR"))
    }
}
