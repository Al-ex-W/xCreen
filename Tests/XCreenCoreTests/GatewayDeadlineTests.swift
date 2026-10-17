import XCTest
@testable import XCreenCore

/// A long Hermes RPC (compaction before a turn) must not be reported as a failure while
/// the gateway is still emitting progress events; a truly silent gateway still fails.
final class GatewayDeadlineTests: XCTestCase {
    func testSlowButProgressingCompactionSucceeds() async throws {
        let (script, root) = try makeScript(progress: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = HermesGateway(defaultDeadline: 0.6, longDeadline: 30)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        let data = try await gateway.compactHard(sessionID: "runtime-xcreen", keepLast: 2)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["focus_topic"] as? String, "here 2")
        await gateway.stop()
    }

    func testSilentCompactionStillFailsWithDeadlineError() async throws {
        let (script, root) = try makeScript(progress: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = HermesGateway(defaultDeadline: 0.6, longDeadline: 30)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        do { _ = try await gateway.compactHard(sessionID: "runtime-xcreen", keepLast: 2); XCTFail("expected deadline") }
        catch { XCTAssertEqual(error as? HermesGatewayError, .deadlineExceeded) }
        await gateway.stop()
    }

    func testSlowButProgressingPromptSubmitSucceeds() async throws {
        let (script, root) = try makeScript(progress: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = HermesGateway(defaultDeadline: 0.6, longDeadline: 30)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        _ = try await gateway.submit(sessionID: "runtime-xcreen", text: "what am i doing right now")
        await gateway.stop()
    }

    func testSilentPromptSubmitFailsWithExistingDeadlineError() async throws {
        let (script, root) = try makeScript(progress: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = HermesGateway(defaultDeadline: 0.6, longDeadline: 30)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        do { _ = try await gateway.submit(sessionID: "runtime-xcreen", text: "hello"); XCTFail("expected deadline") }
        catch { XCTAssertEqual(error as? HermesGatewayError, .deadlineExceeded); XCTAssertEqual(error.localizedDescription, "Hermes gateway did not answer before the deadline.") }
        await gateway.stop()
    }

    func testProgressCannotExtendPastLongDeadline() async throws {
        let (script, root) = try makeScript(progress: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = HermesGateway(defaultDeadline: 0.6, longDeadline: 1.0)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        do { _ = try await gateway.compactHard(sessionID: "runtime-xcreen", keepLast: 2); XCTFail("expected hard cap") }
        catch { XCTAssertEqual(error as? HermesGatewayError, .deadlineExceeded) }
        await gateway.stop()
    }

    private func makeScript(progress: Bool) throws -> (URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-deadline-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("tui_gateway", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("__init__.py"))
        let url = package.appendingPathComponent("entry.py")
        let source = #"""
import json, sys, time
PROGRESS = \#(progress ? "True" : "False")
def send(o): print(json.dumps(o), flush=True)
send({"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}})
for line in sys.stdin:
    request = json.loads(line); rid = request.get("id"); method = request.get("method")
    if method in ("session.compress", "prompt.submit"):
        for _ in range(8):  # ~2.4 s total, far beyond the 0.6 s idle deadline
            time.sleep(0.3)
            if PROGRESS: send({"jsonrpc":"2.0","method":"event","params":{"type":"status.update","session_id":"runtime-xcreen","payload":{"kind":"compressing"}}})
        result = {"focus_topic": request["params"].get("focus_topic"), "removed": 10}
    else: result = {}
    send({"jsonrpc":"2.0","id":rid,"result":result})
"""#
        try source.write(to: url, atomically: true, encoding: .utf8)
        return (url, root)
    }
}
